# DCS-API

A REST API for DCS World multiplayer server state. See which players are connected, what they're flying, where they are, and what mission is running — all via simple HTTP endpoints. Supports server actions such as kicking players.

## Architecture

```
DCS World
  └── Scripts/Hooks/dcsapi.lua             # mission info + player list + units (every 1s)
  └── Scripts/DCS-API/dcsapi_export.lua    # player positions + FPS (every 0.1s)
        │  (loaded via dofile from Export.lua)
        │
        │  require("dcsapi")
        ▼
  Scripts/DCS-API/dcsapi.dll  (Rust)       # bridges DCS ↔ API via HTTP
        │                ▲
        │  POST /ingest  │  GET /commands
        ▼                │
  FastAPI backend  (Python)                # serves REST endpoints to clients
```

Data flows both ways: the DLL pushes game state to `/ingest` every second, and polls `/commands` each frame to execute queued actions (kick, etc.) inside DCS.

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /health` | API server status + `auth_enabled` flag |
| `GET /mission` | Active mission — name, map, runtime (s), fps, players_active, players_max |
| `GET /players` | List of connected players |
| `GET /players/{name}` | Single player — name, player_id, aircraft, ucid, ip, coalition, position (lat/lon/alt), speed (m/s) |
| `GET /units` | All world units (AI + players + statics) |
| `GET /units/{name}` | Single unit — name, class (air/ground/static), type (DCS type name), player_controlled, group_name, coalition, position, speed (m/s) |
| `GET /airbases` | All airbases on the map — name, category (airdrome/helipad/ship), coalition, position |
| `GET /weather` | Current weather — wind_dir (°, from), wind_speed (m/s), temperature (°C), pressure (hPa) |
| `GET /bullseye` | Bullseye positions — red {lat, lon} and blue {lat, lon} |
| `POST /players/{name}/kick` | Kick a player; optional body `{"reason": "..."}` |
| `POST /players/{name}/ban` | Ban a player; body `{"reason": "...", "duration": 0}` (0 = permanent) |
| `POST /players/{name}/message` | Send a private chat message; body `{"message": "..."}` |
| `POST /server/chat` | Send a server-wide chat message; body `{"message": "..."}` |
| `POST /server/broadcast` | Show an in-game text overlay; body `{"message": "...", "duration": 10}` |
| `POST /server/mission/restart` | Load the next mission in the server's rotation (restarts if only one) |
| `POST /server/mission/load` | Load a specific mission file; body `{"path": "C:\\...\\mission.miz"}` |
| `GET /api-doc` | Swagger UI (interactive API explorer) |
| `GET /redoc` | ReDoc UI (alternative API docs) |
| `GET /openapi.json` | OpenAPI schema (for Postman, code generation, etc.) |

### Filtering & Pagination

List endpoints support query parameters:

| Endpoint | Filters | Pagination |
|----------|---------|------------|
| `GET /players` | `coalition=red\|blue\|neutral` | `limit` (default 100), `offset` (default 0) |
| `GET /units` | `class=air\|ground\|static`, `coalition=`, `player_controlled=true\|false` | `limit`, `offset` |
| `GET /airbases` | `coalition=`, `category=airdrome\|helipad\|ship` | `limit` (default 200), `offset` |

### Server Actions

Actions are queued in the API and dispatched into DCS on the next simulation frame (~1s latency).

All action endpoints return `{"queued": true}` on success. Player actions return `404` if the player is not connected, `503` if no mission is active. Commands are dispatched on the next simulation frame (~1s latency).

**Player actions**

```bash
# Kick
curl -X POST http://localhost:4414/players/PlayerName/kick \
  -H "X-API-Key: <key>" -H "Content-Type: application/json" \
  -d '{"reason": "Bye!"}'

# Ban (duration in seconds; 0 = permanent)
curl -X POST http://localhost:4414/players/PlayerName/ban \
  -H "X-API-Key: <key>" -H "Content-Type: application/json" \
  -d '{"reason": "Cheating", "duration": 0}'

