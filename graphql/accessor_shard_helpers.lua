--- Auxiliary functions for shard module usage needed across several modules.

local json = require('json')
local buffer = require('buffer')
local msgpack = require('msgpack')
local net_box = require('net.box')
local utils = require('graphql.utils')
local merger = utils.optional_require('merger')
local shard = utils.optional_require('shard')

local accessor_shard_helpers = {}

function accessor_shard_helpers.shard_check_error(func_name, result, err)
    if result ~= nil then return end

    -- avoid json encoding of an error message (when the error is in the known
    -- format)
    if type(err) == 'table' and type(err.error) == 'string' then
        error({
            message = err.error,
            extensions = {
                shard_error = err,
            }
        })
    end

    error(('%s: %s'):format(func_name, json.encode(err)))
end

-- two return values at most
local function replica_set_call(self, func_name, call_args, opts)
    local first_err

    -- Rerform the request on each node in a replica set starting from a master
    -- node until success or end of the nodes.
    for _, conn in ipairs(self) do
        local ok, res_1, res_2 = pcall(conn.call, conn, func_name, call_args,
            opts)
        if not ok then
            if first_err == nil then
                first_err = res_1
            end
        else
            return res_1, res_2
        end
    end

    return error(first_err)
end

function accessor_shard_helpers.routeall()
    assert(shard ~= nil, 'internal error: no shard module')

    local replicasets = {}

    for _, shard_replica_set in ipairs(shard.shards) do
        local replica_set = {}
        for n = #shard_replica_set, 1, -1 do
            local conn = shard_replica_set[n].conn
            table.insert(replica_set, conn)
        end
        setmetatable(replica_set, {__index = {call = replica_set_call}})
        table.insert(replicasets, replica_set)
    end

    return replicasets
end

-- Case when merger is not supported.
local function mr_call_base(gen_call_args, opts)
    error('not supported yet') -- XXX
end

local function decode_metainfo(buf)
    buf.rpos = assert(net_box.check_iproto_data(buf.rpos, buf.wpos - buf.rpos))
    buf.rpos = assert(msgpack.check_array(buf.rpos, buf.wpos - buf.rpos, 2))
    local res
    res, buf.rpos = msgpack.decode(buf.rpos, buf.wpos - buf.rpos)
    return res
end

--- Wait for data and request for the next data.
local function gen_fetch_source(replicasets, futures, gen_call_args)
    return function(source, _, _)
        local idx = source.idx
        local replica_set = replicasets[idx]
        local future = futures[idx]
        local buf = source.buffer
        assert(buf ~= nil)

        -- the source was entirely drained
        if future == nil then
            assert(buf.rpos == buf.wpos, 'expected buffer end')
            return
        end

        -- wait for requested data
        local res, err = future:wait_result()
        if res == nil then
            error(err)
        end

        -- decode metainfo, leave data to be processed by the merger
        local metainfo = decode_metainfo(buf)

        -- get next args and check whether we need the next call
        local func_name, call_args = gen_call_args(metainfo)
        if func_name == nil then
            futures[idx] = nil
            return
        end

        -- request the next data while we processing the current ones
        local opts = {buffer = buf, is_async = true}
        futures[idx] = replica_set:call(func_name, call_args, opts)
    end
end

-- Case when merger is supported.
local function mr_call_merger(gen_call_args)
    local replicasets = accessor_shard_helpers.routeall()
    local buffers = {}
    local futures = {}

    local func_name, call_args = gen_call_args()
    local collection_name = call_args[1]

    -- the require statement is here to avoid circular dependencies
    local accessor_shard_index_info =
        require('graphql.accessor_shard_index_info')
    local merger_context = accessor_shard_index_info.get_merger_context(
        collection_name, 0)

    -- request for data
    for i, replica_set in ipairs(replicasets) do
        buffers[i] = buffer.ibuf()
        local opts = {is_async = true, buffer = buffers[i]}
        futures[i] = replica_set:call(func_name, call_args, opts)
    end

    local fetch_source = gen_fetch_source(replicasets, futures, gen_call_args)

    return merger.pairs(merger_context, buffers, {fetch_source = fetch_source})
end

function accessor_shard_helpers.mr_call(gen_call_args, opts)
    if merger == nil then
        return mr_call_base(gen_call_args, opts)
    else
        return mr_call_merger(gen_call_args, opts)
    end
end

return accessor_shard_helpers
