// Loads the resource under the harness and runs `qbxmigrate help` to prove the shims work.
const { Harness, connect, PROJECT_DIR, HARNESS_DIR } = require('./driver');

(async () => {
  const conn = await connect('qbxm_test');
  const h = new Harness(conn);
  await h.runFile(HARNESS_DIR + '/shim.lua', 'shim');
  await h.runFile(PROJECT_DIR + '/server.lua', 'server.lua');
  await h.runFile(PROJECT_DIR + '/server/esx.lua', 'server/esx.lua');
  await h.runFile(PROJECT_DIR + '/server/identity.lua', 'server/identity.lua');
  await h.runCode("RUN_COMMAND('help')", 'cmd');
  const printed = h.getGlobal('PRINTED');
  console.log(printed.slice(0, 6).join('\n'));
  await conn.end();
})().catch((e) => { console.error(e); process.exit(1); });
