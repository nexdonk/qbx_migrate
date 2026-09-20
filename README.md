# qbx_migrate — QBCore / ESX ➜ Qbox migration kit

Moves a live **QBCore** or **ESX Legacy** server to **qbx_core + the ox stack** (ox_lib, ox_inventory,
ox_target, oxmysql, qbx_vehicles): database, inventory data, identifiers, and a code audit.

## Read this first

No tool can promise a zero-breakage conversion. Anyone who tells you otherwise is selling something.
What this kit *does* guarantee:

- **Nothing is destroyed.** Every write step snapshots first, every step has a rollback, and the ESX
  step only ever *adds* rows to the qbx tables (your ESX tables are renamed, never dropped).
- **Nothing runs by surprise.** Every step is a dry run until you type `apply`.
- **Nothing is guessed at.** Rewrites happen only where the mapping is mechanical and provable.
  Everything else is reported with file, line, and the exact replacement to make.
- **Nothing is silent.** Every player who would lose an item, every job that no longer exists, every
  vehicle whose model can't be resolved, every unreadable blob — all named in a report *before*
  anything is written.
- **It is tested.** `tests/` runs the actual server Lua against a real MariaDB and checks every
  mapping listed below. Run it yourself before you trust it.

### The identifier problem, solved at login

Qbox keys a player by **`license2:`**. QBCore stored **`license:`**. ESX stored the bare license
hash, `charN:<hash>` (esx_multicharacter), or steam/fivem/discord. `license2` is a *different*
Rockstar identifier and **cannot be computed from any of those** — no offline script can fill it in.

So this kit does the only thing that works: `server/identity.lua` hooks `playerConnecting`, collects
every identifier the joining client presents, finds their rows in `players`, `bans`,
`player_vehicles` (and any table you add to `CONFIG.identity.columns`) by **any** of them — typed or
bare — and rewrites them to `license2:` *before* qbx_core loads their characters. It logs every
rewrite to `qbx_migrate_identity_log`, never touches another account's rows, and is a no-op once a row
is on license2. `qbxmigrate identity` shows what's still pending (players who haven't logged in yet).

---

## Contents

```
qbx_migrate/
├── fxmanifest.lua
├── server.lua                        shared helpers, QBCore steps, command dispatcher
├── server/
│   ├── esx.lua                       ESX -> qbx database conversion + rollback
│   └── identity.lua                  login-time license -> license2 reconciler
├── data/vehicle_models.lua           base-game spawn names (ESX vehicle hash resolution)
├── sql/01_qbx_schema.sql             additive QBCore schema changes, if you prefer raw SQL
├── tools/Convert-QbxResources.ps1    offline code auditor + safe rewriter (QB and ESX rules)
├── shims/                            qb-menu / qb-input / progressbar on ox_lib
└── tests/                            real-database test suite (see tests/README.md)
```

---

## Install

1. Drop `qbx_migrate` into `resources/[qbx]/`.
2. `ensure qbx_migrate` in `server.cfg` **after** `ensure oxmysql` and `ensure ox_lib`.
3. Restart. Console shows `[qbx_migrate] loaded.`

Keep it ensured after the migration: the identity reconciler needs to run on every login until
your players have all come back once. Remove it whenever `qbxmigrate identity` reports nothing
pending, or leave it — it costs one indexed query per connect.

---

## The runbook

Do this on a **copy** of your server and a **copy** of your database. Not the live one. Not once.

### Phase 0 — Back up outside this tool

```
mysqldump -u root -p your_database > pre_migration.sql
```

Copy the whole `resources` folder somewhere safe. This kit's backups are precise and fast, but a full
dump is the only thing that survives a mistake nobody predicted.

### Phase 1 — Audit the code (offline, read-only)

```powershell
cd qbx_migrate\tools
.\Convert-QbxResources.ps1 -ResourcesPath 'C:\FXServer\server-data\resources' -ServerCfg 'C:\FXServer\server-data\server.cfg'
```

Writes `qbx_migration_<timestamp>\MIGRATION_REPORT.md` and `findings.csv`. Changes nothing. Read the
**HIGH** section — that is your actual workload. ESX servers: every `ESX.*` / `xPlayer.*` call is HIGH
because qbx_core has no ESX bridge. QBCore servers: the qb bridge keeps most code running; the
breakage is inventory, target, and string job grades.

### Phase 2 — Apply the safe rewrites (QBCore only)

```powershell
.\Convert-QbxResources.ps1 -ResourcesPath '...' -Apply
```

