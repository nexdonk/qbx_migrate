// End-to-end: ESX Legacy database -> qbxmigrate esx apply -> identity reconcile -> rollback.
const assert = require('assert');
const { Harness, connect, PROJECT_DIR, HARNESS_DIR } = require('./driver');

function joaat(s) {
  s = s.toLowerCase(); let h = 0;
  for (let i = 0; i < s.length; i++) { h = (h + s.charCodeAt(i)) >>> 0; h = (h + (h << 10)) >>> 0; h = (h ^ (h >>> 6)) >>> 0; }
  h = (h + (h << 3)) >>> 0; h = (h ^ (h >>> 11)) >>> 0; h = (h + (h << 15)) >>> 0;
  return h >>> 0;
}
const signed = (u) => (u >= 0x80000000 ? u - 0x100000000 : u);

const HEX1 = 'a'.repeat(40);
const HEX2 = 'b'.repeat(40);
const STEAM3 = '110000112345678';
const STEAM4 = '110000198765432';
const ADDER = signed(joaat('adder'));

const FIXTURE_SQL = `
DROP DATABASE qbxm_test; CREATE DATABASE qbxm_test; USE qbxm_test;
CREATE TABLE users (
  identifier varchar(60) NOT NULL, accounts longtext, \`group\` varchar(50) DEFAULT 'user', inventory longtext,
  job varchar(20) DEFAULT 'unemployed', job_grade int DEFAULT 0, loadout longtext, metadata longtext, position longtext,
  firstname varchar(16), lastname varchar(16), dateofbirth varchar(10), sex varchar(1), height int, skin longtext,
  status longtext, is_dead tinyint(1) DEFAULT 0, disabled tinyint(1) DEFAULT 0, phone_number varchar(20),
  PRIMARY KEY (identifier)) ENGINE=InnoDB;
CREATE TABLE jobs (name varchar(50) PRIMARY KEY, label varchar(50), type varchar(50));
CREATE TABLE job_grades (id int AUTO_INCREMENT PRIMARY KEY, job_name varchar(50), grade int, name varchar(50), label varchar(50), salary int, skin_male longtext, skin_female longtext);
CREATE TABLE items (name varchar(50) PRIMARY KEY, label varchar(50), weight int DEFAULT 1, rare tinyint DEFAULT 0, can_remove tinyint DEFAULT 1);
CREATE TABLE owned_vehicles (owner varchar(60), plate varchar(12) PRIMARY KEY, vehicle longtext, type varchar(20) DEFAULT 'car', job varchar(20), stored tinyint DEFAULT 0, parking varchar(60), pound varchar(60));
CREATE TABLE user_licenses (id int AUTO_INCREMENT PRIMARY KEY, type varchar(60), owner varchar(60));
CREATE TABLE addon_inventory_items (id int AUTO_INCREMENT PRIMARY KEY, inventory_name varchar(100), name varchar(100), count int, owner varchar(60));
CREATE TABLE addon_account_data (id int AUTO_INCREMENT PRIMARY KEY, account_name varchar(100), money int, owner varchar(60));
CREATE TABLE datastore_data (id int AUTO_INCREMENT PRIMARY KEY, name varchar(60), owner varchar(60), data longtext);
CREATE TABLE billing (id int AUTO_INCREMENT PRIMARY KEY, identifier varchar(60), sender varchar(60), target_type varchar(50), target varchar(60), label varchar(255), amount int);
CREATE TABLE ox_inventory (owner varchar(60), name varchar(100) NOT NULL, data longtext, lastupdated timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(), UNIQUE KEY owner_name (owner, name));

INSERT INTO jobs VALUES ('unemployed','Unemployed',NULL), ('police','LSPD','leo');
INSERT INTO job_grades (job_name, grade, name, label, salary, skin_male, skin_female) VALUES
  ('unemployed',0,'unemployed','Unemployed',200,'{}','{}'),
  ('police',0,'recruit','Recruit',20,'{}','{}'), ('police',3,'boss','Chief',300,'{}','{}');
INSERT INTO items VALUES ('bread','Bread',1,0,1), ('water','Water',1,0,1), ('nothing','Nothing',0,0,1), ('phone','Phone',2,0,1);

INSERT INTO users (identifier, accounts, \`group\`, inventory, job, job_grade, loadout, metadata, position, firstname, lastname, dateofbirth, sex, height, status, is_dead, phone_number) VALUES
 ('${HEX1}', '{"money":150,"bank":2000,"black_money":500}', 'superadmin', '{"bread":2,"water":1,"nothing":0}', 'police', 3,
  '{"WEAPON_PISTOL":{"ammo":30,"components":["clip_default","flashlight","clip_extended"],"tintIndex":2}}', '{"health":180,"armor":50}',
  '{"x":100.5,"y":-200.25,"z":30,"heading":90}', 'John', 'Doe', '25/12/1990', 'm', 180, '[{"name":"hunger","val":500000,"percent":50},{"name":"thirst","val":250000,"percent":25}]', 0, '5551234'),
 ('char1:${HEX2}', '{"money":10,"bank":0}', 'user', '[{"name":"bread","count":3},{"name":"phone","count":1}]', 'unemployed', 0, NULL, NULL, NULL, 'Jane', 'Roe', '03/04/2001', 'f', 165, NULL, 1, '5559999'),
 ('char2:${HEX2}', NULL, 'user', NULL, 'police', 0, '[]', NULL, '{"x":1,"y":2,"z":3}', 'Jim', 'Roe', '2002-05-06', 'm', 170, NULL, 0, NULL),
 ('steam:${STEAM3}', '{"money":5,"bank":5}', 'admin', '[{"slot":1,"name":"water","count":2,"metadata":{"foo":"bar"}}]', 'unemployed', 0, NULL, NULL, NULL, 'Ox', 'User', '01/01/1999', 'm', 175, NULL, 0, '5551234'),
 ('char1:${STEAM4}', NULL, 'user', '', 'unemployed', 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0, NULL);

INSERT INTO owned_vehicles (owner, plate, vehicle, stored, parking, pound) VALUES
 ('${HEX1}', 'ABC 123 ', '{"model":${ADDER},"plate":"ABC 123 ","fuelLevel":55.5,"engineHealth":900,"bodyHealth":950,"color1":12}', 1, 'Legion', NULL),
 ('char2:${HEX2}', 'XYZ 999', '{"model":123456789,"plate":"XYZ 999"}', 0, NULL, NULL),
 ('society_police', 'POL 1', '{"model":"police","plate":"POL 1"}', 1, NULL, NULL),
 ('char1:${HEX2}', 'IMP 001', '{"model":${ADDER}}', 0, NULL, 'impound');

INSERT INTO user_licenses (type, owner) VALUES ('drive','${HEX1}'), ('weapon','${HEX1}'), ('dmv','char1:${HEX2}');
INSERT INTO addon_inventory_items (inventory_name, name, count, owner) VALUES ('society_police','bread',10,NULL), ('property','water',2,'${HEX1}');
INSERT INTO addon_account_data (account_name, money, owner) VALUES ('society_police', 12345, NULL), ('bank_savings', 7, '${HEX1}');
INSERT INTO datastore_data (name, owner, data) VALUES ('society_police', NULL, '{"items":[{"name":"water","count":5}],"weapons":[{"name":"WEAPON_BAT","ammo":0,"components":[]}]}');
INSERT INTO ox_inventory (owner, name, data) VALUES ('char1:${HEX2}', 'stash_x', '[]'), ('', 'shared', '[]');
`;

