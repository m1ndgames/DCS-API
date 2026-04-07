use mlua::prelude::*;
use serde::Serialize;
use std::sync::{LazyLock, Mutex};

// --- Config (set once by dcsapi.init(), defaults match dcsapi.cfg) ---

static API_URL: LazyLock<Mutex<String>> = LazyLock::new(|| {
    Mutex::new("http://127.0.0.1:4414/ingest".to_string())
});

static API_KEY: LazyLock<Mutex<String>> = LazyLock::new(|| {
    Mutex::new(String::new())
});

// --- Data structures (mirror the FastAPI models) ---

#[derive(Serialize, Clone, Default)]
struct Position {
    lat: f64,
    lon: f64,
    alt: f64,
}

#[derive(Serialize, Clone)]
struct Player {
    name: String,
    player_id: i32,
    aircraft: String,
    ucid: String,
    ip: String,
    coalition: i32,
    #[serde(skip)]
    unit_name: String,
    position: Position,
    speed: f64,
}

#[derive(Serialize, Clone)]
struct Unit {
    name: String,
    #[serde(rename = "class")]
    unit_class: String,
    #[serde(rename = "type")]
    unit_type: String,
    player_controlled: bool,
    group_name: String,
    coalition: i32,
    position: Position,
    speed: f64,
}

#[derive(Serialize, Clone, Default)]
struct Mission {
    mission: String,
    map: String,
    runtime: f64,
    fps: f64,
    players_active: i32,
    players_max: i32,
}

#[derive(Serialize, Clone)]
struct Airbase {
    name: String,
    category: String,   // "airdrome", "helipad", "ship"
    coalition: i32,
    position: Position,
}

#[derive(Serialize, Clone, Default)]
struct Weather {
    wind_dir: f64,    // degrees, meteorological (direction FROM)
    wind_speed: f64,  // m/s horizontal
    temperature: f64, // Celsius
    pressure: f64,    // hPa
}

#[derive(Serialize, Clone, Default)]
struct BullseyePoint {
    lat: f64,
    lon: f64,
}

#[derive(Serialize, Clone, Default)]
struct Bullseye {
    red: BullseyePoint,
    blue: BullseyePoint,
}

#[derive(Serialize, Clone, Default)]
struct GameState {
    mission: Mission,
    players: Vec<Player>,
    units: Vec<Unit>,
    airbases: Vec<Airbase>,
    weather: Weather,
    bullseye: Bullseye,
}

// --- In-memory state shared across Lua calls ---

static STATE: LazyLock<Mutex<GameState>> = LazyLock::new(|| Mutex::new(GameState::default()));

// --- HTTP POST (fire and forget — API being down must never crash DCS) ---

fn post_state(state: &GameState) {
    let url = API_URL.lock().unwrap().clone();
    let key = API_KEY.lock().unwrap().clone();
    let client = reqwest::blocking::Client::new();
    let mut req = client.post(&url).json(state);
    if !key.is_empty() {
        req = req.header("X-API-Key", key);
    }
    let _ = req.send();
}

// --- Lua-callable functions ---

/// Called by dcsapi.lua on startup with values from dcsapi.cfg.
fn init(_lua: &Lua, (host, port, api_key): (String, u32, String)) -> LuaResult<()> {
    let mut url = API_URL.lock().map_err(|e| LuaError::RuntimeError(e.to_string()))?;
    *url = format!("http://{}:{}/ingest", host, port);
    let mut key = API_KEY.lock().map_err(|e| LuaError::RuntimeError(e.to_string()))?;
    *key = api_key;
    Ok(())
}

/// Called by the hook script each frame/interval with current mission data.
fn update_mission(_lua: &Lua, (name, runtime, map, players_max): (String, f64, String, i32)) -> LuaResult<()> {
    let mut state = STATE.lock().map_err(|e| LuaError::RuntimeError(e.to_string()))?;
    state.mission.mission = name;
    state.mission.runtime = runtime;
    state.mission.map = map;
    state.mission.players_max = players_max;
    post_state(&state);
    Ok(())
}

/// Called by the hook script with a table of connected players.
fn update_players(_lua: &Lua, players: LuaTable) -> LuaResult<()> {
    let mut state = STATE.lock().map_err(|e| LuaError::RuntimeError(e.to_string()))?;

    let mut new_players = Vec::new();
    for pair in players.pairs::<LuaValue, LuaTable>() {
        let (_, p) = pair?;
        new_players.push(Player {
            name:       p.get::<String>("name")?,
            player_id:  p.get::<i32>("player_id")?,
            aircraft:   p.get::<String>("aircraft").unwrap_or_default(),
            ucid:       p.get::<String>("ucid").unwrap_or_default(),
            ip:         p.get::<String>("ip").unwrap_or_default(),
            coalition:  p.get::<i32>("coalition").unwrap_or(0),
            unit_name:  p.get::<String>("unit_name").unwrap_or_default(),
            position: Position {
                lat: p.get::<f64>("lat").unwrap_or(0.0),
                lon: p.get::<f64>("lon").unwrap_or(0.0),
                alt: p.get::<f64>("alt").unwrap_or(0.0),
            },
            speed: p.get::<f64>("speed").unwrap_or(0.0),
        });
    }
    state.mission.players_active = new_players.len() as i32;
    state.players = new_players;
    post_state(&state);
    Ok(())
}

