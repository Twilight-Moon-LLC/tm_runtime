fx_version 'cerulean'
games { 'gta5', 'rdr3' }
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

lua54 'yes'

name 'tm_runtime'
description 'Resource lifecycle events and dependency graph management'
version '0.0.1'
author 'KodeRed'

dependencies {
    'ox_lib',
}

shared_scripts {
    '@ox_lib/init.lua',
}

server_scripts {
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}
