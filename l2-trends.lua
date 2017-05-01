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

local period_price = 0.5
local period_trend = 20

local avg_price = 50
local avg_trend = period_trend/period_price

local sensitivity = 0.2
local spread_open = 0
local spread_fix = 40

local avg_price_open = 5

local pricer = q_bricks.PriceTracker.create()
local ma_bid = q_bricks.MovingAverage.create(avg_price, period_price)
local ma_ask = q_bricks.MovingAverage.create(avg_price, period_price)
local ma_bid_open = q_bricks.MovingAverage.create(avg_price_open, period_price)
local ma_ask_open = q_bricks.MovingAverage.create(avg_price_open, period_price)
local ptrend_bid = q_bricks.Trend.create(avg_trend)
local ptrend_ask = q_bricks.Trend.create(avg_trend)
local alpha_bid = q_bricks.AlphaByTrend.create(sensitivity)
local alpha_ask = q_bricks.AlphaByTrend.create(sensitivity)
local alpha_aggr = q_bricks.AlphaAgg.create()
local alpha_open = q_bricks.AlphaFilterOpen.create(spread_open, ma_bid_open, ma_ask_open)
local alpha_fix = q_bricks.AlphaFilterFix.create(spread_fix)
--local alpha = q_bricks.AlphaSimple.create(40, 5)

local now = nil
local prevLn = nil

function processEvent(ev)
    local t = ev.time or ev.received_time
    if t then
        now = now or t
        now = math.max(now, t)
    end
    if ev.event == "onQuote" then
        pricer:onQuote(ev.l2)

        local quantum = ma_bid:onValue(pricer.bid, now)
        while quantum do
            ptrend_bid:onValue(ma_bid.ma_val, ma_bid.time, true)
            quantum = ma_bid:onValue(pricer.bid, now)
        end

        quantum = ma_ask:onValue(pricer.ask, now)
        while quantum do
            ptrend_ask:onValue(ma_ask.ma_val, ma_ask.time, true)
            quantum = ma_ask:onValue(pricer.ask, now)
        end
        
        quantum = ma_bid_open:onValue(pricer.bid, now)
        while quantum do
            quantum = ma_bid_open:onValue(pricer.bid, now)
        end

        quantum = ma_ask_open:onValue(pricer.ask, now)
        while quantum do
            quantum = ma_ask_open:onValue(pricer.ask, now)
        end

        --ptrend_bid:onValue(ma_bid.val, now)
        --ptrend_ask:onValue(ma_ask.val, now)
        
        alpha_bid:onValue(ptrend_bid.trend)
        alpha_ask:onValue(ptrend_ask.trend)
        alpha_aggr:aggregate(alpha_bid.alpha, alpha_ask.alpha)
        alpha_open:filter(alpha_aggr.alpha, pricer.bid, pricer.ask)
        alpha_fix:filter(alpha_open.alpha, pricer.bid, pricer.bid)
        changed = true
    elseif ev.event == "onAllTrade" then
        --trend:onAllTrade(ev.trade)
        --changed = true
    end

    if changed and now and ma_bid.val and ma_ask.val then
        local ms = math.floor((now - math.floor(now))*1000)
        local timestamp = string.format("%s.%03d", os.date("%H:%M:%S", math.floor(now)), ms)
        local data =
            { mid     = pricer.mid
            , price  = (ma_bid.val + ma_ask.val)/2
            , price_open  = (ma_bid_open.val + ma_ask_open.val)/2
            , trend = (ptrend_bid.trend + ptrend_ask.trend)/2
            , alpha_bid  = alpha_bid.alpha
            , alpha_ask  = alpha_ask.alpha
            , alpha_aggr = alpha_aggr.alpha
            , alpha_open = alpha_open.alpha
            , alpha_fix  = alpha_fix.alpha
            , count_bid  = ma_bid.count
            , count_ask  = ma_ask.count
            }
        local ln = string.format(
            -- mid   price   price-open  trend   alpha-bid alpha-ask  alpha alpha-open alpha-fix  count-bid  count-ask
            "%15.03f %15.03f %15.03f ".."%15.04f %15d " .. "%15d " .. "%15d %15d " ..  "%15d " .. "%15d " .. "%15d"
            , data.mid, data.price, data.price_open, data.trend
            , data.alpha_bid, data.alpha_ask
            , data.alpha_aggr
            , data.alpha_open
            , data.alpha_fix
            , data.count_bid
            , data.count_ask
            )
        if not prevLn or ln ~= prevLn then
            prevLn = ln
            FPrint("%12s %s", timestamp, ln)
        end
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
    -- 2   3    4    5    6    7    8    9    10   11   12
    "%15s %15s %15s %15s %15s %15s %15s %15s %15s %15s %15s"
    , "time"
    -- 2      3         4            5        6            7            8        9             10           11           12
    , "mid", "price", "price-open", "trend", "alpha-bid", "alpha-ask", "alpha", "alpha-open", "alpha-fix", "count-bid", "count-ask"
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
