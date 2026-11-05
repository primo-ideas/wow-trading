#!/usr/bin/env bash
#
# Installs or updates WoW Trading on Ubuntu 26.04: Postgres, the fetcher on a systemd
# timer, the site, and Caddy if given a domain. Safe to run again after a `git pull`.
#
#   sudo ./deploy/install.sh                                # site on 127.0.0.1:3000
#   sudo DOMAIN=trading.example.com ./deploy/install.sh     # site on https://trading.example.com
#   sudo DOMAIN=example.com BASE_PATH=/wow-trading ./deploy/install.sh     # next to other sites
#
# Options, as environment variables. DOMAIN and BASE_PATH are kept for the next runs:
#   DOMAIN        Public domain of the site. Its DNS must already point to this server.
#   BASE_PATH     Path of the site on that domain, when it shares it. Needed if Apache
#                 already runs here: it then gets a route to the site, and nothing else changes.
#   SCOPE         What to fetch on a first install, by default eu/commodities.
#   POLL_MINUTES  Minutes between two cycles, by default 5.
#
# See deploy/README.md.
set -euo pipefail

SCOPE="${SCOPE:-eu/commodities}"
POLL_MINUTES="${POLL_MINUTES:-5}"
DOMAIN="${DOMAIN:-}"
BASE_PATH="${BASE_PATH:-}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=/opt/wow-trading
ETC=/etc/wow-trading
FETCHER_ENV="$ETC/fetcher.env"
SITE_ENV="$ETC/site.env"
SERVICE_USER=wowtrading
OWNER_ROLE=wowtrading
SITE_ROLE=wowtrading_site
DATABASE=wow_trading
# Below this much memory and without swap, compiling can get killed.
SWAP_BELOW_MB=4000
SWAP_FILE=/swapfile
MAX_BUILD_JOBS=4
# A disk too small for the defaults: less swap and write-ahead log, a shorter hourly
# history, and no compiler left behind once the fetcher is built.
if [ "$(df --output=size -BG / | tail -n 1 | tr -dc 0-9)" -lt 16 ]; then
  SMALL_DISK=1 SWAP_SIZE=1G MAX_WAL_SIZE=256MB RETENTION_DAYS=7
else
  SMALL_DISK="" SWAP_SIZE=2G MAX_WAL_SIZE=1GB RETENTION_DAYS=14
fi

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this as root: sudo $0"
[ -f "$REPO/Cargo.toml" ] && [ -d "$REPO/web" ] || die "run this from a copy of the repository"
case "$POLL_MINUTES" in
  ''|*[!0-9]*) die "POLL_MINUTES must be a number of minutes" ;;
esac
[ "$POLL_MINUTES" -ge 1 ] && [ "$POLL_MINUTES" -le 59 ] || die "POLL_MINUTES must be between 1 and 59"
[[ "$BASE_PATH" =~ ^(/[A-Za-z0-9_-]+)*$ ]] || die "BASE_PATH must look like /wow-trading"

. /etc/os-release
[ "${VERSION_ID:-}" = "26.04" ] || printf 'warning: written for Ubuntu 26.04, this is %s\n' "${PRETTY_NAME:-unknown}" >&2

# Whoever ran sudo builds: compiling dependencies does not need to happen as root.
BUILD_USER="${SUDO_USER:-root}"
BUILD_HOME="$(getent passwd "$BUILD_USER" | cut -d: -f6)"
# sudo may leave HOME on root's, where rustup could not write.
as_builder() { runuser -u "$BUILD_USER" -- env -C "$REPO" HOME="$BUILD_HOME" "$@"; }

ensure_packages() {
  step "Installing packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # Not the `cargo` package: sqlx needs a newer Rust than Ubuntu 26.04 has, so rustup
  # installs the version named in rust-toolchain.toml.
  apt-get install -y -qq \
    build-essential cmake pkg-config git curl openssl ca-certificates tzdata \
    postgresql rustup \
    ruby ruby-dev libpq-dev libyaml-dev zlib1g-dev
}

