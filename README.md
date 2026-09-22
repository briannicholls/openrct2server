# MLG Park

Public OpenRCT2 `0.5.5` dedicated server. It appears in the in-game server browser and allows every player to build.

The park and player data are not stored in Git. The server manager supplies the park during setup.

## Requirements

- Ubuntu 24.04 amd64 VM
- 2 vCPU, 2 GB RAM, and 10 GB disk recommended
- Docker Engine with the Compose plugin
- Static public IPv4 address
- Public inbound TCP `11753`
- OpenRCT2 `0.5.5` clients, network version `0.5.5-0`

Install Docker using the [official Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/), then verify:

```bash
docker version
docker compose version
```

## Test Here First

The local test uses a separate container, data directory, and port. It does not interrupt the existing server.

Start a test available only on this machine:

```bash
./scripts/test-local.sh up
```

Manually connect OpenRCT2 to:

```text
127.0.0.1:11754
```

To connect from another device, bind the test to this server's LAN or Tailscale IP:

```bash
TEST_BIND_ADDRESS=SERVER_IP ./scripts/test-local.sh up
```

Then connect to `SERVER_IP:11754`.

Useful test commands:

```bash
./scripts/test-local.sh status
./scripts/test-local.sh logs
./scripts/test-local.sh down
./scripts/test-local.sh reset
```

`down` preserves the test park. `reset` removes the test data so the next `up` starts from the source park again. The test container uses Docker's `unless-stopped` restart policy.

### Test The Public Browser

This is feasible only if this machine can receive public Internet traffic. Forward TCP `11754` through the router/provider firewall, then run:

```bash
TEST_BIND_ADDRESS=0.0.0.0 TEST_ADVERTISE=1 ./scripts/test-local.sh up
```

Look for `MLG Park` in the browser after about one minute. Check registration with:

```bash
./scripts/test-local.sh logs
```

Successful registration prints `Server successfully registered on master server`.

Stop the public test when finished:

```bash
./scripts/test-local.sh down
```

If the connection is behind CGNAT or TCP `11754` cannot be forwarded, the public-browser test cannot work from this machine. The normal local test still verifies the application and park.

For Starlink, enable the `Public IP` option on an eligible Priority plan. Because the standard Starlink router does not provide port forwarding, place it in bypass mode, use a third-party router, and forward TCP `11754` to this server before starting the advertised test.

Behind CGNAT, a raw TCP relay such as Playit can be used instead. Create a custom TCP tunnel targeting `127.0.0.1:11754`, then start the test with the hostname and public port assigned by the relay:

```bash
TEST_BIND_ADDRESS=127.0.0.1 \
TEST_LOCAL_PORT=11754 \
TEST_PORT=PUBLIC_PORT \
TEST_ADVERTISE=1 \
TEST_ADVERTISE_ADDRESS=PUBLIC_HOSTNAME \
./scripts/test-local.sh up
```

Store these `TEST_*` values in the ignored `.env` file when the relay should survive Docker restarts. Run the relay agent as a boot service as well; the Docker restart policy cannot restart an agent running as a temporary shell process.

On this host, Playit runs as a persistent user service:

```bash
systemctl --user status playit-mlg-park.service
systemctl --user restart playit-mlg-park.service
journalctl --user -u playit-mlg-park.service
```

The user has systemd lingering enabled, so the relay starts during boot without an interactive login.

## Deploy To The VM

1. Allow inbound TCP `11753` from the administrator's public IP in the VM provider firewall.

2. Clone the deployment branch:

```bash
sudo mkdir -p /opt/openrct2
sudo chown "$USER":"$USER" /opt/openrct2
git clone --branch public-server \
  https://github.com/briannicholls/openrct2server.git \
  /opt/openrct2
cd /opt/openrct2
```

3. Transfer `server.park` to the VM, then configure it:

```bash
./scripts/setup.sh /path/to/server.park
```

To retain an existing administrator identity, also transfer `users.json` and run:

```bash
./scripts/setup.sh /path/to/server.park /path/to/users.json
```

4. Start the server:

```bash
docker compose up -d
docker compose logs -f server
```

5. If no `users.json` was supplied, connect manually while the firewall is restricted and promote the administrator:

```bash
docker attach openrct2-server
```

```text
network.players
network.players[1].group = 0
```

Replace `1` with the correct player index. Detach without stopping the server with `Ctrl-P`, then `Ctrl-Q`.

6. Open provider-firewall TCP `11753` to `0.0.0.0/0` and verify:

```bash
./scripts/check.sh
```

The server should become healthy and appear as `MLG Park` in the in-game browser within approximately one minute.

Docker-published ports can bypass some UFW forwarding rules, so use the VM provider firewall as the primary perimeter. Public UDP access is not required.

## Routine Commands

```bash
docker compose ps
docker compose logs -f server
docker compose restart server
docker compose stop
docker compose up -d
./scripts/check.sh
```

The container automatically starts after a VM reboot unless it was manually stopped.

## Backups

Create a consistent backup:

```bash
./scripts/backup.sh
```

Restore one:

```bash
./scripts/restore.sh /path/to/openrct2-YYYYMMDDTHHMMSSZ.tar.gz
```

Schedule `scripts/backup.sh` nightly. Backups default to 30-day retention and application logs to 14 days. Copy `backups/*.tar.gz` and their `.sha256` files off the VM because local backups do not protect against VM or disk loss.

## Important Files

| Path | Purpose |
| --- | --- |
| `compose.yaml` | Public server runtime |
| `config/` | Defaults copied during first setup |
| `.env` | Local deployment settings; ignored by Git |
| `data/` | Live parks, users, objects, and logs; ignored by Git |
| `backups/` | Local backups and test data; ignored by Git |

Edit `data/config.ini` to change a deployed server. Editing `config/config.ini` affects only future installations.

## Security Model

This is intentionally an open-builder server with no password. Any player can modify or damage the park. Keep backups and establish an administrator before opening the firewall publicly.

OpenRCT2 uses its native TCP protocol, not HTTPS, so game and chat traffic is not protected by TLS.

## Validate Changes

```bash
./scripts/validate.sh
```
