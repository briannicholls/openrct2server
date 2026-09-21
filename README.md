# MLG Park

Public OpenRCT2 0.5.5 dedicated server. The server is advertised in the in-game server browser and allows anonymous players to build.

This repository contains the deployment configuration, not the live park or player data. The server manager must supply the park during setup.

## Public server warning

The default `User` group can build and remove rides, terraform, change scenery and paths, manage staff and guests, and change park finances. This is intentional. Any public player can damage the park, so scheduled off-VM backups and active moderation are required.

OpenRCT2 uses its native TCP protocol rather than HTTPS. Game and chat traffic is not protected by TLS.

## Deployment target

- Ubuntu 24.04 LTS amd64 VM
- 2 vCPU, 2 GB RAM, and at least 10 GB disk recommended
- Static public IPv4 address
- Inbound TCP port `11753`
- Outbound HTTPS access to `https://servers.openrct2.io`

The pinned container image is Linux/amd64. A Linux VM is recommended even if the administrator normally works with Windows; Docker Desktop is not supported on Windows Server.

## 1. Install Docker

Install Docker Engine from Docker's official Ubuntu repository:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
```

Log out and back in after adding the user to the `docker` group. Confirm the installation:

```bash
docker version
docker compose version
```

Membership in the `docker` group grants administrator-equivalent access to the VM. Only add trusted server managers.

## 2. Clone and configure

The suggested installation path is `/opt/openrct2`:

```bash
sudo mkdir -p /opt/openrct2
sudo chown "$USER":"$USER" /opt/openrct2
git clone --branch public-server https://github.com/briannicholls/openrct2server.git /opt/openrct2
cd /opt/openrct2
```

Run setup with the park supplied out of band:

```bash
./scripts/setup.sh /path/to/server.park
```

Legacy `.sv6` saves are also accepted. If an existing `users.json` should preserve administrator assignments, supply it as the second argument:

```bash
./scripts/setup.sh /path/to/server.park /path/to/users.json
```

Setup creates ignored runtime storage under `data/`, copies safe configuration templates, records the host UID/GID in `.env`, and refuses to overwrite a different existing park.

Place any required custom objects under `data/object/` before starting. The headless image does not require a full RollerCoaster Tycoon 2 installation, but a park may depend on custom objects.

## 3. Configure the firewall

Initially allow TCP `11753` only from the administrator's public IP. Configure this in the VM provider's security group or network firewall before starting the server.

Allow SSH and OpenRCT2 in Ubuntu's host firewall if UFW is in use:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 11753/tcp
sudo ufw enable
```

The provider firewall is the primary perimeter because Docker-published ports can bypass some UFW forwarding rules. Do not expose Docker's daemon port. OpenRCT2 does not require public UDP access.

## 4. Start and bootstrap administration

Start the server:

```bash
docker compose up -d
docker compose logs -f server
```

All players must use OpenRCT2 `0.5.5`, network version `0.5.5-0`.

While TCP `11753` is still restricted, connect from the administrator's OpenRCT2 client by adding the VM's public IP manually. Then attach to the server console:

```bash
docker attach openrct2-server
```

List players and promote the administrator:

```text
network.players
network.players[1].group = 0
```

Replace `1` with the correct player index. Verify the player carefully before promotion. OpenRCT2 saves the assignment to `data/users.json` using the client's public-key identity.

Detach without stopping the server by pressing `Ctrl-P`, then `Ctrl-Q`.

After administrator access is confirmed, change the provider firewall rule for TCP `11753` to allow `0.0.0.0/0`. The server should register with the OpenRCT2 master server within approximately one minute.

```bash
./scripts/check.sh
```

Successful startup logs include:

```text
Server successfully registered on master server
```

## Routine operations

```bash
docker compose ps
docker compose logs -f server
docker compose restart server
docker compose stop
docker compose up -d
./scripts/check.sh
```

The container restarts after a VM reboot unless it was manually stopped. `scripts/check.sh --local` skips the public server-list lookup.

## Backups

Create a consistent backup:

```bash
./scripts/backup.sh
```

The script stops the server only if it is running, archives parks, configuration, permissions, custom objects, and plugins, writes a SHA-256 checksum, rotates closed application logs, and restores the prior running state.

Backups default to 30-day retention. Chat and action logs default to 14-day retention. Change `BACKUP_RETENTION_DAYS` and `LOG_RETENTION_DAYS` in `.env` if needed.

Schedule a nightly backup as the deployment user with `crontab -e`:

```cron
17 4 * * * /opt/openrct2/scripts/backup.sh >> /opt/openrct2/backups/backup.log 2>&1
```

The `backups/` directory is on the same VM and is not disaster recovery by itself. Copy each `.tar.gz` and `.sha256` file to separate storage or configure provider snapshots. Periodically test restoration on another VM.

## Restore

Restore a backup with its adjacent checksum file:

```bash
./scripts/restore.sh /path/to/openrct2-YYYYMMDDTHHMMSSZ.tar.gz
```

Restore first creates another safety backup. The replaced raw data remains under `backups/pre-restore-data-*` for manual rollback. If the server was stopped before restoration, it remains stopped.

## Configuration

Tracked defaults are stored in:

| File | Purpose |
| --- | --- |
| `config/config.ini` | Public listing, server identity, autosaves, logging, and player limits |
| `config/groups.json` | Administrator, spectator, and open-builder permissions |
| `.env.example` | Compose and retention defaults |

Runtime copies are stored under `data/` and are intentionally ignored by Git. Edit `data/config.ini` for a deployed server. Editing `config/config.ini` changes only future installations.

Important network settings:

| Setting | Default |
| --- | --- |
| Public port | TCP `11753` |
| Server browser advertising | Enabled |
| Password | None |
| Known client keys only | Disabled |
| Maximum players | 16 |
| Default group | User/open builder |
| Pause with no clients | Enabled |

Changing the public port is not supported by this deployment because the port advertised to the master server must match the container's listening port.

## Updates and rollback

The image version and digest are pinned in `compose.yaml`. OpenRCT2 clients and the server must use the same network version.

Before an update:

```bash
./scripts/backup.sh
git pull --ff-only
docker compose pull
docker compose up -d
./scripts/check.sh
```

Review version changes before changing the pinned image. Roll back by checking out the previous deployment revision and restoring the pre-update backup.

## Troubleshooting

Inspect container state and recent output:

```bash
docker compose ps
docker compose logs --tail=200 server
```

If the container restarts repeatedly, confirm that the selected park exists:

```bash
grep '^PARK_FILE=' .env
ls -l data/save/
```

If the server runs locally but is absent from the browser, confirm that `advertise = true` is present in `data/config.ini`, outbound HTTPS works, and the provider firewall permits public TCP `11753`.

If the park cannot load, inspect logs for missing custom object names and install those files under `data/object/`.

## Repository validation

Run the same checks used by CI:

```bash
./scripts/validate.sh
```

This validates shell syntax, Compose rendering, public-advertising defaults, the open-builder group, and Git exclusions for runtime data.
