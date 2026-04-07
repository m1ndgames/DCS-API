fn main() {
    // lua.lib (import library pointing to lua.dll) lives in lua_lib/.
    // This path is also set via .cargo/config.toml so mlua-sys picks up
    // LUA_LIB_NAME=lua and LUA_LIB=lua_lib, making our DLL import lua.dll
    // (DCS's Lua runtime) instead of the default lua51.dll.
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    println!("cargo:rustc-link-search=native={}/lua_lib", manifest_dir);
}
