--[[
#    
# Cериализация маркетных данных (уровень 2)
#
#  vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]


local q_l2_data = assert(require("qlib/quik-jit-l2-data"))

local q_persist = {}

function q_persist.preProcessBookSide(count, side)
    count = math.max(0, math.min(20, tonumber(count)))
    if count == 0 then
        return count
    end
    local quotes = {}
    for i = 1,count do
        local q = side[i]
        table.insert(quotes, { price = tonumber(q.price), quantity = tonumber(q.quantity) })
    end
    return count, quotes
end

function q_persist.preProcessL2(l2)
    if not l2 then
        return
    end
    local bid_count, bid = q_persist.preProcessBookSide(l2.bid_count, l2.bid)
    local offer_count, offer = q_persist.preProcessBookSide(l2.offer_count, l2.offer)
    return
        { bid_count = bid_count
        , bid = bid
        , offer_count = offer_count
        , offer = offer
        }
end

function q_persist.parseLine(line)
    local fn, message = loadstring("return {" .. line .. "}")
    assert(fn, message)
    local status, rec = pcall(fn)
    assert(status)
    rec = rec[1]
    rec.l2 = q_persist.preProcessL2(rec.l2)
    return rec
end

function q_persist.loadL2Log(fname, data)
    local file = fname and assert(io.open(fname,"r")) or io.stdin
    data = data or q_l2_data.create()
    for line in file:lines() do
        local rec = q_persist.parseLine(line)
        data:add(rec)
    end
    assert(data.data:size() > 0)
    return data
end

function q_persist.toString(val)
    if type(val) == "table" then
        local s = "{ "
        for k,v in pairs(val) do
            s = string.format('%s [%s] = %s,', s, q_persist.toString(k), q_persist.toString(v))
        end
        return s .. " }"
    elseif type(val) == "string" then
        return '"' .. val .. '"'
    end
    return tostring(val)
end

return q_persist