ensure_swap() {
  local memory_mb
  memory_mb="$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)"
  if [ "$memory_mb" -ge "$SWAP_BELOW_MB" ] || [ -n "$(swapon --noheadings)" ]; then
    return
  fi
  step "Adding $SWAP_SIZE of swap ($memory_mb MB of memory)"
  if [ ! -f "$SWAP_FILE" ]; then
    fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null
  fi
  swapon "$SWAP_FILE"
  grep -q "^$SWAP_FILE " /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
}

ensure_user() {
  id -u "$SERVICE_USER" >/dev/null 2>&1 || \
    useradd --system --home-dir "$APP" --shell /usr/sbin/nologin "$SERVICE_USER"
  install -d -m 755 "$APP" "$APP/bin"
  install -d -m 750 -o root -g "$SERVICE_USER" "$ETC"
}

psql_as_admin() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q "$@"; }

role_exists() {
  [ "$(psql_as_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$1'")" = "1" ]
}

# Creates a role with a new password, written to stdout, if it does not exist yet.
ensure_role() {
  local role="$1" password
  if role_exists "$role"; then
    return
  fi
  password="$(openssl rand -hex 24)"
  psql_as_admin -c "CREATE ROLE $role LOGIN PASSWORD '$password'"
  printf '%s' "$password"
}

value_of() { sed -n "s/^$1=//p" "$2" | tail -n 1; }

# What an earlier run was given, so that `git pull && ./deploy/install.sh` keeps it.
load_saved_settings() {
  [ -f "$SITE_ENV" ] || return 0
  [ -n "$DOMAIN" ] || DOMAIN="$(value_of SITE_HOST "$SITE_ENV")"
  [ -n "$BASE_PATH" ] || BASE_PATH="$(value_of RAILS_RELATIVE_URL_ROOT "$SITE_ENV")"
}

# An install from when the project was called wow-market. Installing next to it would
# start from an empty database while its services kept the port and the history. Its
# directories move last, so that a run stopped halfway comes back here and finishes.
rename_old_install() {
  [ -d /opt/wow-market ] || [ -d /etc/wow-market ] || return 0
  step "Renaming the existing wow-market install to wow-trading"

  systemctl disable --now wow-market-fetcher.timer wow-market-fetcher.service wow-market-site.service 2>/dev/null || true
  rm -f /etc/systemd/system/wow-market-fetcher.timer /etc/systemd/system/wow-market-fetcher.service \
    /etc/systemd/system/wow-market-site.service
  systemctl daemon-reload

  if id -u wowmarket >/dev/null 2>&1; then
    usermod --login "$SERVICE_USER" --home "$APP" wowmarket
    groupmod --new-name "$SERVICE_USER" wowmarket
  fi

  systemctl start postgresql
  # SCRAM passwords survive a rename, which is what Ubuntu's Postgres uses by default.
  if role_exists wowmarket; then
    psql_as_admin -c "ALTER ROLE wowmarket RENAME TO $OWNER_ROLE"
  fi
  if role_exists wowmarket_site; then
    psql_as_admin -c "ALTER ROLE wowmarket_site RENAME TO $SITE_ROLE"
  fi
  if [ "$(psql_as_admin -tAc "SELECT 1 FROM pg_database WHERE datname = 'wow_market'")" = "1" ]; then
    psql_as_admin -c "ALTER DATABASE wow_market RENAME TO $DATABASE"
  fi
  # ensure_database writes it again under its new name.
  rm -f /etc/postgresql/*/main/conf.d/wow-market.conf

  local file
  for file in /etc/wow-market/fetcher.env /etc/wow-market/site.env; do
    if [ -f "$file" ]; then
      sed -i -E 's#^(DATABASE_URL=postgres://)wowmarket(_site)?:(.*/)wow_market$#\1wowtrading\2:\3wow_trading#' "$file"
    fi
  done

  if [ -d /etc/wow-market ]; then
    mv /etc/wow-market "$ETC"
  fi
  if [ -d /opt/wow-market ]; then
    mv /opt/wow-market "$APP"
  fi
}

