// Runs qbx_migrate's server Lua under fengari (Lua 5.3) against a real MariaDB,
// with FiveM/oxmysql shims. Lua yields DB requests; this driver executes them.
const fengari = require('fengari');
const mysql = require('mysql2/promise');
const fs = require('fs');
const path = require('path');

const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;

const HARNESS_DIR = path.resolve(__dirname).replace(/\\/g, '/');
const PROJECT_DIR = (process.env.QBXM_PROJECT || path.resolve(__dirname, '..')).replace(/\\/g, '/');

function jsToLua(L, v) {
  if (v === null || v === undefined) { lua.lua_pushnil(L); return; }
  if (typeof v === 'boolean') { lua.lua_pushboolean(L, v); return; }
  if (typeof v === 'number') {
    if (Number.isInteger(v)) lua.lua_pushinteger(L, v); else lua.lua_pushnumber(L, v);
    return;
  }
  if (typeof v === 'bigint') { lua.lua_pushinteger(L, Number(v)); return; }
  if (typeof v === 'string') { lua.lua_pushstring(L, to_luastring(v)); return; }
  if (Buffer.isBuffer(v)) { lua.lua_pushstring(L, to_luastring(v.toString('utf8'))); return; }
  if (v instanceof Date) { lua.lua_pushstring(L, to_luastring(v.toISOString().slice(0, 19).replace('T', ' '))); return; }
  if (Array.isArray(v)) {
    lua.lua_createtable(L, v.length, 0);
    v.forEach((item, i) => { jsToLua(L, item); lua.lua_rawseti(L, -2, i + 1); });
    return;
  }
  if (typeof v === 'object') {
    lua.lua_createtable(L, 0, Object.keys(v).length);
    for (const [k, val] of Object.entries(v)) {
      if (val === undefined) continue;
      lua.lua_pushstring(L, to_luastring(k));
      jsToLua(L, val);
      lua.lua_rawset(L, -3);
    }
    return;
  }
  lua.lua_pushnil(L);
}

function luaToJs(L, idx) {
  idx = lua.lua_absindex(L, idx);
  const t = lua.lua_type(L, idx);
  switch (t) {
    case lua.LUA_TNIL: return null;
    case lua.LUA_TBOOLEAN: return lua.lua_toboolean(L, idx);
    case lua.LUA_TNUMBER: return lua.lua_isinteger(L, idx) ? Number(lua.lua_tointeger(L, idx)) : lua.lua_tonumber(L, idx);
    case lua.LUA_TSTRING: return to_jsstring(lua.lua_tostring(L, idx));
    case lua.LUA_TTABLE: {
      // Decide array vs object: array when all keys are positive integers.
      const obj = {}; let maxIdx = 0; let allInt = true; let count = 0;
      lua.lua_pushnil(L);
      while (lua.lua_next(L, idx) !== 0) {
        const key = lua.lua_isinteger(L, -2) ? Number(lua.lua_tointeger(L, -2)) : (lua.lua_type(L, -2) === lua.LUA_TSTRING ? to_jsstring(lua.lua_tostring(L, -2)) : String(lua.lua_tonumber(L, -2)));
        if (typeof key === 'number' && key >= 1) { if (key > maxIdx) maxIdx = key; } else allInt = false;
        obj[key] = luaToJs(L, -1);
        count++;
        lua.lua_pop(L, 1);
      }
      if (count === 0) return [];
      if (allInt) {
        const arr = new Array(maxIdx).fill(null);
        for (let i = 1; i <= maxIdx; i++) if (obj[i] !== undefined) arr[i - 1] = obj[i];
        return arr;
      }
      return obj;
    }
    default: return null;
  }
}

class Harness {
  constructor(conn) {
    this.conn = conn;
    this.L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(this.L);
    this.files = {};
    this.setGlobalString('HARNESS_DIR', HARNESS_DIR);
    this.setGlobalString('PROJECT_DIR', PROJECT_DIR);
    // Files the resource reads from itself via LoadResourceFile (fengari has no io.open).
    const projectFiles = {};
    for (const sub of ['data', 'sql']) {
      const dir = path.join(PROJECT_DIR, sub);
      if (!fs.existsSync(dir)) continue;
      for (const f of fs.readdirSync(dir)) projectFiles[sub + '/' + f] = fs.readFileSync(path.join(dir, f), 'utf8');
    }
    jsToLua(this.L, projectFiles);
    lua.lua_setglobal(this.L, to_luastring('PROJECT_FILES'));
  }

