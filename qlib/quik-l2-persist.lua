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


q_persist = {}

local q_l2_data = assert(require("qlib/quik-jit-l2-data"))

local function preProcessBookSide(count, side)
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

local function preProcessL2(l2)
    if not l2 then
        return
    end
    local bid_count, bid = preProcessBookSide(l2.bid_count, l2.bid)
    local offer_count, offer = preProcessBookSide(l2.offer_count, l2.offer)
    return
        { bid_count = bid_count
        , bid = bid
        , offer_count = offer_count
        , offer = offer
        }
end

function q_persist.loadL2Log(fname, data)
    local file = fname and assert(io.open(fname,"r")) or io.stdin
    data = data or q_l2_data.create()
    for line in file:lines() do
        local text = "return {" .. line .. "}"
        local fn, message = loadstring(text)
        assert(fn, message)
        local status, rec = pcall(fn)
        assert(status)
        rec = rec[1]
        rec.l2 = preProcessL2(rec.l2)
        data:add(rec)
    end
    assert(data.data:size() > 0)
    return data
end
