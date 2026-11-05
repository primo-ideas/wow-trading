#!/usr/bin/env bash
#
# Says whether WoW Trading is working on this server. Prints no secret, so its output
# can be shared to get help.
#
#   sudo ./deploy/check.sh
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run this as root: sudo $0" >&2; exit 1; }

ETC=/etc/wow-trading
DATABASE=wow_trading
failed=0

ok() { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; failed=1; }
query() { runuser -u postgres -- psql -d "$DATABASE" -tAc "$1" 2>/dev/null; }

echo "System"
. /etc/os-release
printf '  %s, %s MB of memory, %s of swap\n' "${PRETTY_NAME:-unknown}" \
  "$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)" \
  "$(swapon --show=SIZE --noheadings --bytes 2>/dev/null | awk '{ total += $1 } END { printf "%d MB", total / 1048576 }')"
available_kb="$(df --output=avail -k /var/lib/postgresql | tail -n 1)"
if [ "$available_kb" -gt 2097152 ]; then
  ok "$(( available_kb / 1048576 )) GB free on the disk of the database"
else
  bad "only $(( available_kb / 1024 )) MB free on the disk of the database: the fetcher stops below 1 GB"
fi

echo "Configuration"
if [ -n "$(sed -n 's/^BLIZZARD_CLIENT_ID=//p' "$ETC/fetcher.env" 2>/dev/null)" ] &&
   [ -n "$(sed -n 's/^BLIZZARD_CLIENT_SECRET=//p' "$ETC/fetcher.env" 2>/dev/null)" ]; then
  ok "Battle.net credentials are set"
else
  bad "Battle.net credentials are missing in $ETC/fetcher.env"
fi
printf '  scope: %s\n' "$(sed -n 's/^WOW_SCOPE=//p' "$ETC/fetcher.env" 2>/dev/null)"

echo "Services"
for unit in postgresql wow-trading-site.service wow-trading-fetcher.timer; do
  if systemctl is-active --quiet "$unit"; then ok "$unit is running"; else bad "$unit is not running"; fi
done
systemctl list-timers wow-trading-fetcher.timer --no-pager --no-legend | sed 's/^/  next: /'
result="$(systemctl show wow-trading-fetcher.service --property=Result --value)"
state="$(systemctl show wow-trading-fetcher.service --property=ActiveState --value)"
if [ "$result" = "success" ]; then
  ok "last cycle succeeded (now: $state)"
else
  bad "last cycle ended with: $result (now: $state)"
fi

echo "Site"
if curl --silent --fail --max-time 10 --output /dev/null http://127.0.0.1:3000/up; then
  ok "answers on 127.0.0.1:3000"
else
  bad "does not answer on 127.0.0.1:3000"
fi
site_host="$(sed -n 's/^SITE_HOST=//p' "$ETC/site.env" 2>/dev/null)"
if [ -n "$site_host" ]; then
  if curl --silent --fail --max-time 15 --output /dev/null "https://$site_host/up"; then
    ok "answers on https://$site_host"
  else
    bad "does not answer on https://$site_host: check its DNS, and that ports 80 and 443 are open"
  fi
fi

echo "Data"
if [ "$(query "SELECT to_regclass('public.snapshots') IS NOT NULL")" != "t" ]; then
  bad "no tables yet: the fetcher has never completed its start"
else
  query "SELECT '  ' || h.region || ' / ' || h.name || ': ' || count(s.taken_at) || ' snapshots, latest ' ||
                to_char(max(s.taken_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'
         FROM snapshots s JOIN auction_houses h ON h.id = s.auction_house_id
         GROUP BY h.region, h.name ORDER BY h.region, h.name"
  query "SELECT '  items: ' || count(name) || ' named, ' || count(icon_url) || ' with an icon, out of ' || count(id) FROM items"
  query "SELECT '  database size: ' || pg_size_pretty(pg_database_size(current_database()))"
  age_minutes="$(query "SELECT round(extract(epoch FROM now() - max(taken_at)) / 60) FROM snapshots")"
  if [ -z "$age_minutes" ]; then
    bad "no snapshot yet"
  elif [ "$age_minutes" -lt 180 ]; then
    ok "latest snapshot is $age_minutes minutes old"
  else
    bad "latest snapshot is $age_minutes minutes old: see the logs below"
  fi
fi

echo "Recent problems in the fetcher's logs"
journalctl --unit wow-trading-fetcher.service --since "-3 hours" --no-pager --output=cat --priority=warning 2>/dev/null | tail -n 5
journalctl --unit wow-trading-fetcher.service --since "-3 hours" --no-pager --output=cat 2>/dev/null |
  grep -E ' (ERROR|WARN) |^error' | cut -c1-200 | tail -n 10

echo
if [ "$failed" -eq 0 ]; then
  echo "Everything looks fine."
else
  echo "Something is wrong: see FAIL above. Logs: journalctl -u wow-trading-fetcher.service -u wow-trading-site.service -n 100"
  exit 1
fi
