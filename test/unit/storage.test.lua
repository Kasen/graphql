#!/usr/bin/env tarantool

local tap = require('tap')
local fio = require('fio')

-- require in-repo version of graphql/ sources despite current working directory
local cur_dir = fio.abspath(debug.getinfo(1).source:match("@?(.*/)")
    :gsub('/./', '/'):gsub('/+$', ''))
package.path =
    cur_dir .. '/../../?/init.lua' .. ';' ..
    cur_dir .. '/../../?.lua' .. ';' ..
    package.path

local storage = require('graphql.storage')

local test = tap.test('storage')
test:plan(0)

box.cfg({})
box.schema.create_space('test')
box.space.test:create_index('pk', {
    type = 'tree',
    unique = true,
    parts = {
        {field = 1, type = 'unsigned'},
    },
})
box.space.test:create_index('sk', {
    type = 'tree',
    unique = false,
    parts = {
        {field = 2, type = 'string', is_nullable = true},
    },
})

box.space.test:insert({1, 'a'})
box.space.test:insert({2, 'b'})
box.space.test:insert({3, 'c'})
box.space.test:insert({4, 'c'})
box.space.test:insert({5, 'c'})
box.space.test:insert({6, 'c'})
box.space.test:insert({7, 'c'})
box.space.test:insert({8, 'c'})
box.space.test:insert({9, 'c'})
box.space.test:insert({10, 'c'})
box.space.test:insert({11, 'c'})
box.space.test:insert({12, 'c'})
box.space.test:insert({13, 'd'})
box.space.test:insert({14, 'e'})
box.space.test:insert({15, 'f'})
box.space.test:insert({16, 'g'})

storage.init()
storage.set_block_size(2)

local function print_all_chunks(space_name, index_name, key, opts)
    local metainfo
    local cursor
    local data
    repeat
        metainfo, data = single_select(space_name, index_name, key, opts, cursor)
        cursor = metainfo.cursor
        print(require('yaml').encode({metainfo, data}))
    until cursor.is_end
end

--print_all_chunks('test', 'sk', {}, {})
--print_all_chunks('test', 'pk', {}, {limit = 1})
print_all_chunks('test', 'pk', {1}, {})

box.space.test:drop()
os.exit(test:check() == true and 0 or 1)
