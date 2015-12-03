--[[
#
# Скальпер
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

require("qlib/quik-etc")
require("qlib/quik-utils")

local q_scalper = {
    etc = { -- master configuration
        asset = "RIZ5",
        class = "SPBFUT",
        title = "qscalper",

        account = "SPBFUT005B2",
        firmid =  "SPBFUT589000",

        priceStepSize = 10,     -- granularity of price (minimum price shift)
        priceStepValue = 12,    -- price of price step (price of minimal price shift)
        minPrice = 0,
        maxPrice = 1e12,
        minSpread = 1,

        absPositionLimit = 5,
        relPositionLimit = 0.3,
        dealCost = 6,

        avgFactor = 20,
        confBand = 0.7,
        maxDeviation = 2,
        trendFactor = 1,

        params = {
            { name="avgFactor", min=1, max=1e32, step=1, precision=1e-4 },
            { name="confBand", min=0, max=3, step=0.1, precision=1e-4 },
            { name="maxDeviation", min=0, max=1e6, step=0.1, precision=1.e-4 },
            { name="trendFactor", min=0, max=1e6, step=0.1, precision=1e-4 },
        },
        schedule = {
            { from = { hour=10, min=30 }, to = { hour=21, min=00 } } 
        },
    },

    ui_mapping = {
        { name="asset", title="Бумага", ctype=QTABLE_STRING_TYPE, width=8, format="%s" },
        { name="bid", title="Покупка", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        { name="offer", title="Продажа", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        { name="trend", title="Трэнд", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.02f" },
        { name="spread", title="Cпред", ctype=QTABLE_DOUBLE_TYPE, width=10, format="%.02f" },
        { name="state", title="Состояние", ctype=QTABLE_STRING_TYPE, width=15, format="%s" },
        { name="lastError", title="Последняя операция", ctype=QTABLE_STRING_TYPE, width=32, format="%s" }, 
    },
}

_G["quik-scalper"] = q_scalper

local strategy = {}

local order = {
    asset = false,
    class = false,
    account = false,

    operation = false,

    id = false,        -- TRANS_ID
    key = false,       -- ORDER_NUM
    status = false,    -- STATUS

    balance = 0,       -- Quantity
    position = 0,      -- Generated position
}

function order.getNextTransId()
    local transId = 1
    local n = getNumberOf("orders")
    if n > 0 then
        transId = getItem("orders", n - 1).trans_id + 10
    end
    return tostring(transId)
end

function order:isPending()
    return self.id and not self.key
end

function order:isActive()
    return self.balance > 0
end

function order:kill(class, asset)
    assert(self.class and self.asset and self.key, "order has not been sent")
    if not self:isActive() then
        return true
    end
    local order = {
        TRANS_ID=self.getNextTransId(),
        CLASSCODE=self.class,
        SECCODE=self.asset,
        ACTION="KILL_ORDER",
        ORDER_KEY=tostring(orderKey),
    }
    local res =  self.sendTransaction(order)
    if res == "" then
        self.id = nil
        self.key = nil
        self.status = nil
        self.balance = 0
        return true
    end
    return false, res
end

function order:send(operation, price, size)
    assert(not self:isActive(), "The order is active")
    
    self.operation = operation

    local order = {
        TRANS_ID=self.getNextTransId(),
        ACCOUNT=self.account,
        CLASSCODE=self.class,
        SECCODE=self.asset,
        ACTION="NEW_ORDER",
        TYPE="L",
        OPERATION=self.operation,
        EXECUTE_CONDITION="PUT_IN_QUEUE",
        PRICE=tostring(price),
        QUANTITY=tostring(size),
    }
    local res = self.sendTransaction(order)
    if res == "" then
        self.id = order.TRANS_ID
        self.balance = size
        self.price = price
        self.size = size
        return true
    end
    self.size = 0
    self.balance = 0
    return false, res
end

local orderStatusSuccess = {}
-- see https://forum.quik.ru/forum10/topic604/
orderStatusSuccess[1] = true
orderStatusSuccess[3] = true -- completed
orderStatusSuccess[4] = true

function order:onTransReply(reply)
    if reply.trans_id ~= self.id then
        return
    end
    local status = tonumber(reply.status)
    self.status = { code=status, message=reply.result_msg }
    if orderStatusSuccess(status) then
        self.key = self.key or reply.order_num
        local mult = (self.operation == "B" and 1) or -1
        self.position = self.position + mult*(self.balance - reply.balance)
        -- status == 3 means the transaction has been filled and deactivated
        self.balance = (status == 3) and 0 or tonumber(reply.balance)
    else
        self.id = nil
        self.key = nil
        self.balance = 0
    end
    return true
end

function order:onTrade(trade)
end

local q_order = { }

function q_order.create(account, class, asset)
    local self = {}
    setmetatable(self, { __index = order })

    self.account = account
    self.class = class
    self.asset = asset

    return self
end

function q_scalper.create(etc)

    etc = config.create(q_scalper.etc)
    local self = { 
        title = "scalper",
        etc = etc,
        ui_mapping = q_scalper.ui_mapping,
        ui_state = {
            asset = "--",
            bid = "--",
            offer = "--",
            trend = "--",
            spread = "--",
            status = "--",
            lastError = "--", 
        },
        state = {
            limit = 0,
            halt = 0,
            pause = true,

            bid = {
                price = false,
                dispersion = 0,
                deviation = 0,
                trend = 0,
                order = q_order.create(etc.account, etc.class, etc.asset)
            },

            offer = {
                price = false,
                dispersion = 0,
                deviation = 0,
                trend = 0,
                order = q_order.create(etc.account, etc.class, etc.asset)
            },
            position = 0,
            order = q_order.create(etc.account, etc.class, etc.asset)
        },
    }

    self.etc = config.create(q_scalper.etc)
    if etc then
        self.etc.asset = etc.asset
        self.etc.class = etc.class
        self.etc:merge(etc)
    end

    self.etc.minPrice = tonumber(getParamEx(self.etc.class, self.etc.asset, "PRICEMIN").param_value)
    self.etc.maxPrice = tonumber(getParamEx(self.etc.class, self.etc.asset, "PRICEMAX").param_value)
    self.etc.priceStepSize = tonumber(getParamEx(self.etc.class, self.etc.asset, "SEC_PRICE_STEP").param_value)
    self.etc.priceStepValue = tonumber(getParamEx(self.etc.class, self.etc.asset, "STEPPRICE").param_value)
    assert(self.etc.minPrice > 0)
    assert(self.etc.maxPrice > 0)
    assert(self.etc.priceStepSize > 0)
    assert(self.etc.priceStepValue > 0)
    self.etc.minSpread = math.ceil(self.etc.dealCost/self.etc.priceStepValue)*self.etc.priceStepSize

    setmetatable(self, { __index = strategy })

    return self
end

function strategy:init()

    self.etc.account = q_utils.getAccount() or self.etc.account
    self.etc.firmid = q_utils.getFirmID() or self.etc.firmid
    self.state.limit = self:getLimit()

    self.ui_state.asset = self.etc.asset

end

function strategy:onStartStopCallback()
    self.state.pause = not self.state.pause
end

function strategy:onHaltCallback()
    self.state.halt = not self.state.halt
end


function strategy:getLimit()
    local moneyLimit = q_utils.getMoneyLimit(self.etc.account)*self.etc.relPositionLimit
    local buyLimit = math.floor(moneyLimit/q_utils.getBuyDepo(self.etc.class, self.etc.asset))
    local sellLimit = math.floor(moneyLimit/q_utils.getBuyDepo(self.etc.class, self.etc.asset))
    return math.min(self.etc.absPositionLimit, math.min(buyLimit, sellLimit))
end

function strategy:getBidPrice(l2)
    local limit = self.state.limit
    local money = 0
    for i = 0,l2.bid_count - 1 do
        local index = l2.bid_count - i
        local quote = l2.bid[index]
        local size = math.min(limit, quote.quantity)
        money = money + quote.price*size
        limit = limit - size
        if limit == 0 then
            break
        end
    end
    local size = self.state.limit - limit
    if size then
        return money/size
    end
    return q_utils.getMinPrice(self.etc.class, self.etc.asset) 
end

function strategy:getOfferPrice(l2)
    local limit = self.state.limit
    local money = 0
    for i = 1,l2.offer_count do
        local quote = l2.offer[i]
        local size = math.min(limit, quote.quantity)
        money = money + quote.price*size
        limit = limit - size
        if limit == 0 then
            break
        end
    end
    local size = self.state.limit - limit
    if size then
        return money/size
    end
    return q_utils.getMaxPrice(self.etc.class, self.etc.asset) 
end

function strategy:calcSide(side, getSidePrice, l2)
    local price = getSidePrice(self, l2)
    if price == side.price then
        return false
    end
    local alpha = 2/(1 + self.etc.avgFactor)
    side.price = side.price or price
    side.price = side.price + (price - side.price)*alpha
    side.dispersion = side.dispersion + ((price - side.price)^2 - side.dispersion)*alpha
    side.deviation = side.dispersion ^ 0.5
    
    local trend = (price - side.price)/alpha
    side.trend = side.trend + (trend - side.trend)*alpha

    return true
end

function strategy:onTrade(trade)
    if class ~= self.etc.class or asset ~= self.etc.asset then
        return
    end
    local res = self.state.bid.order:onTrade(trade) or
    self.state.offer.order:onTrade(trade) or self.state.order:onTrade(trade)
end

function strategy:onTransReply(reply)
    local res = self.state.bid.order:onTransReply(reply) or 
        self.state.offer.order:onTransReply(reply) or
        self.state.order:onTransReply(reply)
end

function strategy:onQuote(class, asset)
    if class ~= self.etc.class or asset ~= self.etc.asset then
        return
    end

    local etc = self.etc
    local state = self.state
    local l2 = getQuoteLevel2(self.etc.class, self.etc.asset)
    local bidTick = self:calcSide(state.bid, self.getBidPrice, l2)
    local offerTick = self:calcSide(state.offer, self.getOfferPrice, l2)
    local maxBid = math.floor((state.bid.price + state.bid.deviation*etc.confBand)/etc.priceStepSize)
    local minOffer = math.ceil((state.offer.price - state.offer.deviation*etc.confBand)/etc.priceStepSize)
    local spread = (maxBid - minOffer)*etc.priceStepValue - etc.minSpread

    self.ui_state.bid = state.bid.price
    self.ui_state.offer = state.offer.price
    self.ui_state.trend = (state.bid.trend + state.offer.trend)/2
    self.ui_state.spread = spread
    self.ui_state.lastError = ""

    if state.halt then
        self.ui_state.state = "Полная остановка"
    end

    if state.offer.order:isPending() or state.bid.order:isPending() then
        self.ui_state.state = "Заявки отправлены"
        return -- at least one order is pending
    end

    local isActive = false
    if state.offer.order:isActive() then
        isActive = true
        local maxDeviation = state.offer.deviation*etc.maxDeviation
        if ((state.offer.price - state.offer.order.price) > maxDeviation) or state.pause then
            self.ui_state.state = "Отмена заявок"
            state.offer.order:kill()
            self:killPosition()
        end
    elseif state.offer.order.position ~= 0 then
        state.position = state.position + state.offer.order.position
        state.offer.order.position = 0
    end

    if state.bid.order:isActive() then
        isActive = true
        local maxDeviation = state.bid.deviation*etc.maxDeviation
        if ((state.bid.order.price - state.bid.price) > maxDeviation) or state.pause then
            self.ui_state.state = "Отмена заявок"
            state.bid.order:kill()
            self:killPosition()
        end
    elseif state.bid.order.position ~= 0 then
        satte.position = state.position + state.bid.order.position
        state.bid.oreder.position = 0
    end

    if isActive or state.order:isActive() then
        return
    end
    if self.state.position ~= 0 then
        self.ui_state.state = "Закрытие позиций"
        self:killPosition()
        return
    end

    if state.pause then
        self.ui_state.state = "Временная остановка"
        return
    end

    self.ui_state.state = "Отслеживание рынка"

    if spread > 0 then
        local offset = (state.bid.trend + state.offer.trend)*etc.trendFactor/2
        state.limit = self:getLimit()
        local res, err = state.bid.order:send("S", maxBid + offset, state.limit)
        if res then
            res, err = state.offer.order:send("B",  minOffer + offset, state.limit)
            if not res then
                state.bid.order:kill()
            end
        end
        self.ui_state.lastError = err
    end
end

function strategy:killPosition()
    local res, err = true, ""
    if self.state.position > 0 then
        res, err = self.state.order:send('S', self.etc.minPrice, self.state.position)
    elseif self.state.position < 0 then
        res, err = self.state.order:send('B', self.etc.maxPrice, -self.state.position)
    else
        return
    end
    self.state.position = 0
end
