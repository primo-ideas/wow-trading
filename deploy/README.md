# Deploy to a server

For a small Ubuntu 26.04 server, for example a Scaleway instance. A single script installs everything: Postgres, the fetcher and its timer, the site, and Caddy for HTTPS if you give it a domain.

> **Not tested on a real server yet.** The site has run in production mode and the fetcher on the real API, but on Windows. `install.sh` and the systemd units have never been run on Linux, for lack of access during development. It is written to be safely run again: if it fails, fix the cause and run it again.

## Install

Plan for about 20 GB of disk for the commodities and one realm, compilation included. The repository must be reachable from the server.

```sh
git clone <repository-url> wow-trading
cd wow-trading
sudo SCOPE=eu/commodities,eu/hyjal ./deploy/install.sh
```

Expect several minutes: the fetcher compiles on the spot. The script adds 2 GB of swap if the server has less than 4 GB of memory and no swap, and limits simultaneous compilations to 4, fewer on a small server.

It then stops and asks for the Battle.net credentials:

1. Create a client on <https://develop.battle.net/access/clients>.
2. Fill in `BLIZZARD_CLIENT_ID` and `BLIZZARD_CLIENT_SECRET`, without quotes:

   ```sh
   sudo nano /etc/wow-trading/fetcher.env
   ```

3. Start it, then check:

   ```sh
   sudo systemctl enable --now wow-trading-fetcher.timer
   sudo systemctl start --no-block wow-trading-fetcher.service
   sudo ./deploy/check.sh
   ```

`check.sh` says what works and what does not, and shows no secret: its output can be shared to ask for help.

### See the site

By default, the site only listens on the server. From your computer, go through an SSH tunnel, then open <http://127.0.0.1:3000>:

```sh
ssh -L 3000:127.0.0.1:3000 <server>
```

To make it public, point the domain's DNS to the server, open ports 80 and 443 in its Scaleway security group, then run the script again. Caddy obtains and renews the certificate on its own:

```sh
sudo DOMAIN=trading.example.com ./deploy/install.sh
```

The site has no authentication: once public, anyone can read it. It cannot change the database, as its Postgres role only has read access.

### Next to other sites

If the domain serves other things, give the site a path of its own. Where Apache already runs, with a certificate for that domain, the script adds a route to it in `/etc/apache2/conf-available/wow-trading.conf`, and neither installs Caddy nor changes anything else:

```sh
sudo DOMAIN=example.com BASE_PATH=/wow-trading ./deploy/install.sh
```

That route applies to every domain Apache serves on the server, which is why it only ever claims a path. To give the site a domain of its own on such a server, give that domain an Apache virtual host that sends everything to the site, for example with `ProxyPass / http://127.0.0.1:3000/` next to the certificate Certbot adds, then run the script with `DOMAIN` alone. It checks that virtual host, leaves it as it is, and removes the route of an earlier run on a path:

```sh
sudo DOMAIN=trading.example.com ./deploy/install.sh
```

The script remembers `DOMAIN` and `BASE_PATH` for the next runs. A path of `/` counts as none.

### On an IPv6-only server

Battle.net and GitHub have no IPv6 address. Without an IPv4 address on the server, the fetcher cannot reach Battle.net, and `check.sh` says so: attach one, for example a flexible IP on Scaleway, and also add an `A` record for readers without IPv6.

To install or update such a server, send the code from your computer rather than cloning it:

```sh
git bundle create - HEAD | ssh root@server 'cat > wow-trading.bundle'
ssh root@server 'git clone wow-trading.bundle wow-trading'
```

For an update, replace the second command with `git -C wow-trading pull ../wow-trading.bundle HEAD`.

## When the fetcher runs

**A systemd timer, every 5 minutes.**

Blizzard publishes once an hour. On November 5, 2026, the 93 European markets all changed at the same time, at 10:21:54, 11:21:53 and 12:21:53 UTC. That is few measurements: a single day, a single region.