Mechanical mappings only (`exports['qb-core']` ➜ `exports['qbx_core']`, qb-target ➜ ox_target compat,
`grade.level == '2'` ➜ `== 2`, manifest dependencies). Every touched file is backed up and a
`Restore-Backup.ps1` is generated.

### Phase 3 — Database: pick your path

```
qbxmigrate inspect      # read-only: what tables/blobs you actually have
qbxmigrate check        # read-only: environment, schema, jobs, inventory formats
```

`check` tells you which path you're on.

#### Path A — QBCore ➜ Qbox

```
qbxmigrate schema apply       # additive columns/tables
qbxmigrate items apply        # output/items.lua  -> merge into ox_inventory/data/items.lua
qbxmigrate jobs apply         # output/jobs.lua + gangs.lua -> qbx_core/shared/
# swap resources (Phase 4), restart with qbx_core + ox_inventory running, then:
qbxmigrate check              # "Items NOT defined in ox_inventory" must be empty
qbxmigrate inventory          # DRY RUN — read it
qbxmigrate inventory apply    # backs up, then converts
qbxmigrate phone apply
qbxmigrate metadata apply
convertjobs                   # qbx_core's own command, populates player_groups
```

Inventory conversion handles legacy `stashitems` / `trunkitems` / `gloveboxitems` and the unified
`inventories(identifier, items)` table used by modern qb-inventory, qs-inventory and ps-inventory,
both at once if present. See **Inventory mapping** below.

#### Path B — ESX ➜ Qbox

```
qbxmigrate esx                # DRY RUN — read it: identifier shapes, unresolved vehicles,
                              #   orphan vehicles, undefined items, stash renames
qbxmigrate esx apply          # backs up, renames users -> esx_users, creates the qbx
                              #   tables, converts everything
qbxmigrate items apply        # output/items.lua from the ESX `items` table
qbxmigrate jobs apply         # output/jobs.lua from `jobs` + `job_grades`
# merge generated files, swap resources (Phase 4), restart with qbx_core + ox_inventory, then:
qbxmigrate check
qbxmigrate esx                # dry run again: "Items NOT defined in ox_inventory" must be empty
```

If it isn't empty, add the items and run `qbxmigrate esx apply` again — the step is **idempotent**:
every character keeps the citizenid it was given the first time (`qbx_migrate_esx_map`), every insert
is keyed, re-running just refreshes the data.

Undo everything the ESX step did:

```
qbxmigrate esx rollback apply
```

Deletes exactly the rows it inserted (players, vehicles, stashes, groups), reverses the ox_inventory
owner rewrites, and renames `esx_users` back to `users`. Your ESX database is back as it was.

**What the ESX step maps**

| ESX | Qbox |
| --- | --- |
| `users` (one row per character) | `players` (one row per character) |
| `identifier` bare hash / `charN:hash` / `license:` / `steam:` / `fivem:` / `discord:` | `players.license` typed (`license:hash`, `steam:…`); `charN` ➜ `cid = N`, else 1. Rewritten to `license2:` at first login. |
| `accounts.money` / `.bank` | `money.cash` / `money.bank` (`crypto` 0) |
| `accounts.black_money` | `black_money` item in the inventory (as ox_inventory on ESX does) |
| `job` + `job_grade` with `jobs` / `job_grades` | `job {name, label, payment, type, isboss (grade name = boss), grade {name, level}}` + `player_groups` row |
| `firstname`, `lastname`, `dateofbirth` (DD/MM/YYYY), `sex`, `height`, `phone_number` | `charinfo {firstname, lastname, birthdate YYYY-MM-DD, gender 0/1, height, phone, cid}` + `players.phone_number` (duplicates left NULL, qbx generates one) |
| `inventory` — legacy `{"bread":2}` map, legacy `[{name,count}]` list, qs/qb slotted list, or already-ox list | `players.inventory` in ox format. Already-ox lists are left **byte-identical**. |
| `loadout` weapons `{ammo, components, tintIndex}` | `weapon_*` items with `metadata {ammo, durability 100, serial, tint, components}`; component names mapped via `CONFIG.esx.componentMap`, `clip_extended` per weapon class; unknown ones dropped and counted |
| `status` (`hunger`/`thirst`/`stress` 0–1,000,000) | `metadata.hunger` / `.thirst` / `.stress` 0–100 |
| `is_dead`, `metadata.health` / `.armor` | `metadata.isdead` / `.health` / `.armor` (the full ESX metadata blob is kept under `metadata.esx`) |
| `user_licenses` (`drive`/`dmv` ➜ driver, `weapon`, others by name) | `metadata.licences` |
| `position {x,y,z,heading}` | `position {x,y,z,w}` |
| `group` admin/superadmin/mod | `output/esx_admins.cfg` — `add_principal identifier.license:… group.admin` lines for server.cfg (Qbox has no DB groups) |
| `owned_vehicles` | `player_vehicles`: `vehicle` = model name resolved from the hash (base-game list bundled + `qbx_core/shared/vehicles.lua` + `qb-core/shared/vehicles.lua` + the ESX `vehicles` table + `CONFIG.esx.vehicleModels`), `hash`, `mods` = the props JSON, `stored`/`pound` ➜ `state` 1/0/2, `parking` ➜ `garage`, fuel/engine/body from the props, `trunk`/`glovebox` copied if ox already stored them |
| `addon_inventory_items` + `datastore_data` (same society name merged) | `ox_inventory` stashes, owner `''` for shared, citizenid for owned; **stash names are kept** (`society_police`) — whatever qbx/ox script owns the stash must register it under that name |
| `addon_account_data` society balances | `management_funds` if that table exists, always `output/esx_society_funds.json` |
| `ox_inventory.owner` = ESX identifier (servers that already ran ox_inventory) | rewritten to the new citizenid |

