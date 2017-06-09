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

    local new_bid = (not self.bid and bid_price) or (bid_price and self.bid ~= bid_price)
    local new_ask = (not self.ask and ask_price) or (ask_price and self.ask ~= ask_price)
    local new_mid = new_bid or new_ask and (self.bid and self.ask)

    self.bid = bid_price or self.bid
    self.ask = ask_price or self.ask

    if self.bid and self.ask then
        self.mid = (self.bid + self.ask)/2
    end
    return new_bid, new_ask, new_mid
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

function MovingAverage:onValue(val, now)
    assert(val)
    if not self.ma_val then
        self.ma_val = val
        self.val = val
        return true
    end

    self.ma_val = self.ma_val + self.k*(val - self.ma_val)
    return true
end

function MovingAverage.create(averageFactor, period)
    local self = { ma_val = nil
                 , k = 1/(averageFactor + 1)
                 }

    setmetatable(self, {__index = MovingAverage})
    return self
end

local VolumeCounter = {}

function VolumeCounter:onTime(now)
    if not self.time then
        self.time = now
        return false
    end
    if now > self.time + self.period then
        local buy = self.buy.val/self.period
        self.ma_abs_buy = self.ma_abs_buy + self.k*(buy - self.ma_abs_buy)
        self.buy.val = 0
        self.buy.count = 0
        
        local sell = self.sell.val/self.period
        self.ma_abs_sell = self.ma_abs_sell + self.k*(sell - self.ma_abs_sell)
        self.sell.val = 0
        self.sell.count = 0

        local volume = buy - sell
        self.ma_abs_volume = self.ma_abs_volume + self.k*(volume - self.ma_abs_volume)

        self.ma_buy = self.ma_abs_buy/self.ma_abs_volume
        self.ma_sell = self.ma_abs_sell/self.ma_abs_volume
        self.ma_volume = self.ma_buy + self.ma_sell

        self.time = self.time + self.period
        self.count = self.buy.count + self.sell.count
        
        return true
    end
    return false
end

function VolumeCounter:onAllTrade(trade)
    local sign = ((trade.flags % 2) ~= 0) and -1 or 1

    if (trade.flags % 2) == 0 then
        self.buy.val = self.buy.val + trade.qty
        self.buy.count = self.buy.count + 1
    else
        self.sell.val = self.sell.val - trade.qty
        self.sell.count = self.sell.count + 1
    end

    return false
end

function VolumeCounter.create(averageFactor, period)
    local self = { k = 1/(averageFactor + 1)
                 , period = period
                 , buy = { val = 0, count = 0 }
                 , sell = { val = 0, count = 0 }
                 , ma_abs_buy = 0
                 , ma_buy = 0
                 , ma_abs_sell = 0
                 , ma_sell = 0
                 , ma_abs_volume = 0
                 , ma_volume = 0
                 , ma_count = 0
                 }
    setmetatable(self, {__index = VolumeCounter})
    return self
end

local Trend = {}

function Trend:onValue(val)

    assert(val)
    if not self.trend then
        self.values:reset(val)
        self.trend = 0
    else
        self.values:push_back(val)
        --local f0, f1, f2 = self.values:getAt(self.values.size), self.values:getAt(math.floor(self.values.size/2)), val
        --self.trend = (f0-4*f1+3*f2)/self.values.size
        local f0, f1 = self.values:getAt(self.values.size), val
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

local AlphaByTrend = { epsilon = 1e-9
                     , alpha = 0
                     }

function AlphaByTrend:onValue(trend)
    local alpha = self.alpha or 0

    local signal = self.signal and self.signal.alpha
    signal = signal or 0
    local sensitivity = (signal > -self.epsilon and signal < self.epsilon) and self.sensitivity1 or self.sensitivity2

    if trend < -sensitivity then
        alpha = -1
    elseif trend > sensitivity then
        alpha = 1
    end

    self.alpha = alpha
end

function AlphaByTrend.create(signal, sensitivity1, sensitivity2)
    sensitivity1 = sensitivity1 or AlphaByTrend.epsilon
    sensitivity2 = sensitivity2 or sensitivity1
    local self = { sensitivity1 = sensitivity1
                 , sensitivity2 = sensitivity2
                 , alpha = 0
                 , signal = signal
                 }
    setmetatable(self, {__index = AlphaByTrend})
    return self
end

local AlphaAgg = {}

function AlphaAgg:aggregate(bid_alpha, ask_alpha)
    local alpha = self.alpha or 0
    if bid_alpha > 0 and ask_alpha >= 0 then
        alpha = 1
    elseif ask_alpha < 0 and bid_alpha <= 0 then
        alpha = -1
    elseif bid_alpha > 0 and ask_alpha < 0 then
        alpha = 0
    end
    self.alpha = alpha
    return alpha
end

function AlphaAgg.create()
    local self = { alpha = 0 }
    setmetatable(self, {__index = AlphaAgg})
    return self
end

local AlphaFilterOpen = {}

function AlphaFilterOpen:filter(alpha, bid, ask)
    self.alpha = self.alpha or 0
    if self.alpha == alpha then
        return alpha
    end

    local fair_bid, fair_ask = bid, ask
    if self.spread == 0 then
        fair_bid = self.ma.ma_val
        fair_ask = self.ma.ma_val
    else
        fair_bid = self.ma.ma_val + self.spread
        fair_ask = self.ma.ma_val - self.spread
    end

    if alpha > self.alpha and ask > fair_ask then
        alpha = self.alpha
    elseif alpha < self.alpha and bid < fair_bid then
        alpha = self.alpha
    end
    self.alpha = alpha
    return alpha
end

function AlphaFilterOpen.create(spread, ma)
    self = { alpha = 0
           , spread = spread
           , ma = ma
           }
    setmetatable(self, {__index = AlphaFilterOpen})
    return self
end

local AlphaFilterFix = {}

function AlphaFilterFix:filter(alpha, bid, ask)
    
    self.open_alpha = self.open_alpha or 0
    self.alpha = self.alpha or 0

    if alpha ~= self.open_alpha then
        if alpha < 0 then
            self.open_price = bid
        elseif alpha > 0 then
            self.open_price = ask
        else
            self.open_price = nil
        end
        self.open_alpha = alpha
        self.alpha = alpha
    elseif self.alpha > 0 then
        assert(alpha > 0)
        if bid >= self.open_price + self.spread then
            self.alpha = 0
            alpha = 0
        end
    elseif self.alpha < 0 then
        assert(alpha < 0)
        if ask <= self.open_price - self.spread then
            self.alpha = 0
            alpha = 0
        end
    else
        alpha = 0
    end
    return alpha
end

function AlphaFilterFix.create(spread)
    local self = { open_alpha = 0
                 , alpha = 0
                 , spread = spread
                 }
    setmetatable(self, {__index = AlphaFilterFix})
    return self
end

local q_bricks = { PriceTracker = PriceTracker
                 , MovingAverage = MovingAverage
                 , Trend = Trend
                 , AlphaByTrend = AlphaByTrend
                 , AlphaAgg = AlphaAgg
                 , AlphaFilterOpen = AlphaFilterOpen
                 , AlphaFilterFix = AlphaFilterFix
                 , VolumeCounter = VolumeCounter
                 }

return q_bricks

