-- =====================================================================================
-- qbx_migrate :: 01_qbx_schema.sql
-- Additive schema migration: QBCore -> Qbox (qbx_core + ox_inventory).
-- Nothing here drops a table, drops a column, or deletes a row.
--
-- SYNTAX NOTE: `ADD COLUMN IF NOT EXISTS` is MariaDB. Almost every FiveM server runs
-- MariaDB. If you are on real MySQL 8, delete the `IF NOT EXISTS` from the ALTER
-- statements and run only the ones you actually need, or just use the in-game
-- `qbxmigrate schema apply` command which checks each column individually.
--
-- BACK UP FIRST:  mysqldump -u root -p yourdb > qbcore_backup.sql
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- players : columns qbx_core expects
-- -------------------------------------------------------------------------------------
ALTER TABLE `players`
    ADD COLUMN IF NOT EXISTS `last_logged_out` timestamp NULL DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS `userId` INT UNSIGNED DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS `phone_number` VARCHAR(20) DEFAULT NULL;

-- player_groups has a foreign key on players.citizenid; the collations must match.
ALTER TABLE `players`
    MODIFY COLUMN `citizenid` varchar(50) NOT NULL COLLATE utf8mb4_unicode_ci,
    MODIFY COLUMN `name` varchar(255) NOT NULL COLLATE utf8mb4_unicode_ci;

-- -------------------------------------------------------------------------------------
-- bans : qbx_core ban storage
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `bans` (
    `id` int(11) NOT NULL AUTO_INCREMENT,
    `name` varchar(50) DEFAULT NULL,
    `license` varchar(50) DEFAULT NULL,
    `discord` varchar(50) DEFAULT NULL,
    `ip` varchar(50) DEFAULT NULL,
    `reason` text DEFAULT NULL,
    `expire` int(11) DEFAULT NULL,
    `bannedby` varchar(255) NOT NULL DEFAULT 'LeBanhammer',
    PRIMARY KEY (`id`),
    KEY `license` (`license`),
    KEY `discord` (`discord`),
    KEY `ip` (`ip`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------------------------------------
-- player_groups : qbx_core multijob / multigang
-- Populate it AFTER qbx_core is installed by running `convertjobs` in the server console.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `player_groups` (
    `citizenid` VARCHAR(50) NOT NULL,
    `group` VARCHAR(50) NOT NULL,
    `type` VARCHAR(50) NOT NULL,
    `grade` TINYINT(3) UNSIGNED NOT NULL,
    PRIMARY KEY (`citizenid`, `type`, `group`),
    CONSTRAINT `fk_citizenid` FOREIGN KEY (`citizenid`) REFERENCES `players` (`citizenid`)
        ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------------------------------------
-- ox_inventory : stash storage (SELECT data FROM ox_inventory WHERE owner = ? AND name = ?)
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ox_inventory` (
    `owner` varchar(60) DEFAULT NULL,
    `name` varchar(100) NOT NULL,
    `data` longtext DEFAULT NULL,
    `lastupdated` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
    UNIQUE KEY `owner_name` (`owner`,`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------------------------------------
-- player_vehicles : ox_inventory keeps vehicle storage on the vehicle row, keyed by id
--   SELECT plate, trunk    FROM player_vehicles WHERE id = ?
--   SELECT plate, glovebox FROM player_vehicles WHERE id = ?
-- -------------------------------------------------------------------------------------
ALTER TABLE `player_vehicles`
    ADD COLUMN IF NOT EXISTS `trunk` longtext DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS `glovebox` longtext DEFAULT NULL;

-- -------------------------------------------------------------------------------------
-- qbx_migrations : bookkeeping so steps are never applied twice
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `qbx_migrations` (
    `id` varchar(64) NOT NULL,
    `ran_at` timestamp NOT NULL DEFAULT current_timestamp(),
    `rows_affected` int(11) NOT NULL DEFAULT 0,
    `notes` text DEFAULT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================================
-- NOT DONE HERE ON PURPOSE (data conversion needs logic, not SQL):
--   players.inventory            qb item format -> ox item format
--   stashitems                   -> ox_inventory
--   trunkitems / gloveboxitems   -> player_vehicles.trunk / .glovebox
-- Run `qbxmigrate inventory apply` in the server console for those.
--
-- The legacy tables stashitems / trunkitems / gloveboxitems are deliberately LEFT IN
-- PLACE. Drop them yourself only once you are satisfied the migration worked.
-- =====================================================================================
