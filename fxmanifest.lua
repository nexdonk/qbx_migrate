fx_version "cerulean"
game "gta5"
lua54 "yes"

description "QBX Migration utilities: QBCore / ESX -> Qbox (qbx_core + ox stack)"
author "qbx_migrate"
version "2.0.0"

server_scripts {
    "@ox_lib/init.lua",
    "@oxmysql/lib/MySQL.lua",
    "server.lua",          -- shared helpers, QBCore steps, command dispatcher (defines QBXM)
    "server/esx.lua",      -- ESX -> qbx database conversion
    "server/identity.lua", -- login-time license -> license2 reconciler
    "server/panel.lua",    -- HTTP bridge for the local control panel (run.bat)
}

files {
    "sql/*.sql",
    "data/*.lua",
}

dependencies {
    "oxmysql",
    "ox_lib",
}