# Private message
curl -X POST http://localhost:4414/players/PlayerName/message \
  -H "X-API-Key: <key>" -H "Content-Type: application/json" \
  -d '{"message": "Watch your altitude!"}'
```

**Server actions**

```bash
# Server-wide chat
curl -X POST http://localhost:4414/server/chat \
  -H "X-API-Key: <key>" -H "Content-Type: application/json" \
  -d '{"message": "Server restarting in 5 minutes"}'

# In-game text overlay (shown to all players for N seconds)
curl -X POST http://localhost:4414/server/broadcast \
  -H "X-API-Key: <key>" -H "Content-Type: application/json" \
  -d '{"message": "Welcome to the server!", "duration": 15}'

# Restart (loads next mission in rotation; restarts if only one mission)
curl -X POST http://localhost:4414/server/mission/restart \
  -H "X-API-Key: <key>"

# Load a specific mission file
curl -X POST http://localhost:4414/server/mission/load \
  -H "X-API-Key: <key>" -H "Content-Type: application/json" \
  -d '{"path": "C:\\Users\\...\\Missions\\mymission.miz"}'
```

## Installation

### 0. Security

Both config files ship with a default API key that is **publicly known** and must be changed before exposing the API to any network:

```bash
python -c "import secrets; print(secrets.token_hex(32))"
```

Set the generated value as `api_key` in **both**:
- `Scripts/DCS-API/dcsapi.cfg` (read by the DCS module)
- `API/dcsapi.cfg` (read by the FastAPI backend)

Restart both DCS and uvicorn after changing the key. Set `api_key =` (empty) to disable auth entirely for local development.

### 1. API Backend

Requires Python 3.11+.

```bash
cd API
python -m venv .venv
.venv/Scripts/pip install -r requirements.txt
.venv/Scripts/uvicorn main:app --host 0.0.0.0 --port 4414
```

### 2. DCS Module

Download the latest release archive (`dcsapi-module-vX.Y.Z.zip`) and extract it directly into your `Saved Games/DCS World/` directory. The archive already contains the correct folder structure:

```
Scripts/
  DCS-API/
    dcsapi.dll
    dcsapi_export.lua
    dcsapi.cfg
  Hooks/
    dcsapi.lua
```

Then add one line to `Saved Games/DCS World/Scripts/Export.lua` (create the file if it doesn't exist):

```lua
dofile(lfs.writedir()..'Scripts/DCS-API/dcsapi_export.lua')
```

The `Scripts/Hooks/dcsapi.lua` file is picked up by DCS automatically — no further changes needed.

### 3. Docker (optional)

A pre-built image is published to GitHub Container Registry. Mount your `API/dcsapi.cfg` so the container picks up your API key:

```bash
docker run -d \
  -p 4414:4414 \
  -v /path/to/your/dcsapi.cfg:/app/dcsapi.cfg:ro \
  ghcr.io/m1ndgames/dcs-api:latest
```

Or with Docker Compose — add a `volumes` key to `docker-compose.yml`:

```yaml
services:
  api:
    image: ghcr.io/m1ndgames/dcs-api:latest
    ports:
      - "4414:4414"
    volumes:
      - ./API/dcsapi.cfg:/app/dcsapi.cfg:ro
    restart: unless-stopped
```

> **Note**: The image does not bundle `dcsapi.cfg`. If no config is mounted, authentication is disabled — do not expose the port publicly without it.

## Building from Source

- **API**: Python 3.11, FastAPI, uvicorn
- **Module**: Rust (stable), targeting `x86_64-pc-windows-msvc`

The release archive is built automatically by GitHub Actions on every `v*` tag push. To build the DLL locally:

```bash
cd Module
cargo build --release
# outputs: Module/target/release/dcsapi.dll
```
