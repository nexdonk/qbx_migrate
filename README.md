# qbx_migrate — QBCore ➜ Qbox migration kit

Migrates a live QBCore server to **qbx_core + the ox stack** (ox_lib, ox_inventory, ox_target, oxmysql).

## Read this first

No tool can promise a zero-breakage conversion. Anyone who tells you otherwise is selling something.
What this kit *does* guarantee:

- **Nothing is destroyed.** Every write step takes a snapshot first, and every step has a rollback.
- **Nothing runs by surprise.** Every step is a dry run until you type `apply`.
- **Nothing is guessed at.** Rewrites happen only where the mapping is mechanical and provable. Everything else is reported with file, line, and the exact replacement to make.
- **Nothing is silent.** Every player who would lose an item, every job that no longer exists, every unreadable blob — all named in a report *before* anything is written.

The breakage in a QBCore ➜ Qbox move is almost never the core. `qbx_core` ships a QBCore bridge that keeps
the vast majority of QBCore code running unchanged. The breakage lives in four places:

| Area | Why it breaks |
| --- | --- |
| **Inventory** | `qb-inventory` / `qs-inventory` / `ps-inventory` ➜ `ox_inventory`. Different item format, different exports, different DB layout. Nothing bridges this. |
| **Targeting** | `qb-target` ➜ `ox_target`. ox_target's qtarget compat layer covers most calls; the rest need hand conversion. |
| **Job grades** | Qbox grades are **numbers**. QBCore uses **strings**. Every `== '2'` comparison silently fails. |
| **Items not in ox_inventory** | ox_inventory discards any item it does not have defined. Missing item = deleted item. |

---

## Contents

```
qbx_migrate/
├── fxmanifest.lua                    resource manifest
├── server.lua                        in-game DB migrator (qbxmigrate console command)
├── sql/
│   └── 01_qbx_schema.sql             additive schema changes, if you prefer raw SQL
├── tools/
│   └── Convert-QbxResources.ps1      offline code auditor + safe rewriter
└── shims/
    ├── qb-menu/                      qb-menu API on ox_lib context menus
    ├── qb-input/                     qb-input API on ox_lib input dialogs
    └── progressbar/                  progressbar API on ox_lib progress bars
```

---

## Install

1. Drop the `qbx_migrate` folder into `resources/[qbx]/`.
2. Add `ensure qbx_migrate` to `server.cfg` **after** `ensure oxmysql` and `ensure ox_lib`.
3. Restart. You should see `[qbx_migrate] loaded.` in the console.

Requires `oxmysql` and `ox_lib`. `qb-core` must still be present (not necessarily started) for the
items/jobs generators to read its shared files.

---

## The runbook

Do this on a **copy** of your server and a **copy** of your database. Not the live one. Not once.

### Phase 0 — Back up outside this tool

```
mysqldump -u root -p your_database > qbcore_pre_migration.sql
```

Copy the whole `resources` folder somewhere safe. This kit's backups are precise and fast, but a
full dump is the only thing that survives a mistake nobody predicted.

### Phase 1 — Audit the code (offline, read-only)

```powershell
cd C:\Users\unico\OneDrive\Desktop\qbx_migrate\tools
.\Convert-QbxResources.ps1 -ResourcesPath 'C:\FXServer\server-data\resources' -ServerCfg 'C:\FXServer\server-data\server.cfg'
```

Writes `qbx_migration_<timestamp>\MIGRATION_REPORT.md` and `findings.csv`. Changes nothing.

Read the **HIGH** section. That is your actual workload. Everything else is noise by comparison.

### Phase 2 — Apply the safe rewrites

```powershell
.\Convert-QbxResources.ps1 -ResourcesPath 'C:\FXServer\server-data\resources' -Apply
```

Rewrites only the mechanical mappings:

| From | To |
| --- | --- |
| `exports['qb-core']` | `exports['qbx_core']` |
| `exports['qb-target']:AddBoxZone` etc. | `exports['ox_target']:AddBoxZone` (qtarget compat) |
| `exports['qb-target']:AddGlobalPed` | `exports['ox_target']:Ped` |
| `job.grade.level == '2'` | `job.grade.level == 2` |
| `dependency 'qb-core'` in manifests | `dependency 'qbx_core'` |

