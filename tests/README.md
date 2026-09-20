# qbx_migrate tests

The resource's server Lua runs unmodified under [fengari](https://github.com/fengari-lua/fengari)
(Lua 5.3 in JS) with shims for the FiveM natives and the oxmysql `MySQL.*.await` API, against a
**real MariaDB**. Every query the migration issues hits a real database; nothing is mocked at the
SQL level.

## Setup

1. Node 18+.
2. A throwaway MariaDB/MySQL reachable at `127.0.0.1:3399`, user `qbxm` / password `qbxm`, with
   rights to `DROP DATABASE qbxm_test` (the suites recreate it every run). Override with
   `QBXM_DB_HOST`, `QBXM_DB_PORT`, `QBXM_DB_USER`, `QBXM_DB_PASS`.

   A disposable instance with the MariaDB Windows build:
   ```
   mariadb-install-db --datadir=C:\tmp\qbxm_db --port=3399 --password=
   mariadbd --datadir=C:\tmp\qbxm_db --port=3399 --bind-address=127.0.0.1 --console
   mariadb -h127.0.0.1 -P3399 -uroot -e "CREATE USER 'qbxm'@'127.0.0.1' IDENTIFIED BY 'qbxm'; GRANT ALL ON *.* TO 'qbxm'@'127.0.0.1';"
   ```
3. `cd tests && npm install`

## Run

```
npm test            # syntax check + ESX suite + QB suite
npm run test:esx    # ESX Legacy db -> esx apply -> rerun -> items/jobs/check -> identity -> rollback -> re-apply
npm run test:qb     # QBCore db -> schema/inventory/phone/metadata apply -> rerun -> identity -> backup restore
```

**Never point these at a real server database.** They drop and recreate `qbxm_test`.

## What the ESX suite asserts

- `users` renamed to `esx_users`; qbx tables created; nothing written on a dry run
- identifier shapes: bare 40-hex, `charN:hex`, `steam:...`, `charN:<steam hex>` all normalised; cids preserved per account
- money / job (label, payment, boss, type) / charinfo (DMY date, gender, phone, height) / metadata (status → hunger/thirst, licences, health, armor) / position
- inventory: legacy `{name=count}` map, legacy `[{name,count}]` list, already-ox list left byte-identical; loadout weapons with ammo/tint/components, `black_money` as an item, zero-count items dropped
- vehicles: hash → model, `stored`/`pound` → state, `parking` → garage, props → mods/fuel/engine/body; unresolved models and unowned vehicles reported and skipped
- societies merged from `addon_inventory_items` + `datastore_data`; owned stashes rekeyed; existing `ox_inventory` owners remapped
- ACE snippet for admins; society funds JSON
- idempotent re-run keeps citizenids; rollback restores everything; apply after rollback works
- login reconciler rewrites `players` / `player_vehicles` / `bans` to `license2:` for every identifier the client presents (typed or bare), never touches other accounts, and is a no-op on the second connect
