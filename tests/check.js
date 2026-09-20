const luaparse = require('luaparse');
const fs = require('fs');
let bad = 0;
for (const f of process.argv.slice(2)) {
  try {
    luaparse.parse(fs.readFileSync(f, 'utf8'), { luaVersion: '5.3', comments: false, scope: true });
    console.log('OK   ' + f);
  } catch (e) {
    bad++;
    console.log('FAIL ' + f + ': ' + e.message);
  }
}
process.exit(bad ? 1 : 0);
