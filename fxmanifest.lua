fx_version "cerulean"
game "gta5"
lua54 "yes"

description "QBX Migration utilities for QBCore"
author "qbx_migrate"
version "1.0.0"

server_scripts {
    "@ox_lib/init.lua",
    "@oxmysql/lib/MySQL.lua",
    "server.lua"
}

files {
    "sql/*.sql"
}

dependencies {
    "oxmysql",
    "ox_lib"
}
