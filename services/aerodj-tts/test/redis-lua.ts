/**
 * Runs the limiter's REAL Lua scripts against an in-memory Redis stand-in, so tests
 * exercise the exact script text that Upstash would execute (not a JS re-implementation).
 * Uses fengari (Lua 5.3 in pure JS); the scripts use only integers and the commands
 * below, which behave the same in Redis' Lua 5.1.
 *
 * Supported commands: GET, SET (with optional NX, EX and KEEPTTL), INCR, INCRBY, EXPIRE, PEXPIRE.
 * Each EVAL runs to completion synchronously, like a script in single-threaded Redis.
 */
import { lauxlib, lua, lualib, to_luastring, type LuaState } from 'fengari';

export class FakeRedis {
  readonly data = new Map<string, string>();
  /** Absolute expiry (ms since epoch) per key, as set by EXPIRE / PEXPIRE. */
  readonly expiresAt = new Map<string, number>();
  /** Every command a script issued, in order. */
  readonly commands: string[][] = [];

  /**
   * Opt-in: drop a key whose expiry is at or before `now()` when a command touches it,
   * like Redis' lazy expiry. Off by default so suites that predate it keep their behaviour.
   */
  evictExpired = false;

  constructor(public now: () => number = () => Date.UTC(2026, 9, 28, 12)) {}

  private command(args: string[]): string | number | false {
    this.commands.push(args);
    const [verb, key, ...rest] = args;
    if (this.evictExpired) {
      const at = this.expiresAt.get(key);
      if (at !== undefined && at <= this.now()) {
        this.data.delete(key);
        this.expiresAt.delete(key);
      }
    }
    switch (verb.toUpperCase()) {
      case 'GET':
        return this.data.get(key) ?? false;
      case 'SET': {
        // SET key value [NX] [EX seconds] [KEEPTTL], as the scripts use them. NX on an
        // existing key returns nil (false in Lua) and changes nothing, like Redis.
        const opts = rest.slice(1).map((r) => r.toUpperCase());
        if (opts.includes('NX') && this.data.has(key)) return false;
        this.data.set(key, rest[0]);
        const ex = opts.indexOf('EX');
        if (ex >= 0) this.expiresAt.set(key, this.now() + Number(rest[1 + ex + 1]) * 1000);
        else if (!opts.includes('KEEPTTL')) this.expiresAt.delete(key);
        return 'OK';
      }
      case 'INCR':
      case 'INCRBY': {
        const by = verb.toUpperCase() === 'INCR' ? 1 : Number(rest[0]);
        const current = Number(this.data.get(key) ?? '0');
        if (!Number.isInteger(current) || !Number.isInteger(by)) throw new Error('ERR value is not an integer');
        this.data.set(key, String(current + by));
        return current + by;
      }
      case 'EXPIRE':
        // Like Redis: 0 and no TTL for a missing key.
        if (!this.data.has(key)) return 0;
        this.expiresAt.set(key, this.now() + Number(rest[0]) * 1000);
        return 1;
      case 'PEXPIRE':
        this.expiresAt.set(key, this.now() + Number(rest[0]));
        return 1;
      default:
        throw new Error(`unsupported command ${verb}`);
    }
  }

  /** EVAL script numkeys key... arg... -> integer reply (Lua number), or null for nil/false. */
  eval(script: string, keys: string[], args: string[]): number | null {
    const L: LuaState = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);
    const pushArray = (name: string, values: string[]) => {
      lua.lua_newtable(L);
      values.forEach((v, i) => {
        lua.lua_pushstring(L, to_luastring(v));
        lua.lua_rawseti(L, -2, i + 1);
      });
      lua.lua_setglobal(L, to_luastring(name));
    };
    pushArray('KEYS', keys);
    pushArray('ARGV', args);
    lua.lua_newtable(L);
    lua.lua_pushjsfunction(L, (state) => {
      const n = lua.lua_gettop(state);
      const callArgs: string[] = [];
      for (let i = 1; i <= n; i++) {
        const t = lua.lua_type(state, i);
        if (t === lua.LUA_TNUMBER) {
          // Redis converts Lua numbers to integers when passing them as arguments.
          callArgs.push(String(Math.trunc(lua.lua_tonumber(state, i))));
        } else if (t === lua.LUA_TSTRING) {
          callArgs.push(lua.lua_tojsstring(state, i));
        } else {
          return lauxlib.luaL_error(state, to_luastring('redis.call: unsupported argument type'));
        }
      }
      const reply = this.command(callArgs);
      if (reply === false) lua.lua_pushboolean(state, false);
      else if (typeof reply === 'number') lua.lua_pushinteger(state, reply);
      else lua.lua_pushstring(state, to_luastring(reply));
      return 1;
    });
    lua.lua_setfield(L, -2, to_luastring('call'));
    lua.lua_setglobal(L, to_luastring('redis'));

    if (lauxlib.luaL_loadstring(L, to_luastring(script)) !== lua.LUA_OK) {
      throw new Error(`Lua compile error: ${lua.lua_tojsstring(L, -1)}`);
    }
    if (lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
      throw new Error(`Lua runtime error: ${lua.lua_tojsstring(L, -1)}`);
    }
    const t = lua.lua_type(L, -1);
    if (t === lua.LUA_TNIL || (t === lua.LUA_TBOOLEAN && !lua.lua_toboolean(L, -1))) return null;
    if (t === lua.LUA_TNUMBER) return Math.trunc(lua.lua_tonumber(L, -1)); // Redis: number -> integer reply
    throw new Error('unsupported script return type');
  }

  /** Counter value as an integer (0 when absent). */
  get(key: string): number {
    return Number(this.data.get(key) ?? '0');
  }
}

/**
 * Upstash REST stand-in backed by `FakeRedis`: POST ["EVAL", script, numkeys, ...keys, ...args]
 * returns { result }. Yields once before running so concurrent requests interleave.
 */
export function fakeUpstash(opts: { status?: number; redis?: FakeRedis } = {}) {
  const redis = opts.redis ?? new FakeRedis();
  const calls: { url: string; auth: string | null; command: unknown[] }[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    const command = JSON.parse(String(init.body)) as unknown[];
    calls.push({ url: String(url), auth: new Headers(init.headers).get('authorization'), command });
    await new Promise((r) => setImmediate(r));
    if (opts.status && opts.status !== 200) return new Response('{"error":"down"}', { status: opts.status });
    const [verb, script, numKeys, ...rest] = command as [string, string, number, ...string[]];
    if (verb !== 'EVAL') throw new Error('unexpected verb');
    const keys = rest.slice(0, numKeys);
    const args = rest.slice(numKeys);
    return new Response(JSON.stringify({ result: redis.eval(script, keys, args) }), { status: 200 });
  }) as typeof fetch;
  return { redis, calls, fetchImpl };
}
