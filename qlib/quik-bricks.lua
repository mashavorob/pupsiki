--[[
#
# ��������� ����������
#
# vi: ft=lua:fenc=cp1251 
#
# ���� �� ������ ��������� ��� ������ �� ��� ���������
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

function MovingAverage:onValue(val, now)
    if not val then
        return
    end
    if not self.val then
        self.time = now
        self.val = val
        self.ma_val = val
        self.count = 0
        self.acc = { val = val, count = 1, prev = val }

        return true
    end

    if self.time + self.period <= now then
        local avg = self.acc.val/self.acc.count
        self.ma_val = self.ma_val + self.k*(avg - self.ma_val)
        self.val = self.ma_val
        self.time = self.time + self.period
        self.count = self.acc.count
        self.acc.val = self.acc.prev
        self.acc.count = 1
        return true
    end
    
    if not self.acc.prev or val ~= self.acc.prev then
        self.acc.val = self.acc.val + val
        self.acc.count = self.acc.count + 1
        --self.val = self.ma_val + self.k*(self.acc.val/self.count.val - self.ma_val)
        self.acc.prev = val
    end
    return false
end

function MovingAverage.create(averageFactor, period)
    local self = { val = nil
                 , count = 0 
                 , k = 1/(averageFactor + 1)
                 , period = period
                 , acc = { val = 0, count = 0, prev = nil }
                 }

    setmetatable(self, {__index = MovingAverage})
    return self
end

local Trend = {}

function Trend:onValue(val, now, quant)

    if not val then
        return
    end
    if not self.trend then
        self.values:reset(val)
        self.times:reset(now)
        self.trend = 0
    else
        if quant then
            self.values:push_back(val)
            self.times:push_back(now)
        end
        
        local t0 = self.times:getAt(self.times.size)
        local period = now - t0
        if period > 0 then
            --local f0, f1, f2 = self.values:getAt(self.values.size), self.values:getAt(math.floor(self.values.size/2)), val
            --self.trend = (f0-4*f1+3*f2)/period
            local f0, f1 = self.values:getAt(self.values.size), val
            self.trend = (f1 - f0)/period
        else
            self.trend = 0
        end
    end
end

function Trend.create(size)
    local self = { values = q_cbuffer.create(size)
                 , times = q_cbuffer.create(size)
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

    if trend < -self.sensitivity then
        alpha = -1
    elseif trend > self.sensitivity then
        alpha = 1
    end

    self.alpha = alpha
end

function AlphaByTrend.create(sensitivity)
    local self = { sensitivity = sensitivity or AlphaByTrend.epsilon
                 , alpha = 0
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
        local fair_price = (self.ma_bid.ma_val + self.ma_ask.ma_val)/2
        fair_bid = fair_price
        fair_ask = fair_ask
    else
        fair_bid = self.ma_bid.ma_val + self.spread
        fair_ask = self.ma_ask.ma_val - self.spread
    end

    if alpha > self.alpha and ask > fair_ask then
        alpha = self.alpha
    elseif alpha < self.alpha and bid < fair_bid then
        alpha = self.alpha
    end
    self.alpha = alpha
    return alpha
end

function AlphaFilterOpen.create(spread, ma_bid, ma_ask)
    self = { alpha = 0
           , spread = spread
           , ma_bid = ma_bid
           , ma_ask = ma_ask
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
                 }

return q_bricks
