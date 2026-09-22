# $MLG B5 - Ultimate Fun Land

This repository runs one persistent public OpenRCT2 server. Docker Compose owns
the game process, and Playit exposes it through:

```text
della-avoided.tun.ply.gg:39970
```

There is no alternate test or private deployment. Test changes on the same
configuration and use `scripts/update.sh` to apply them safely.

## Layout

- `config/config.ini`: the only editable OpenRCT2 server configuration
- `config/groups.json`: the only editable permission-group configuration
- `.env`: host binding, game port, limits, and active park filename
- `data/`: generated runtime state, users, logs, objects, plugins, and saves
- `backups/`: timestamped archives and pre-restore state
- `compose.yaml`: the only deployment definition

At every container start, the tracked files under `config/` are copied into
`data/`. Do not edit `data/config.ini` or `data/groups.json`; those runtime
copies are replaced on restart.

## Public Configuration

The current home-hosted Playit deployment uses these `.env` values:

```dotenv
BIND_ADDRESS=127.0.0.1
HOST_PORT=11754
SERVER_PORT=39970
```

Playit forwards `della-avoided.tun.ply.gg:39970` to
`127.0.0.1:11754`. The OpenRCT2 container listens on port `39970`, so its
master-server advertisement matches the public endpoint.

The public identity lives in `config/config.ini`:

```ini
advertise = true
advertise_address = "della-avoided.tun.ply.gg"
server_name = "{RED}$M{WHITE}L{BABYBLUE}G{WHITE} B5 - Ultimate Fun Land"
server_description = "Buy $MLG. Don't focus on no girls, just buy $MLG."
server_greeting = "https://mlg.lol"
```

The Playit agent is managed independently by the enabled user service
`playit-mlg-park.service`. Its secret is not stored in this repository.

## Initial Setup

Requirements:

- Docker Engine with the Compose plugin
- Bash, curl, tar, and sha256sum
- A `.park` or legacy `.sv6` save

Initialize a new host without overwriting existing server state:

```bash
./scripts/setup.sh /absolute/path/to/park.park
./scripts/update.sh
./scripts/check.sh
```

`setup.sh` copies the park into `data/save/`, creates `.env` when needed, and
refuses to replace an existing destination park.

## Apply Changes

Edit `config/config.ini` or `config/groups.json`, then apply and verify them:

```bash
./scripts/update.sh
```

Replace the active park and apply configuration in one operation:

```bash
./scripts/update.sh /absolute/path/to/replacement.park
```

The update command creates a full backup, stops the server, installs the park,
clears stale autosaves, restarts the server, waits for health, and confirms the
public server-list entry. If startup or registration fails, it restores the
previous config, park, and `.env` and starts the prior state again.

## Operations

```bash
docker compose up -d
docker compose stop
docker compose logs -f server
./scripts/check.sh
./scripts/check.sh --local
./scripts/validate.sh
```

The service uses `restart: unless-stopped`, so Docker restores it after a host
reboot or process failure. The container filesystem is read-only, capabilities
are dropped, and writable paths are limited to runtime data and temporary
files.

## Backups

Create a consistent archive of runtime data, canonical configuration, and
deployment settings:

```bash
./scripts/backup.sh
```

A standalone backup refuses to restart the server when unapplied config or
deployment changes exist; apply those changes with `scripts/update.sh` first.

Restore one archive after reviewing its contents:

```bash
tar -tzf backups/openrct2-YYYYMMDDTHHMMSSZ.tar.gz
./scripts/restore.sh backups/openrct2-YYYYMMDDTHHMMSSZ.tar.gz
```

Restore verifies an adjacent SHA-256 checksum when present, rejects unsafe
archive paths, creates a safety backup, and retains the previous raw state.

Each backup run removes old compressed backups and runtime logs according to
`BACKUP_RETENTION_DAYS` and `LOG_RETENTION_DAYS` in `.env`.

## Moving Hosts

Use the same files and workflow on a direct-connect VM. Set the externally
reachable game port in both `HOST_PORT` and `SERVER_PORT`, bind the required
interface, update `advertise_address`, and allow that TCP port through the
provider firewall. The Compose and update logic do not change.

## Secrets

Keep `.env`, `data/`, `backups/`, Playit credentials, and server-generated user
records out of Git. Never commit API keys or passwords in plugin configuration.
