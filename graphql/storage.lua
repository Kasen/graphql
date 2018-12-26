local log = require('log')
local json = require('json')
-- local yaml = require('yaml')
local ffi = require('ffi')

local storage = {}

local BLOCK_SIZE = 1000

local iterator_types = {
    [box.index.EQ] = true,
    [box.index.REQ] = true,
    [box.index.ALL] = true,
    [box.index.LT] = true,
    [box.index.LE] = true,
    [box.index.GE] = true,
    [box.index.GT] = true,
}

local asc_iterator_types = {
    [box.index.EQ] = true,
    [box.index.ALL] = true,
    [box.index.GE] = true,
    [box.index.GT] = true,
}

local function check_iterator_type(opts, key)
    local key_is_nil = (key == nil or
        (type(key) == 'table' and #key == 0))
    local iterator_type = box.internal.check_iterator_type(opts, key_is_nil)
    if not iterator_types[iterator_type] then
        error('wrong iterator type')
    end
    return iterator_type
end

local function key_from_tuple(tuple, index)
    local key = {}
    for _, part in ipairs(index.parts) do
        table.insert(key, tuple[part.fieldno] or box.NULL)
    end
    return key
end

local function tuple_equal(t1, t2, index)
    for _, part in ipairs(index.parts) do
        local fieldno = part.fieldno
        if t1[fieldno] ~= t2[fieldno] then
            return false
        end
    end
    return true
end

local function tuple_equal_key(tuple, key, index)
    local keypartno = 1
    for _, part in ipairs(index.parts) do
        local fieldno = part.fieldno
        if key[keypartno] ~= nil and tuple[fieldno] ~= key[keypartno] then
            return false
        end
        keypartno = keypartno + 1
    end
    return true
end

local function next_cursor(data, size, index, iterator, offset, eq_key,
        next_limit, key)
    local tuple = data[size]
    local next_key = key_from_tuple(tuple, index)
    local next_offset
    local next_iterator

    if index.unique then
        if asc_iterator_types[iterator] then
            next_iterator = box.index.GT
        else
            next_iterator = box.index.LT
        end

        next_offset = 0
    else
        if asc_iterator_types[iterator] then
            next_iterator = box.index.GE
        else
            next_iterator = box.index.LE
        end

        -- XXX: we can check data[size + 1] to avoid offset
        next_offset = 1

        --[[
        if tuple_equal_key(tuple, next_key, index) then -- XXX
            next_offset = offset + size
        else
        ]]--
            for i = size - 1, 1, -1 do
                if tuple_equal(tuple, data[i], index) then
                    next_offset = next_offset + 1
                end
            end
            if next_offset == size then
                next_key = key
                next_offset = next_offset + offset
            end
            --assert(next_offset < size)
        --end
    end

    return {
        eq_key = eq_key,
        next_key = next_key,
        next_iterator = next_iterator,
        next_offset = next_offset,
        next_limit = next_limit,
        is_end = false,
    }
end

local function single_select(space_name, index_name, key, opts, cursor)
    log.info(('single_select(%s, %s, %s, %s, %s)'):format(
        space_name, index_name or 'nil', json.encode(key),
        json.encode(opts), json.encode(cursor)))

    local index = index_name == nil and
        box.space[space_name].index[0] or
        box.space[space_name].index[index_name]

    if cursor ~= nil then
        key = cursor.next_key
        opts = {
            iterator = cursor.next_iterator,
            offset = cursor.next_offset,
            limit = cursor.next_limit,
        }
    end

    local opts = table.copy(opts or {})
    assert(opts.limit == nil or type(opts.limit) == 'number' or (
        type(opts.limit) == 'cdata' and (ffi.istype('int64_t', opts.limit) or
        ffi.istype('uint64_t', opts.limit))))

    local is_end = false

    -- set limit to max(limit, BLOCK_SIZE) + 1 to send max(limit, BLOCK_SIZE)
    -- tuples and detect whether there are more; set next_limit
    local next_limit
    local real_limit
    if opts.limit == nil then
        opts.limit = BLOCK_SIZE + 1
    elseif opts.limit > BLOCK_SIZE then
        opts.limit = BLOCK_SIZE + 1
        next_limit = opts.limit - BLOCK_SIZE
    else
        real_limit = opts.limit
    end

    local data = index:select(key, opts)
    local size = #data

    -- cut the tuple out of the block
    if size == BLOCK_SIZE + 1 then
        data[size] = nil
        size = size - 1
    end

    is_end = is_end or (real_limit ~= nil and size <= real_limit) or
        size < BLOCK_SIZE

    if is_end then
        local metainfo = {
            cursor = {
                is_end = true,
            },
            size = size,
        }
        -- log.info('single_select retval: ' .. yaml.encode({metainfo, data}))
        return metainfo, data
    end

    local iterator = check_iterator_type(opts, key)
    local eq_key
    if cursor == nil then
        if iterator == box.index.EQ or iterator == box.index.REQ then
            eq_key = key
        end
    end

    if eq_key and not tuple_equal_key(data[size], eq_key, index) then
        data[size] = nil
        for i = size - 1, 1, -1 do
            if not tuple_equal_key(data[i], eq_key, index) then
                data[size] = nil
            end
        end
        is_end = true
    end

    if is_end then
        local metainfo = {
            cursor = {
                is_end = true,
            },
            size = #data,
        }
        -- log.info('single_select retval: ' .. yaml.encode({metainfo, data}))
        return metainfo, data
    end

    local offset = opts.offset or 0
    local metainfo = {
        cursor = next_cursor(data, size, index, iterator, offset, eq_key,
            next_limit, key),
        size = #data,
    }

    -- log.info('single_select retval: ' .. yaml.encode({metainfo, data}))
    return metainfo, data
end

local function batch_select(space_name, index_name, keys, opts)
    log.info(('batch_select(%s, %s, %s, %s)'):format(
        space_name, index_name or 'nil', json.encode(keys),
        json.encode(opts)))

    local index = index_name == nil and
        box.space[space_name].index[0] or
        box.space[space_name].index[index_name]
    local results = {}

    for _, key in ipairs(keys) do
        -- log.info('batch_select key:\n' .. json.encode(key))
        local tuples = index:select(key, opts)
        -- log.info('batch_select tuples:\n' .. yaml.encode(tuples))
        table.insert(results, tuples)
    end

    -- log.info('batch_select result:\n' .. yaml.encode(results))
    return results
end

function storage.functions()
    return {
        single_select = single_select,
        batch_select = batch_select,
    }
end

function storage.init()
    for k, v in pairs(storage.functions()) do
        _G[k] = v
    end
end

-- declare globals for require('strict').on()
for k, _ in pairs(storage.functions()) do
    _G[k] = nil
end

-- for testing
function storage.get_block_size()
    return BLOCK_SIZE
end

-- for unit testing
function storage.set_block_size(new_block_size)
    local old_block_size = BLOCK_SIZE
    BLOCK_SIZE = new_block_size
    return old_block_size
end

return storage
