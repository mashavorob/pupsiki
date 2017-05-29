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

local q_triggerThreshold = 0.7

local q_scalper =
     -- master configuration
    { etc =
        -- Параметры стратегии
        { avgFactorTrend    = 37        -- коэффициент осреднения тренда
        , avgFactorPrice    = 880       -- коэффициент осреднения цены
        , avgFactorOpen     = 86        -- коэффициент осреднения цены для открытия позиции
        , sensitivity1      = 0.06      -- порог чувствительности
        , sensitivity2      = 0.081     -- порог чувствительности
        , fixSpread         = 99        -- фиксация прибыли

        , priceCandle       = 0.25      -- ширина свечи цены, сек
        , enterSpread       = 0         -- отступ от края стакана для открытия позиции

        , params = 
            { { name="avgFactorTrend", min=1,    max=1e7, step=20,    precision=1   }
            , { name="avgFactorPrice", min=1,    max=1e7, step=100,   precision=1   }
            , { name="avgFactorOpen",  min=1,    max=1e7, step=20,    precision=1   }
            --, { name="priceCandle",    min=0.25, max=0.25, step=0.1,  precision=0.05}
            
            --[[ parameter with function
            , { name="historyLen"
            ,   min=3
            ,   max=1e7
            ,   step=10
            ,   precision=1     
            ,   get_min = function(self) return self.priceCandle*2.01 end
            }  --]]

            , { name="sensitivity1"
            ,   min=0
            ,   max=1e5
            ,   step=0.01
            ,   precision=0.001 
            ,   get_max = function(self) return self.sensitivity2 end
            }
            , { name="sensitivity2"
            ,   min=0
            ,   max=1e5
            ,   step=0.01
            ,   precision=0.001 
            ,   get_min = function(self) return self.sensitivity1 end
            }
            --, { name="enterSpread",    min=-100, max=100, step=10,    precision=1     }
            , { name="fixSpread",      min=0,    max=1e5, step=10,    precision=1     }

            --[[
            
            -- Parameter with function
            
            , { name="sensitivity"
              , min=0
              , max=1e5
              , step=0.001
              , precision=0.001
              , get_max = function(self) return self.saturation end
              }
              ]]
            } 
        }

        , ui_mapping =
            { { name="position",  title="Позиция",                      ctype=QTABLE_DOUBLE_TYPE, width=12, format="%.0f"  }
            , { name="targetPos", title="Рас.позиция",                  ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f"  }
            , { name="spot",      title="Цена",                         ctype=QTABLE_STRING_TYPE, width=22, format="%s"    }
            , { name="margin",    title="Маржа",                        ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.02f" }
            , { name="comission", title="Коммисия",                     ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.02f" }
            , { name="lotsCount", title="Контракты",                    ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f"  }
            , { name="balance",   title="Доход/Потери",                 ctype=QTABLE_STRING_TYPE, width=25, format="%s"    }
            , { name="state",     title="Состояние",                    ctype=QTABLE_STRING_TYPE, width=40, format="%s"    }
            , { name="lastError", title="Результат последней операции", ctype=QTABLE_STRING_TYPE, width=45, format="%s"    }
        }

        , PHASE_TRADING = 4
        , PHASE_PRICE_CHANGE  = 5
    }

function q_scalper.create(etc)

    local self = q_base_strategy.create("averager", q_scalper.etc, etc)

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
            , trigger = 0
            , pricer = q_bricks.PriceTracker.create()
            , ma_bid = q_bricks.MovingAverage.create(self.etc.avgFactorPrice, self.etc.priceCandle)
            , ma_ask = q_bricks.MovingAverage.create(self.etc.avgFactorPrice, self.etc.priceCandle)
            , ma_bid_open = q_bricks.MovingAverage.create(self.etc.avgFactorOpen, self.etc.priceCandle)
            , ma_ask_open = q_bricks.MovingAverage.create(self.etc.avgFactorOpen, self.etc.priceCandle)
            , trend_bid = q_bricks.Trend.create(self.etc.avgFactorTrend)
            , trend_ask = q_bricks.Trend.create(self.etc.avgFactorTrend)
            , alpha_aggr = q_bricks.AlphaAgg.create()
            }
            self.state.market.alpha_open = q_bricks.AlphaFilterOpen.create( self.etc.enterSpread
                                                                          , self.state.market.ma_bid_open
                                                                          , self.state.market.ma_ask_open
                                                                          )

            self.state.market.alpha_fix = q_bricks.AlphaFilterFix.create(self.etc.fixSpread)

            self.state.market.alpha_bid = q_bricks.AlphaByTrend.create( self.state.market.alpha_fix
                                                                      , self.etc.sensitivity1
                                                                      , self.etc.sensitivity2
                                                                      )

            self.state.market.alpha_ask = q_bricks.AlphaByTrend.create( self.state.market.alpha_fix
                                                                      , self.etc.sensitivity1
                                                                      , self.etc.sensitivity2
                                                                      )
            self.state.market.alpha = self.state.market.alpha_aggr

    self.state.targetPos = 0
    self.state.position = 0
    self.state.state = "--"

    setmetatable(self, { __index = q_scalper })

    return self
end

function q_scalper:init()
    q_base_strategy.init(self)
end

function q_scalper:updatePosition()

    local state = self.state
    local etc = self.etc
    local market = state.market
    if not market.ma_bid.val or not market.ma_ask.val then
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
        state.state = "Ожидание исполнения заявки"
    elseif state.order:isPending() then
        state.state = "Отправка заявки"
    elseif not state.order:isPending() then
        lotSize = math.min(math.abs(diff), lotSize)

        if diff > 0 then
            state.state = (state.targetPos == 0) and "Ликивидация позиции" or "Открытие длинной позиции"
            local price = market.offer + etc.priceStepSize
            self:Print("Enter long at: %d@%f bid=%.0f offer=%.0f market.mid=%.0f ma_ask.val=%.2f"
                , lotSize, price
                , market.bid
                , market.offer
                , market.mid
                , market.ma_ask.val
                )
            local res, err = state.order:send('B', price, lotSize, "KILL_BALANCE")
            self:checkStatus(res, err)
            state.buyPrice = price
            state.hold = false
        elseif diff < 0 then
            state.state = (state.targetPos == 0) and "Ликивидация позиции" or "Открытие короткой позиции"
            local price = market.bid - etc.priceStepSize
            self:Print("Enter short at: %d@%f bid=%.0f offer=%.0f mid=%.0f ma_bid.val=%.2f"
                , lotSize, price
                , market.bid
                , market.offer
                , market.mid
                , market.ma_bid.val
                )
            local res, err = state.order:send('S', price, lotSize, "KILL_BALANCE")
            self:checkStatus(res, err)
            state.sellPrice = price
            state.hold = false
        else
            if market.trigger <= q_triggerThreshold then
                self.state.state = string.format("Недостаточно данных (%.3f)", market.trigger)
            else
                state.state = "Удержание позиции"
            end
            if not state.hold then
                self:Print("hold position %d", state.targetPos)
                state.hold = true
            end
        end
    end
end

function q_scalper:onTransReply(reply)
    self:Print("onTransReply(status=%s, result_msg='%s')", tostring(reply.status), reply.result_msg or "") 
    q_base_strategy.onTransReply(self, reply)
end

function q_scalper:onTrade(trade)
    self.inherited.onTrade(self, trade)
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
    local new_bid, new_ask, new_mid = market.pricer:onQuote(l2)
    market.bid = market.pricer.bid
    market.offer = market.pricer.ask
    market.mid = market.pricer.mid
    if not market.mid then
        return
    end
    local now = quik_ext.gettime()

    if new_bid then
        local quant = market.ma_bid:onValue(market.pricer.bid, now)
        while quant do
            market.trend_bid:onValue(market.ma_bid.ma_val, market.ma_bid.time, true)
            quant = market.ma_bid:onValue(market.pricer.bid, now)
        end
        quant = market.ma_bid_open:onValue(market.pricer.bid, now)
        while quant do
            quant = market.ma_bid_open:onValue(market.pricer.bid, now)
        end
    end

    if new_ask then
        quant = market.ma_ask:onValue(market.pricer.ask, now)
        while quant do
            market.trend_ask:onValue(market.ma_ask.ma_val, market.ma_ask.time, true)
            quant = market.ma_ask:onValue(market.pricer.ask, now)
        end
        quant = market.ma_ask_open:onValue(market.pricer.ask, now)
        while quant do
            quant = market.ma_ask_open:onValue(market.pricer.ask, now)
        end
    end

    if new_mid and market.trend_bid.trend and market.trend_ask.trend then
        market.alpha_bid:onValue(market.trend_bid.trend)
        market.alpha_ask:onValue(market.trend_ask.trend)
        market.alpha_aggr:aggregate(market.alpha_bid.alpha, market.alpha_ask.alpha)

        market.alpha:filter(market.alpha_aggr.alpha, market.pricer.bid, market.pricer.ask)

        market.trigger = market.trigger + market.ma_bid.k*(1 - market.trigger)

        self:calcPlannedPos()
    end
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

    return res, err
end

function q_scalper:checkOrders()
    local state = self.state

    local pending = state.order:isPending()
    local active = state.order:isActive()

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
