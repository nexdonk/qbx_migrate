// End-to-end: QBCore database -> schema apply -> inventory apply -> identity reconcile.
const assert = require('assert');
const { Harness, connect, PROJECT_DIR, HARNESS_DIR } = require('./driver');

const LIC = 'license:' + 'e'.repeat(40);
const FIXTURE_SQL = `
DROP DATABASE qbxm_test; CREATE DATABASE qbxm_test; USE qbxm_test;
CREATE TABLE players (
  id int AUTO_INCREMENT, citizenid varchar(50) NOT NULL, cid int, license varchar(255) NOT NULL, name varchar(255) NOT NULL,
  money text NOT NULL, charinfo text, job text NOT NULL, gang text, position text NOT NULL, metadata text NOT NULL, inventory longtext,
  last_updated timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (citizenid), KEY id (id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE player_vehicles (id int AUTO_INCREMENT PRIMARY KEY, license varchar(50), citizenid varchar(50), vehicle varchar(50), hash varchar(50), mods longtext, plate varchar(15) NOT NULL UNIQUE, garage varchar(50), fuel int DEFAULT 100, engine float DEFAULT 1000, body float DEFAULT 1000, state int DEFAULT 1);
CREATE TABLE stashitems (id int AUTO_INCREMENT PRIMARY KEY, stash varchar(255) NOT NULL, items longtext);
CREATE TABLE trunkitems (id int AUTO_INCREMENT PRIMARY KEY, plate varchar(255) NOT NULL, items longtext);
CREATE TABLE gloveboxitems (id int AUTO_INCREMENT PRIMARY KEY, plate varchar(255) NOT NULL, items longtext);
CREATE TABLE bans (id int AUTO_INCREMENT PRIMARY KEY, name varchar(50), license varchar(50), discord varchar(50), ip varchar(50), reason text, expire int, bannedby varchar(255) NOT NULL DEFAULT 'x');

INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory) VALUES
 ('QBX00001', 1, '${LIC}', 'Bob', '{"cash":100,"bank":500,"crypto":0}', '{"firstname":"Bob","lastname":"B","phone":"1234567","birthdate":"1990-01-01","gender":0,"cid":1}',
  '{"name":"police","label":"LSPD","payment":50,"onduty":true,"isboss":false,"grade":{"name":"Officer","level":"1"}}', '{"name":"none","label":"No Gang","isboss":false,"grade":{"name":"none","level":0}}',
  '{"x":1,"y":2,"z":3,"w":4}', '{"hunger":80,"thirst":70}',
  '{"1":{"name":"lockpick","amount":2,"info":{},"slot":1,"type":"item"},"2":{"name":"weapon_pistol","amount":1,"info":{"serie":"ABC","quality":88,"attachments":["at_flashlight"]},"slot":2,"type":"weapon"},"3":{"name":"cash","amount":100,"info":{},"slot":3},"5":{"name":"burger","amount":1,"info":{"quality":40},"slot":5}}'),
 ('QBX00002', 1, 'license:${'f'.repeat(40)}', 'Al', '{"cash":0,"bank":0,"crypto":0}', '{"firstname":"Al","lastname":"A","phone":"7654321","cid":1}',
  '{"name":"unemployed","grade":{"level":0}}', '{"name":"none"}', '{}', '{}', '[{"slot":1,"name":"water","count":1,"metadata":{}}]');
INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES ('${LIC}', 'QBX00001', 'adder', '1', '{}', 'QB 001', 'pillbox', 1);
INSERT INTO stashitems (stash, items) VALUES ('policestash', '{"1":{"name":"lockpick","amount":5,"info":{},"slot":1}}');
INSERT INTO trunkitems (plate, items) VALUES ('QB 001', '{"1":{"name":"burger","amount":3,"info":{},"slot":1}}'), ('NOVEH', '{"1":{"name":"water","amount":1,"info":{},"slot":1}}');
INSERT INTO gloveboxitems (plate, items) VALUES ('QB 001', '[]');
INSERT INTO bans (name, license, reason, expire) VALUES ('Bob', '${LIC}', 'test', 0);
`;

