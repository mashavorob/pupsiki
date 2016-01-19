--[[
#
# ��������
#
# vi: ft=lua:fenc=cp1251 
#
# ���� �� ������ ��������� ��� ������ �� ��� ���������
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

require("qlib/quik-etc")
require("qlib/quik-avg")
require("qlib/quik-order")
require("qlib/quik-utils")

local q_scalper = {
    etc = { -- master configuration

        -- ������� ���������, ���������� � ������
        asset = "RIH6",         -- ������
        class = "SPBFUT",       -- �����
        title = "qscalper - [RIH6]",     -- ��������� �������

        -- ��������� ����������� �������������
        account = "SPBFUT005eC",
        firmid =  "SPBFUT589000",

        priceStepSize = 10,     -- granularity of price (minimum price shift)
        priceStepValue = 12,    -- price of price step (price of minimal price shift)
        minSpread = 1,          -- ����������� �����
        maxSpread = 2,          -- ������������ �����

        -- ��������� ���������� �������
        absPositionLimit = 3,   -- ������������ ���������� ������� (���������� �����������)
        relPositionLimit = 0.5, -- ������������ ���������� ������� �� ��������� � ������� �����

        maxLoss = 3000,          -- ������������ ���������� ������

        avgFactorFast = 70,     -- "�������" ����������� ����������
        avgFactorSlow = 300,    -- "���������" ���������� ����������
        avgFactorLot = 200,     -- ����������� ���������� ������� ���� (������)

        maxImbalance = 5,       -- ����������� ���������� ��������� ������� ������ ������
        maxAverageLots = 40,    -- ������� ������� �� ����� ����� ���������� ������� �����
                                -- �� ���� ������� (������� ������ ������ = ������� ���)

        nearForecast = 12,      -- ������� ���� (�������� ������)
        farForecast = 75,       -- ������� ���� (�������� ������)

        dealCost = 2,           -- �������� ����
        enterErrorThreshold = 1,-- ���������� ������ �� ����� (����� ����)
        
        confBandSlow = 0.5,     -- "������������� ��������" (���/���� ����, � �������������������� �����������)
        confBandFast = 0.7,     -- "������������� ��������" (����. ���������� �� ������� ���� � �������������������� �����������) 
        trendThreshold = 0.5,   -- ���������� �������� ������ ����� ������ �������� ��������� 
                                -- ���� ��� �������� ��� ����������� ������� ���������
                                -- ��������� �������� �������� � ����������� ����������� ������
                                --
        params = {
            { name="avgFactorFast", min=1, max=1e32, step=1, precision=1e-4 },
            { name="avgFactorSlow", min=1, max=1e32, step=1, precision=1e-4 },
        },
        -- ���������� ������
        schedule = {
            { from = { hour=10, min=01, sec=00 }, to = { hour=12, min=55, sec=00 } }, -- 10:01 - 12:55
            { from = { hour=13, min=05, sec=00 }, to = { hour=13, min=55, sec=00 } }, -- 13:01 - 13:55
            { from = { hour=14, min=16, sec=00 }, to = { hour=15, min=45, sec=00 } }, -- 14:16 - 15:45
            { from = { hour=16, min=01, sec=00 }, to = { hour=18, min=55, sec=00 } }, -- 16:01 - 18:55
            { from = { hour=19, min=01, sec=00 }, to = { hour=21, min=55, sec=00 } }, -- 19:01 - 21:55
        },
    },

    ui_mapping = {
        { name="position", title="�������", ctype=QTABLE_DOUBLE_TYPE, width=10, format="%.0f" },
        { name="trend", title="�����", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.3f" },
        { name="spread", title="C����", ctype=QTABLE_STRING_TYPE, width=22, format="%s" },
        { name="minmax", title="���/���� ����", ctype=QTABLE_STRING_TYPE, width=25, format="%s" },
        { name="volume", title="�����: �������/�������/�����", ctype=QTABLE_STRING_TYPE, width=35, format="%s" },
        { name="balance", title="�����/������", ctype=QTABLE_STRING_TYPE, width=25, format="%s" },
        { name="state", title="���������", ctype=QTABLE_STRING_TYPE, width=60, format="%s" },
        { name="lastError", title="��������� ��������� ��������", ctype=QTABLE_STRING_TYPE, width=80, format="%s" }, 
    },
}

_G["quik-scalper"] = q_scalper

local strategy = {}

local PHASE_INIT            = 1
local PHASE_WAIT            = 2
local PHASE_HOLD            = 3
local PHASE_CLOSE           = 4
local PHASE_PRICE_CHANGE    = 5
local PHASE_CANCEL          = 6

local HISTORY_TO_ANALYSE    = 30000
local MIN_HISTORY           = 1000

function q_scalper.create(etc)

    local self = { 
        title = "scalper",
        etc = config.create(q_scalper.etc),
        ui_mapping = q_scalper.ui_mapping,
        ui_state = {
            position = 0,
            trend = "--",
            spread = "-- / -- (--)",
            minmax = "-- / --",
            volume = "-- / -- / -- (--)",
            balance = "-- / --",
            state = "--",
            lastError = "--", 
        },
        state = {
            halt = false,   -- immediate stop
            pause = true,   -- temporary stop
            cancel = true,  -- closing current position

            phase = PHASE_INIT,

            position = 0,

            -- profit/loss
            balance = {
                atStart = 0,
                maxValue = 0,
                currValue = 0,
            },

            -- market status
            market = {
                bid = 0,
                offer = 0,
                trend = 0,
                minPrice = 0,
                maxPrice = 0,
                fastPrice = 0,
            },

            -- planed position
            plannedPos = {
                op = false,         -- operation to enter:
                                    --   'B' - long (buy then sell)
                                    --   'S' - short (sell then buy)
                buyPrice = false,   -- price to buy
                sellPrice = false,  -- price to sell
            },
            
            fastPrice = { },
            slowPrice = { },
            lotSize = { },
            buyVolume = { },
            sellVolume = { },
            absVolume = { },
            summVolume = { },

            order = { },
            state = "--",
        },
    }

    if etc then
        self.etc.account = etc.account or self.etc.account
        self.etc.firmid = etc.firmid or self.etc.firmid
        self.etc.asset = etc.asset or self.etc.asset
        self.etc.class = etc.class or self.etc.class
        self.etc:merge(etc)
    end

    setmetatable(self, { __index = strategy })

    self.etc.limit = self:getLimit()
    self.title = string.format( "%s - [%s]"
                              , self.title
                              , self.etc.asset
                              )

    return self
end

function strategy:checkSchedule(now)
    now = now or os.time()

    local today = os.date("*t", now)
    for _,period in ipairs(self.etc.schedule) do
        period.from.year = today.year
        period.from.month = today.month
        period.from.day = today.day
        period.to.year = today.year
        period.to.month = today.month
        period.to.day = today.day
        if now >= os.time(period.from) and now <= os.time(period.to) then
            return true
        end
    end
    return false
end

function strategy:getLimit()
    local moneyLimit = q_utils.getMoneyLimit(self.etc.account)*self.etc.relPositionLimit
    local buyLimit = math.floor(moneyLimit/q_utils.getBuyDepo(self.etc.class, self.etc.asset))
    local sellLimit = math.floor(moneyLimit/q_utils.getBuyDepo(self.etc.class, self.etc.asset))
    return math.min(self.etc.absPositionLimit, math.min(buyLimit, sellLimit))
end

function strategy:getMinTickCount()
    return math.max(self.etc.avgFactorSlow, self.etc.avgFactorTrend)/4
end

function strategy:updateParams()
    self.etc.priceStepSize = tonumber(getParamEx(self.etc.class, self.etc.asset, "SEC_PRICE_STEP").param_value)
    self.etc.priceStepValue = tonumber(getParamEx(self.etc.class, self.etc.asset, "STEPPRICE").param_value)
    assert(self.etc.priceStepSize > 0, "priceStepSize(" .. self.etc.asset .. ") = " .. self.etc.priceStepSize .. "\n" .. debug.traceback())
    assert(self.etc.priceStepValue > 0, "priceStepValue(" .. self.etc.asset .. ") = " .. self.etc.priceStepValue
        .. "\n" .. debug.traceback())
    self.etc.minSpread = math.ceil(self.etc.dealCost*2/self.etc.priceStepValue)*self.etc.priceStepSize
    self.etc.maxSpread = math.max(self.etc.minSpread, self.etc.maxSpread*self.etc.priceStepSize)
end

function strategy:init()

    self.etc.account = q_utils.getAccount() or self.etc.account
    self.etc.firmid = q_utils.getFirmID() or self.etc.firmid

    local balance = q_utils.getBalance(self.etc.account)
    self.state.balance.atStart = balance
    self.state.balance.maxValue = balance
    self.state.balance.currValue = balance

    self.state.fastPrice = q_avg.createEx(self.etc.avgFactorFast, 2)
    self.state.slowPrice = q_avg.createEx(self.etc.avgFactorSlow, 1)
    self.state.lotSize = q_avg.createEx(self.etc.avgFactorLot, 0)
    self.state.sellVolume = q_avg.createEx(self.etc.avgFactorFast, 1)
    self.state.buyVolume = q_avg.createEx(self.etc.avgFactorFast, 1)
    self.state.absVolume = q_avg.createEx(self.etc.avgFactorFast, 1)
    self.state.summVolume = q_avg.createEx(self.etc.avgFactorFast, 1)

    self.state.order = q_order.create(self.etc.account, self.etc.class, self.etc.asset)

    self.state.position = q_utils.getPos(self.etc.asset)

    self:updateParams()

    -- walk through all trade
    local n = getNumberOf("all_trades")
    local first = math.max(0, n - HISTORY_TO_ANALYSE)
    assert(n > 0, "������� ���� ������ ������, ����� ����������\n")
    assert(n - first > MIN_HISTORY, "������������ ������������ ������, ����� ����������\n")
    
    self.state.lotSize:onValue(1)
    self.state.phase = PHASE_INIT

    for i = first, n - 1 do
        local trade = getItem("all_trades", i)
        local currTime = os.time(trade.datetime)
        if trade.sec_code == self.etc.asset and trade.class_code == self.etc.class --[[and self:checkSchedule(currTime)]] then
            local price = trade.price

            local l2 = { 
                bid_count = 1, 
                offer_count = 1,
                bid = { {
                    price = price,
                    quantity = 1e12,
                } },
                offer = { {
                    price = price,
                    quantity = 1e12,
                } },
            }

            if bit.band(trade.flags, 1) ~= 0 then
                -- ������ �� �������
                l2.offer[1].price = l2.offer[1].price + 2*self.etc.priceStepSize
            else
                -- ������ �� �������
                l2.bid[1].price = l2.bid[1].price - 2*self.etc.priceStepSize
            end

            local price = (l2.bid[1].price + l2.offer[1].price)/2

            self.state.fastPrice:onValue(price)
            self.state.slowPrice:onValue(price)
            self.state.lotSize:onValue(trade.qty)

            self:calcMarketParams(l2)
        end
    end
    Subscribe_Level_II_Quotes(self.etc.class, self.etc.asset)
    self.state.phase = PHASE_WAIT
    self:calcPlannedPos()
end

function strategy:updatePosition()
    local state = self.state
    state.position = state.position + state.order.position
    state.order.position = 0
end

function strategy:onStartStopCallback()
    self.state.pause = not self.state.pause
    if self.state.pause then
        self.state.cancel = true
    end
end

function strategy:onHaltCallback()
    self.state.halt = not self.state.halt
end

function strategy:onTransReply(reply)
    q_order.onTransReply(reply)
    self:updatePosition()
    self:onMarketShift()
end

function strategy:onTrade(trade)
    q_order.onTrade(trade)
end

local sellVolume = 0
local buyVolume = 0

function strategy:onAllTrade(trade)
    if trade.class_code ~= self.etc.class or trade.sec_code ~= self.etc.asset then
        return
    end
    self.state.lotSize:onValue(trade.qty)
    if bit.band(trade.flags, 1) ~= 0 then
        -- �������
        sellVolume = sellVolume + trade.qty
    else
        -- �������
        buyVolume = buyVolume + trade.qty
    end
end

local prevPrice = -1

function strategy:checkPrice()
    local l2 = self:getQuoteLevel2()
    if l2.bid_count <= 1 or l2.offer_count <= 1 then
        return
    end

    local bid = tonumber(l2.bid[l2.bid_count].price)
    local offer = tonumber(l2.offer[1].price)
    local price = (bid + offer)/2

    if price ~= prevPrice then
        prevPrice = price

        self.state.fastPrice:onValue(price)
        self.state.slowPrice:onValue(price)

        self:calcMarketParams(l2)

        self.state.sellVolume:onValue(sellVolume)
        self.state.buyVolume:onValue(buyVolume)
        self.state.absVolume:onValue(buyVolume + sellVolume)
        self.state.summVolume:onValue(buyVolume - sellVolume)
        sellVolume = 0
        buyVolume = 0
        
        return true
    end
end

function strategy:onQuote(class, asset)
    if class ~= self.etc.class or asset ~= self.etc.asset then
        return
    end

    if self:checkPrice() then
        self:updatePosition()
        self:onMarketShift()
    end
end

function strategy:onIdle()
    q_order.onIdle()
    self:updatePosition()

    if self:checkPrice() then
        self:onMarketShift()
    end

    local state = self.state
    local ui_state = self.ui_state

    -- kill position
    if state.cancel then
        ui_state.state = "����������"

        local active = state.order:isActive() or state.order:isPending()

        if state.phase ~= PHASE_CANCEL and state.order:isActive() then
            local res, err = state.order:kill()
            self:checkStatus(res, err)
        end

        if not active then
            if state.position ~= 0 and not self:checkSchedule() then
                state.state = "�������� �������: �������"
            elseif state.position > 0 then
                self.etc.minPrice = tonumber(getParamEx(self.etc.class, self.etc.asset, "PRICEMIN").param_value)
                assert(self.etc.minPrice > 0, "�������� ����������� ����: " .. self.etc.minPrice .. "\n" .. debug.traceback())
                state.phase = PHASE_CANCEL
                local res, err = state.order:send("S", self.etc.minPrice, self.state.position)
                self:checkStatus(res, err)
                return
            elseif state.position < 0 then
                self.etc.maxPrice = tonumber(getParamEx(self.etc.class, self.etc.asset, "PRICEMAX").param_value)
                assert(self.etc.maxPrice > 0, "�������� ������������ ����: " .. self.etc.maxPrice .. "\n" .. debug.traceback())
                state.phase = PHASE_CANCEL
                local res, err = state.order:send("B", self.etc.maxPrice, -self.state.position)
                self:checkStatus(res, err)
                return
            else
                state.phase = PHASE_WAIT
                state.cancel = false
            end
        end
    end

    ui_state.position = state.position
    ui_state.trend = state.fastPrice:getTrend()
    local plannedPos = state.plannedPos
    if plannedPos.buyPrice and plannedPos.sellPrice then
        ui_state.spread = string.format( "%s %.0f / %.0f (%.0f)"
                                       , plannedPos.op or 'N'
                                       , plannedPos.buyPrice
                                       , plannedPos.sellPrice
                                       , plannedPos.sellPrice - plannedPos.buyPrice
                                       )
    else
        ui_state.spread = "-- / -- (--)"
    end
    ui_state.minmax = string.format( "%.0f / %.0f"
                                   , state.market.minPrice
                                   , state.market.maxPrice
                                   )
    ui_state.volume = string.format( "%.3f / %.3f / %.3f (%.3f)"
                                   , state.buyVolume:getAverage()
                                   , state.sellVolume:getAverage()
                                   , state.absVolume:getAverage()
                                   , state.summVolume:getAverage()
                                   )
                                   
    local balance = q_utils.getBalance(self.etc.account)
    state.balance.maxValue = math.max(state.balance.maxValue, balance)
    state.balance.currValue = balance

    ui_state.balance = string.format( "%.0f / %.0f"
                                    , state.balance.currValue - state.balance.atStart
                                    , state.balance.currValue - state.balance.maxValue
                                    )

    if state.order:isPending() then
        ui_state.state = "�������� ������ (" .. state.state .. ")"
    elseif state.order:isActive() then
        ui_state.state = "�������� ���������� ������ (" .. state.state .. ")"
    elseif state.pause then
        ui_state.state = "�����"
    elseif state.halt then
        ui_state.state = "���������"
    elseif not self:checkSchedule() then
        ui_state.state = "��������� �� ����������"
    else
        ui_state.state = state.state
    end

    ui_state.lotSize = state.lotSize:getAverage()

    local plannedPos = state.plannedPos
    ui_state.lastError = "--"
end

function strategy:getQuoteLevel2()
    local l2 = getQuoteLevel2(self.etc.class, self.etc.asset)

    l2.bid_count = tonumber(l2.bid_count)
    l2.offer_count = tonumber(l2.offer_count)

    for i = 1,l2.bid_count do
        local q = l2.bid[i]
        q.price = tonumber(q.price)
        q.quantity = tonumber(q.quantity)
    end
    for i = 1,l2.offer_count do
        local q = l2.offer[i]
        q.price = tonumber(q.price)
        q.quantity = tonumber(q.quantity)
    end
    return l2
end

function strategy:calcOfferDemand(l2)
    l2 = l2 or self:getQuoteLevel2()
    local demand, offer = 0, 0
    for i = 0, math.min(5, l2.bid_count) - 1 do
        local q = l2.bid[l2.bid_count - i]
        demand = demand + q.quantity
    end
    for i = 1, math.min(5, l2.offer_count) do
        local q = l2.offer[i]
        offer = offer + q.quantity
    end
    return offer, demand
end

function strategy:calcMinBidMaxOffer(l2)
    l2 = l2 or self:getQuoteLevel2()

    local maxVolume = self.state.lotSize.average*self.etc.maxAverageLots

    local demand = 0
    local minBid = l2.bid[l2.bid_count].price + self.etc.priceStepSize
    for i = 0, #l2.bid - 1 do
        local q = l2.bid[l2.bid_count - i]
        if demand + q.quantity > maxVolume then
            break
        end
        demand = demand + q.quantity
        minBid = q.price
    end
    local offer, maxOffer = 0, l2.offer[1].price - self.etc.priceStepSize
    for i = 1, l2.offer_count do
        local q = l2.offer[i]
        if offer + q.quantity > maxVolume then
            break
        end
        offer = offer + q.quantity
        maxOffer = q.price
    end
    return minBid, maxOffer
end

-- function calculates market parameters
function strategy:calcMarketParams(l2)

    local etc = self.etc
    local state = self.state
    local market = state.market

    market.bid = l2.bid[l2.bid_count].price
    market.offer = l2.offer[1].price

    local slowDeviation = state.slowPrice:getDeviation()
    local slowPrice = state.slowPrice:getAverage()
    local bandShift = slowDeviation*(1 - etc.confBandSlow)
    local trendThreshold = etc.trendThreshold*state.fastPrice:getTrendDeviation()

    market.trend = state.fastPrice:getTrend()
    market.trend2 = state.fastPrice:getTrend2()

    market.maxPrice = slowPrice + slowDeviation
    market.minPrice = slowPrice - slowDeviation
    if market.trend > trendThreshold then
        market.minPrice = market.minPrice + bandShift 
    --    market.maxPrice = market.maxPrice + bandShift 
    elseif market.trend < -trendThreshold then
        market.maxPrice = market.maxPrice - bandShift
      --  market.minPrice = market.minPrice - bandShift
    end
    market.maxPrice = math.floor(market.maxPrice/etc.priceStepSize)*etc.priceStepSize
    market.minPrice = math.ceil(market.minPrice/etc.priceStepSize)*etc.priceStepSize

    market.fastPrice = state.fastPrice:getAverage()
end

-- function returns operation, price
function strategy:calcPlannedPos()

    local etc = self.etc
    local state = self.state
    local market = state.market
    local offerVol, demandVol = self:calcOfferDemand(l2)
    local confBand = state.fastPrice:getDeviation()*etc.confBandFast
    local maxBand = state.fastPrice:getDeviation()
    local mean = (market.bid + market.offer)/2

    local loss = state.balance.maxValue - state.balance.currValue
    if loss > etc.maxLoss then
        self.state.state = string.format( "���������� ������ (%.0f �� %0f)"
                                           , loss
                                           , etc.maxLoss
                                           )
        state.plannedPos.op = false
        return
    end

    local nearShift = market.trend*etc.nearForecast + market.trend2*math.pow(etc.nearForecast, 2)/2
    local farShift = market.trend*etc.farForecast + market.trend2*math.pow(etc.farForecast, 2)/2
    local trendThreshold = state.fastPrice:getDeviation(1)*etc.trendThreshold
    if market.trend >= 0 then
        local basePrice = math.min(mean, market.fastPrice)
        local nearPrice = math.floor((basePrice + nearShift)/etc.priceStepSize)*etc.priceStepSize
        local farPrice = math.ceil((basePrice + farShift)/etc.priceStepSize)*etc.priceStepSize
        farPrice = math.min(farPrice, nearPrice + etc.maxSpread)
        farPrice = math.min(farPrice, market.maxPrice)
        state.plannedPos = { op = 'B', buyPrice = nearPrice, sellPrice = farPrice }
    else
        local basePrice = math.max(mean, market.fastPrice)
        local nearPrice = math.ceil((basePrice + nearShift)/etc.priceStepSize)*etc.priceStepSize
        local farPrice = math.ceil((basePrice + farShift)/etc.priceStepSize)*etc.priceStepSize
        farPrice = math.max(farPrice, nearPrice - etc.maxSpread)
        farPrice = math.max(farPrice, market.minPrice)
        state.plannedPos = { op = 'S', buyPrice = farPrice, sellPrice = nearPrice }
    end

    if state.plannedPos.op then
        local spread = state.plannedPos.sellPrice - state.plannedPos.buyPrice
        local profit = spread/etc.priceStepSize*etc.priceStepValue - etc.dealCost*2
        if (profit <= 0) or (spread < etc.minSpread) then
            self.state.state = "����������"
            -- spread is not good enough to make profit 
            state.plannedPos.op = false
        elseif math.abs(market.trend) < trendThreshold then
            self.state.state = "�� ���������� �����"
            state.plannedPos.op = false
        end
    end

    if market.trend >= 0 and offerVol/demandVol >= etc.maxImbalance then
        self.state.state = "��������������� ���������"
        state.plannedPos.op = false
    elseif market.trend < 0 and demandVol/offerVol >= etc.maxImbalance then
        self.state.state = "��������������� ���������"
        state.plannedPos.op = false
    end
    
    if not self:checkSchedule() then
        state.plannedPos.op = false
        self.state.state = "�������"
    end
end

function strategy:onMarketShift()

    local etc = self.etc
    local state = self.state
    local market = state.market
    
    -- pre update phases
    if state.phase == PHASE_HOLD and not state.order:isActive() then
        state.phase = PHASE_CLOSE
    end

    if state.phase >= PHASE_CLOSE and
       not state.order:isPending() and
       not state.order:isActive() and
       state.position == 0 
    then
        state.phase = PHASE_WAIT
    end
    
    if state.phase == PHASE_WAIT and state.position ~= 0 and not state.order:isActive() then
        state.phase = PHASE_CLOSE
    end

    -- check halts and pending orders
    if self.state.halt or self.state.cancel or self.state.pause or state.order:isPending() then
        return
    end

    if state.phase == PHASE_WAIT then

        -- calculate enter price and operation
        self:calcPlannedPos()

        if state.order:isActive() then
            local maxError = etc.enterErrorThreshold*etc.priceStepValue
            local enterPrice = state.plannedPos.op == 'B' and state.plannedPos.buyPrice or state.plannedPos.sellPrice
                
            if not state.plannedPos.op or 
                state.order.operation ~= state.plannedPos.op or 
                math.abs(enterPrice - state.order.price) >= maxError
                or state.position ~= 0 and ( 
                    state.order.operation == 'B' and (market.offer > state.order.price + etc.priceStepSize) or
                    state.order.operation == 'S' and (market.bid < state.order.price - etc.priceStepSize)
                )
            then
                state.phase = PHASE_HOLD
                self.state.state = "��������� ���� �����"
                local res, err = state.order:kill()
                self:checkStatus(res, err)
                return
            end
        elseif state.plannedPos.op then
            local price, res, err = false, true, ""
            
            if state.plannedPos.op == 'B' then
                self.state.state = "�������� ����"
                res, err = state.order:send('B', state.plannedPos.buyPrice, self:getLimit())
            elseif state.plannedPos.op == 'S' then
                self.state.state = "�������� ����"
                res, err = state.order:send('S', state.plannedPos.sellPrice, self:getLimit())
            else
                res, err = false, "������������� ������������ ��������: " .. state.plannedPos.op .. 
                  string.format("(�������: %.0f, �������: %.0f)", state.plannedPos.buyPrice, state.plannedPos.sellPrice)
            end
            self:checkStatus(res, err)
        end
    elseif state.phase == PHASE_CLOSE then
        if state.order:isActive() then
            local kill = false
            if state.order.operation == 'B' then
                if state.order.price < market.minPrice then
                    kill = true
                end
            elseif state.order.operation == 'S' then
                if state.order.price > market.maxPrice then
                    kill = true
                end
            end
            if kill then
                self.state.state = "��������� ����"
                local res, err = state.order:kill()
                self:checkStatus(res, err)
                state.phase = PHASE_PRICE_CHANGE
            end
        elseif state.position > 0 then
            local price = state.order.price + market.trend*etc.farForecast + market.trend2*math.pow(etc.farForecast, 2)/2 
            if state.order.price + etc.minSpread < market.offer then
                price = math.max(state.order.price + etc.minSpread, market.offer - etc.priceStepSize)
            else
                price = math.floor(price/etc.priceStepSize)*etc.priceStepSize
                price = math.max(price, state.order.price + etc.minSpread)
            end
            price = math.min(price, state.order.price + etc.maxSpread)
            price = math.min(price, market.maxPrice)
            self.state.state = "�������� �������"
            local res, err = state.order:send('S', price, state.position)
            self:checkStatus(res, err)
        else -- position is strictly negative
            local price = state.order.price + market.trend*etc.farForecast + market.trend2*math.pow(etc.farForecast, 2)/2 
            if state.order.price - etc.minSpread > market.bid then
                price = math.min(state.order.price - etc.minSpread, market.bid + etc.priceStepSize)
            else
                price = math.ceil(price/etc.priceStepSize)*etc.priceStepSize
                price = math.min(price, state.order.price - etc.minSpread)
            end
            price = math.max(price, state.order.price - etc.maxSpread)
            price = math.max(price, market.minPrice)
            self.state.state = "�������� �������"
            local res, err = state.order:send('B', price, -state.position)
            self:checkStatus(res, err)
        end
    elseif state.phase == PHASE_PRICE_CHANGE then
        if state.order:isActive() then
            local maxPrice = market.offer + state.fastPrice:getDeviation()/2
            local minPrice = market.bid - state.fastPrice:getDeviation()/2
            local kill = false
            if state.order.operation == 'B' then
                if state.order.price < minPrice then
                    kill = true
                end
            elseif state.order.operation == 'S' then
                if state.order.price > maxPrice then
                    kill = true
                end
            end
            if kill then
                self.state.state = "��������� ����"
                local res, err = state.order:kill()
                self:checkStatus(res, err)
            end
        else
            local res, err = true, ""
            if state.position > 0 then
                res, err = state.order:send('S', market.bid, state.position)
            elseif state.position < 0 then
                res, err = state.order:send('B', market.offer, -state.position)
            end
            self:checkStatus(res, err)
        end
    end
end

function strategy:onDisconnected()
    q_order.onDisconnected()
end

function strategy:checkStatus(status, err)
    if not status then
        assert(err, "err is nil\n" .. debug.traceback())
        self.state.lastError = "������: " .. err
        self.state.state = "������������ (" .. self.state.state .. ")"
        self.state.halt = true
        return false
    end    
    self.ui_state.lastError = "OK"
    return true
end

function strategy:killOrder(order)
    local res, err = order:kill()
    if not self:checkStatus(res, err) then
        return false
    end
    local newOrder = q_order.create(self.etc.account, self.etc.class, self.etc.asset)
    if order == self.state.bid.order then
        self.state.bid.order = newOrder
    elseif order == self.state.offer.order then
        self.state.offer.order = newOrder
    elseif order == self.state.order then
        self.state.order = newOrder
    else
        assert(false, "Unknown order has been killed\n" .. debug.traceback())
    end
    return true 
end

function strategy:killPosition()
    self.state.cancel = true
end
