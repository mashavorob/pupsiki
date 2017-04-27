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
local q_bricks = require("qlib/quik-bricks")
local q_base_strategy = require("qlib/quik-base-strategy")

local q_triggerThreshold = 0.1

local q_scalper =
     -- master configuration
    { etc =
        -- Параметры стратегии
        { avgFactorFast     = 750       -- коэффициент осреднения быстрый
        , avgFactorSlow     = 9000      -- коэфициент осреднения медленый
        , historyLen        = 400       -- длина истории для вычисления локальных экстремумов
        , sensitivity       = 0.015     -- порог чувствительности
        , saturation        = 5         -- порог насыщения
        , enterSpread       = 0         -- отступ от края стакана для открытия позиции
        , spread            = 3         -- спред для фиксации прибыли

        , params = 
            { { name="avgFactorFast",  min=1,    max=1e7, step=10,  precision=1    }
            , { name="avgFactorSlow",  min=1,    max=1e7, step=10,  precision=1    }
            , { name="historyLen",     min=3,    max=1e7, step=10,  precision=1    }
            , { name="sensitivity"
              , min=0
              , max=1e5
              , step=0.001
              , precision=0.001
              --, get_max = function(self) return self.saturation end
              }
            , { name="saturation"
              , min=0
              , max=1e5
              , step=5
              , precision=1
              --, get_min = function(self) return self.sensitivity end
              }
            , { name="enterSpread",    min=-100, max=100, step=1,   precision=1    }
            , { name="spread",         min=1,    max=100, step=1,   precision=1    }
            } 
        }

        , ui_mapping =
            { { name="position", title="Позиция", ctype=QTABLE_DOUBLE_TYPE, width=12, format="%.0f" }
            , { name="targetPos", title="Рас.позиция", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" }
            , { name="spot", title="Цена", ctype=QTABLE_STRING_TYPE, width=22, format="%s" }
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
            , trend = 0
            , trigger = 0
            , pricer = q_bricks.PriceTracker.create()
            , ma_fast = q_bricks.MovingAverage.create(self.etc.avgFactorFast)
            , ma_slow = q_bricks.MovingAverage.create(self.etc.avgFactorSlow)
            , trend2 = q_bricks.Trend.create(self.etc.historyLen)
            , alpha = q_bricks.AlphaByTrend.create(self.etc.saturation, self.etc.sensitivity)
            }

    self.state.targetPos = 0
    self.state.position = 0
    self.state.take_profit = { } -- multiply orders
    self.state.state = "--"

    setmetatable(self, { __index = q_scalper })

    return self
end

function q_scalper:init()
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
    if not market.ma_fast.val then
        return
    end

    -- check state
    if state.cancel or state.pause or state.halt then
        self:Print("updatePosition() stop due to: state.cancel=%s state.pause=%s state.halt=%s",
            state.cancel, state.pause, state.halt)
        return
    end

    local phase = self:checkSchedule()
    if not phase then
        return
    end

    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)

    if state.order:isDeactivating() then
        state.order = q_order.create(self.etc.account, self.etc.class, self.etc.asset)
    end

    -- remove inactive take-profit orders
    local i = 1
    while i <= #state.take_profit do
        local order = state.take_profit[i]
        if order:isActive() then
            if (order.operation == 'B' and state.targetPos > 0) or
                (order.operation == 'S' and state.targetPos < 0)
            then
                self:Print("Kill take profit order trans_id=%d, order_num=%d, active=%s", order.trans_id, order.order_num, order.active)
                local res, err = order:kill()
                self:checkStatus(res, err)
            end
        elseif not order:isPending() then
            table.remove(state.take_profit, i)
            i = i - 1
        end
        i = i + 1
    end

    local pending = state.order:isPending()
    local diff = state.targetPos - counters.position
    local absLimit = 2*etc.absPositionLimit
    local relLimit = math.min(1, 2*etc.relPositionLimit)
    local lotSize = self:getLimit(absLimit, relLimit)
    assert(lotSize > 0)

    if not state.activeCount then
        state.activeCount = 0
    end

    if state.order:isActive() then
        state.activeCount = state.activeCount or 0
        state.activeCount = state.activeCount + 1
        assert(state.activeCount < 10000)
        state.waitForFairPrice = false
        state.state = "Ожидание исполнения заявки"
    elseif state.order:isPending() then
        state.state = "Отправка заявки"
    elseif not state.order:isPending() then
        lotSize = math.min(math.abs(diff), lotSize)
        local spread = (diff > 0) and -etc.enterSpread or etc.enterSpread
        local fairPrice = math.floor(market.ma_fast.val/etc.priceStepSize + 0.5 + spread)*etc.priceStepSize

        if diff > 0 and market.offer <= fairPrice then
            state.state = (state.targetPos == 0) and "Ликивидация позиции" or "Открытие длинной позиции"
            local price = market.offer + etc.priceStepSize
            self:Print("Enter long at: %d@%f bid=%.0f offer=%.0f market.mid=%.0f ma_fast.val=%.2f"
                , lotSize, price
                , market.bid
                , market.offer
                , market.mid
                , market.ma_fast.val
                )
            local res, err = state.order:send('B', price, lotSize, "KILL_BALANCE")
            self:checkStatus(res, err)
            state.buyPrice = price
            state.waitForFairPrice = false
            state.hold = false
        elseif diff < 0 and market.bid >= fairPrice then
            state.state = (state.targetPos == 0) and "Ликивидация позиции" or "Открытие короткой позиции"
            local price = market.bid - etc.priceStepSize
            self:Print("Enter short at: %d@%f bid=%.0f offer=%.0f mid=%.0f ma_fast.val=%.2f"
                , lotSize, price
                , market.bid
                , market.offer
                , market.mid
                , market.ma_fast.val
                )
            local res, err = state.order:send('S', price, lotSize, "KILL_BALANCE")
            self:checkStatus(res, err)
            state.sellPrice = price
            state.waitForFairPrice = false
            state.hold = false
        elseif diff == 0 then
            if market.trigger <= q_triggerThreshold then
                self.state.state = string.format("Недостаточно данных (%.3f)", market.trigger)
            else
                state.state = "Удержание позиции"
            end
            state.waitForFairPrice = false
            if not state.hold then
                self:Print("hold position %d", state.targetPos)
                state.hold = true
            end
        elseif diff ~= 0 then
            state.state = "Ожидание цены"
            if not state.waitForFairPrice then
                state.hold = false
                state.waitForFairPrice = true
                self:Print("waiting for fair price %s@%s", (diff > 0) and "BUY" or "SELL", q_base_strategy.formatValue(fairPrice))
            end
        end
    end
    if counters.position > 0 and state.targetPos > 0
        or counters.position < 0 and state.targetPos < 0
    then
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
        local tp_diff = counters.position + tp_balance
        if tp_diff ~= 0 then
            local order = q_order.create(self.etc.account, self.etc.class, self.etc.asset)
            local spread = etc.spread --math.max(math.floor(etc.openThreshold*market.sigma/etc.priceStepSize + 0.5), etc.minSpread)
            spread = spread*etc.priceStepSize
            local res, err = false, ""
            if counters.position > 0 and tp_diff > 0 then
                self:Print("fixing profit - SELL  %d@%f", tp_diff, state.buyPrice + spread)
                res, err = order:send('S', state.buyPrice + spread, tp_diff)
                self:checkStatus(res, err)
            elseif counters.position < 0 and tp_diff < 0 then
                self:Print("fixing profit - BUY  %d@%f", -tp_diff, state.sellPrice - spread)
                res, err = order:send('B', state.sellPrice - spread, -tp_diff)
                self:checkStatus(res, err)
            end
            if res then
                table.insert(state.take_profit, order)
            end
            state.state = "Реализация позиции"
        end
    end
end

function q_scalper:onTransReply(reply)
    self:Print("onTransReply(status=%s, result_msg='%s')", tostring(reply.status), reply.result_msg or "") 
    q_base_strategy.onTransReply(self, reply)
end

function q_scalper:onTrade(trade)
    self.inherited.onTrade(self, trade)

    local state = self.state
    if trade.trans_id == state.order.trans_id then
        if state.order.operation == 'B' then
            self:Print("onTrade(buy@%s)", q_base_strategy.formatValue(trade.price))
            state.buyPrice = trade.price
        elseif state.order.operation == 'S' then
            self:Print("onTrade(sell@%s)", q_base_strategy.formatValue(trade.price))
            state.sellPrice = trade.price
        end
    end

    self:calcPlannedPos()
    self:updatePosition()
end

function q_scalper:onQuote(class, asset)
    assert(class)
    assert(asset)
    if class ~= self.etc.class or asset ~= self.etc.asset then
        return
    end

    local etc = self.etc
    local state = self.state
    local market = state.market

    local l2 = getQuoteLevel2(etc.class, etc.asset)
    market.pricer:onQuote(l2)
    market.bid = market.pricer.bid
    market.offer = market.pricer.ask
    market.mid = market.pricer.mid
    if not market.mid then
        return
    end
    market.ma_fast:onValue(market.mid)
    market.ma_slow:onValue(market.mid)
    market.trend = market.ma_fast.val - market.ma_slow.val
    market.trend2:onValue(market.trend)
    market.trigger = market.trigger + market.ma_slow.k*(1 - market.trigger)
    market.alpha:onValue(market.trend, market.trend2.trend)

    self:calcPlannedPos()
    self:updatePosition()

end

function q_scalper:onAllTrade(trade)
end

function q_scalper:onIdle(now)
    self.inherited.onIdle(self, now)

    self:updatePosition()

    local state = self.state
    local ui_state = self.ui_state
    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    
    ui_state.position = counters.position
    ui_state.targetPos = state.targetPos

    local format = self:getPriceFormat()

    ui_state.spot = string.format(format, state.market.mid or 0)
    ui_state.dev = self.formatValue(state.market.dev2)

    ui_state.lastError = "--"
    self:Print("onIdle(): ui_state.state='%s'", ui_state.state)
end

-- function returns operation, price
function q_scalper:calcPlannedPos()
    local etc = self.etc
    local state = self.state
    local market = state.market
   
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

    if market.trigger <= q_triggerThreshold then
        self.state.state = string.format("Недостаточно данных (%.3f)", market.trigger)
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

    state.targetPos = self:getAlpha()*self:getLimit()
end

function q_scalper:getAlpha()
    local etc = self.etc
    local state = self.state
    local market = state.market

    local alpha = self.state.market.alpha.alpha
    if market.trigger < q_triggerThreshold then 
        alpha = 0
    else
        local phase = self:checkSchedule()
        local sphase = (not phase) and "Closed" or (phase == self.CONTINUOUS_TRADING) and "Continuous trading" or "Closing"
        if state.prev_phase ~= sphase then
            self:Print("phase='%s' (%s)", sphase, tostring(phase))
            state.prev_phase = sphase
        end
        if not phase or phase ~= self.CONTINUOUS_TRADING then
            alpha = 0
        end
    end
    self.state.market.alpha.alpha = alpha
    return self.state.market.alpha.alpha
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

function q_scalper:onDisconnected()
end

function q_scalper:killPosition()
    self:Print("killPosition()")
    assert(false)
    self.state.cancel = true
end

setmetatable(q_scalper, { __index = q_base_strategy}) 
return q_scalper
