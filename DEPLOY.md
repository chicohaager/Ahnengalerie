# Deploying Ahnengalerie

Ahnengalerie is upstream Gramps Web with a theme and a lock on self-registration. The
backend is upstream's own image (`dmstraub/gramps-webapi`); this repo only contributes
the built frontend (`dist/`) that the `Dockerfile` copies into it. Everything below was
measured on a ZimaOS host on 2026-09-14 (ZimaOS v1.7.1-beta1 → v1.7.1, Docker 28.3.2,
gramps-webapi 3.22.0, Gramps 6.0.8).

## 1. Build the frontend

```bash
npm ci
npm run build          # → dist/ (about 15 MB, ~15 s)
```

## 2. ZimaOS (current home)

Prerequisites on the host — measure them, do not assume (`docker info` as the SSH user,
`rsync` present):

- the SSH user can talk to the Docker socket (member of `docker`, verified with `docker info`)
- a Docker registry answering on the host's `127.0.0.1:5000` — the build script starts one
  if none answers

### Why a registry on localhost

ZimaOS' app installer **always pulls** the images a compose names, through its own mirror
orchestrator (`image_pull_orchestrator.go`, tried `docker.1ms.run`, `docker.m.daocloud.io`,
`docker.1panel.live`). An image that exists only in the host's local Docker daemon fails
the install with *"Bild konnte nicht gezogen werden: Repository existiert nicht"* — and the
app silently never appears in the grid. A `registry:2` container published on
`127.0.0.1:5000` only (not on the LAN) is what the installer can pull from. Localhost is in
Docker's default insecure-registry set, so no daemon configuration is needed.

### Build, push, install

```bash
deploy/zimaos/build-on-host.sh <ssh-user>@<zimaos-ip>
#   rsyncs dist/ + Dockerfile to /DATA/AppData/ahnengalerie-build/, builds
#   127.0.0.1:5000/ahnengalerie:local there, pushes it, pulls it back (the counter-check
#   that mirrors what the installer does), and pre-creates the bind-mount directories.

python3 ~/dev/zimapp/zimapp.py validate deploy/zimaos/ahnengalerie.yml
ZIMA_USER=<zimaos-user> ZIMA_PASS=<zimaos-password> \
  python3 ~/dev/zimapp/zimapp.py install deploy/zimaos/ahnengalerie.yml --host <zimaos-ip>
```

The install registers the tile, starts `web`, `celery` and `redis`, and `zimapp` waits
until the grid reports `running` and the tile URL answers 200.

### Firewall (ZFW)

If the host runs ZFW with `default_policy: deny`, the published port **must** get an
allow rule, and the timing matters: ZFW's `dockerwatch` recompiles `compiled.sh` on every
container event and emits a per-port `DROP` for each published port that has no rule. It
does not apply that script — so right after the install the port still answers (the live
chain is stale), and the **next `zfw apply` — which the boot service runs — blocks it from
the LAN**. Measured exactly so: reachable after install, unreachable after the next
reboot, until the rule existed.

Add the rule through the ZFW API (needs the ZimaOS session JWT **and** a same-origin
`Origin:` header — the CSRF guard answers 403 without it):

```
GET  /v2/zfw/api/rules                → append {zone: docker, ports: [8300], source: <lan cidr>, action: allow}
POST /v2/zfw/api/rules                → {"status":"saved"}
POST /v2/zfw/api/apply {"safe":true}  → dead-man timer armed (120 s)
curl http://<zimaos-ip>:8300/         → must be 200 from a LAN client
POST /v2/zfw/api/commit               → timer cancelled, boot-persistent
```

Live check: `iptables -S DOCKER-USER | grep 8300` shows a `RETURN` for the LAN source in
front of the `LOG` + `DROP` pair.

### First start

Open `http://<zimaos-ip>:8300/`. While no owner account exists, the app shows the
first-run wizard (`POST /api/token/create_owner/` answers 201; once an owner exists it
answers 405). **Create the owner right away** — an open wizard on the LAN hands the admin
account to whoever opens the URL first. Then add family members under *Settings →
Manage users*. Self-registration is off on both sides (`GRAMPSWEB_REGISTRATION_DISABLED`
→ `POST /api/users/<name>/register/` = 405; the button is hidden by `src/config.js`).

### Updating a running install

```bash
npm run build
deploy/zimaos/build-on-host.sh <ssh-user>@<zimaos-ip>
ssh <ssh-user>@<zimaos-ip> 'cd /var/lib/casaos/apps/ahnengalerie && sudo docker compose up -d --force-recreate web celery'
```

**Never "uninstall + install" through ZimaOS to update.** Uninstall removes
`/DATA/AppData/ahnengalerie/` wholesale — tree, media, user accounts, secret key
(measured: the directory was gone after the uninstall). If you must uninstall, back up
that directory first (`tar` it as root; the files are root-owned).

### What lives where

| Path on the host                              | Contents                                  |
| --------------------------------------------- | ----------------------------------------- |
| `/DATA/AppData/ahnengalerie/db/`              | the Gramps tree (SQLite, one dir per tree)|
| `/DATA/AppData/ahnengalerie/media/`           | uploaded photos and scans                 |
| `/DATA/AppData/ahnengalerie/users/`           | user accounts (`users.sqlite`)            |
| `/DATA/AppData/ahnengalerie/secret/`          | Flask secret; losing it logs everyone out |
| `/DATA/AppData/ahnengalerie/index,cache,tmp/` | rebuildable / disposable                  |
| `/DATA/AppData/ahnengalerie-build/`           | build context (outside the app dir on purpose) |
| `/var/lib/casaos/apps/ahnengalerie/`          | the compose ZimaOS installed (root-only)  |

Back up the first four. A restore is: same compose, same paths, copy the four
directories back before the first start.

## 3. Later: VPS behind Pangolin

Not done yet. The plan agreed on 2026-09-14: keep the LAN install, expose it through the
existing Pangolin tunnel (the `newt` client already runs on the ZimaOS host) with
Pangolin's own authentication in front of Gramps Web's login, so family members need no
VPN. Two things to set when that happens:

- `GRAMPSWEB_BASE_URL` = the public URL (used in e-mails and links)
- e-mail settings (`GRAMPSWEB_EMAIL_HOST` …) if password resets by mail are wanted; until
  then the "forgot password" link cannot send anything and the admin resets passwords
  under *Manage users*

## 4. Keeping up with upstream

```bash
git fetch upstream
git merge upstream/main        # conflicts, if any, are confined to the files listed in README.md
npm ci && npm test && npm run build
```

## Notes from the first deployment (2026-09-14)

- `web` and `celery` both create the tree named in `GRAMPSWEB_TREE` at boot. Started
  together they created **two** trees of the same name; the compose therefore gates
  `celery` on `web`'s healthcheck (`condition: service_healthy`). One `web` with four
  gunicorn workers created exactly one tree.
- Uploads go through `/tmp` in the `web` container and are read by `celery`, so `/tmp`
  is a shared bind mount (upstream's compose uses a named volume for the same reason).
- Importing upstream's bundled `example.gramps` (XML) failed in `dry_run_import` on
  3.22.0 both as plain XML and gzipped; the bundled `sample.ged` imported fine. Not
  investigated further — the family starts with an empty tree.
