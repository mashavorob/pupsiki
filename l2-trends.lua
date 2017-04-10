#!/usr/bin/env luajit
-- vi: ft=lua:fenc=cp1251 
--[[
#
# Анализ трендов
#
# Пример использования:
#
# cat <l2-данные> | l2-trends.lua > data.csv
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_persist = assert(require("qlib/quik-l2-persist"))
local q_bricks = assert(require("qlib/quik-bricks"))

local function FPrint(fmt, ...)
    local args = {...}

    print( string.format(fmt, unpack(args)) )
end

local function EPrint(fmt, ...)
    local args = {...}

    local message = string.format(fmt, unpack(args)) .. "\n"
    io.stderr:write(message)
end

local xbit = bit or bit32

local trendAvg1 = 250
local trendAvg2 = 250

local pricer = q_bricks.PriceTracker.create()
local ma1 = q_bricks.MovingAverage.create(100)
local ma2 = q_bricks.MovingAverage.create(3000)
local ptrendB1 = q_bricks.Trend.create(trendAvg1)
local ptrendA2 = q_bricks.Trend.create(trendAvg2)
local ptrendB2 = q_bricks.Trend.create(trendAvg2)
local alphaA = q_bricks.AlphaByTrend.create(12, 5)
local alphaB = q_bricks.AlphaByTrend.create(0.01)

local now = nil

function processEvent(ev)
    local t = ev.time or ev.received_time
    if t then
        now = now or t
        now = math.max(now, t)
    end
    if ev.event == "onQuote" then
        pricer:onQuote(ev.l2)

        ma1:onValue(pricer.mid)
        ma2:onValue(pricer.mid)
        ptrendB1:onValue(ma2.val)
        ptrendA2:onValue(ma1.val - ma2.val)
        ptrendB2:onValue(ptrendB1.trend)
        alphaA:onValue(ma1.val - ma2.val, ptrendA2.trend)
        alphaB:onValue(ptrendB1.trend, ptrendB2.trend)
        changed = true
    elseif ev.event == "onAllTrade" then
        --trend:onAllTrade(ev.trade)
        --changed = true
    end

    if changed and now and ma1.val then
        local ms = math.floor((now - math.floor(now))*1000)
        local timestamp = string.format("%s.%03d", os.date("%H:%M:%S", math.floor(now)), ms)
        local data =
            { mid     = pricer.mid
            , price1  = ma1.val
            , price2  = ma2.val
            , trendA1 = ma1.val - ma2.val
            , trendB1 = ptrendB1.trend
            , trendA2 = ptrendA2.trend
            , trendB2 = ptrendB2.trend
            , alphaA  = alphaA.alpha
            , alphaB  = alphaB.alpha
            }
        FPrint(
            "%12s " ..
            -- mid   price1  price2  trendA1 trendB1 trendA2 trendB2 alphaA alphaB
            "%15.03f %15.03f %15.04f %15.04f %15.08f %15.12f %15.12f %15d %15d"
            , timestamp
            , data.mid, data.price1, data.price2, data.trendA1, data.trendB1, data.trendA2, data.trendB2, data.alphaA, data.alphaB
            )
    end
end

function normalize(t)
    for k,v in pairs(t) do
        if type(v) == "string" then
            if v == string.match(v, "[0-9.]+") then
                t[k] = tonumber(v)
            end
        elseif type(v) == "table" then
            normalize(v)
        end
    end
end

FPrint(
    "%12s " ..
    -- 2   3    4    5    6    7    8    9    10
    "%15s %15s %15s %15s %15s %15s %15s %15s %15s"
    , "time"
    -- 2      3         4         5          6          7          8          9         10
    , "mid", "price1", "price2", "trendA1", "trendB1", "trendA2", "trendB2", "alphaA", "alphaB"
    )

local ln = 0

for line in io.stdin:lines() do
    local success, ev = pcall(q_persist.parseLine, line)
    ln = ln + 1
    if success then
        normalize(ev)
        processEvent(ev)
    else
        EPrint("Error parsing line %d, erroneous line is:\n%s\n", ln, line)
    end
end