ensure_database() {
  step "Setting up Postgres"
  systemctl enable --now postgresql

  local owner_password site_password
  owner_password="$(ensure_role "$OWNER_ROLE")"
  site_password="$(ensure_role "$SITE_ROLE")"

  if [ "$(psql_as_admin -tAc "SELECT 1 FROM pg_database WHERE datname = '$DATABASE'")" != "1" ]; then
    runuser -u postgres -- createdb --owner "$OWNER_ROLE" --encoding UTF8 --locale C --template template0 "$DATABASE"
  fi

  # The site can read whatever the fetcher creates, including its daily partitions, and nothing else.
  psql_as_admin -d "$DATABASE" <<SQL
GRANT CONNECT ON DATABASE $DATABASE TO $SITE_ROLE;
GRANT USAGE ON SCHEMA public TO $SITE_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO $SITE_ROLE;
ALTER DEFAULT PRIVILEGES FOR ROLE $OWNER_ROLE IN SCHEMA public GRANT SELECT ON TABLES TO $SITE_ROLE;
SQL

  local version conf memory_mb shared_buffers
  version="$(psql_as_admin -tAc "SHOW server_version_num" | cut -c1-2)"
  conf="/etc/postgresql/$version/main/conf.d/wow-trading.conf"
  memory_mb="$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)"
  shared_buffers=$(( memory_mb / 4 ))
  # Losing the last commits in a crash is fine: the next cycle gets those snapshots again.
  cat > "$conf" <<CONF
# Written by deploy/install.sh.
shared_buffers = ${shared_buffers}MB
effective_cache_size = $(( memory_mb / 2 ))MB
max_wal_size = $MAX_WAL_SIZE
synchronous_commit = off
CONF
  systemctl restart postgresql

  # Credentials are kept across runs: an update must not need them typed again.
  if [ ! -f "$FETCHER_ENV" ]; then
    [ -n "$owner_password" ] || die "role $OWNER_ROLE exists but $FETCHER_ENV does not: restore it, or drop the role"
    install -m 640 -o root -g "$SERVICE_USER" /dev/null "$FETCHER_ENV"
    cat > "$FETCHER_ENV" <<ENV
# Create a client on https://develop.battle.net/access/clients
BLIZZARD_CLIENT_ID=
BLIZZARD_CLIENT_SECRET=

# What to fetch: eu, eu/hyjal, eu/commodities, or several separated by commas.
# Each market takes around 1 GB of disk: see deploy/README.md before adding many.
WOW_SCOPE=$SCOPE
WOW_LOCALE=en_US
WOW_HOURLY_RETENTION_DAYS=$RETENTION_DAYS

DATABASE_URL=postgres://$OWNER_ROLE:$owner_password@127.0.0.1:5432/$DATABASE
ENV
  fi

  if [ ! -f "$SITE_ENV" ]; then
    [ -n "$site_password" ] || die "role $SITE_ROLE exists but $SITE_ENV does not: restore it, or drop the role"
    install -m 640 -o root -g "$SERVICE_USER" /dev/null "$SITE_ENV"
    cat > "$SITE_ENV" <<ENV
DATABASE_URL=postgres://$SITE_ROLE:$site_password@127.0.0.1:5432/$DATABASE
SECRET_KEY_BASE=$(openssl rand -hex 64)
ENV
  fi

  # Set on every run, as a domain can be added later.
  sed -i '/^SITE_HOST=/d;/^RAILS_RELATIVE_URL_ROOT=/d' "$SITE_ENV"
  if [ -n "$DOMAIN" ]; then
    echo "SITE_HOST=$DOMAIN" >> "$SITE_ENV"
  fi
  if [ -n "$BASE_PATH" ]; then
    echo "RAILS_RELATIVE_URL_ROOT=$BASE_PATH" >> "$SITE_ENV"
  fi
}