/// Called by the hook script with a table of all world units (AI + players + statics).
fn update_units(_lua: &Lua, units: LuaTable) -> LuaResult<()> {
    let mut state = STATE.lock().map_err(|e| LuaError::RuntimeError(e.to_string()))?;

    let mut new_units = Vec::new();
    for pair in units.pairs::<LuaValue, LuaTable>() {
        let (_, u) = pair?;
        new_units.push(Unit {
            name:              u.get::<String>("name").unwrap_or_default(),
            unit_class:        u.get::<String>("unit_class").unwrap_or_default(),
            unit_type:         u.get::<String>("unit_type").unwrap_or_default(),
            player_controlled: u.get::<bool>("player_controlled").unwrap_or(false),
            group_name:        u.get::<String>("group_name").unwrap_or_default(),
            coalition:         u.get::<i32>("coalition").unwrap_or(0),
            position: Position {
                lat: u.get::<f64>("lat").unwrap_or(0.0),
                lon: u.get::<f64>("lon").unwrap_or(0.0),
                alt: u.get::<f64>("alt").unwrap_or(0.0),
            },
            speed: u.get::<f64>("speed").unwrap_or(0.0),
        });
    }
    state.units = new_units;
    post_state(&state);
    Ok(())
}

/// Called by the hook script with a table of all airbases on the map.
fn update_airbases(_lua: &Lua, airbases: LuaTable) -> LuaResult<()> {
    let mut state = STATE.lock().map_err(|e| LuaError::RuntimeError(e.to_string()))?;

    let mut new_airbases = Vec::new();
    for pair in airbases.pairs::<LuaValue, LuaTable>() {
        let (_, ab) = pair?;
        new_airbases.push(Airbase {
            name:      ab.get::<String>("name").unwrap_or_default(),
            category:  ab.get::<String>("category").unwrap_or_default(),
            coalition: ab.get::<i32>("coalition").unwrap_or(0),
            position: Position {
                lat: ab.get::<f64>("lat").unwrap_or(0.0),
                lon: ab.get::<f64>("lon").unwrap_or(0.0),
                alt: ab.get::<f64>("alt").unwrap_or(0.0),
            },
        });
    }
    state.airbases = new_airbases;
    post_state(&state);
    Ok(())
}

/// Called by the hook script with current weather conditions at sea level.
fn update_weather(_lua: &Lua, (wind_dir, wind_speed, temperature, pressure): (f64, f64, f64, f64)) -> LuaResult<()> {
    let mut state = STATE.lock().map_err(|e| LuaError::RuntimeError(e.to_string()))?;
    state.weather = Weather { wind_dir, wind_speed, temperature, pressure };
    post_state(&state);
    Ok(())
}

/// Called by the hook script with bullseye positions for red and blue coalitions.
fn update_bullseye(_lua: &Lua, (red_lat, red_lon, blue_lat, blue_lon): (f64, f64, f64, f64)) -> LuaResult<()> {
    let mut state = STATE.lock().map_err(|e| LuaError::RuntimeError(e.to_string()))?;
    state.bullseye = Bullseye {
        red:  BullseyePoint { lat: red_lat,  lon: red_lon  },
        blue: BullseyePoint { lat: blue_lat, lon: blue_lon },
    };
    post_state(&state);
    Ok(())
}

/// Called by dcsapi_export.lua each interval with the current server FPS.
fn set_fps(_lua: &Lua, fps: f64) -> LuaResult<()> {
    let mut state = STATE.lock().map_err(|e| LuaError::RuntimeError(e.to_string()))?;
    state.mission.fps = (fps * 100.0).round() / 100.0;
    post_state(&state);
    Ok(())
}

/// Called by dcsapi_export.lua each interval with a table of { [unitName] = {lat, lon, alt} }.
fn set_positions_by_name(_lua: &Lua, obj_positions: LuaTable) -> LuaResult<()> {
    let mut state = STATE.lock().map_err(|e| LuaError::RuntimeError(e.to_string()))?;

    for pair in obj_positions.pairs::<String, LuaTable>() {
        let (unit_name, pos) = pair?;
        if let Some(player) = state.players.iter_mut().find(|p| p.unit_name == unit_name) {
            player.position = Position {
                lat: pos.get::<f64>("lat").unwrap_or(0.0),
                lon: pos.get::<f64>("lon").unwrap_or(0.0),
                alt: pos.get::<f64>("alt").unwrap_or(0.0),
            };
        }
    }
    post_state(&state);
    Ok(())
}

// --- Lua module entry point ---

#[mlua::lua_module]
fn dcsapi(lua: &Lua) -> LuaResult<LuaTable> {
    let exports = lua.create_table()?;
    exports.set("init",                  lua.create_function(init)?)?;
    exports.set("update_mission",        lua.create_function(update_mission)?)?;
    exports.set("update_players",        lua.create_function(update_players)?)?;
    exports.set("update_units",          lua.create_function(update_units)?)?;
    exports.set("update_airbases",       lua.create_function(update_airbases)?)?;
    exports.set("update_weather",        lua.create_function(update_weather)?)?;
    exports.set("update_bullseye",       lua.create_function(update_bullseye)?)?;
    exports.set("set_fps",               lua.create_function(set_fps)?)?;
    exports.set("set_positions_by_name", lua.create_function(set_positions_by_name)?)?;
    Ok(exports)
}
