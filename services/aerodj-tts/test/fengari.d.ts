// Minimal typing for the parts of fengari (a Lua 5.3 VM in pure JS, devDependency) that
// test/redis-lua.ts uses to run the limiter's real Lua scripts.
declare module 'fengari' {
  export type LuaState = unknown;
  export const lua: {
    LUA_OK: number;
    LUA_TNIL: number;
    LUA_TBOOLEAN: number;
    LUA_TNUMBER: number;
    LUA_TSTRING: number;
    lua_gettop(L: LuaState): number;
    lua_type(L: LuaState, idx: number): number;
    lua_tojsstring(L: LuaState, idx: number): string;
    lua_toboolean(L: LuaState, idx: number): boolean;
    lua_isinteger(L: LuaState, idx: number): boolean;
    lua_tointeger(L: LuaState, idx: number): number;
    lua_tonumber(L: LuaState, idx: number): number;
    lua_pushinteger(L: LuaState, n: number): void;
    lua_pushboolean(L: LuaState, b: boolean): void;
    lua_pushstring(L: LuaState, s: Uint8Array): void;
    lua_pushjsfunction(L: LuaState, fn: (L: LuaState) => number): void;
    lua_newtable(L: LuaState): void;
    lua_setfield(L: LuaState, idx: number, k: Uint8Array): void;
    lua_rawseti(L: LuaState, idx: number, n: number): void;
    lua_setglobal(L: LuaState, name: Uint8Array): void;
    lua_pcall(L: LuaState, nargs: number, nresults: number, msgh: number): number;
  };
  export const lauxlib: {
    luaL_newstate(): LuaState;
    luaL_loadstring(L: LuaState, s: Uint8Array): number;
    luaL_error(L: LuaState, fmt: Uint8Array): never;
  };
  export const lualib: { luaL_openlibs(L: LuaState): void };
  export function to_luastring(s: string): Uint8Array;
}
