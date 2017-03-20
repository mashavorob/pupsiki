--[[
#
# Стратегия скальпер
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]


local q_config = require("qlib/quik-etc")
local q_order = require("qlib/quik-order")
local q_utils = require("qlib/quik-utils")
local q_time = require("qlib/quik-time")
local q_base_strategy = require("qlib/quik-base-strategy")

local q_triggerThreshold = 0.9

local q_scalper =
     -- master configuration
    { etc =
        -- Параметры стратегии
        { avgFactorSpot     = 1000       -- коэффициент осреднения спот
        , avgFactorSigma    = 5000       -- коэфициент осреднения волатильности
        , openThreshold     = 1          -- порог чувствительности для входа в позицию
        , stopLossThreshold = 2          -- порог чувствительности для выхода из позиции

        -- Вспомогательные параметры
        , minSpread = 10                 -- Внимание: спред береться из соотвествующего файла:
                                         --     * pupsik-scalper-si.lua,
                                         --     * pupsik-scalper-ri.lua,
                                         --     * и так далее
                                         -- расчет: стоимость открытия позиции + стоимость закрытия позиции + маржа
                                          
        , enterSpread = 0                -- отступ от края стакана для открытия позиции

        , params = 
            { { name="avgFactorSpot",  min=1, max=1e32, step=10, precision=1 }
            , { name="avgFactorSigma", min=1, max=1e32, step=10, precision=1 }
            , { name="openThreshold"
              , min=0
              , max=1e32
              , get_max = function (func) 
                    return func.stopLossThreshold
                end
              , step=0.1
              , precision=0.1
              }
            , { name="stopLossThreshold"
              , min=0
              , max=1e32
              , get_min = function (func) 
                    return func.openThreshold
                end
              , step=0.1
              , precision=0.1 
              }
            , { name="minSpread", min=-100, max=100, step=1, precision=1 }
            , { name="enterSpread", min=-100, max=100, step=1, precision=1 }
            } 
        }

        , ui_mapping =
            { { name="position", title="Позиция", ctype=QTABLE_DOUBLE_TYPE, width=12, format="%.0f" }
            , { name="targetPos", title="Рас.позиция", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" }
            , { name="spot", title="Цена", ctype=QTABLE_STRING_TYPE, width=22, format="%s" }
            , { name="trend", title="Тренд", ctype=QTABLE_STRING_TYPE, width=15, format="%s" }
            , { name="margin", title="Маржа", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.02f" }
            , { name="comission", title="Коммисия", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.02f" }
            , { name="lotsCount", title="Контракты", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" }
            , { name="balance", title="Доход/Потери", ctype=QTABLE_STRING_TYPE, width=25, format="%s" }
            , { name="state", title="Состояние", ctype=QTABLE_STRING_TYPE, width=40, format="%s" }
            , { name="lastError", title="Результат последней операции", ctype=QTABLE_STRING_TYPE, width=45, format="%s" }
        }

        , PHASE_TRADING = 4
        , PHASE_PRICE_CHANGE  = 5
    }

function q_scalper.create(etc)

    local self = q_base_strategy.create("scalper", q_scalper.etc, etc)

    self.inherited = getmetatable(q_scalper).__index

    self.ui_mapping = q_scalper.ui_mapping
    self.ui_state =
            { position = 0
            , targetPos = 0
            , spot = "--"
            , trend = "--"
            , margin = 0
            , comission = 0
            , lotsCount = 0
            , balance = "-- / --"
            , ordersLatencies = "-- / --"
            , state = "--"
            , lastError = "--" 
            }
            -- market status
    self.state.market =
            { bid = 0
            , offer = 0
            , mid = 0
            , avgMid = false
            , trend = 0
            , trend2 = 0
            , dev_2 = 0     -- deviation^2
            , deviation = 0
            , trigger = 0
            }

    self.state.targetPos = 0
    self.state.position = 0
    self.state.take_profit = { } -- multiply orders
    self.state.state = "--"

    setmetatable(self, { __index = q_scalper })

    return self
end

function q_scalper:init()
    self:Print("q_scalper:init(): self.etc.avgFactorSpot = %d", self.etc.avgFactorSpot)
    q_base_strategy.init(self)
end

function q_scalper:calcSpread(spread)
    local etc = self.etc
    local market = self.state.market
    local buyPrice, sellPrice = 0, 0
    if spread == 0 then
        buyPrice = math.floor(market.mid/etc.priceStepSize)*etc.priceStepSize
        sellPrice = math.ceil(market.mid/etc.priceStepSize)*etc.priceStepSize
    elseif spread < 0 then
        buyPrice = market.offer - (spread + 1)*etc.priceStepSize
        sellPrice = market.bid + (spread + 1)*etc.priceStepSize
    else
        buyPrice = market.bid - (spread - 1)*etc.priceStepSize
        sellPrice = market.offer + (spread - 1)*etc.priceStepSize
    end
    return buyPrice, sellPrice
end

function q_scalper:updatePosition()

    local state = self.state
    local etc = self.etc
    local market = state.market

    -- check state
    if state.cancel or state.pause or state.halt then
        self:Print("updatePosition() stop due to: state.cancel=%s state.pause=%s state.halt=%s",
            state.cancel, state.pause, state.halt)
        return
    end

    local sellPrice, buyPrice = self:calcSpread(etc.enterSpread)
    local res, err = true, "<Not Error>"

    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)

    if state.phase == q_scalper.PHASE_TRADING then
        local maxSpread = math.floor(market.deviation*etc.stopLossThreshold/etc.priceStepSize + 0.5)
        maxSpread = math.max(maxSpread, etc.minSpread)*etc.priceStepSize
        if ((state.order.operation == 'B' and market.mid < (state.order.price - maxSpread)) or
            (state.order.operation == 'S' and market.mid > (state.order.price + maxSpread))) and
            (state.order:isActive() or counters.position ~= 0) and false
        then
            state.targetPos = 0
            state.phase = q_scalper.PHASE_PRICE_CHANGE
            self:Print("Killing position because price is out of range: %s@%f - %f (%f)"
                , state.order.operation, state.order.price, market.mid, maxSpread)
        elseif state.order.operation == 'B' and state.targetPos < 0 then
            self:Print("Changing trend to backwardation")
            state.phase = q_scalper.PHASE_PRICE_CHANGE
        elseif state.order.operation == 'S' and state.targetPos > 0 then
            self:Print("Changing trend to contango")
            state.phase = q_scalper.PHASE_PRICE_CHANGE
        end
    end

    if state.phase == q_scalper.PHASE_TRADING 
        and counters.position == 0
        and not state.order:isActive()
    then
        
        -- enter position
        if state.order:isPending() then
            -- order was sent, just wait until onTransReply()
            return
        end
 
        -- unsure all taking profit orders filled
        for i,order in ipairs(state.take_profit) do
            if order:isActive() or order:isPending() then
                self:checkStatus(false, "Оверфил при фиксировании дохода")
                return
            end
        end

        if #state.take_profit > 0 then
            -- drop inactive taking profit orders
            state.take_profit = {}
        end
        local lotSize = self:getLimit(etc.absPositionLimit, etc.relPositionLimit)
        if state.targetPos > 0 then
            self:Print("Enter long at: %d@%f", lotSize, buyPrice)
            state.state = "Открытие лонг"
            res, err = state.order:send('B', buyPrice, lotSize)
            state.buyPrice = buyPrice
        elseif state.targetPos < 0 then
            self:Print("Enter short at: %d@%f", lotSize, sellPrice)
            state.state = "Открытие шорт"
            res, err = state.order:send('S', sellPrice, lotSize)
            state.sellPrice = sellPrice
        else
            --self:Print("Hold zero (1): target=%d actual=%d", state.targetPos, counters.position)
        end
    elseif state.phase == q_scalper.PHASE_TRADING
        and (counters.position ~= 0 or state.order:isActive())
    then
        -- taking profit
        local position = counters.position
        if state.order.operation == 'B' and position < 0 
            or state.order.operation == 'S' and position > 0
        then
            self:Print("Ignore taking profit: state.order.operation = %s, position = %f", state.order.operation, position)
            position = 0
        end

        local tp_balance = 0 -- take profit balance
        for i,order in ipairs(state.take_profit) do
            if order:isActive() or order:isPending() then
                if order.operation == 'B' then
                    tp_balance = tp_balance + order.balance
                else
                    tp_balance = tp_balance - order.balance
                end
            end
        end

        -- create take profit orders to neitralize bought/sold orders
        local diff = position + tp_balance

        local order = q_order.create(self.etc.account, self.etc.class, self.etc.asset)
        local spread = math.max(math.floor(etc.openThreshold*market.deviation/etc.priceStepSize + 0.5), etc.minSpread)
        spread = spread*etc.priceStepSize
        if position > 0 and diff > 0 then
            res, err = order:send('S', state.buyPrice + spread, diff)
            self:Print("fixing profit - SELL  %d@%f", diff, order.price)
        elseif position < 0 and diff < 0 then
            res, err = order:send('B', state.sellPrice - spread, -diff)
            self:Print("fixing profit - BUY  %d@%f", -diff, order.price)
        end
        if res then
            table.insert(state.take_profit, order)
        end
        state.state = "Реализация позиции"
    elseif state.phase == q_scalper.PHASE_PRICE_CHANGE then

        -- kill taking profit orders
        local activeOrders = false
        for i,order in ipairs(state.take_profit) do
            if order:isActive() then
                self:Print("Price changing - kill take profit")
                local res, err = order:kill()
                self:checkStatus(res, err)
                activeOrders = true
            elseif order:isPending() then
                self:Print("Price changing - take profit order is pending")
                activeOrders = true
            end
        end
        if state.order:isPending() then
            -- order was sent, just wait until onTransReply()
            self:Print("Price changing - order is pending")
            activeOrders = true
        end
        if state.order:isDeactivating() then
            self:Print("Price changing - order is deactivating")
            -- discard deactivating order
            local price = state.order.price
            state.order = q_order.create(self.etc.account, self.etc.class, self.etc.asset)
            state.order.price = price
        end

        -- kill old order
        if state.order:isActive() then
            activeOrders = true
            if ((state.targetPos > 0 and state.order.operation == 'S') 
                or (state.targetPos < 0 and state.order.operation == 'B'))
            then
                self:Print("Price changing - kill order")
                local res, err = state.order:kill()
                self:checkStatus(res, err)
            end
        end

        if activeOrders then
            self:Print("Price changing - active orders")
            return
        end

        if #state.take_profit > 0 then
            -- drop inactive taking profit orders
            state.take_profit = {}
        end

        local diff = state.targetPos - counters.position
        local lotSize = math.min(math.abs(diff), self:getLimit(2*etc.absPositionLimit, math.min(1, 2*etc.relPositionLimit)))
        if diff > 0 then
            self:Print("Changing to long at: %d@%f", lotSize, buyPrice)
            state.state = "Переключение в лонг"
            res, err = state.order:send('B', buyPrice, lotSize)
            state.buyPrice = buyPrice
        elseif diff < 0 then
            self:Print("Changing to short at: %d@%f", lotSize, sellPrice)
            state.state = "Переключение в шорт"
            res, err = state.order:send('S', sellPrice, lotSize)
            state.sellPrice = sellPrice
        else
            self:Print("Hold position (2): target=%d actual=%d", state.targetPos, counters.position)
        end
        state.phase = q_scalper.PHASE_TRADING
    elseif state.phase == q_scalper.PHASE_READY then
        --self:Print("Waiting for trigger:  %.02f", market.trigger)
    else
        self:Print("Something goes different: state:phase = %d", state.phase)
    end
    self:checkStatus(res, err)
end

function q_scalper:onTransReply(reply)
    self.inherited.onTransReply(self, reply)
    self:updatePosition()
end

function q_scalper:onTrade(trade)
    self.inherited.onTrade(self, trade)
    self:updatePosition()
end

function q_scalper:checkL2()
    local bid, offer, l2 = self:getQuoteLevel2()
    if not bid or not offer then
        return false
    end

    self:calcMarketParams(bid, offer, l2)
    return true
end

function q_scalper:onQuote(class, asset)
    assert(class)
    assert(asset)
    if class ~= self.etc.class or asset ~= self.etc.asset then
        return
    end

    if self:checkL2() then
        self:calcPlannedPos()
        self:updatePosition()
        --self:--onMarketShift()
    end
end

function q_scalper:onAllTrade(trade)
end

function q_scalper:onIdle(now)
    self.inherited.onIdle(self, now)

    self:updatePosition()
    --self:onMarketShift()

    local state = self.state
    local ui_state = self.ui_state
    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    
    ui_state.position = counters.position
    ui_state.targetPos = state.targetPos

    local format = self:getPriceFormat() .. " /%s"

    ui_state.spot = string.format(format, (state.market.avgMid or 0), self.formatValue(state.market.deviation))
    ui_state.trend = self.formatValue(state.market.trend2)

    ui_state.lastError = "--"
    self:Print("onIdle(): ui_state.state='%s'", ui_state.state)
end

-- function calculates market parameters
function q_scalper:calcMarketParams(bid, offer, l2)

    local etc = self.etc
    local state = self.state
    local market = state.market

    market.bid = bid
    market.offer = offer
    market.l2 = l2
    local mid = (bid + offer)/2

    local k1 = 1/(1 + etc.avgFactorSpot)
    local k2 = 1/(1 + etc.avgFactorSigma)

    market.avgMid = market.avgMid or mid
    if math.abs(market.avgMid - mid) > 1000 then
        self:Print("market.avgMid=%f, mid=%f, bid=%f, offer=%f",market.avgMid,mid, bid, offer)
        assert(false)
    end
    
    market.mid = mid
    market.avgMid = market.avgMid + k1*(market.mid - market.avgMid)
--    self:Print("average=%.2f mid=%.2f bid=%d ask=%d", market.avgMid, mid, bid, offer)
    
    local trend = market.mid - market.avgMid
    market.trend = market.trend + k1*(trend - market.trend)
    
    local trend2 = trend - market.trend
    market.trend2 = market.trend2 + k1*(trend2 - market.trend2)


    local dev_2 = trend*trend
    market.dev_2 = market.dev_2 + k2*(dev_2 - market.dev_2)
    market.deviation = math.sqrt(market.dev_2)

    market.trigger = market.trigger + k1*(1 - market.trigger)
end

-- function returns operation, price
function q_scalper:calcPlannedPos()
    local etc = self.etc
    local state = self.state
    local market = state.market
   
    local prevTargetPos = state.targetPos
    state.targetPos = 0

    local loss = state.balance.maxValue - state.balance.currValue
    if loss > etc.maxLoss then
        self.state.state = string.format( "Превышение убытка (%.0f из %0f)"
                                        , loss
                                        , etc.maxLoss
                                        )
        self:Print("calcPlannedPos(): exceed loss limit")
        return
    end

    if market.trigger <= 0.5 then
        self.state.state = string.format("Недостаточно данных (%.2f)", market.trigger)
        return
    end
    if state.phase == q_scalper.PHASE_READY then
        state.phase = q_scalper.PHASE_TRADING
        self:Print("calcPlannedPos(): trigger activated")
    end
    if state.halt or state.pause or state.cancel then
        self:Print("calcPlannedPos(): state.halt=%s state.pause=%s state.cancel=%s",
            state.halt, state.pause, state.cancel)
        return
    end

    if not self:checkSchedule() or self:isEOD() then
        return
    end

    local spread = math.floor(market.deviation*etc.openThreshold/etc.priceStepSize + 0.5)
    --[[
    self.prevSpread = self.prevSpread or etc.minSpread
    if spread < etc.minSpread then
        if self.prevSpread >= etc.minSpread then
            self:Print("calcPlannedPos(): calculated spread is too small: %d", spread)
        end
        --state.targetPos = 0
    else
        if self.prevSpread < etc.minSpread then
            self:Print("calcPlannedPos(): calculated spread is big enough: %d", spread)
        end
    end
    self.prevSpread = spread
    ]]

    if market.trend > 0 
        and market.mid <= (market.avgMid - spread) 
    then
        state.targetPos = 1
    elseif market.trend < 0 
        and market.mid >= (market.avgMid - spread) 
    then
        state.targetPos = -1
    end

    state.targetPos = state.targetPos*self:getLimit()

    if state.targetPos == 0 then
        local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
        state.targetPos = counters.position
    end
end

function q_scalper:killOrders()
    local state = self.state
    local res, err = true, ""

    if state.order:isActive() then
        res, err = state.order:kill()
    end

    for _,order in ipairs(state.take_profit) do
        if order:isActive() then
            local tp_res, tp_err = order:kill()
            if not tp_res and res then
                res, err = tp_res, tp_err
            end
        end
    end
    return res, err
end

function q_scalper:checkOrders()
    local state = self.state

    local pending = state.order:isPending()
    local active = state.order:isActive()

    for _, order in ipairs(state.take_profit) do
        pending = pending or order:isPending()
        if order:isActive() then
            active = true
        end
    end
    return pending, active
end
--[[
function q_scalper:onMarketShift()

    local etc = self.etc
    local state = self.state
    local market = state.market
    
    -- check halts and pending orders
    if self.state.halt or self.state.cancel or self.state.pause then
        self:Print("onMarketShift() exit due to halt cancel or pause")
        return
    end

    self:updatePosition()
    local pending, active = self:checkOrders()

    if pending then
        return
    end
    
    prevPos = prevPos or 0
    if state.targetPos ~= prevPos then
        self:Print("onMarketShift(): state.targetPos = %s", tostring(state.targetPos))
        prevPos = state.targetPos
    end

    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    local diff = (state.targetPos - counters.position)
    local price = state.order.price or market.mid
    local enterSpread = etc.enterSpread*etc.priceStepSize
    local sellPrice = market.offer + enterSpread
    local buyPrice = market.bid - enterSpread

    local res, err = true, ""

    if active then
        state.state = "Ожидание исполнения ордера"
        if (diff > 0 and state.order.operation == 'S') or (diff < 0 and state.order.operation == 'B') then
            res, err = self:killOrders()
            state.phase = q_scalper.PHASE_CANCEL
            state.state = "Отмена ордера из-за изменения тренда"
            self:Print("Cancel order due to trend changing")
        end
        self:checkStatus(res, err)
        -- wait while the order is canceled
        return
    elseif diff ~= 0 then
        state.take_profit = {} -- discard inactive take-profit orders
        state.state = "Отправка ордера"
        -- lot cannot be bigger
        local lotSize = math.min(math.abs(diff), self:getLimit(2*etc.absPositionLimit, 2*self.etc.relPositionLimit))
        local res, err = true, ""
        state.order = q_order.create(self.etc.account, self.etc.class, self.etc.asset)
        if diff < 0 then
            self:Print("Enter short at: %d@%f", lotSize, sellPrice)
            state.state = (state.targetPos < 0) and "Открытие шорт" or "Закрытие лонг"
            res, err = state.order:send('S', sellPrice, lotSize)
        else
            self:Print("Enter long at: %d@%f", lotSize, buyPrice)
            state.state = (state.targetPos > 0) and "Открытие лонг" or "Закрыте шорт"
            res, err = state.order:send('B', buyPrice, lotSize)
        end
        state.refPrice = market.mid
        self:checkStatus(res, err)
    else
        state.state = string.format("%.3f Удержание позиции", market.trigger)
    end
end
]]

function q_scalper:onDisconnected()
end

function q_scalper:checkStatus(status, err)
    if not status then
        self:Print("status: %s, error: %s", status, err)
        assert(false)
        assert(err, "err is nil")
        self.ui_state.lastError = "Ошибка: " .. tostring(err)
        self.ui_state.state = "Приостановка (" .. self.state.state .. ")"
        self.state.halt = true
        return false
    end    
    self.ui_state.lastError = "OK"
    return true
end

function q_scalper:killPosition()
    self:Print("killPosition()")
    assert(false)
    self.state.cancel = true
end

setmetatable(q_scalper, { __index = q_base_strategy}) 
return q_scalper