# Each compiler can take over a gigabyte: fewer at a time is slower, but it finishes.
build_jobs() {
  local memory_mb jobs
  memory_mb="$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)"
  jobs=$(( memory_mb / 1500 + 1 ))
  [ "$jobs" -le "$(nproc)" ] || jobs="$(nproc)"
  [ "$jobs" -le "$MAX_BUILD_JOBS" ] || jobs="$MAX_BUILD_JOBS"
  printf '%s' "$jobs"
}

fetcher_sources_hash() {
  (cd "$REPO" && find fetcher Cargo.toml Cargo.lock rust-toolchain.toml -type f -print0 |
    sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}

build_fetcher() {
  local hash toolchain
  hash="$(fetcher_sources_hash)"
  # Without a change there, an update of the site need not take a compilation.
  if [ -x "$APP/bin/wow-trading-fetcher" ] && [ "$(cat "$APP/bin/.sources-hash" 2>/dev/null)" = "$hash" ]; then
    step "The fetcher has not changed: not building it again"
    return
  fi

  step "Building the fetcher (several minutes the first time, more on a small server)"
  toolchain="$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$REPO/rust-toolchain.toml")"
  [ -n "$toolchain" ] || die "no toolchain named in rust-toolchain.toml"

  as_builder rustup toolchain install "$toolchain" --profile minimal --no-self-update
  # `rustup run` rather than `cargo`, which the rustup package may not put on the PATH.
  as_builder rustup run "$toolchain" cargo build --release --locked --jobs "$(build_jobs)" -p wow-trading-fetcher
  install -m 755 "$REPO/target/release/wow-trading-fetcher" "$APP/bin/wow-trading-fetcher"
  printf '%s' "$hash" > "$APP/bin/.sources-hash"

  # All of this comes back at the next build, which then only costs time.
  if [ -n "$SMALL_DISK" ]; then
    step "Removing the compiler and its output, as this disk is small"
    rm -rf "$REPO/target" "$BUILD_HOME/.cargo/registry"
    as_builder rustup toolchain uninstall "$toolchain"
    apt-get clean
  fi
}

build_site() {
  step "Building the site"
  install -d -m 755 "$APP/web"
  # A clean copy, keeping only the gems already installed.
  find "$APP/web" -mindepth 1 -maxdepth 1 ! -name vendor -exec rm -rf {} +
  tar -C "$REPO/web" --exclude=./log --exclude=./tmp --exclude=./vendor --exclude=./test -cf - . | tar -C "$APP/web" -xf -
  install -d -m 755 "$APP/web/vendor" "$APP/web/.bundle"
  install -d -m 755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$APP/web/tmp" "$APP/web/log"

  (
    cd "$APP/web"
    # Ubuntu's Ruby may know of Bundler without a `bundle` command: install the one the
    # lockfile names, so that it does not try to swap itself for it at each start.
    local bundler_version
    bundler_version="$(sed -n '/^BUNDLED WITH$/{n;s/ *//p}' Gemfile.lock)"
    [ -n "$bundler_version" ] || die "no Bundler version named in Gemfile.lock"
    gem list --installed --exact bundler --version "$bundler_version" >/dev/null 2>&1 ||
      gem install --no-document bundler --version "$bundler_version"
    export BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT=development:test BUNDLE_PATH=vendor/bundle
    bundle config set --local deployment true
    bundle config set --local without development:test
    bundle config set --local path vendor/bundle
    bundle install --quiet --jobs "$(build_jobs)"
    # Compiling assets touches neither the database nor the secret, but Rails wants both set.
    # The path matters here: compiled stylesheets refer to their fonts by full path.
    RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 DATABASE_URL=postgres://unused/unused \
      RAILS_RELATIVE_URL_ROOT="$BASE_PATH" bundle exec rails assets:precompile
  )
}

install_units() {
  step "Installing the systemd units"
  install -m 644 "$REPO/deploy/wow-trading-fetcher.service" /etc/systemd/system/
  install -m 644 "$REPO/deploy/wow-trading-site.service" /etc/systemd/system/
  sed "s|^OnCalendar=.*|OnCalendar=*:0/$POLL_MINUTES|" "$REPO/deploy/wow-trading-fetcher.timer" \
    > /etc/systemd/system/wow-trading-fetcher.timer
  chmod 644 /etc/systemd/system/wow-trading-fetcher.timer
  systemctl daemon-reload
}

