#!/usr/bin/env luajit
--[[
    Specialized unix tool to analize USD vs Si

    Loads l2 - log file from stdin and prints table to stdout
]]

assert(require("qlib/quik-l2-persist"))

local data = q_persist.loadL2Log()

print("loaded: ", data.data:size())

local counters =
    {
    }    

local assets = {}
local assetInfos = 
    { USD000000TOD =
        { name = 'USD today'
        , mult = 1000
        }
    , USD000UTSTOM =
        { name = 'USD tomorow'
        , mult = 1000
        }
    }

-- pass 1: build list of asset using first 1000 lines
local count = 1000
for _,rec in data.data:items() do
    count = count - 1
    if count == 0 then
        break
    end
    if rec.asset and counters[rec.asset] == nil then
        table.insert(assets, rec.asset)
        counters[rec.asset] = 
            { bid = 0
            , offer = 0
            , spot = false
            , trend = 0
            }
    end
end

local header = "time, unix time"

for _,asset in ipairs(assets) do
    local info = assetInfos[asset] or { name = asset, mult = 1 }
    header = string.format("%s, %s bid, %s offer, %s spot, %s trend", header, info.name, info.name, info.name, info.name)
end

print(header)
header = nil

local function formatLine()
    local ln = false
    for _,asset in ipairs(assets) do
        ln = ln and (ln ..  ", ") or ""
        local cnt = counters[asset]
        ln = ln .. string.format("%.0f, %.0f, %.2f, %.4f", cnt.bid or 0, cnt.offer or 0, cnt.spot or 0, cnt.trend or 0)
    end
    return ln
end


local line = false
local k = 1/(1 + 50)

for _,rec in data.data:items() do
    if rec.event == "onQuote" then
        local cnt = counters[rec.asset]
        local tm = rec.tstamp
        local bid_count = tonumber(rec.l2.bid_count)
        local offer_count = tonumber(rec.l2.offer_count)
        if cnt and bid_count > 0 and offer_count > 0 then
            local info = assetInfos[rec.asset] or { name = asset, mult = 1 }
            cnt.bid = tonumber(rec.l2.bid[bid_count].price)*info.mult
            cnt.offer = tonumber(rec.l2.offer[1].price)*info.mult
            local spot = (cnt.bid + cnt.offer)/2
            cnt.spot = cnt.spot and (cnt.spot + k*(spot - cnt.spot)) or spot
            local trend = (spot - cnt.spot)*k
            cnt.trend = cnt.trend + k*(trend - cnt.trend)

            local newLn = formatLine()
            if not line or newLn ~= line then
                line = newLn
                local utime = math.floor(tm)
                local mcs = math.floor((tm - utime)*1000)
                print(string.format("%s.%d, %.03f, %s", os.date("%H:%M:%S", utime), mcs, tm, line))
            end
        end
    end
end

