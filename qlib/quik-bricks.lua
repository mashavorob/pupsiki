--[[
#
# Коллекция алгоритмов
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_cbuffer = assert(require("qlib/quik-cbuffer"))

local PriceTracker = {}

function PriceTracker:onQuote(l2)
    local bid = l2.bid or {}
    local ask = l2.offer or {}

    local bid_price = (#bid > 0) and tonumber(bid[#bid].price)
    local ask_price = (#ask > 0) and tonumber(ask[1].price)

    self.bid = bid_price or self.bid
    self.ask = ask_price or self.ask

    if self.bid and self.ask then
        self.mid = (self.bid + self.ask)/2
    end
end

function PriceTracker.create()
    self = { bid = nil
           , ask = nil
           , mid = nil
           }
    setmetatable(self, {__index = PriceTracker})
    return self
end

local MovingAverage = {}

function MovingAverage:onValue(val)
    if not val then
        return
    end
    if self.val then
        self.val = self.val + self.k*(val - self.val)
    else
        self.val = val
    end
end

function MovingAverage.create(averageFactor)
    local self = { val = nil
                 , k = 1/(averageFactor + 1)
                 }

    setmetatable(self, {__index = MovingAverage})
    return self
end

local Trend = {}

function Trend:onValue(val)

    if not val then
        return
    end
    if not self.trend then
        self.values:reset(val)
        self.trend = 0
    else
        self.values:push_back(val)
        --local f0, f1, f2 = self.values:getAt(self.values.size), self.values:getAt(math.floor(self.values.size/2)), self.values:getAt(1)
        --self.trend = (f0-4*f1+3*f2)/self.values.size
        local f0, f1 = self.values:getAt(self.values.size), self.values:getAt(1)
        self.trend = (f1 - f0)/self.values.size
    end
end

function Trend.create(size)
    local self = { values = q_cbuffer.create(size)
                 , trend = nil
                 }
    setmetatable(self, {__index = Trend})
    return self
end

local AlphaSimple = { alpha=0 }

function AlphaSimple:onValue(trend)
    if trend == 0 then
        return
    end

    self.trend = self.trend or trend
    if self.trend*trend < 0 then
        self.alpha = (trend > 0) and 1 or -1
    end
    self.trend = trend
    return self.alpha
end

function AlphaSimple.create()
    local self = {}
    setmetatable(self, {__index=AlphaSimple})
    return self
end

local AlphaByTrend = { epsilon = 1e-9
                      , saturation = 1e9
                      , alpha = 0
                      }

function AlphaByTrend:onValue(trend_1, trend_2)
    if trend_1 > self.saturation and trend_2 > self.sensitivity then
        self.alpha = 1
    elseif trend_1 < -self.saturation and trend_2 < -self.sensitivity then
        self.alpha = -1
    elseif trend_1 > self.saturation and trend_2 < -self.sensitivity and self.alpha > 0 then
        self.alpha = 0 ---1
    elseif trend_1 < -self.saturation and trend_2 > self.sensitivity and self.alpha < 0 then
        self.alpha = 0 --1
    end
end

function AlphaByTrend.create(saturation, sensitivity)
    local self = { saturation = saturation or AlphaByTrend.saturation
                 , sensitivity = sensitivity or AlphaByTrend.epsilon
                 , alpha2 = 0
                 , alpha = 0
                 }
    setmetatable(self, {__index = AlphaByTrend})
    return self
end

local q_bricks = { PriceTracker = PriceTracker
                 , MovingAverage = MovingAverage
                 , Trend = Trend
                 , AlphaSimple = AlphaSimple
                 , AlphaByTrend = AlphaByTrend
                 }

return q_bricks