const OX_ITEMS_LUA = `
OX_ITEMS = {
  bread = { weight = 100 }, water = { weight = 200 }, phone = { weight = 50 }, black_money = { weight = 0 },
  weapon_pistol = { weight = 1000 }, weapon_bat = { weight = 500 },
  at_flashlight = { weight = 10 }, at_clip_extended_pistol = { weight = 10 },
}
RESOURCE_STATES = { ox_inventory = 'started', oxmysql = 'started', ox_lib = 'started' }
FIXTURE_FILES['qbx_core/shared/vehicles.lua'] = "return { police = { model = 'police', hash = joaat('police') } }"
`;

async function load(h) {
  await h.runFile(HARNESS_DIR + '/shim.lua', 'shim');
  await h.runCode(OX_ITEMS_LUA, 'fixtures');
  await h.runFile(PROJECT_DIR + '/server.lua', 'server.lua');
  await h.runFile(PROJECT_DIR + '/server/esx.lua', 'server/esx.lua');
  await h.runFile(PROJECT_DIR + '/server/identity.lua', 'server/identity.lua');
}

const q = async (conn, sql, p) => (await conn.query(sql, p))[0];
const one = async (conn, sql, p) => (await q(conn, sql, p))[0];
const J = (s) => (typeof s === 'string' ? JSON.parse(s) : s);

