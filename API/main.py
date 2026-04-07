from pathlib import Path

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Query, Security
from fastapi.security import APIKeyHeader
from pydantic import BaseModel, Field, field_validator

# --- Auth ---
# Read api_key from dcsapi.cfg next to this file.
# If the key is empty or the file is missing, authentication is disabled.

def _read_api_key() -> str:
    cfg = Path(__file__).parent / "dcsapi.cfg"
    if not cfg.exists():
        return ""
    for line in cfg.read_text().splitlines():
        m_key, _, m_val = line.partition("=")
        m_key = m_key.strip()
        m_val = m_val.strip()
        if m_key == "api_key" and not m_val.startswith("#"):
            return m_val
    return ""

_api_key = _read_api_key()
_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

def _require_auth(key: str | None = Security(_key_header)):
    if _api_key and key != _api_key:
        raise HTTPException(status_code=403, detail="Invalid or missing API key")


app = FastAPI(
    title="DCS API",
    description="API for DCS World multiplayer server state.\n\n"
                "Set `api_key` in `API/dcsapi.cfg` to enable authentication. "
                "When enabled, pass the key via the `X-API-Key` header "
                "(use the **Authorize** button above in Swagger UI).",
    docs_url="/api-doc",
)

# All public endpoints live on this router — auth applied in one place.
router = APIRouter(dependencies=[Depends(_require_auth)])


# --- Models ---

class Mission(BaseModel):
    mission: str
    map: str
    runtime: float  # seconds
    fps: float
    players_active: int
    players_max: int


class Position(BaseModel):
    lat: float
    lon: float
    alt: float  # meters


_COALITION_NAMES = {0: "neutral", 1: "red", 2: "blue"}

def _to_coalition(v: int | str) -> str:
    if isinstance(v, int):
        return _COALITION_NAMES.get(v, "neutral")
    return v


class Player(BaseModel):
    name: str
    player_id: int
    aircraft: str
    ucid: str
    ip: str
    coalition: str
    position: Position
    speed: float  # m/s

    @field_validator("coalition", mode="before")
    @classmethod
    def coalition_to_str(cls, v): return _to_coalition(v)


class Unit(BaseModel):
    model_config = {"populate_by_name": True}

    name: str
    unit_class: str = Field(alias="class")
    type: str           # DCS type name, e.g. "BTR-60", "A-10C_2"
    player_controlled: bool
    group_name: str
    coalition: str
    position: Position
    speed: float  # m/s

    @field_validator("coalition", mode="before")
    @classmethod
    def coalition_to_str(cls, v): return _to_coalition(v)


class Airbase(BaseModel):
    name: str
    category: str   # "airdrome", "helipad", "ship"
    coalition: str
    position: Position

    @field_validator("coalition", mode="before")
    @classmethod
    def coalition_to_str(cls, v): return _to_coalition(v)


class Weather(BaseModel):
    wind_dir: float    # degrees, meteorological convention (direction FROM)
    wind_speed: float  # m/s
    temperature: float # Celsius
    pressure: float    # hPa


class BullseyePoint(BaseModel):
    lat: float
    lon: float


class Bullseye(BaseModel):
    red: BullseyePoint
    blue: BullseyePoint


class GameState(BaseModel):
    mission: Mission
    players: list[Player]
    units: list[Unit] = []
    airbases: list[Airbase] = []
    weather: Weather | None = None
    bullseye: Bullseye | None = None


# --- In-memory state ---

state: GameState | None = None


# --- Ingest (called by DCS module — also requires key when auth is enabled) ---

@app.post("/ingest", include_in_schema=False, dependencies=[Depends(_require_auth)])
def ingest(game_state: GameState):
    global state
    state = game_state
    return {"ok": True}


# --- Health (always public) ---

@app.get("/health")
def health():
    return {"status": "ok", "auth_enabled": bool(_api_key)}


# --- Protected endpoints ---

@router.get("/mission", response_model=Mission | None)
def mission():
    return state.mission if state else None


@router.get("/players", response_model=list[Player])
def players(
    coalition: str | None = None,
    limit: int = Query(100, ge=1, le=1000),
    offset: int = Query(0, ge=0),
):
    if not state:
        return []
    result = state.players
    if coalition:
        result = [p for p in result if p.coalition == coalition]
    return result[offset : offset + limit]


@router.get("/players/{name}", response_model=Player | None)
def player(name: str):
    if not state:
        return None
    return next((p for p in state.players if p.name == name), None)


@router.get("/units")
def units(
    unit_class: str | None = Query(None, alias="class"),
    coalition: str | None = None,
    player_controlled: bool | None = None,
    limit: int = Query(100, ge=1, le=1000),
    offset: int = Query(0, ge=0),
):
    if not state:
        return []
    result = state.units
    if unit_class:
        result = [u for u in result if u.unit_class == unit_class]
    if coalition:
        result = [u for u in result if u.coalition == coalition]
    if player_controlled is not None:
        result = [u for u in result if u.player_controlled == player_controlled]
    return [u.model_dump(by_alias=True) for u in result[offset : offset + limit]]


@router.get("/units/{name}")
def unit(name: str):
    if not state:
        return None
    u = next((u for u in state.units if u.name == name), None)
    return u.model_dump(by_alias=True) if u else None


@router.get("/airbases", response_model=list[Airbase])
def airbases(
    coalition: str | None = None,
    category: str | None = None,
    limit: int = Query(200, ge=1, le=1000),
    offset: int = Query(0, ge=0),
):
    if not state:
        return []
    result = state.airbases
    if coalition:
        result = [ab for ab in result if ab.coalition == coalition]
    if category:
        result = [ab for ab in result if ab.category == category]
    return result[offset : offset + limit]


@router.get("/weather", response_model=Weather | None)
def weather():
    return state.weather if state else None


@router.get("/bullseye", response_model=Bullseye | None)
def bullseye():
    return state.bullseye if state else None


app.include_router(router)
