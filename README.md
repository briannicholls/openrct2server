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
- Bash, curl, Python 3, tar, sha256sum, and ffmpeg for custom music packaging
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

## Custom Ride Music

Put the audio files for one ride-music style in:

```text
data/music/source/
```

Files are ordered by filename, and filenames become the track names shown in
OpenRCT2. MP3, M4A, AAC, FLAC, OGG, Opus, AIFF, and WAV inputs are supported.
Each track must be at least 39 seconds long. Only put audio there that may be
redistributed to every player joining the server.

Package and install the current files, then restart the server safely:

```bash
./scripts/package-music.py
./scripts/update.sh
```

The packager converts every track to padded OGG/Vorbis whose file size matches
its decoded PCM length. The audio members are stored inside the object so the
network save can compress their metadata padding from roughly 29 MB to about
4 MB. This keeps timing identical on the headless server and graphical clients
without making object loading seek through nested compression. It creates a
content-hashed custom object under `data/object/` and a local loader under
`data/plugin/`. The hash is part of the object identifier so a client can never
silently reuse an older track with the same identifier.

On the first installation, join as an administrator, open a ride's Music tab,
enable music, and select `Ultimate Fun Land Radio`. That ride setting is shared
with all players. The server sends the packaged object and audio to players when
they join; playback still respects each player's ride-music volume and camera
location. Repackaging later replaces the prior object in the same music slot,
so rides already using that slot continue to use it.

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

The `openrct2-watchdog.timer` checks public registration every five minutes.
It restarts OpenRCT2 only when local health and the Playit endpoint work but the
server remains absent from a reachable master list for three consecutive
checks, no players are connected, and a fresh autosave exists. Inconclusive or
unsafe failures are logged without restarting. The supplied unit expects this
repository at `%h/games/openrct2`; install it for the current user with:

```bash
systemctl --user link "$PWD/systemd/openrct2-watchdog.service"
systemctl --user link "$PWD/systemd/openrct2-watchdog.timer"
systemctl --user enable --now openrct2-watchdog.timer
```

On every start, the container resumes the newest autosave when it is newer than
the configured base park. Watchdog recovery pins the exact fresh autosave it
checked and never falls back silently to older park state. A deliberate
`scripts/update.sh replacement.park` clears older autosaves, so park replacement
still starts the supplied file.

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