configure_web_server() {
  [ -n "$DOMAIN" ] || return 0
  if systemctl is-active --quiet apache2; then
    configure_apache
  else
    configure_caddy
  fi
}

# Apache already answers here: Caddy could not take its ports, and the domain may serve
# other things. One path of the domain goes to the site, and nothing else changes.
configure_apache() {
  [ -n "$BASE_PATH" ] || die "Apache runs on this server: give the site a path of its own with BASE_PATH, like /wow-trading"
  apache2ctl -S 2>/dev/null | grep " $DOMAIN " >/dev/null || die "Apache has no virtual host for $DOMAIN, so no certificate to serve it with"

  step "Configuring Apache for https://$DOMAIN$BASE_PATH"
  a2enmod -q proxy proxy_http headers
  cat > /etc/apache2/conf-available/wow-trading.conf <<APACHE
# Written by deploy/install.sh.
<Location "$BASE_PATH">
	ProxyPreserveHost On
	ProxyPass "http://127.0.0.1:3000$BASE_PATH"
	ProxyPassReverse "http://127.0.0.1:3000$BASE_PATH"
	RequestHeader set X-Forwarded-Proto "https"
</Location>
APACHE
  a2enconf -q wow-trading
  if ! apache2ctl configtest 2>/dev/null; then
    a2disconf -q wow-trading
    die "Apache refuses this configuration: it was disabled again, and Apache left running as it was"
  fi
  # New modules take a restart.
  systemctl restart apache2
}

configure_caddy() {
  step "Configuring Caddy for $DOMAIN"
  apt-get install -y -qq caddy
  local caddyfile=/etc/caddy/Caddyfile
  if [ -f "$caddyfile" ] && ! grep -q 'Written by deploy/install.sh' "$caddyfile"; then
    cp "$caddyfile" "$caddyfile.before-wow-trading"
  fi
  cat > "$caddyfile" <<CADDY
# Written by deploy/install.sh.
$DOMAIN {
	encode zstd gzip
	reverse_proxy 127.0.0.1:3000
}
CADDY
  systemctl enable caddy
  systemctl reload-or-restart caddy
}

has_credentials() {
  [ -n "$(value_of BLIZZARD_CLIENT_ID "$FETCHER_ENV")" ] && [ -n "$(value_of BLIZZARD_CLIENT_SECRET "$FETCHER_ENV")" ]
}

start_services() {
  systemctl enable wow-trading-site.service
  systemctl restart wow-trading-site.service
  systemctl enable wow-trading-fetcher.timer

  if has_credentials; then
    systemctl restart wow-trading-fetcher.timer
    # Without waiting for it: a first cycle takes minutes. Not an error if one is running.
    systemctl start --no-block wow-trading-fetcher.service
    step "Done. Check with: sudo $REPO/deploy/check.sh"
  else
    systemctl stop wow-trading-fetcher.timer
    step "Almost done: Battle.net credentials are missing"
    cat <<TEXT
1. Create a client on https://develop.battle.net/access/clients
2. Fill in BLIZZARD_CLIENT_ID and BLIZZARD_CLIENT_SECRET:
     sudo nano $FETCHER_ENV
3. Start fetching:
     sudo systemctl enable --now wow-trading-fetcher.timer
     sudo systemctl start --no-block wow-trading-fetcher.service
4. Check with:
     sudo $REPO/deploy/check.sh
TEXT
  fi

  if [ -z "$DOMAIN" ]; then
    cat <<TEXT

The site listens on this server only. To see it from your computer:
  ssh -L 3000:127.0.0.1:3000 <server>
then open http://127.0.0.1:3000. To serve it publicly, run this script again with DOMAIN set.
TEXT
  fi
}

ensure_packages
rename_old_install
load_saved_settings
ensure_swap
ensure_user
ensure_database
build_fetcher
build_site
install_units
configure_web_server
start_services