  setGlobalString(name, value) {
    lua.lua_pushstring(this.L, to_luastring(value));
    lua.lua_setglobal(this.L, to_luastring(name));
  }

  async runFile(file, chunkname) {
    const code = fs.readFileSync(file, 'utf8');
    return this.runCode(code, chunkname || file);
  }

  // Runs Lua code in a coroutine, servicing yielded DB/file requests until it finishes.
  async runCode(code, chunkname) {
    const L = this.L;
    const co = lua.lua_newthread(L);
    const status = lauxlib.luaL_loadbuffer(co, to_luastring(code), code.length, to_luastring('=' + chunkname));
    if (status !== lua.LUA_OK) throw new Error('load error: ' + to_jsstring(lua.lua_tostring(co, -1)));

    let nargs = 0;
    for (;;) {
      const res = lua.lua_resume(co, L, nargs);
      if (res === lua.LUA_OK) { lua.lua_pop(L, 1); return; }
      if (res !== lua.LUA_YIELD) {
        const msg = to_jsstring(lua.lua_tostring(co, -1));
        const tb = lauxlib.luaL_traceback ? '' : '';
        lua.lua_pop(L, 1);
        throw new Error('Lua error: ' + msg + tb);
      }
      const req = luaToJs(co, -1);
      lua.lua_pop(co, lua.lua_gettop(co));
      if (req && req.file) {
        this.files[req.file] = req.data;
        nargs = 0;
        continue;
      }
      try {
        const out = await this.exec(req);
        lua.lua_pushboolean(co, true);
        jsToLua(co, out);
        nargs = 2;
      } catch (e) {
        lua.lua_pushboolean(co, false);
        lua.lua_pushstring(co, to_luastring(String(e.message || e)));
        nargs = 2;
      }
    }
  }

  fixParams(params) {
    if (params == null) return [];
    if (!Array.isArray(params)) return Object.values(params);
    return params.map((p) => (p === undefined ? null : p));
  }

  async exec(req) {
    const { db, query, params } = req;
    const conn = this.conn;
    if (db === 'transaction') {
      const list = params || [];
      await conn.beginTransaction();
      try {
        for (const entry of list) {
          const q = typeof entry === 'string' ? entry : entry.query;
          const v = typeof entry === 'string' ? [] : this.fixParams(entry.values);
          await conn.query(q, v);
        }
        await conn.commit();
        return true;
      } catch (e) { await conn.rollback(); throw e; }
    }
    if (db === 'prepare') {
      const batch = Array.isArray(params) && params.length > 0 && Array.isArray(params[0]) ? params : [params];
      const results = [];
      for (const row of batch) {
        const [r] = await conn.query(query, this.fixParams(row));
        results.push(Array.isArray(r) ? r : (r.affectedRows ?? 0));
      }
      return batch.length === 1 && !(Array.isArray(params) && params.length > 0 && Array.isArray(params[0])) ? results[0] : results;
    }
    const [rows] = await conn.query(query, this.fixParams(params));
    if (db === 'query') return Array.isArray(rows) ? rows : { affectedRows: rows.affectedRows, insertId: rows.insertId };
    if (db === 'scalar') { if (!Array.isArray(rows) || rows.length === 0) return null; const r = rows[0]; return r[Object.keys(r)[0]]; }
    if (db === 'single') return Array.isArray(rows) && rows.length ? rows[0] : null;
    if (db === 'insert') return rows.insertId;
    if (db === 'update') return rows.affectedRows;
    return rows;
  }

  // Read a Lua global (marshalled to JS).
  getGlobal(name) {
    lua.lua_getglobal(this.L, to_luastring(name));
    const v = luaToJs(this.L, -1);
    lua.lua_pop(this.L, 1);
    return v;
  }
}

async function connect(database) {
  return mysql.createConnection({ host: process.env.QBXM_DB_HOST || '127.0.0.1', port: Number(process.env.QBXM_DB_PORT || 3399), user: process.env.QBXM_DB_USER || 'qbxm', password: process.env.QBXM_DB_PASS || 'qbxm', database, multipleStatements: true, dateStrings: true, supportBigNumbers: true });
}

module.exports = { Harness, connect, PROJECT_DIR, HARNESS_DIR };
