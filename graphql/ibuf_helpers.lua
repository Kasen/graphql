local bit = require('bit')
local ffi = require('ffi')
local msgpackffi = require('msgpackffi')

local ibuf_helpers = {}

local IPROTO_DATA = 0x30

-- Read the next char from buffer.
local function ibuf_getchar(buf)
    if buf.rpos >= buf.wpos then
        error('unexpected end of buffer')
    end
    local c = buf.rpos[0]
    buf.rpos = buf.rpos + 1
    return ffi.cast('unsigned char', c)
end

-- Less optimal then msgpackffi code, but much more readable.
local function decode_u32(buf)
    local c1 = ibuf_getchar(buf)
    local c2 = ibuf_getchar(buf)
    local c3 = ibuf_getchar(buf)
    local c4 = ibuf_getchar(buf)
    return tonumber(bit.lshift(c1, 24) + bit.lshift(c2, 16) +
        bit.lshift(c3, 8) + c4)
end

-- Return amount of return values.
function ibuf_helpers.ibuf_decode_call_header(buf)
    local c = ibuf_getchar(buf)
    if not (c >= 0x80 and c <= 0x8f) then -- fixmap
        error('wrong call header: expected fixmap')
    end
    if bit.band(c, 0xf) ~= 1 then -- size 1
        error('wrong call header: expected fixmap size 1')
    end
    c = ibuf_getchar(buf)
    if not (c <= 0x7f) then -- fixint
        error('wrong call header: expected fixint')
    end
    if tonumber(c) ~= IPROTO_DATA then
        error('wrong call header: expected IPROTO_DATA')
    end
    c = ibuf_getchar(buf)
    if c ~= 0xdd then -- array32
        error('wrong call header: expected array32')
    end

    return decode_u32(buf)
end

-- Decode the next return value.
function ibuf_helpers.ibuf_decode_next(buf)
    local res, newpos = msgpackffi.decode(buf.rpos)
    buf.rpos = ffi.cast('char *', newpos)
    return res
end

-- Ensure the whole buffer was read.
function ibuf_helpers.ibuf_ensure_end(buf)
    assert(buf.rpos <= buf.wpos)
    if buf.rpos < buf.wpos then
        error('expected buffer end')
    end
end

return ibuf_helpers