(async () => {
  const conn = await connect('qbxm_test');
  await conn.query(FIXTURE_SQL);
  const h = new Harness(conn);
  await load(h);

  // ---- dry run: nothing written
  await h.runCode("RUN_COMMAND('esx')", 'cmd');
  let printed = h.getGlobal('PRINTED');
  assert.ok(printed.some((l) => l.includes('WOULD RENAME `users`')), 'dry run announces rename');
  assert.ok(printed.some((l) => l.includes('DRY RUN')), 'dry run label');
  assert.ok(!printed.some((l) => l.includes('FAILED')), 'dry run had no FAILED: ' + printed.filter((l) => l.includes('FAILED')).join('\n'));
  const tablesAfterDry = (await q(conn, 'SHOW TABLES')).map((r) => Object.values(r)[0]);
  assert.ok(tablesAfterDry.includes('users') && !tablesAfterDry.includes('players'), 'dry run created nothing');
  const esxDryReport = Object.entries(h.files).find(([k]) => k.endsWith('_esx.md'));
  assert.ok(esxDryReport, 'report file saved');
  console.log('dry run OK, report lines:', esxDryReport[1].split('\n').length);

  // ---- apply
  await h.runCode("PRINTED = {} RUN_COMMAND('esx', 'apply')", 'cmd');
  printed = h.getGlobal('PRINTED');
  const failed = printed.filter((l) => /FAILED|ERROR/.test(l));
  assert.deepStrictEqual(failed, [], 'apply had errors:\n' + failed.join('\n'));

  const tables = (await q(conn, 'SHOW TABLES')).map((r) => Object.values(r)[0]);
  assert.ok(tables.includes('esx_users') && !tables.includes('users'), 'users renamed to esx_users');
  for (const t of ['players', 'player_vehicles', 'player_groups', 'bans', 'ox_inventory', 'qbx_migrate_esx_map', 'qbx_migrate_esx_log', 'qbx_migrations']) {
    assert.ok(tables.includes(t), 'table created: ' + t);
  }

  const players = await q(conn, 'SELECT * FROM players ORDER BY license, cid');
  assert.strictEqual(players.length, 5, 'five characters');
  const byLicense = {};
  for (const p of players) (byLicense[p.license] = byLicense[p.license] || []).push(p);
  assert.deepStrictEqual(Object.keys(byLicense).sort(), ['license:' + HEX1, 'license:' + HEX2, 'steam:' + STEAM3, 'steam:' + STEAM4].sort(), 'identifier normalisation');
  assert.deepStrictEqual(byLicense['license:' + HEX2].map((p) => p.cid), [1, 2], 'multichar cids preserved');
  assert.strictEqual(byLicense['steam:' + STEAM4][0].cid, 1, 'char1:steamhex -> cid 1');

  const u1 = byLicense['license:' + HEX1][0];
  assert.deepStrictEqual(J(u1.money), { cash: 150, bank: 2000, crypto: 0 }, 'money');
  const job = J(u1.job);
  assert.strictEqual(job.name, 'police'); assert.strictEqual(job.grade.level, 3); assert.strictEqual(job.isboss, true);
  assert.strictEqual(job.label, 'LSPD'); assert.strictEqual(job.payment, 300); assert.strictEqual(job.type, 'leo'); assert.strictEqual(job.grade.name, 'Chief');
  const ci = J(u1.charinfo);
  assert.strictEqual(ci.birthdate, '1990-12-25'); assert.strictEqual(ci.gender, 0); assert.strictEqual(ci.phone, '5551234'); assert.strictEqual(ci.cid, 1);
  assert.strictEqual(ci.firstname, 'John'); assert.strictEqual(ci.height, 180);
  assert.strictEqual(u1.phone_number, '5551234');
  assert.strictEqual(u1.name, 'John Doe');
  const meta = J(u1.metadata);
  assert.strictEqual(meta.hunger, 50); assert.strictEqual(meta.thirst, 25); assert.strictEqual(meta.isdead, false);
  assert.strictEqual(meta.health, 180); assert.strictEqual(meta.armor, 50);
  assert.deepStrictEqual(meta.licences, { id: true, driver: true, weapon: true });
  assert.deepStrictEqual(J(u1.position), { x: 100.5, y: -200.25, z: 30, w: 90 });
  const inv = J(u1.inventory);
  const byName = Object.fromEntries(inv.map((i) => [i.name, i]));
  assert.deepStrictEqual(Object.keys(byName).sort(), ['black_money', 'bread', 'water', 'weapon_pistol'], 'inventory names (nothing x0 dropped)');
  assert.strictEqual(byName.bread.count, 2); assert.strictEqual(byName.water.count, 1);
  assert.strictEqual(byName.black_money.count, 500);
  assert.strictEqual(byName.weapon_pistol.count, 1);
  assert.strictEqual(byName.weapon_pistol.metadata.ammo, 30);
  assert.strictEqual(byName.weapon_pistol.metadata.durability, 100);
  assert.strictEqual(byName.weapon_pistol.metadata.tint, 2);
  assert.deepStrictEqual(byName.weapon_pistol.metadata.components.sort(), ['at_clip_extended_pistol', 'at_flashlight']);
  assert.ok(byName.weapon_pistol.metadata.serial, 'weapon serial generated');
  const slots = inv.map((i) => i.slot);
  assert.strictEqual(new Set(slots).size, slots.length, 'unique slots');
  assert.strictEqual(J(u1.gang).name, 'none');

  const jane = byLicense['license:' + HEX2][0];
  const janeInv = J(jane.inventory);
  assert.deepStrictEqual(janeInv.map((i) => [i.name, i.count]).sort(), [['bread', 3], ['phone', 1]], 'legacy list inventory');
  assert.strictEqual(J(jane.charinfo).birthdate, '2001-04-03', 'DMY date');
  assert.strictEqual(J(jane.charinfo).gender, 1);
  assert.strictEqual(J(jane.metadata).isdead, true);
  assert.strictEqual(J(jane.metadata).licences.driver, true, 'dmv -> driver');
  const jim = byLicense['license:' + HEX2][1];
  assert.strictEqual(J(jim.charinfo).birthdate, '2002-05-06', 'ISO date passthrough');
  assert.strictEqual(J(jim.job).name, 'police'); assert.strictEqual(J(jim.job).grade.level, 0);
  assert.strictEqual(jim.inventory, '[]');
  assert.deepStrictEqual(J(jim.money), { cash: 0, bank: 0, crypto: 0 });

  const ox = byLicense['steam:' + STEAM3][0];
  assert.strictEqual(ox.inventory, '[{"slot":1,"name":"water","count":2,"metadata":{"foo":"bar"}}]', 'already-ox inventory untouched');
  assert.strictEqual(ox.phone_number, null, 'duplicate phone left NULL');
  const empty = byLicense['steam:' + STEAM4][0];
  assert.strictEqual(empty.inventory, '[]');
  assert.strictEqual(J(empty.charinfo).firstname, 'Firstname');

  const groups = await q(conn, 'SELECT * FROM player_groups ORDER BY citizenid');
  assert.strictEqual(groups.length, 2, 'two police players in player_groups');
  assert.ok(groups.every((g) => g.group === 'police' && g.type === 'job'));

  const vehicles = await q(conn, 'SELECT * FROM player_vehicles ORDER BY plate');
  assert.deepStrictEqual(vehicles.map((v) => v.plate), ['ABC 123 ', 'IMP 001'], 'resolved+owned vehicles only');
  const adder = vehicles[0];
  assert.strictEqual(adder.citizenid, u1.citizenid); assert.strictEqual(adder.license, u1.license);
  assert.strictEqual(adder.vehicle, 'adder'); assert.strictEqual(adder.hash, String(ADDER));
  assert.strictEqual(adder.state, 1); assert.strictEqual(adder.garage, 'Legion'); assert.strictEqual(adder.fuel, 55);
  assert.strictEqual(Math.round(adder.engine), 900); assert.strictEqual(Math.round(adder.body), 950);
  assert.strictEqual(J(adder.mods).color1, 12);
  assert.strictEqual(vehicles[1].state, 2, 'pound -> impounded');
  assert.strictEqual(vehicles[1].citizenid, jane.citizenid);
  assert.ok(printed.some((l) => l.includes('unresolved') || l.includes('matches no known spawn name')), 'unresolved model reported');
  assert.ok(printed.some((l) => l.includes('not an ESX user')), 'orphan reported');
  assert.ok(printed.some((l) => l.includes('0 duplicate plates')), 'duplicate plate count reported');

  const stashes = await q(conn, "SELECT owner, name, data FROM ox_inventory ORDER BY name");
  const stashMap = Object.fromEntries(stashes.map((s) => [s.owner + '/' + s.name, s.data]));
  const police = J(stashMap['/society_police']);
  assert.deepStrictEqual(police.map((i) => [i.name, i.count]).sort(), [['bread', 10], ['water', 5], ['weapon_bat', 1]], 'society merged from both ESX tables');
  assert.deepStrictEqual(J(stashMap[u1.citizenid + '/property']).map((i) => [i.name, i.count]), [['water', 2]], 'owned stash rekeyed to citizenid');
  assert.ok(stashMap[jane.citizenid + '/stash_x'] !== undefined, 'existing ox stash owner remapped');
  assert.ok(stashMap['/shared'] !== undefined, 'unowned ox stash untouched');

  assert.ok(h.files['output/esx_admins.cfg'].includes(`add_principal identifier.license:${HEX1} group.admin`), 'superadmin -> admin ACE');
  assert.ok(h.files['output/esx_admins.cfg'].includes(`add_principal identifier.steam:${STEAM3} group.admin`), 'admin ACE (steam)');
  assert.deepStrictEqual(J(h.files['output/esx_society_funds.json']), { society_police: 12345 }, 'society funds exported');

  const mig = await one(conn, "SELECT * FROM qbx_migrations WHERE id = 'esx'");
  assert.ok(mig && mig.rows_affected > 0, 'migration marked');
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM qbx_migrate_esx_map')).n, 5);
  assert.ok(printed.some((l) => l.includes('backed up `users`')), 'backup ran before apply');
  console.log('apply OK');

  // ---- re-run: idempotent
  const before = (await q(conn, 'SELECT citizenid, license, cid FROM players ORDER BY citizenid'));
  await h.runCode("PRINTED = {} RUN_COMMAND('esx', 'apply')", 'cmd');
  printed = h.getGlobal('PRINTED');
  assert.deepStrictEqual(printed.filter((l) => /FAILED|ERROR/.test(l)), [], 'rerun errors');
  const after = (await q(conn, 'SELECT citizenid, license, cid FROM players ORDER BY citizenid'));
  assert.deepStrictEqual(after, before, 'rerun keeps citizenids / cids');
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM player_vehicles')).n, 2);
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM ox_inventory')).n, 4);
  console.log('rerun OK (idempotent)');

  // ---- items / jobs / check / all(dry) on the converted DB
  await h.runCode("PRINTED = {} RUN_COMMAND('items', 'apply') RUN_COMMAND('jobs', 'apply') RUN_COMMAND('check') RUN_COMMAND('all')", 'cmd');
  printed = h.getGlobal('PRINTED');
  assert.deepStrictEqual(printed.filter((l) => /FAILED/.test(l)), [], 'items/jobs/check/all errors:\n' + printed.filter((l) => /FAILED/.test(l)).join('\n'));
  assert.ok(h.files['output/items.lua'].includes('["nothing"]'), 'ESX items generated (nothing not in ox)');
  assert.ok(!h.files['output/items.lua'].includes('["bread"]'), 'items already in ox skipped');
  assert.ok(h.files['output/jobs.lua'].includes('["police"]') && h.files['output/jobs.lua'].includes('isboss = true'), 'jobs generated');
  assert.ok(h.files['output/gangs.lua'].includes("['none']"), 'gangs generated');
  console.log('items/jobs/check OK');

  // ---- identity reconcile on connect
  const NEW2 = 'license2:' + 'c'.repeat(40);
  await conn.query("INSERT INTO bans (name, license, reason, expire) VALUES ('x', ?, 'test', 0)", ['license:' + HEX1]);
  await h.runCode(`PLAYER_IDENTIFIERS[1] = { 'license:${HEX1}', '${NEW2}', 'steam:${STEAM3}', 'discord:123', 'ip:1.2.3.4' } PRINTED = {} CONNECT_DONE = RUN_CONNECT(1)`, 'cmd');
  assert.strictEqual(h.getGlobal('CONNECT_DONE'), true, 'deferral completed');
  const rows1 = await q(conn, 'SELECT license, cid FROM players WHERE license = ? ORDER BY cid', [NEW2]);
  assert.strictEqual(rows1.length, 2, 'license: and steam: rows both rewritten to license2 (' + JSON.stringify(rows1) + ')');
  assert.strictEqual((await one(conn, 'SELECT license FROM player_vehicles WHERE plate = ?', ['ABC 123 '])).license, NEW2, 'vehicle license rewritten');
  assert.strictEqual((await one(conn, 'SELECT license FROM bans')).license, NEW2, 'ban rewritten');
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM players WHERE license = ?', ['license:' + HEX2])).n, 2, 'other account untouched');
  const logN = (await one(conn, 'SELECT COUNT(*) AS n FROM qbx_migrate_identity_log')).n;
  assert.ok(logN >= 3, 'identity log written');
  await h.runCode('PRINTED = {} RUN_CONNECT(1)', 'cmd');
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM qbx_migrate_identity_log')).n, logN, 'second connect is a no-op');
  // ESX bare-value match (ESX 'license' type stored bare -> we typed it; but also test a bare row)
  await conn.query("UPDATE players SET license = ? WHERE license = ? AND cid = 1", [HEX2, 'license:' + HEX2]);
  await h.runCode(`PLAYER_IDENTIFIERS[2] = { 'license:${HEX2}', 'license2:${'d'.repeat(40)}' } RUN_CONNECT(2)`, 'cmd');
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM players WHERE license = ?', ['license2:' + 'd'.repeat(40)])).n, 2, 'bare and typed rows for one account both rewritten');
  await h.runCode("PRINTED = {} RUN_COMMAND('identity')", 'cmd');
  printed = h.getGlobal('PRINTED');
  assert.ok(printed.some((l) => l.includes('players.license')), 'identity report');
  console.log('identity OK');

  // ---- rollback
  await h.runCode("PRINTED = {} RUN_COMMAND('esx', 'rollback') RUN_COMMAND('esx', 'rollback', 'apply')", 'cmd');
  printed = h.getGlobal('PRINTED');
  assert.deepStrictEqual(printed.filter((l) => /FAILED|ERROR/.test(l)), [], 'rollback errors:\n' + printed.filter((l) => /FAILED|ERROR/.test(l)).join('\n'));
  const tables2 = (await q(conn, 'SHOW TABLES')).map((r) => Object.values(r)[0]);
  assert.ok(tables2.includes('users') && !tables2.includes('esx_users'), 'users renamed back');
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM users')).n, 5, 'ESX users intact');
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM players')).n, 0, 'migrated players removed');
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM player_vehicles')).n, 0);
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM player_groups')).n, 0);
  const oxAfter = await q(conn, 'SELECT owner, name FROM ox_inventory ORDER BY name');
  assert.deepStrictEqual(oxAfter.map((r) => r.owner + '/' + r.name), ['/shared', 'char1:' + HEX2 + '/stash_x'], 'stashes removed, owner restored');
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM qbx_migrate_esx_map')).n, 0);
  console.log('rollback OK');

  // ---- apply again after rollback works (fresh cycle)
  await h.runCode("PRINTED = {} RUN_COMMAND('esx', 'apply')", 'cmd');
  printed = h.getGlobal('PRINTED');
  assert.deepStrictEqual(printed.filter((l) => /FAILED|ERROR/.test(l)), [], 're-apply after rollback');
  assert.strictEqual((await one(conn, 'SELECT COUNT(*) AS n FROM players')).n, 5);
  console.log('re-apply OK');

  await conn.end();
  console.log('\nALL ESX TESTS PASSED');
})().catch((e) => { console.error(e); process.exit(1); });