Every touched file is copied to `qbx_migration_<timestamp>\backup\` first, and a
`Restore-Backup.ps1` is written next to it. One command puts everything back.

### Phase 3 — Swap the resources

Use the **Legacy resources installed** table in the report. The important ones:

| Remove | Install |
| --- | --- |
| `qb-core` | `qbx_core` |
| `qb-inventory` | `ox_inventory` |
| `qb-target` | `ox_target` |
| `qb-menu`, `qb-input`, `progressbar` | the shims in `shims/` (or rewrite to `ox_lib`) |
| `qb-doorlock` | `ox_doorlock` (doors must be re-created) |
| `LegacyFuel` / `qb-fuel` | `ox_fuel` |
| `qb-clothing`, `qb-skinshop` | `illenium-appearance` |
| `qb-policejob`, `qb-ambulancejob`, `qb-garages`, `qb-management`, … | `qbx_police`, `qbx_ambulancejob`, `qbx_garages`, `qbx_management`, … |

**Never leave `qb-core` and `qbx_core` both ensured.** They fight over the same events. The audit
flags this as a conflict.

To use the shims: delete the original `qb-menu` / `qb-input` / `progressbar` folders, copy the ones
from `shims/` in their place, and ensure them **after** `ox_lib`.

### Phase 4a — Find out what your inventory actually stores

**Do this first if you are on qs-inventory (Quasar), ps-inventory, lj-inventory, or modern
qb-inventory.** Those either don't publish their schema (Quasar is escrowed) or changed it
between versions. Rather than guessing, ask the database:

```
qbxmigrate inspect
```

Read-only. Reports:

- every table with an `items` / `inventory` / `data` / `trunk` / `glovebox` column
- the full column list and a real sample row from each
- whether each blob is **qb/qs format** (`amount` + `info`) or **ox format** (`count` + `metadata`)
- for a unified `inventories` table: the identifier prefixes actually in use, and where each
  one will be routed
- whether `players.inventory` exists

If a prefix routes to the wrong place, fix `CONFIG.trunkPrefixes` / `glovePrefixes` /
`skipPrefixes` / `stashPrefixStrip` at the top of `server.lua`. If your inventory writes to a
table this tool doesn't know, point `CONFIG.unifiedTable` / `unifiedIdColumn` /
`unifiedItemsColumn` at it.

### Phase 4b — Pre-flight the database

In the **server console**:

```
qbxmigrate check
```

Read `qbx_migrate/output/<stamp>_check.md`. It tells you:

- which resources are running / missing / conflicting
- which schema changes are still pending
- **which job and gang names your players hold that qbx_core does not define** — every one of those
  players gets reset to unemployed on login unless you fix it
- how many inventories are qb format vs already ox format vs unreadable JSON
- which migrations have already run

### Phase 5 — Schema (additive, safe)

```
qbxmigrate schema            # dry run, shows exactly what it would do
qbxmigrate schema apply
```

Adds `players.last_logged_out`, `players.userId`, `players.phone_number`, the `bans`,
`player_groups`, `ox_inventory` and `qbx_migrations` tables, `player_vehicles.trunk` /
`.glovebox`, and fixes the `citizenid` collation that the `player_groups` foreign key needs.

Nothing is dropped. Ever.

### Phase 6 — Generate items and jobs

```
qbxmigrate items apply
qbxmigrate jobs apply
```

Produces, in `qbx_migrate/output/`:

- `items.lua` — every item from `qb-core/shared/items.lua` that ox_inventory does **not** already
  define, in ox format. **Merge into `ox_inventory/data/items.lua`.**
- `jobs.lua` / `gangs.lua` — your jobs and gangs with **numeric** grade keys. **Replace
  `qbx_core/shared/jobs.lua` and `gangs.lua`.**

Then copy your item images: `qb-inventory/html/images/*` ➜ `ox_inventory/web/images/`.

Restart the server, then re-run `qbxmigrate check` and confirm the job audit is clean.

> **This step is not optional.** ox_inventory silently discards any item it does not have defined.
> If `lockpick` is not in `data/items.lua`, every lockpick on your server disappears the moment a
> player loads in.

### Phase 7 — Convert the inventory data

```
qbxmigrate inventory          # DRY RUN — do this first, always
```

The report lists, per player and per stash:

- items whose ox definition is missing (**these will be lost — go back to Phase 6**)
- items that could not be placed (no free slot)
- inventories that exceed the ox weight cap
- account items stripped (money lives in `players.money`; ox_inventory recreates the `money` item —
  leaving a stale one would duplicate cash)
- unreadable JSON blobs, which are left untouched

Once the "Items NOT defined in ox_inventory" table is empty:

```
qbxmigrate inventory apply
```

This auto-backs-up before writing. It converts:

**Layout A — legacy qb-inventory / older ps-inventory:**

| From | To (ox_inventory) |
| --- | --- |
| `players.inventory` (`{name, amount, info, slot}`) | `players.inventory` (`[{slot, name, count, metadata}]`) |
| `stashitems` | `ox_inventory` table (`owner=''`, `name`, `data`) |
| `trunkitems` | `player_vehicles.trunk`, matched by plate ➜ id |
| `gloveboxitems` | `player_vehicles.glovebox`, matched by plate ➜ id |

**Layout B — modern qb-inventory / qs-inventory (Quasar) / newer ps-inventory:**

One `inventories(identifier, items)` table, routed by identifier prefix:

| identifier | routed to |
| --- | --- |
| `trunk-PLATE`, `big_trunk-PLATE` | `player_vehicles.trunk` |
| `glovebox-PLATE` | `player_vehicles.glovebox` |
| a bare `citizenid` | `players.inventory` |
| `drop-…` | skipped (ground drops don't persist in ox) |
| anything else | `ox_inventory` stash, prefix stripped |

Both layouts are handled, and both can be present at once. Every stash rename is printed as a
from ➜ to table — if a script registers its stash under the old name, the contents won't show
up, so check that table.

If a player has items in **both** `players.inventory` and the `inventories` table, `players.inventory`
wins and the conflict is reported. Nothing is silently overwritten.

**Metadata remapping:**

| qb / qs `info` key | ox `metadata` key |
| --- | --- |
| `serie`, `serial` | `serial` |
| `attachments`, `attachment` | `components` |
| `quality` / `durability` **on a weapon** | `durability` (0-100, correct) |
| `durability` **on anything else** | `condition` |
| `quality` **on anything else** | `quality` |
| everything else | copied verbatim |

That weapon/non-weapon split matters. In ox, `durability` on an item with `degrade` set is a
**unix expiry timestamp**, not a percentage. Passing a burger's `durability: 88` straight through
tells ox the burger expired in 1970 and it gets binned on load. Weapons keep the percentage;
everything else gets the value preserved under a key ox doesn't reserve.

The step is idempotent: inventories already in ox format are detected and skipped, so a re-run is
harmless. The legacy `stashitems` / `trunkitems` / `gloveboxitems` tables are **left in place**.
Drop them yourself, later, once you are satisfied.

### Phase 8 — Finish

```
qbxmigrate phone apply        # backfill players.phone_number from charinfo (skips duplicates)
qbxmigrate metadata apply     # add missing metadata keys; never overwrites an existing value
```

Then, with qbx_core running and your `shared/jobs.lua` in place:

```
convertjobs
```

That is qbx_core's own command. It populates `player_groups` for multijob/multigang. Re-run
`qbxmigrate check` — `player_groups` should no longer be empty.

### Or, all at once

```
qbxmigrate all                # full dry run of every step, one report
qbxmigrate all apply          # backup, then every step in the correct order
```

---

## Rollback

**Code:**
```powershell
.\qbx_migration_<timestamp>\Restore-Backup.ps1
```

**Database:**
```
qbxmigrate restore <stamp>          # dry run, lists what it would restore
qbxmigrate restore <stamp> apply
```

`<stamp>` is a folder name under `qbx_migrate/backups/`. Restores `players`, `player_vehicles`,
`ox_inventory` and the legacy qb tables to their snapshot state.

Rollback restores **data**, not schema. Added columns stay — they are harmless to QBCore.
If you need a true point-in-time reset, that is what the Phase 0 `mysqldump` is for.

---

## Command reference

```
qbxmigrate help
qbxmigrate inspect                  read-only schema discovery (run first on qs/ps/lj-inventory)
qbxmigrate check                    read-only audit
qbxmigrate backup                   snapshot every table this tool can touch
qbxmigrate restore <stamp> apply    restore from backups/<stamp>
qbxmigrate schema    [apply]        additive schema changes
qbxmigrate items     [apply]        generate output/items.lua
qbxmigrate jobs      [apply]        generate output/jobs.lua + output/gangs.lua
qbxmigrate inventory [apply]        qb-inventory data -> ox_inventory format
qbxmigrate phone     [apply]        backfill players.phone_number
qbxmigrate metadata  [apply]        add missing metadata keys
qbxmigrate all       [apply]        everything, in order
```

Without `apply`, every step is a dry run that writes only a report.
The command is ACE-restricted (`command.qbxmigrate`) and intended for the server console.

Tuning lives in the `CONFIG` table at the top of `server.lua` — batch size, whether to strip
account items, the source table names if you were on `ps-inventory`, and the metadata defaults.

---

## What this kit does NOT do

Stated plainly, so you find out here and not at 2am on launch night:

- **It does not rewrite inventory logic.** Every `AddItem` / `RemoveItem` / `PlayerData.items` call
  is reported with file and line and the exact ox_inventory replacement — but a human makes the
  change. The semantics differ too much for a regex to be trusted with it.
- **It does not migrate clothing.** `qb-clothing` / `playerskins` ➜ `illenium-appearance` has its
  own converter. Use theirs.
- **It does not migrate doorlocks.** `ox_doorlock` doors must be re-created.
- **It does not migrate housing, phone data, or third-party scripts** with their own tables.
- **It does not convert `qb-target` option tables that ox_target's compat layer cannot handle**
  (`AddEntityZone`, `AddComboZone`). Those are reported as HIGH.
- **It does not touch anything under `[ox]`, `qbx_core`, `ox_lib`, or `node_modules`.**

---

## Sources

- [Converting from QBCore to Qbox](https://docs.qbox.re/converting)
- [qbx_core server exports](https://docs.qbox.re/resources/qbx_core/exports/server)
- [qbx_core client exports](https://docs.qbox.re/resources/qbx_core/exports/client)
- [qbx_core.sql](https://github.com/Qbox-project/qbx_core/blob/main/qbx_core.sql)
- [qbx_vehicles vehicles.sql](https://github.com/Qbox-project/qbx_vehicles/blob/main/vehicles.sql)
- [ox_inventory MySQL layer](https://github.com/overextended/ox_inventory/blob/main/modules/mysql/server.lua)
- [ox_target qtarget compatibility](https://github.com/overextended/ox_target/blob/main/client/compat/qtarget.lua)
- [Qbox txAdmin recipe](https://github.com/Qbox-project/txAdminRecipe)