- **Why not once an hour, at the right minute:** nothing guarantees that this minute stays the same, or that it is the same in other regions. A minute off would lose an hour of data.
- **Why asking often costs nothing:** each request carries `If-Modified-Since`, and Blizzard answers 304 without data as long as nothing has changed. New snapshots thus arrive less than 5 minutes after they are published.
- **Why not more often:** the data does not change any faster. And each cycle looks up to 1,000 new items, which is 2,000 requests: at 5 minutes, this stays under Battle.net's limit of 36,000 requests per hour.
- **Why systemd rather than cron:** a cycle still running is not started again on top of itself, logs go to the journal, the start order with Postgres is handled, and the fetcher runs with no rights beyond the network and its database.

To change the interval, run the script again:

```sh
sudo POLL_MINUTES=10 ./deploy/install.sh
```

## Size the server

These figures come from real snapshots of `eu/commodities` and `eu/hyjal`, and a simulated history of the same size, as no market has two weeks of real data yet.

| | |
| --- | --- |
| Site | 130 MB of memory (measured on Windows) |
| Fetcher | 110 MB at the peak of a cycle, 20 MB without a new snapshot |
| Postgres | A quarter of the server's memory, set by the script |
| Disk, per market | About 1 GB for 14 days of hourly detail |
| Disk, daily summaries | About 2 MB per day and per market, never purged |

2 GB of memory should be comfortable for the commodities and one or two realms. On 1 GB, it should work with the swap, without guarantee: this has not been measured. Page times have not been measured on a small server either.

On a disk under 16 GB, the script adapts: 1 GB of swap instead of 2, less write-ahead log, 7 days of hourly detail, and it removes the Rust compiler and its output once the fetcher is built. They come back at the next update of the fetcher, which then takes as long as the first build.

If disk runs short, lower `WOW_HOURLY_RETENTION_DAYS` in `/etc/wow-trading/fetcher.env`: 7 halves the hourly detail. The fetcher no longer runs when less than 1 GB is free, so that Postgres and the site keep working, and `check.sh` reports it.

## Day to day

| To | Command |
| --- | --- |
| Know if all is well | `sudo ./deploy/check.sh` |
| Read the fetcher's logs | `journalctl -u wow-trading-fetcher.service -f` |
| Read the site's logs | `journalctl -u wow-trading-site.service -f` |
| Run a cycle right now | `sudo systemctl start --no-block wow-trading-fetcher.service` |
| Pause the fetcher | `sudo systemctl stop wow-trading-fetcher.timer` |
| Update | `git pull && sudo ./deploy/install.sh` |
| Follow other markets | Change `WOW_SCOPE` in `/etc/wow-trading/fetcher.env`, taken into account at the next cycle |
| Back up the database | `sudo -u postgres pg_dump -Fc wow_trading > wow_trading.dump` |

No backup is automatic. The history cannot be rebuilt, as Blizzard only gives the present state: a regular dump, or Scaleway's volume snapshots, are the only safety net.

### Updating an install from before the rename

The project used to be called wow-market. On a server installed under that name, `install.sh` renames the install before updating it: the services, the system user, `/opt/wow-market`, `/etc/wow-market`, the database and its roles. The history and the credentials are kept. A `git pull` still works, as GitHub redirects the old address.

Item names already stored stay in the language they were fetched in, and an existing `fetcher.env` keeps its `WOW_LOCALE`. To change language, set `WOW_LOCALE` in `/etc/wow-trading/fetcher.env`, then forget the stored names:

```sh
sudo -u postgres psql -d wow_trading -c "UPDATE items SET name = NULL, resolved_at = NULL; UPDATE pets SET name = NULL, resolved_at = NULL;"
```

The fetcher looks them up again at 1,000 per cycle, which takes about 2 hours for 25,000 items. Until then they show as `Item #…`.

## What the script creates

| What | Where |
| --- | --- |
| Programs | `/opt/wow-trading` |
| Credentials and settings, readable by root and `wowtrading` only | `/etc/wow-trading/fetcher.env`, `/etc/wow-trading/site.env` |
| System user | `wowtrading` |
| Postgres database and roles | `wow_trading`, `wowtrading` (owner, for the fetcher), `wowtrading_site` (read only, for the site) |
| systemd units | `wow-trading-fetcher.service`, `wow-trading-fetcher.timer`, `wow-trading-site.service` |
| With a domain | `/etc/caddy/Caddyfile`, the previous one being kept as `Caddyfile.before-wow-trading` |