Reported, **not** migrated: `skin` (use illenium-appearance's importer; `esx_users.skin` stays),
`billing`, phone tables, properties, `multicharacter_slots`, and any third-party table keyed by the ESX
identifier — `qbx_migrate_esx_map (identifier, citizenid, license, cid)` is left in place for your own
`UPDATE` statements.

Vehicles with an unresolvable model hash and vehicles whose owner isn't a user (job/society cars) are
**listed and skipped**, never written half-right. Add addon spawn names to `CONFIG.esx.vehicleModels`
and re-run; set `CONFIG.esx.keepOrphanVehicles = true` to write society cars with `citizenid NULL`.

### Phase 4 — Swap the resources

Use the **Legacy resources installed** table in the audit report. The important ones:

| Remove | Install |
| --- | --- |
| `qb-core` / `es_extended` / `esx_multicharacter` / `esx_identity` | `qbx_core` |
| `qb-inventory`, `qs-inventory`, `ps-inventory`, `esx_inventoryhud` | `ox_inventory` |
| `qb-target` | `ox_target` |
| `qb-menu`, `qb-input`, `progressbar`, `esx_menu_*` | the shims in `shims/`, or rewrite to `ox_lib` |
| `qb-doorlock`, `esx_doorlock` | `ox_doorlock` (doors re-created) |
| `LegacyFuel`, `qb-fuel` | `ox_fuel` |
| `qb-clothing`, `esx_skin`, `skinchanger` | `illenium-appearance` |
| `qb-policejob`, `esx_policejob`, … | `qbx_police`, `qbx_ambulancejob`, `qbx_garages`, `qbx_management`, … |

**Never leave `qb-core` / `es_extended` and `qbx_core` both ensured.** The audit flags this.
ESX: `qbx_core` creates its own `users` table (userId / license2) — that is why the ESX step
renames yours. Do not rename it back while qbx_core is installed.

### Phase 5 — First logins

Players connect. For each one, the console prints:

```
[qbx_migrate] identity: players.license `license:abc…` -> `license2:def…` for Bob (2 rows)
[qbx_migrate] identity: bans.license `license:abc…` -> `license2:def…` for Bob (1 rows)
```

qbx_core then finds their characters by license2 (it also matches `license:` as a fallback, so even a
player who slips past the reconciler still loads). `qbxmigrate identity` at any time shows how many
rows are still on a pre-Qbox identifier — those are players who haven't come back yet.

### Or, all at once

```
qbxmigrate all                # full dry run of every applicable step, one report
qbxmigrate all apply          # backup, then [esx] + schema + items + jobs + inventory + phone + metadata
```

The ESX step is included automatically when an ESX `users` table is detected.

---

## Inventory mapping (QBCore path)

| From | To (ox_inventory) |
| --- | --- |
| `players.inventory` (`{name, amount, info, slot}`) | `players.inventory` (`[{slot, name, count, metadata}]`) |
| `stashitems` | `ox_inventory` (`owner=''`, `name`, `data`) |
| `trunkitems` / `gloveboxitems` | `player_vehicles.trunk` / `.glovebox`, matched by plate ➜ id |
| `inventories` `trunk-PLATE` / `glovebox-PLATE` / bare citizenid / `stash-x` / `drop-…` | vehicle row / `players.inventory` / stash (prefix stripped, rename listed) / skipped |

Metadata: `serie`/`serial` ➜ `serial`, `attachments` ➜ `components`, weapon `quality`/`durability` ➜
`durability` (0–100), non-weapon `durability` ➜ `condition` (ox reads `durability` on a degradable item
as an expiry timestamp — passing 88 through would bin the item as expired in 1970), everything else
verbatim. `money`/`cash` items are stripped (cash lives in `players.money`; ox recreates the item).
Already-ox blobs are detected and skipped, so re-runs are harmless.

---

## Rollback

| What | How |
| --- | --- |
| Code rewrites | `.\qbx_migration_<timestamp>\Restore-Backup.ps1` |
| QBCore data (players, vehicles, ox_inventory, legacy qb tables) | `qbxmigrate restore <stamp> apply` — `<stamp>` is a folder under `backups/`; each apply step makes one, never overwriting another even inside the same second |
| Everything the ESX step inserted | `qbxmigrate esx rollback apply` |
| Identifier rewrites | `qbx_migrate_identity_log` records old ➜ new per table; they are harmless to leave (qbx_core matches either) |

Restores put **data** back, not schema. Added columns and tables stay — they are harmless to QBCore
and empty for ESX. A true point-in-time reset is what the Phase 0 dump is for.

---

## Command reference

```
qbxmigrate help
qbxmigrate inspect                  read-only schema discovery
qbxmigrate check                    read-only audit
qbxmigrate backup                   snapshot every table this tool can touch
qbxmigrate restore <stamp> apply    restore from backups/<stamp>
qbxmigrate esx       [apply]        ESX -> qbx (creates the qbx tables, idempotent)
qbxmigrate esx rollback [apply]     undo the esx step exactly
qbxmigrate schema    [apply]        additive schema changes
qbxmigrate items     [apply]        output/items.lua (qb-core shared file or ESX items table)
qbxmigrate jobs      [apply]        output/jobs.lua + gangs.lua (qb-core shared or ESX tables)
qbxmigrate inventory [apply]        qb-inventory data -> ox_inventory format
qbxmigrate phone     [apply]        backfill players.phone_number
qbxmigrate metadata  [apply]        add missing metadata keys
qbxmigrate identity                 rows still on a pre-Qbox identifier
qbxmigrate all       [apply]        everything applicable, in order
```

Without `apply`, every step is a dry run that writes only a report to `output/`. The command is
ACE-restricted (`command.qbxmigrate`) and intended for the server console.

Tuning lives in the `CONFIG` table at the top of `server.lua`: batch size, account-item stripping,
qb table names and identifier prefixes, metadata defaults, `identity.columns` (which tables get their
identifier rewritten at login), and the `esx` block (users table name, identifier type, date format,
weight multiplier, addon vehicle models, orphan vehicle policy, weapon component map).

---

## What this kit does NOT do

Stated plainly, so you find out here and not at 2am on launch night:

- **It does not rewrite gameplay logic.** Every `AddItem` / `xPlayer.addInventoryItem` /
  `ESX.GetPlayerFromId` call is reported with file, line and the ox/qbx replacement — a human makes the
  change. The semantics differ too much for a regex to be trusted with it.
- **It does not compute license2 offline.** Nothing can. It rewrites it at login instead.
- **It does not migrate clothing.** illenium-appearance has its own converters.
- **It does not migrate doorlocks, housing, phone data, billing, or third-party tables.**
- **It does not touch anything under `[ox]`, `qbx_core`, `ox_lib`, or `node_modules`.**

---

## Sources

- [Converting from QBCore to Qbox](https://docs.qbox.re/converting)
- [qbx_core.sql](https://github.com/Qbox-project/qbx_core/blob/main/qbx_core.sql) and
  [server/storage/players.lua](https://github.com/Qbox-project/qbx_core/blob/main/server/storage/players.lua)
  (`users` table, `license = ? OR license = ?` character lookup, cid normalisation)
- [qbx_vehicles vehicles.sql](https://github.com/Qbox-project/qbx_vehicles/blob/main/vehicles.sql)
- [ox_inventory MySQL layer](https://github.com/overextended/ox_inventory/blob/main/modules/mysql/server.lua)
  and [ESX bridge](https://github.com/overextended/ox_inventory/blob/main/modules/bridge/esx/server.lua)
- [es_extended legacy.sql](https://github.com/esx-framework/esx_core/blob/main/%5BSQL%5D/legacy.sql),
  [ESX.GetIdentifier](https://github.com/esx-framework/esx_core/blob/main/%5Bcore%5D/es_extended/server/functions.lua),
  [esx_multicharacter database.lua](https://github.com/esx-framework/esx_core/blob/main/%5Bcore%5D/esx_multicharacter/server/modules/database.lua)
- [ox_target qtarget compatibility](https://github.com/overextended/ox_target/blob/main/client/compat/qtarget.lua)
