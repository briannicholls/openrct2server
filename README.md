# Hraesvelgr Park

Private OpenRCT2 0.5.5 dedicated server exposed only through Tailscale.

## Park file

Place the saved park in `data/save/` and preserve its extension.

- OpenRCT2 park: `data/save/server.park`
- Legacy RCT2 save: `data/save/server.sv6`, then set `PARK_FILE=server.sv6` in `.env`

The service intentionally remains stopped until the park file is installed.
The headless image has been verified without a full RCT2 installation. If the supplied park references unavailable custom objects, add those object files under `data/object/` after the first load attempt identifies them.

## Start and stop

```bash
docker compose up -d
docker compose logs -f server
docker compose stop
```

The container restarts automatically after a host reboot unless it was manually stopped.

## Connect

All players must be connected to the same Tailscale network and use OpenRCT2 0.5.5 (network version `0.5.5-0`). Connect to either:

```text
hraesvelgr:11753
100.73.141.107:11753
```

The server is not advertised on the public OpenRCT2 server list and does not require an in-game password. Tailscale controls access.

## Administration

Attach to the server console:

```bash
docker attach openrct2-server
```

Detach without stopping it by pressing `Ctrl-P`, then `Ctrl-Q`.

After joining from the game client, list players and promote the desired player to the administrator group:

```text
network.players
network.players[1].group = 0
```

Replace `1` with the player's actual index. OpenRCT2 persists the assignment in `data/users.json`.

## Files

- `compose.yaml`: pinned server runtime and Tailscale-only networking
- `.env`: park filename selected by Compose
- `data/config.ini`: server identity, password, and runtime configuration
- `data/save/`: active park and automatic saves
- `data/users.json`: persistent player permissions, created after players join
