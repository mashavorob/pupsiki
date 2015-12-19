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
require("qlib/quik-order")
require("qlib/quik-utils")

local q_scalper = {
    etc = { -- master configuration
        asset = "RIH6",
        class = "SPBFUT",
        title = "qscalper",

        account = "SPBFUT005eC",
        firmid =  "SPBFUT589000",

        priceStepSize = 10,     -- granularity of price (minimum price shift)
        priceStepValue = 12,    -- price of price step (price of minimal price shift)
        minPrice = 0,
        maxPrice = 1e12,
        minSpread = 1,
        maxSpread = 1,

        absPositionLimit = 1,
        relPositionLimit = 0.3,
        dealCost = 6,

        avgFactor = 50,
        avgFactor2 = 1000,
        confBand = 1,
        maxLoss = 10,
        maxDeviation = 2,
        nearFuture = 10, -- forecast for 3 ticks
        farFuture = 200, -- forecast for 50 ticks

        params = {
            { name="avgFactor", min=1, max=1e32, step=1, precision=1e-4 },
            { name="avgFactor2", min=1, max=1e32, step=1, precision=1e-4 },
            { name="confBand", min=0, max=3, step=0.1, precision=1e-4 },
            { name="maxLoss", min=0, max=1e6, step=0.1, precision=1.e-4 },
            { name="trendFactor", min=0, max=1e6, step=0.1, precision=1e-4 },
        },
        schedule = {
            { from = { hour=10, min=30 }, to = { hour=21, min=00 } } 
        },
    },

    ui_mapping = {
        { name="asset", title="Бумага", ctype=QTABLE_STRING_TYPE, width=8, format="%s" },
        { name="control", title="Упавление", ctype=QTABLE_STRING_TYPE, width=12, format="%s" },
        { name="position", title="Позиция", ctype=QTABLE_DOUBLE_TYPE, width=10, format="%s" },
        { name="deviation", title="Норм. Отклонение", ctype=QTABLE_STRING_TYPE, width=20, format="%s" },
        { name="bid", title="Покупка", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        { name="offer", title="Продажа", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        { name="shortPosEnter", title="Вход в шорт", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        { name="shortPosExit", title="Выход из шорт", ctype=QTABLE_DOUBLE_TYPE, width=25, format="%.0f" },
        { name="longPosEnter", title="Вход в лонг", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        { name="longPosExit", title="Выход из лонг", ctype=QTABLE_DOUBLE_TYPE, width=25, format="%.0f" },
        { name="trend", title="Трэнд", ctype=QTABLE_STRING_TYPE, width=15, format="%s" },
        { name="spread", title="Cпред (шорт/лонг)", ctype=QTABLE_STRING_TYPE, width=20, format="%.02f" },
        { name="state", title="Состояние", ctype=QTABLE_STRING_TYPE, width=20, format="%s" },
        { name="lastError", title="Результат последняя операции", ctype=QTABLE_STRING_TYPE, width=80, format="%s" }, 
    },
}

_G["quik-scalper"] = q_scalper

local strategy = {}

function q_scalper.create(etc)

    local self = { 
        title = "scalper",
        etc = config.create(q_scalper.etc),
        ui_mapping = q_scalper.ui_mapping,
        ui_state = {
            asset = "--",
            position = 0,
            lastTrade = "--",
            bid = "--",
            offer = "--",
            futureBid = "--",
            futureOffer = "--",
            trend = "--",
            spread = "-- / --",
            status = "--",
            lastError = "--", 
        },
        state = {
            limit = 0,
            halt = false,   -- immediate stop
            pause = true,   -- temporary stop
            cancel = true,  -- closing current position

            tickCount = 0,

            bid = {
                price = false,
                dispersion = 0,
                deviation = 0,
                trend = 0,
                nearForecast = 0,
                farForecast = 0,
                order = q_order.create(etc.account, etc.class, etc.asset)
            },

            offer = {
                price = false,
                dispersion = 0,
                deviation = 0,
                trend = 0,
                nearForecast = 0,
                farForecast = 0,
                order = q_order.create(etc.account, etc.class, etc.asset)
            },
            position = 0,
            order = q_order.create(etc.account, etc.class, etc.asset)
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

    self:checkPriceBounds()
    self.etc.priceStepSize = tonumber(getParamEx(self.etc.class, self.etc.asset, "SEC_PRICE_STEP").param_value)
    self.etc.priceStepValue = tonumber(getParamEx(self.etc.class, self.etc.asset, "STEPPRICE").param_value)
    assert(self.etc.priceStepSize > 0, "priceStepSize(" .. self.etc.asset .. ") = " .. self.etc.priceStepSize)
    assert(self.etc.priceStepValue > 0, "priceStepValue(" .. self.etc.asset .. ") = " .. self.etc.priceStepValue)
    self.etc.minSpread = math.ceil(self.etc.dealCost/self.etc.priceStepValue)*self.etc.priceStepSize

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
    if self.state.pause then
        self.state.cancel = true
    end
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
    
    local alpha2 = 2/(1 + self.etc.avgFactor2)
    local trend = (price - side.price)*alpha
    side.trend = side.trend + (trend - side.trend)*alpha2
    side.nearForecast = side.price + trend*self.etc.nearFuture
    side.farForecast = side.price + trend*self.etc.farFuture

    return true
end

function strategy:onTransReply(reply)
    q_order.onTransReply(reply)
end

function strategy:onTrade(trade)
    q_order.onTrade(trade)
end

function strategy:onAllTrade(trade)
    --[[
    if trade.class_code ~= self.etc.class or trade.sec_code ~= self.etc.asset then
        return
    end
    
    if self.state.halt then
        self.ui_state.state = "Полная остановка"
        return
    end

    local l2 = getQuoteLevel2(self.etc.class, self.etc.asset)
    local quote = { price = trade.price, quantity = trade.qty}

    -- cheating
    if trade.flags % 2 == 1 then
        -- add extra offer
        table.insert(l2.offer, 1, quote)
        l2.offer_count = l2.offer_count + 1
        self.ui_state.lastTrade = "SELL at " .. tostring(trade.price)
    else
        -- add extra bid
        table.insert(l2.bid, quote)
        l2.bid_count = l2.bid_count + 1
        self.ui_state.lastTrade = "BUY  at " .. tostring(trade.price)
    end
    
    self:onQuoteOrTrade(l2)
    ]]
end

function strategy:onQuote(class, asset)
    if class ~= self.etc.class or asset ~= self.etc.asset then
        return
    end

    if self.state.halt then
        self.ui_state.state = "Полная остановка"
        return
    end

    local l2 = getQuoteLevel2(self.etc.class, self.etc.asset)
    self:onQuoteOrTrade(l2)
end

function strategy:updatePosition()
    local orders = { self.state.offer.order, self.state.bid.order, self.state.order }
    for _, order in ipairs(orders) do
        if order.position ~= 0 then
            self.state.position = self.state.position + order.position
            order.position = 0
        end
    end
end

function strategy:onIdle()
    q_order.onIdle()

    self:updatePosition()

    local state = self.state
    local ui_state = self.ui_state
    if state.cancel then
        
        ui_state.control = "Ликвидация"
        
        local active = state.order:isActive() or state.order:isPending()
        local orders = { state.offer.order, state.bid.order }
        for _, order in ipairs(orders) do
            if order:isActive() then
                active = true
                local res, err = order:kill()
                self:checkStatus(res, err)
            end
        end

        if not active then
            local res, err = true, ""
            if state.position > 0 then
                res, err = self.state.order:send("S", state.bid.nearForecast, self.state.position)
            elseif state.position < 0 then
                res, err = self.state.order:send("B", state.offer.nearForecast, -self.state.position)
            else
                -- no position no active orders
                state.cancel = false
            end
            self:checkStatus(res, err)
        end
    elseif state.pause then
        ui_state.control = "Пауза"
    elseif state.halt then
        ui_state.control = "Остановка"
    else
        ui_state.control = "Работа"
    end
end

function strategy:getMinTickCount()
    return  math.max(self.etc.avgFactor, self.etc.avgFactor2)/10
end

function strategy:onQuoteOrTrade(l2)

    local etc = self.etc
    local state = self.state
    local bidTick = self:calcSide(state.bid, self.getBidPrice, l2)
    local offerTick = self:calcSide(state.offer, self.getOfferPrice, l2)

    state.bid.nearForecast = state.bid.nearForecast + state.bid.deviation*etc.confBand 
    state.offer.nearForecast = state.offer.nearForecast - state.offer.deviation*etc.confBand

    state.bid.nearForecast = math.floor(state.bid.nearForecast/etc.priceStepSize)*etc.priceStepSize
    state.offer.nearForecast = math.ceil(state.offer.nearForecast/etc.priceStepSize)*etc.priceStepSize

    -- When position is open then it is better to use trade price as near forecast
    if state.position < 0 and state.bid.order.price then
        state.bid.nearForecast = state.bid.order.price
    elseif state.position > 0 and state.offer.order.price then
        state.offer.nearForecast = state.offer.order.price
    end

    -- forecast to exit position
    state.bid.farForecast = math.ceil(state.bid.farForecast/etc.priceStepSize)*etc.priceStepSize
    state.offer.farForecast = math.floor(state.offer.farForecast/etc.priceStepSize)*etc.priceStepSize

    local shortSpread = state.bid.nearForecast - state.offer.farForecast
    local longSpread = state.bid.farForecast - state.offer.nearForecast
    local minSpread = etc.minSpread*etc.priceStepSize/etc.priceStepValue

    self:updatePosition()

    local ui_state = self.ui_state
    ui_state.position = state.position
    ui_state.deviation = string.format("%.3f", state.bid.deviation) .. " / " .. string.format("%.3f", state.offer.deviation)
    ui_state.bid = state.bid.price
    ui_state.offer = state.offer.price
    ui_state.shortPosEnter = state.bid.nearForecast
    ui_state.shortPosExit = state.offer.farForecast
    ui_state.longPosEnter = state.offer.farForecast
    ui_state.longPosExit = state.bid.farForecast
    ui_state.trend = string.format("%.3f", state.bid.trend) .. " / " .. string.format("%.3f", state.offer.trend)
    ui_state.spread = tostring(shortSpread) .. " / " .. tostring(longSpread)
    ui_state.lastError = "--"

    -- check if there are pending orders
    if state.offer.order:isPending() then
        ui_state.state = "Заявка на покупку отправлена"
        return
    end

    if state.bid.order:isPending() then
        ui_state.state = "Заявка на продажу отправлена"
        return
    end

    if state.order:isPending() then
        ui_state.state = "Заявка на ликвидацию позиции отправлена"
        return
    end
    
    -- check if we have enough data
    state.tickCount = state.tickCount + 1
    local minCount = self:getMinTickCount()
    if state.tickCount < minCount then
        ui_state.state = "Накопление данных: " .. tostring(state.tickCount) .. " из " .. tostring(minCount)
        return
    end

    -- check if we are killing position
    if state.cancel then
        return
    end

    -- check if there are active orders
    if state.offer.order:isActive() then
        local maxDiff = 0
        if state.position ~= 0 then
            maxDiff = etc.maxLoss
            if state.offer.trend < 0 then 
                maxDiff = maxDiff + etc.maxSpread
            end
        else
            maxDiff = etc.maxDeviation
        end
        maxDiff = maxDiff*etc.priceStepSize
        local maxPrice = state.offer.order.price + maxDiff
        if state.offer.price >= maxPrice then
            ui_state.state = "Отмена покупки"
            if state.position ~= 0 then
                state.tickCount = self:getMinTickCount()*3/4
            end
            self:killPosition()
        else
            ui_state.state = "Отмена при цене выше:" .. string.format("%.0f", maxPrice)
            ui_state.state = ui_state.state .. " (" .. string.format("%.0f", state.offer.price) .. ")"
        end
        return
    end

    if state.order:isActive() then
        local maxDiff = etc.maxDeviation*etc.priceStepSize
        if math.abs((state.bid.price + state.offer.price)/2 - state.order.price) > maxDiff then
            ui_state.state = "Ликвидация: изменение цены"
            if state.position ~= 0 then
                state.tickCount = self:getMinTickCount()*3/4
            end
            state.order:kill()
            self:killPosition()
        else
            ui_state.state = "Отмена при отклонении цены на:" .. string.format("%.0f", maxDiff)
            ui_state.state = ui_state.state .. " от " .. string.format("%.0f", state.order.price)
        end
        return
    end

    if state.bid.order:isActive() then
        local maxDiff = 0
        if state.position ~= 0 then
            maxDiff = etc.maxLoss
            if state.offer.trend > 0 then 
                maxDiff = maxDiff + etc.maxSpread
            end
        else
            maxDiff = etc.maxDeviation
        end
        maxDiff = maxDiff*etc.priceStepSize
        local minPrice = state.bid.order.price - maxDiff
        if state.bid.price <= minPrice then
            ui_state.state = "Отмена продажи"
            self:killPosition()
            state.tickCount = self:getMinTickCount()*3/4
        else
            ui_state.state = "Отмена при цене ниже:" .. string.format("%.0f", minPrice)
            ui_state.state = ui_state.state .. " (" .. string.format("%.0f", state.offer.price) .. ")"
        end
        return
    end

    -- check if we are in position
    if state.position > 0 then
        -- in long position
        if not state.bid.order:isActive() then -- fix profit
            self.ui_state.status = "Закрытие лонг"
            local size = state.position
            local price = state.offer.order.price + etc.maxSpread*etc.priceStepSize
            local res, err = state.bid.order:send("S", price, size)
            self:checkStatus(res, err)
        end
        return
    elseif state.position < 0 then
        -- in short position
        if not state.offer.order:isActive() then -- fix profit
            self.ui_state.status = "Закрытие шорт"
            local size = -state.position
            local price = state.bid.order.price - etc.maxSpread*etc.priceStepSize
            local res, err = state.offer.order:send("B", price, size)
            self:checkStatus(res, err)
        end
        return
    end

    if state.pause then
        self.ui_state.state = "Временная остановка"
        return
    end
       
    local minTrend = math.min(state.bid.trend, state.offer.trend)
    local maxTrend = math.max(state.bid.trend, state.offer.trend)

    local res, err = true, ""
    if longSpread > minSpread and longSpread >= shortSpread and (minTrend > 0 or state.position >= state.limit) then -- contango
        self.ui_state.status = "Открытие лонг"
        state.limit = self:getLimit()
        res, err = state.offer.order:send("B", state.offer.nearForecast - etc.priceStepSize, state.limit)
    elseif shortSpread > minSpread and shortSpread > longSpread and (maxTrend < 0 or state.position <= -state.limit) then -- backwardation
        state.limit = self:getLimit()
        self.ui_state.status = "Открытие шорт"
        res, err = state.bid.order:send("S", state.bid.nearForecast + etc.priceStepSize, state.limit)
    end
    if not self:checkStatus(res, err) then
        return
    end

    self.ui_state.state = "Мониторинг"
end

function strategy:onDisconnected()
    q_order.onDisconnected()
end

function strategy:checkStatus(status, err)
    if not status then
        self.ui_state.lastError = self.ui_state.status .. ": Ошибка: " .. err
        self.ui_state.status = "Приостановка (" .. self.ui_state.status .. ")"
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
        assert(false, "Unknown order has been killed")
    end
    return true 
end

function strategy:checkPriceBounds()
    self.etc.minPrice = tonumber(getParamEx(self.etc.class, self.etc.asset, "PRICEMIN").param_value)
    self.etc.maxPrice = tonumber(getParamEx(self.etc.class, self.etc.asset, "PRICEMAX").param_value)
    assert(self.etc.minPrice > 0, "minprice(" .. self.etc.asset .. ") = " .. self.etc.minPrice)
    assert(self.etc.maxPrice > 0, "maxPrice(" .. self.etc.asset .. ") = " .. self.etc.maxPrice)
end

function strategy:killPosition()
    self.state.cancel = true
end
