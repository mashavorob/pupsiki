#!/usr/bin/env luajit
-- vi: ft=lua:fenc=cp1251 
--[[
#
# ������ �������
#
# ������ �������������:
#
# cat <l2-������> | l2-trends.lua > data.csv
#
# ���� �� ������ ��������� ��� ������ �� ��� ���������
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

local period_price = 0.25

local avg_price = 880
local avg_trend = 37
local avg_stoch = 37

local avg_volume = 1000

local sensitivity1 = 0.06
local sensitivity2 = 0.1
local spread_open = 0
local spread_fix = 86
local spread_open_stoch = 3
local spread_fix_stoch = 6

local avg_price_open = 99

local pricer = q_bricks.PriceTracker.create()

local ma_bid = q_bricks.MovingAverage.create(avg_price, period_price)
local ma_ask = q_bricks.MovingAverage.create(avg_price, period_price)

local ma_bid_open = q_bricks.MovingAverage.create(avg_price_open, period_price)
local ma_ask_open = q_bricks.MovingAverage.create(avg_price_open, period_price)

local ma_bid_stoch = q_bricks.MovingAverage.create(avg_stoch, period_price)
local ma_ask_stoch = q_bricks.MovingAverage.create(avg_stoch, period_price)

local ptrend_bid = q_bricks.Trend.create(avg_trend)
local ptrend_ask = q_bricks.Trend.create(avg_trend)

local volume = q_bricks.VolumeCounter.create(avg_volume, period_price)

local alpha_fix = q_bricks.AlphaFilterFix.create(spread_fix)

local alpha_bid = q_bricks.AlphaByTrend.create(alpha_fix, sensitivity1, sensitivity2)
local alpha_ask = q_bricks.AlphaByTrend.create(alpha_fix, sensitivity1, sensitivity2)
local alpha_aggr = q_bricks.AlphaAgg.create()
local alpha_open = q_bricks.AlphaFilterOpen.create(spread_open, ma_bid_open, ma_ask_open)

local alpha_stoch = q_bricks.AlphaStochOpen.create(spread_open_stoch, ma_bid_stoch, ma_ask_stoch)
local alpha_fix_stoch = q_bricks.AlphaFilterFix.create(spread_fix_stoch)

local now = nil
local prevLn = nil

function processEvent(ev)
    local t = ev.time or ev.received_time
    if t then
        now = now or t
        now = math.max(now, t)
    end

    while volume:onTime(now) do
    end

    if ev.event == "onQuote" then
        local new_bid, new_ask, new_mid = pricer:onQuote(ev.l2)

        if new_bid then
            local quantum = ma_bid:onValue(pricer.bid, now)
            while quantum do
                ptrend_bid:onValue(ma_bid.ma_val, ma_bid.time, true)
                quantum = ma_bid:onValue(pricer.bid, now)
            end
            quantum = ma_bid_open:onValue(pricer.bid, now)
            while quantum do
                quantum = ma_bid_open:onValue(pricer.bid, now)
            end
            quantum = ma_bid_stoch:onValue(pricer.bid, now)
            while quantum do
                quantum = ma_bid_stoch:onValue(pricer.bid, now)
            end
        end
        if new_ask then
            local quantum = ma_ask:onValue(pricer.ask, now)
            while quantum do
                ptrend_ask:onValue(ma_ask.ma_val, ma_ask.time, true)
                quantum = ma_ask:onValue(pricer.ask, now)
            end
            quantum = ma_ask_open:onValue(pricer.ask, now)
            while quantum do
                quantum = ma_ask_open:onValue(pricer.ask, now)
            end
            quantum = ma_ask_stoch:onValue(pricer.ask, now)
            while quantum do
                quantum = ma_ask_stoch:onValue(pricer.ask, now)
            end
        end

        if new_mid and ptrend_bid.trend and ptrend_ask.trend then
            alpha_bid:onValue(ptrend_bid.trend)
            alpha_ask:onValue(ptrend_ask.trend)
            alpha_aggr:aggregate(alpha_bid.alpha, alpha_ask.alpha)
            alpha_open:filter(alpha_aggr.alpha, pricer.bid, pricer.ask)
            alpha_fix:filter(alpha_open.alpha, pricer.bid, pricer.bid)

            alpha_stoch:filter(alpha_fix.alpha, alpha_fix_stoch.alpha, pricer.bid, pricer.ask)
            alpha_fix_stoch:filter(alpha_stoch.alpha, pricer.bid, pricer.bid)
            changed = true
        end
    elseif ev.event == "onAllTrade" then
        volume:onAllTrade(ev.trade)
        changed = true
    end

    if changed and now and ma_bid.val and ma_ask.val then
        local ms = math.floor((now - math.floor(now))*1000)
        local timestamp = string.format("%s.%03d", os.date("%H:%M:%S", math.floor(now)), ms)
        local data =
            { mid     = pricer.mid
            , price  = (ma_bid.val + ma_ask.val)/2
            , price_open  = (ma_bid_open.ma_val + ma_ask_open.ma_val)/2
            , trend = (ptrend_bid.trend + ptrend_ask.trend)/2
            , alpha_bid  = alpha_bid.alpha
            , alpha_ask  = alpha_ask.alpha
            , alpha_aggr = alpha_aggr.alpha
            , alpha_open = alpha_open.alpha
            , alpha_fix  = alpha_fix.alpha
            , alpha_stoch = alpha_stoch.alpha
            , alpha_fix_stoch = alpha_fix_stoch.alpha
            , sell_volume = volume.ma_sell
            , buy_volume = volume.ma_buy
            , volume = volume.ma_volume
            }
        local ln = string.format(
          -- mid   price   price-open  trend       
            "%15.03f %15.03f %15.03f ".."%15.04f ".. 
          -- alpha-bid alpha-ask  alpha alpha-open alpha-fix alpha-stoch alpha-stoch-fix
            "%15d " .. "%15d " .. "%15d %15d " ..  "%15d ".. "%15d "..   "%15d " .. 
          -- sell-volume buy-volume  volume
            "%15.04f ".."%15.04f ".."%15.04f" 
            , data.mid, data.price, data.price_open, data.trend
            , data.alpha_bid, data.alpha_ask
            , data.alpha_aggr
            , data.alpha_open
            , data.alpha_fix
            , data.alpha_stoch
            , data.alpha_fix_stoch
            , data.sell_volume
            , data.buy_volume
            , data.volume
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
    -- 2   3    4    5    6    7    8    9    10   11   12   13   14   15
    "%15s %15s %15s %15s %15s %15s %15s %15s %15s %15s %15s %15s %15s %15s"
    , "time"
    -- 2      3         4            5
    , "mid", "price", "price-open", "trend"
    -- 6            7            8        9             10           11             12
    , "alpha-bid", "alpha-ask", "alpha", "alpha-open", "alpha-fix", "alpha-stoch", "alpha-stoch-fix"
    -- 13          14         15
    , "sell-vol", "buy-vol", "vol"
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