const FIX_LUA = `
OX_ITEMS = { lockpick = { weight = 100 }, water = { weight = 200 }, burger = { weight = 50 }, weapon_pistol = { weight = 1000 }, at_flashlight = { weight = 5 }, money = { weight = 0 } }
RESOURCE_STATES = { ox_inventory = 'started', oxmysql = 'started', ox_lib = 'started' }
`;
const q = async (conn, sql, p) => (await conn.query(sql, p))[0];
const one = async (conn, sql, p) => (await q(conn, sql, p))[0];
const J = (s) => (typeof s === 'string' ? JSON.parse(s) : s);

(async () => {
  const conn = await connect('qbxm_test');
  await conn.query(FIXTURE_SQL);
  const h = new Harness(conn);
  await h.runFile(HARNESS_DIR + '/shim.lua', 'shim');
  await h.runCode(FIX_LUA, 'fixtures');
  await h.runFile(PROJECT_DIR + '/server.lua', 'server.lua');
  await h.runFile(PROJECT_DIR + '/server/esx.lua', 'server/esx.lua');
  await h.runFile(PROJECT_DIR + '/server/identity.lua', 'server/identity.lua');

  await h.runCode("RUN_COMMAND('inspect') RUN_COMMAND('check') RUN_COMMAND('schema') RUN_COMMAND('schema', 'apply') RUN_COMMAND('inventory') RUN_COMMAND('inventory', 'apply') RUN_COMMAND('phone', 'apply') RUN_COMMAND('metadata', 'apply') RUN_COMMAND('all')", 'cmd');
  let printed = h.getGlobal('PRINTED');
  const failed = printed.filter((l) => /FAILED/.test(l));
  assert.deepStrictEqual(failed, [], 'errors:\n' + failed.join('\n'));
  assert.ok(!printed.some((l) => l.includes('ESX database detected')), 'QB db not mistaken for ESX');

  for (const c of ['last_logged_out', 'userId', 'phone_number']) {
    assert.ok((await q(conn, `SHOW COLUMNS FROM players LIKE '${c}'`)).length === 1, 'column added ' + c);
  }
  assert.ok((await q(conn, "SHOW COLUMNS FROM player_vehicles LIKE 'trunk'")).length === 1, 'trunk column');
  const coll = (await one(conn, "SELECT COLLATION_NAME c FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME='players' AND COLUMN_NAME='citizenid'")).c;
  assert.strictEqual(coll, 'utf8mb4_unicode_ci', 'collation fixed');
  for (const t of ['player_groups', 'ox_inventory']) assert.ok((await q(conn, `SHOW TABLES LIKE '${t}'`)).length === 1, 'table ' + t);

  const bob = await one(conn, "SELECT * FROM players WHERE citizenid = 'QBX00001'");
  const inv = J(bob.inventory);
  assert.ok(Array.isArray(inv), 'ox array');
  const byName = Object.fromEntries(inv.map((i) => [i.name, i]));
  assert.deepStrictEqual(Object.keys(byName).sort(), ['burger', 'lockpick', 'weapon_pistol'], 'cash stripped');
  assert.strictEqual(byName.lockpick.count, 2);
  assert.strictEqual(byName.weapon_pistol.metadata.serial, 'ABC');
  assert.strictEqual(byName.weapon_pistol.metadata.durability, 88);
  assert.deepStrictEqual(byName.weapon_pistol.metadata.components, ['at_flashlight']);
  assert.strictEqual(byName.burger.metadata.quality, 40, 'non-weapon quality kept as quality');
  assert.strictEqual(byName.burger.slot, 5);
  assert.strictEqual(bob.phone_number, '1234567', 'phone backfilled');
  assert.strictEqual(J(bob.metadata).hunger, 80); assert.strictEqual(J(bob.metadata).stress, 0, 'metadata default added');
  const al = await one(conn, "SELECT * FROM players WHERE citizenid = 'QBX00002'");
  assert.strictEqual(al.inventory, '[{"slot":1,"name":"water","count":1,"metadata":{}}]', 'already-ox untouched');

  const stash = await one(conn, "SELECT data FROM ox_inventory WHERE name = 'policestash' AND owner = ''");
  assert.deepStrictEqual(J(stash.data).map((i) => [i.name, i.count]), [['lockpick', 5]], 'stash converted');
  const veh = await one(conn, "SELECT trunk, glovebox FROM player_vehicles WHERE plate = 'QB 001'");
  assert.deepStrictEqual(J(veh.trunk).map((i) => [i.name, i.count]), [['burger', 3]], 'trunk converted');
  assert.strictEqual(veh.glovebox, null, 'empty glovebox left alone');
  assert.ok(printed.some((l) => l.includes('NOVEH')), 'orphan trunk plate reported');

  // idempotent inventory re-run
  await h.runCode("PRINTED = {} RUN_COMMAND('inventory', 'apply')", 'cmd');
  printed = h.getGlobal('PRINTED');
  assert.ok(printed.some((l) => /players: 0 rows need conversion, 2 already ox format/.test(l)), 'rerun detects ox: ' + printed.filter((l) => l.includes('need conversion')).join(' | '));

  // identity: QBCore license -> license2
  const NEW = 'license2:' + '1'.repeat(40);
  await h.runCode(`PLAYER_IDENTIFIERS[1] = { '${LIC}', '${NEW}', 'ip:9.9.9.9' } PRINTED = {} RUN_CONNECT(1)`, 'cmd');
  assert.strictEqual((await one(conn, "SELECT license FROM players WHERE citizenid = 'QBX00001'")).license, NEW, 'players.license -> license2');
  assert.strictEqual((await one(conn, "SELECT license FROM players WHERE citizenid = 'QBX00002'")).license, 'license:' + 'f'.repeat(40), 'other player untouched');
  assert.strictEqual((await one(conn, 'SELECT license FROM bans')).license, NEW, 'bans.license -> license2');
  assert.strictEqual((await one(conn, "SELECT license FROM player_vehicles WHERE plate = 'QB 001'")).license, NEW, 'player_vehicles.license -> license2');

  // no license2 on client (edge): nothing happens, no error
  await h.runCode(`PLAYER_IDENTIFIERS[3] = { 'license:${'f'.repeat(40)}' } PRINTED = {} RUN_CONNECT(3)`, 'cmd');
  printed = h.getGlobal('PRINTED');
  assert.ok(!printed.some((l) => l.includes('FAILED')), 'no-license2 connect is quiet');

  // restore round-trip
  const stamps = Object.keys(h.files).map((f) => (f.match(/^backups\/([^/]+)\/manifest\.json$/) || [])[1]).filter(Boolean).sort();
  const stamp = stamps[0];
  assert.ok(stamp, 'backup stamp found');
  assert.strictEqual(stamps.length, 2, 'two distinct backup stamps even within one second: ' + stamps.join(','));
  // Feed the saved backup files back to LoadResourceFile through FIXTURE_FILES.
  const fileEntries = Object.entries(h.files).filter(([k]) => k.startsWith('backups/' + stamp + '/'));
  let luaFix = '';
  for (const [k, v] of fileEntries) luaFix += `FIXTURE_FILES['qbx_migrate/${k}'] = ${JSON.stringify(v)}\n`;
  await h.runCode(luaFix, 'fixfiles');
  await conn.query("UPDATE players SET inventory = '[]' WHERE citizenid = 'QBX00001'");
  await h.runCode(`PRINTED = {} RUN_COMMAND('restore', '${stamp}') RUN_COMMAND('restore', '${stamp}', 'apply')`, 'cmd');
  printed = h.getGlobal('PRINTED');
  assert.deepStrictEqual(printed.filter((l) => /FAILED|ERROR/.test(l)), [], 'restore errors:\n' + printed.filter((l) => /FAILED|ERROR/.test(l)).join('\n'));
  const restoredRaw = (await one(conn, "SELECT inventory FROM players WHERE citizenid = 'QBX00001'")).inventory;
  const restored = J(restoredRaw);
  assert.ok(!Array.isArray(restored) && restored['1'].amount === 2, 'restore put the qb-format inventory back. got: ' + restoredRaw + '\n' + printed.join('\n'));
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM ox_inventory')).n, 0, 'ox_inventory wiped back to the (empty) snapshot');

  await conn.end();
  console.log('\nALL QB TESTS PASSED');
})().catch((e) => { console.error(e); process.exit(1); });
