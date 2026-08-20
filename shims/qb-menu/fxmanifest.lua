fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qb-menu'
description 'qb-menu API implemented on top of ox_lib context menus. Drop-in replacement so legacy scripts keep working under Qbox.'
author 'qbx_migrate'
version '1.0.0'

client_scripts {
    '@ox_lib/init.lua',
    'client.lua'
}

dependencies {
    'ox_lib'
}
