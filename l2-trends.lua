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

local window = {}
local windowSize = 1000

local priceAvg = 0
local normThreshold = 1
local jumpThreshold = 2

local FWAverager = {}

function FWAverager:moveNext(window)
    if #self.front then
        table.insert(self.back, self.front[1])
        table.remove(self.front, 1)
    end
    while #self.back > self.size do
        table.remove(self.back, 1)
    end
    local len = math.max(1, self.size)
    if #self.front < len then
        -- skip extracted record
        local index, i = 1, 1
        while i < #window and index <= #self.front do
            local ev = window[i]
            if ev.event == "onQuote" then
                index = index + 1
            end
            i = i + 1
        end

        while i < #window and #self.front < len do
            local ev = window[i]
            if ev.event == "onQuote" then
                table.insert(self.front, self.extractPrice(ev.l2))
            end
            i = i + 1
        end
    end
    if #self.front > 0 or #self.back > 0 then
        local sum = 0
        for _,p in ipairs(self.back) do sum = sum + p end
        for _,p in ipairs(self.front) do sum = sum + p end
        self.average = sum/(#self.front + #self.back)
    end
    return self.average
end

function FWAverager.create(side, len)

    local self = { size = len
                 , back = {}
                 , front = {}
                 , average = 0
                 }
    if side == 'B' then
        self.extractPrice = function (l2) return l2.bid_count > 0 and l2.bid[#l2.bid].price or 0 end
    else
        self.extractPrice = function (l2) return l2.offer_count > 0 and l2.offer[1].price or 0 end
    end
    setmetatable(self, {__index = FWAverager})
    return self
end


local Trend = {}

function Trend:onQuote(l2)

    local bid = l2.bid or {}
    local ask = l2.offer or {}

    local bid_price = (#bid > 0) and bid[#bid].price
    local ask_price = (#ask > 0) and ask[1].price

    bid_price = bid_price or ask_price
    ask_price = ask_price or bid_price
    local mid_price = ask_price and (ask_price + bid_price)/2
    self.mid_price = self.mid_price or mid_price
    if not mid_price then
        return
    end
    
    self.mid_price = self.mid_price + 1/(self.priceAvg + 1)*(mid_price - self.mid_price)

    local trend = mid_price - self.mid_price
    self.trend = self.trend + 1/(self.priceAvg2 + 1)*(trend - self.trend)

    local trend2 = trend - self.trend
    self.trend2 = self.trend2 + 1/(self.priceAvg2 + 1)*(trend2 - self.trend2)
   
    local sigma = math.pow(trend2, 2)
    self.sigma = self.sigma + 1/(self.sigmaAvg + 1)*(sigma - self.sigma)
end

function Trend.create(priceAvg, priceAvg2, sigmaAvg)
    local self = { mid_price = nil
                 , sigma = 0
                 , trend = 0
                 , trend2 = 0
                 , priceAvg = priceAvg
                 , priceAvg2 = priceAvg2
                 , sigmaAvg = sigmaAvg
                 , trigger = 0
                 }
    setmetatable(self, {__index = Trend})
    return self
end

local avg_bid = FWAverager.create('B', priceAvg)
local avg_ask = FWAverager.create('A', priceAvg)
local trend = Trend.create(50, 50, 5000)

local now = nil

function processLine(window)
    local ev = window[1]

    local t = ev.time or ev.received_time
    if t then
        now = now or t
        now = math.max(now, t)
    end
    if ev.event == "onQuote" then
        avg_bid:moveNext(window)
        avg_ask:moveNext(window)
        trend:onQuote(ev.l2)
        changed = true
    end
    table.remove(window, 1)

    if changed and now and 
        trend.mid_price and
        avg_bid.average > 0 and avg_ask.average > 0
     then
        local ms = math.floor((now - math.floor(now))*1000)
        local timestamp = string.format("%s.%03d", os.date("%H:%M:%S", math.floor(now)), ms)
        local data =
            { mid = (avg_bid.average + avg_ask.average)/2
            , price = trend.mid_price
            , up_price = math.sqrt(trend.sigma)*normThreshold
            , low_price = -math.sqrt(trend.sigma)*normThreshold
            , up_bar = math.sqrt(trend.sigma)*jumpThreshold
            , low_bar = -math.sqrt(trend.sigma)*jumpThreshold
            , trend = trend.trend
            , trend2 = trend.trend2
            }
        print(string.format(
            "%12s " ..
            -- mid    price  up-p    low-p   u-b     l-b      trend   trend2
            "%15.03f %15.03f %15.03f %15.03f %15.03f %15.03f  %15.04f %15.04f"
            , timestamp
            , data.mid, data.price
            , data.up_price, data.low_price, data.up_bar, data.low_bar, data.trend, data.trend2
            ))
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

print(string.format(
    "%12s " ..
    -- 2    3    4    5    6    7    8    9
    "%15s %15s %15s %15s %15s %15s %15s %15s"
    , "time"
    -- 2      3        4           5            6               7               8        9
    , "mid", "price", "up-price", "low-price", "upper-barier", "lower-barier", "trend", "trend2"
    ))

local ln = 0

for line in io.stdin:lines() do
    local success, ev = pcall(q_persist.parseLine, line)
    ln = ln + 1
    if success then
        normalize(ev)
        table.insert(window, ev)
        while #window > windowSize do
            processLine(window)
        end
    else
        io.stderr:write( string.format("Error parsing line %d, erroneous line is:\n%s\n", ln, line) )
    end
end

while #window > 0 do
    processLine(window)
end


