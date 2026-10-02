// server/panel.lua: token + loopback gate, command whitelist, job capture and report pickup.
const assert = require('assert');
const { Harness, connect, PROJECT_DIR, HARNESS_DIR } = require('./driver');

(async () => {
  const conn = await connect('qbxm_test');
  await conn.query('DROP DATABASE qbxm_test; CREATE DATABASE qbxm_test; USE qbxm_test;');
  const h = new Harness(conn);
  await h.runFile(HARNESS_DIR + '/shim.lua', 'shim');
  await h.runCode("RESOURCE_STATES = { oxmysql = 'started', ox_lib = 'started' }", 'fixtures');
  for (const f of ['server.lua', 'server/esx.lua', 'server/identity.lua', 'server/panel.lua']) {
    await h.runFile(PROJECT_DIR + '/' + f, f);
  }

  const token = h.files['panel_token.txt'];
  assert.match(token, /^[0-9a-f]{32}$/, 'token generated and saved');

  // Runs one request; `then` lets queued CreateThread jobs finish first.
  const call = async (method, path, opts = {}) => {
    const headers = opts.headers || { 'X-Qbxm-Token': token };
    const lua = `
      if ${opts.drain ? 'true' : 'false'} then local t = THREADS; THREADS = {}; for _, fn in ipairs(t) do fn() end end
      local code, body = HTTP_REQUEST(${JSON.stringify(method)}, ${JSON.stringify(path)}, ${luaTable(headers)},
        ${JSON.stringify(opts.address || '127.0.0.1:51000')}, ${JSON.stringify(opts.body ? JSON.stringify(opts.body) : '')})
      RESULT = { code = code, body = body }`;
    await h.runCode(lua, 'request');
    return h.getGlobal('RESULT');
  };
  const luaTable = (o) => '{' + Object.entries(o).map(([k, v]) => `[${JSON.stringify(k)}] = ${JSON.stringify(v)}`).join(', ') + '}';

  let r = await call('GET', '/status', { address: '10.0.0.5:4000' });
  assert.strictEqual(r.code, 403, 'remote address refused');
  r = await call('GET', '/status', { headers: { 'X-Qbxm-Token': 'nope' } });
  assert.strictEqual(r.code, 401, 'bad token refused');
  r = await call('GET', '/status', { headers: { 'x-qbxm-token': token }, address: '[::1]:5000' });
  assert.strictEqual(r.code, 200, 'lowercase header + ipv6 loopback accepted');
  assert.strictEqual(r.body.busy, false);

  for (const body of [{ command: 'convertjobs' }, { command: 'restore', arg2: '../../etc' }, { command: 'schema', arg2: 'apply', arg3: 'x' }, { command: 'esx', arg2: 'rollback', arg3: 'nope' }]) {
    r = await call('POST', '/run', { body });
    assert.strictEqual(r.code, 400, 'refused ' + JSON.stringify(body));
  }

  r = await call('POST', '/run', { body: { command: 'inspect' } });
  assert.strictEqual(r.code, 200, JSON.stringify(r.body));
  const id = r.body.id;
  r = await call('POST', '/run', { body: { command: 'check' } });
  assert.strictEqual(r.code, 409, 'second job refused while one is queued');

  r = await call('GET', `/job?id=${id}&from=0`, { drain: true });
  assert.strictEqual(r.code, 200);
  assert.strictEqual(r.body.status, 'done', JSON.stringify(r.body).slice(0, 400));
  assert.strictEqual(r.body.command, 'qbxmigrate inspect');
  assert.ok(r.body.lines.some((l) => l.includes('report written')), 'console output captured');
  assert.match(r.body.reportFile, /^output\/\d{8}_\d{6}_inspect\.md$/);
  assert.match(r.body.report, /^# qbx_migrate schema inspection/, 'report content returned');
  const next = r.body.next;
  r = await call('GET', `/job?id=${id}&from=${next}`);
  assert.deepStrictEqual(r.body.lines, [], 'from= skips lines already sent');

  r = await call('POST', '/run', { body: { command: 'restore', arg2: '20990101_000000', arg3: 'apply' } });
  assert.strictEqual(r.code, 200, 'restore with a stamp allowed');
  r = await call('GET', `/job?id=${r.body.id}&from=0`, { drain: true });
  assert.strictEqual(r.body.status, 'done');
  assert.ok(r.body.report.includes('no backup manifest'), 'missing stamp reported, not crashed');

  r = await call('GET', '/status');
  assert.strictEqual(r.body.jobs.length, 2);
  assert.strictEqual(r.body.jobs[0].command, 'qbxmigrate restore 20990101_000000 apply', 'newest job first');
  r = await call('GET', '/job?id=999');
  assert.strictEqual(r.code, 404);

  await conn.end();
  console.log('panel suite: OK');
})().catch((e) => { console.error(e); process.exit(1); });
