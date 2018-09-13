-- requires
-- --------

local fio = require('fio')

-- require in-repo version of graphql/ sources despite current working directory
package.path = fio.abspath(debug.getinfo(1).source:match("@?(.*/)")
    :gsub('/./', '/'):gsub('/+$', '')) .. '/../../?.lua' .. ';' .. package.path

local tap = require('tap')
local yaml = require('yaml')
local clock = require('clock')
local fiber = require('fiber')
local digest = require('digest')
local multirunner = require('test.common.multirunner')
local graphql = require('graphql')
local utils = require('graphql.utils')
local test_utils = require('test.test_utils')
local vb = require('test.virtual_box')
local test_run = utils.optional_require('test_run')
test_run = test_run and test_run.new()

-- constants
-- ---------

local SCRIPT_DIR = fio.abspath(debug.getinfo(1).source:match("@?(.*/)")
    :gsub('/./', '/'):gsub('/+$', ''))

-- module
-- ------

local bench = {}

local function workload(ctx, virtbox, bench_prepare, bench_iter, opts)
    local iterations = opts.iterations
    local exp_checksum = opts.checksum
    local conf_type = ctx.conf_type

    local state = {virtbox = virtbox}

    bench_prepare(state, ctx)

    local test = tap.test('workload')
    test:plan(1)

    local start_time = clock.monotonic64()

    local checksum = digest.crc32.new()

    -- first iteration; print result and update checksum
    local result = bench_iter(state)
    local statistics = result.meta.statistics
    local result_str = yaml.encode(result.data)
    checksum:update(result_str .. '1')

    -- the rest iterations; just update checksum
    for i = 2, iterations do
        local result = bench_iter(state)
        local result_str = yaml.encode(result.data)
        checksum:update(result_str .. tostring(i))
        if i % 100 == 0 then
            fiber.yield()
        end
    end

    local end_time = clock.monotonic64()

    local checksum = checksum:result()
    local tap_extra = {
        result = result,
        checksum = checksum,
        conf_type = conf_type,
    }

    if exp_checksum == nil then
        -- report user the result to check and the checksum to fill in the test
        local msg = 'check results below and fill the test with checksum below'
        test:ok(false, msg, tap_extra)
    else
        test:is(checksum, exp_checksum, 'checksum', tap_extra)
    end

    local duration = tonumber(end_time - start_time) / 1000^3
    local latency_avg = duration / iterations
    local rps_avg = iterations / duration

    return {
        ok = checksum == exp_checksum,
        duration_successive = duration,
        latency_successive_avg = latency_avg,
        rps_successive_avg = rps_avg,
        statistics = statistics,
    }
end

local function write_result(test_name, conf_name, bench_result, to_file)
    local result_name = ('%s.%s'):format(test_name, conf_name)
    local result_suffix = os.getenv('RESULT_SUFFIX')
    if result_suffix ~= nil and result_suffix ~= '' then
        result_name = ('%s.%s'):format(result_name, result_suffix)
    end

    local metrics = {
        'duration_successive',
        'latency_successive_avg',
        'rps_successive_avg',
        'statistics.resulting_object_cnt',
        'statistics.fetches_cnt',
        'statistics.fetched_object_cnt',
        'statistics.full_scan_cnt',
        'statistics.index_lookup_cnt',
        'statistics.cache_hits_cnt',
        'statistics.cache_hit_objects_cnt',
    }

    local result = ''
    for _, metric in ipairs(metrics) do
        local value
        local value_type
        if metric:startswith('statistics.') then
            value = bench_result.statistics[metric:gsub('^.-%.', '')]
            value_type = '%d'
        else
            value = bench_result[metric]
            value_type = '%f'
        end
        result = result .. ('%s.%s: ' .. value_type .. '\n'):format(
            result_name, metric, value)
    end

    if not to_file then
        print(result)
        return
    end

    local timestamp = os.date('%Y%m%dT%H%M%S')
    local file_name = ('bench.%s.%s.result.txt'):format(
        result_name, timestamp)
    local file_path = fio.abspath(fio.pathjoin(SCRIPT_DIR, '../..', file_name))

    local open_flags = {'O_WRONLY', 'O_CREAT', 'O_TRUNC'}
    local fh, err = fio.open(file_path, open_flags, tonumber('644', 8))
    assert(fh ~= nil, ('open("%s", ...) error: %s'):format(file_path,
        tostring(err)))
    fh:write(result)
    fh:close()
end

-- `init_function` and `cleanup_function` pushed down to storages, but
-- `bench_prepare` called on the frontend
function bench.run(test_name, opts)
    -- allow to run under tarantool on 'space' configuration w/o test-run
    local conf_name = test_run and test_run:get_cfg('conf') or 'space'
    local conf_type = multirunner.get_conf(conf_name).type

    local iterations = opts.iterations[conf_type]
    assert(iterations ~= nil)

    -- checksum can be nil, 'not ok' will be reported
    local checksum = opts.checksums[conf_type]

    local result = multirunner.run_conf(conf_name, {
        test_run = test_run,
        init_function = opts.init_function,
        cleanup_function = opts.cleanup_function,
        meta = opts.meta,
        workload = function(ctx)
            local virtbox = vb.get_virtbox_for_accessor(ctx.conf_type, ctx)
            return workload(ctx, virtbox, opts.bench_prepare, opts.bench_iter, {
                iterations = iterations,
                checksum = checksum,
            })
        end,
        servers = {'shard_tcp1', 'shard_tcp2', 'shard_tcp3', 'shard_tcp4'},
        use_tcp = true,
    })
    if result.ok then
        write_result(test_name, conf_name, result, not not test_run)
    end
end

-- helper for preparing benchmarking environment
function bench.bench_prepare_helper(testdata, ctx, virtbox)
    testdata.fill_test_data(virtbox)
    return test_utils.graphql_from_testdata(testdata, {
        timeout_ms = graphql.TIMEOUT_INFINITY,
    }, ctx)
end

return bench
