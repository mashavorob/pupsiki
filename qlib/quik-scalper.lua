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
local q_cbuffer = assert(require("qlib/quik-cbuffer"))
local q_base_strategy = require("qlib/quik-base-strategy")

local q_triggerThreshold = 0.9

local q_scalper =
     -- master configuration
    { etc =
        -- Параметры стратегии
        { avgFactorSpot     = 1000       -- коэффициент осреднения спот
        , avgFactorVol      = 600        -- коэфициент осреднения отклонения
        , avgFactorTrend    = 200        -- длина истории для вычисления тренда
        , avgFactorSigma    = 5000       -- коэфициент осреднения волатильности
        , openThreshold     = 1          -- порог чувствительности для входа в позицию

        -- Вспомогательные параметры
        , minSpread = 10                 -- Внимание: спред береться из соотвествующего файла:
                                         --     * pupsik-scalper-si.lua,
                                         --     * pupsik-scalper-ri.lua,
                                         --     * и так далее
                                         -- расчет: стоимость открытия позиции + стоимость закрытия позиции + маржа
                                          
        , maxError          = 2          -- максимально приемлимая ошибка цены ордера (шагов цены)

        , params = 
            { { name="avgFactorSpot",  min=1,    max=1e4, step=10,  precision=1    }
            , { name="avgFactorVol",   min=1,    max=1e4, step=10,  precision=1    }
            , { name="avgFactorTrend", min=1,    max=1e4, step=10,  precision=1    }
            , { name="avgFactorSigma", min=1,    max=1e4, step=10,  precision=1    }
            , { name="openThreshold",  min=0,    max=100, step=0.1, precision=0.01 }
            , { name="minSpread",      min=-100, max=100, step=1,   precision=1    }
            , { name="maxError",       min=0,    max=100, step=1,   precision=1    }
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
            , vol = 0
            , avgMid = false
            , avgVol = 0
            , trend = 0
            , sigma_2 = 0     -- sigma^2
            , sigma = 0
            , trigger = 0
            , vols = q_cbuffer.create(self.etc.avgFactorTrend)
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
        -- unreachable
        state.activeCount = state.activeCount or 0
        state.activeCount = state.activeCount + 1
        assert(state.activeCount < 100)
        --[[
        local kill = false
        if diff == 0 then
            self:Print("kill order: target is reached")
            kill = true
        elseif (diff < 0 and state.order.operation == 'B') or
             (diff > 0 and state.order.operation == 'S')
        then
            self:Print("kill order: direction has changed")
            kill = true
        elseif (state.order.operation == 'B' and math.abs(state.order.price - buyPrice) > etc.maxError*etc.priceStepSize) or
            (state.order.operation == 'S' and math.abs(state.order.price - sellPrice) > etc.maxError*etc.priceStepSize)
        then
            self:Print("kill order: price has changed")
            kill = true
        end
        if kill then
            local res, err = state.order:kill()
            self:checkStatus(res, err)
        end
        -- ]]
    elseif not state.order:isPending() then
        lotSize = math.min(math.abs(diff), lotSize)
        local fairPrice = math.floor(market.avgMid/etc.priceStepSize + 0.5)*etc.priceStepSize

        if diff > 0 and market.offer <= fairPrice then
            self:Print("Enter long at: %d@%f", lotSize, fairPrice)
            state.state = "Открытие лонг"
            local res, err = state.order:send('B', fairPrice, lotSize, "KILL_BALANCE")
            self:checkStatus(res, err)
            state.buyPrice = fairPrice
            state.waitForFairPrice = false
        elseif diff < 0 and market.bid >= fairPrice then
            self:Print("Enter short at: %d@%f", lotSize, fairPrice)
            state.state = "Открытие шорт"
            local res, err = state.order:send('S', fairPrice, lotSize, "KILL_BALANCE")
            self:checkStatus(res, err)
            state.sellPrice = fairPrice
            state.waitForFairPrice = false
        elseif diff == 0 then
            state.waitForFairPrice = false
        elseif diff ~= 0 and not state.waitForFairPrice then
            state.waitForFairPrice = true
            self:Print("waiting for fair price %s@%s", (diff > 0) and "BUY" or "SELL", q_base_strategy.formatValue(fairPrice))
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
            local spread = etc.minSpread --math.max(math.floor(etc.openThreshold*market.sigma/etc.priceStepSize + 0.5), etc.minSpread)
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
    q_base_strategy.onTransReply(self, reply)
    local state = self.state
    if reply.trans_id == state.order.trans_id then
        self:Print("onTransReply(trans_id=%s, reply.balance=%s)", tostring(reply.trans_id), tostring(reply.balance))
        self:Print("isPending()=%s isActive()=%s balance=%d", state.order:isPending(), state.order:isActive(), state.order.balance)
        assert(reply.balance == 0)
    end
    --self:updatePosition()
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
    end
end

function q_scalper:onAllTrade(trade)
    local etc = self.etc
    local state = self.state
    local market = state.market
    local vols = market.vols

    if bit.band(trade.flags, 1) ~= 0 then
        market.vol = market.vol - trade.qty
    elseif bit.band(trade.flags, 2) ~= 0 then
        market.vol = market.vol + trade.qty
    end
    market.avgVol = market.avgVol + 1/(etc.avgFactorVol + 1)*(market.vol - market.avgVol)
    vols:push_back(market.avgVol)
    local f0, f1, f2 = vols:getAt(vols.size), vols:getAt(math.floor(vols.size/2)), vols:getAt(1)
    --market.trend = (f0-4*f1+3*f2)/vols.size
    market.trend = (f2 - f0)/vols.size
end

function q_scalper:onIdle(now)
    self.inherited.onIdle(self, now)

    self:updatePosition()

    local state = self.state
    local ui_state = self.ui_state
    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    
    ui_state.position = counters.position
    ui_state.targetPos = state.targetPos

    local format = self:getPriceFormat() .. " /%s"

    ui_state.spot = string.format(format, (state.market.avgMid or 0), self.formatValue(state.market.sigma))
    ui_state.dev = self.formatValue(state.market.dev2)

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

    local k_spot  = 1/(1 + etc.avgFactorSpot)
    local k_vol   = 1/(1 + etc.avgFactorVol)
    local k_sigma = 1/(1 + etc.avgFactorSigma)
    local k_trigger = math.min(k_spot, k_vol, k_sigma)

    market.mid = mid
    if not market.avgMid then
        market.avgMid = mid
    else
        market.avgMid = market.avgMid + k_spot*(market.mid - market.avgMid)
    end

    local dev = market.avgMid - market.mid
    local sigma_2 = dev*dev
    market.sigma_2 = market.sigma_2 + k_sigma*(sigma_2 - market.sigma_2)
    market.sigma = math.sqrt(market.sigma_2)

    market.trigger = market.trigger + k_trigger*(1 - market.trigger)
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

    state.targetPos = self:getAlpha()*self:getLimit()

end

function q_scalper:getAlpha()
    local alpha = 0
    
    local etc = self.etc
    local state = self.state
    local market = state.market
    local sigma = market.sigma*etc.openThreshold

    if market.trend > 0 then
        alpha = 1
    elseif market.trend < 0 then
        alpha = -1
    end

    return alpha
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
