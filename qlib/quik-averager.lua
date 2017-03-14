--[[
#
# Стратегия на скользящем среднем
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

local q_averager = 
    { etc =  -- master configuration
        -- Главные параметры, задаваемые в ручную
        { asset = "SiH7"                 -- бумага
        , class = "SPBFUT"               -- класс
        , title = "qaverager - [SiH7]"   -- заголовок таблицы

        -- Параметры вычисляемые автоматически
        , account = "SPBFUT005eC"
        , firmid =  "SPBFUT589000"

        , priceStepSize = 1              -- granularity of price (minimum price shift)
        , priceStepValue = 1             -- price of price step (price of minimal price shift)
        , dealCost = 0.5                 -- биржевой сбор

        -- Параметры задаваемые вручную
        , brokerComission = 1            -- коммисия брокера
        , absPositionLimit = 1           -- максимальная приемлемая позиция (абсолютное ограничение)
        , relPositionLimit = 0.6         -- максимальная приемлемая позиция по отношению к размеру счета

        , maxLoss = 1000                 -- максимальная приемлимая потеря

        -- Параметры стратегии
        , avgFactorSpot   = 690           -- коэффициент осреднения спот
        , avgFactorSigma  = 5000          -- коэфициент осреднения волатильности
        , enterThreshold  = 0.7           -- порог чувствительности для входа в позицию
        , cancelThreshold = 1.6           -- порог чувствительности для выхода из позиции

        -- Вспомогательные параметры
        , enterSpread = 3                 -- отступ от края стакана для открытия позиции

        , avgFactorDelay = 20             -- коэффициент осреднения задержек Quik

        
        , params = 
            { { name="avgFactorSpot",  min=1, max=1e32, step=10, precision=1 }
            , { name="avgFactorSigma", min=1, max=1e32, step=10, precision=1 }
            , { name="enterThreshold"
              , min=0
              , max=1e32
              , get_max = function (func) 
                    return func.cancelThreshold
                end
              , step=0.1
              , precision=0.1
              }
            , { name="cancelThreshold"
              , min=0
              , max=1e32
              , get_min = function (func) 
                    return func.enterThreshold
                end
              , step=0.1
              , precision=0.1 
              }
            , { name="enterSpread", min=0, max=1e32, step=1, precision=1 }
            } 
        -- расписание работы
        , schedule = 
            { q_time.interval("10:00", "12:55") -- 10:01 - 12:55
            , q_time.interval("13:05", "13:58") -- 13:01 - 13:55
            , q_time.interval("14:05", "15:44") -- 14:16 - 15:45
            , q_time.interval("16:01", "18:50") -- 16:01 - 18:55
            , q_time.interval("19:01", "21:55") -- 19:01 - 21:55
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
            , { name="ordersLatencies", title="Задер.заявок (ms)", ctype=QTABLE_STRING_TYPE, width=20, format="%s" }
            , { name="state", title="Состояние", ctype=QTABLE_STRING_TYPE, width=40, format="%s" }
            , { name="lastError", title="Результат последней операции", ctype=QTABLE_STRING_TYPE, width=45, format="%s" }
        }
    }

_G["quik-averager"] = q_averager

local strategy = {}

local HISTORY_TO_ANALYSE    = 30000
local MIN_HISTORY           = 300

local PHASE_INIT                = 1
local PHASE_WAIT                = 2
local PHASE_HOLD                = 3
local PHASE_CLOSE               = 4
local PHASE_PRICE_CHANGE        = 5
local PHASE_CANCEL              = 6

function q_averager.create(etc)

    local self = 
        { title = "averager"
        , etc = q_config.create(q_averager.etc)
        , ui_mapping = q_averager.ui_mapping
        , ui_state =
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
        , state =
            { halt = false   -- immediate stop
            , pause = true   -- temporary stop
            , cancel = true  -- closing current position

            , phase = PHASE_INIT

            -- profit/loss
            , balance =
                { atStart = 0
                , maxValue = 0
                , currValue = 0
                }

            -- market status
            , market =
                { bid = 0
                , offer = 0
                , mid = 0
                , avgMid = 0
                , trend = 0
                , trend2 = 0
                , dev_2 = 0     -- deviation^2
                , deviation = 0
                }

            , targetPos = 0
            , position = 0
            
            , order = { }
            , state = "--"
            , count = -100
            }
        }

    if etc then
        self.etc.account = etc.account or self.etc.account
        self.etc.firmid = etc.firmid or self.etc.firmid
        self.etc.asset = etc.asset or self.etc.asset
        self.etc.class = etc.class or self.etc.class
        self.etc:merge(etc)
    end

    setmetatable(self, { __index = strategy })

    self.title = string.format( "%s - [%s]"
                              , self.title
                              , self.etc.asset
                              )
    if global_suffix then
        self.title = self.title .. "-" .. tostring(global_suffix)
    end

    return self
end

function strategy:checkSchedule()
    local now = quik_ext.gettime()
    for _,period in ipairs(self.etc.schedule) do
        if period:isInside(now) then
            return true
        end
    end
    return false
end

function strategy:isEOD()
    local now = quik_ext.gettime()
    local timeLeft = self.etc.schedule[#self.etc.schedule]:getTimeLeft(now)
    return timeLeft < 60*5
end

function strategy:getLimit(absLimit, relLimit)
    
    absLimit = absLimit or self.etc.absPositionLimit
    relLimit = math.min(1, relLimit or self.etc.relPositionLimit)


    assert(absLimit)
    assert(relLimit)
    local moneyLimit = q_utils.getMoneyLimit(self.etc.account)
    assert(moneyLimit)
    moneyLimit = moneyLimit*relLimit
    local buyLimit = math.floor(moneyLimit/q_utils.getBuyDepo(self.etc.class, self.etc.asset))
    local sellLimit = math.floor(moneyLimit/q_utils.getBuyDepo(self.etc.class, self.etc.asset))
    return math.min(absLimit, math.min(buyLimit, sellLimit))
end

function strategy:getMinTickCount()
    return math.max(self.etc.avgFactorSpot, self.etc.avgFactorTrend)/4
end

function strategy:updateParams()
    self.etc.priceStepSize = tonumber(getParamEx(self.etc.class, self.etc.asset, "SEC_PRICE_STEP").param_value)
    self.etc.priceStepValue = tonumber(getParamEx(self.etc.class, self.etc.asset, "STEPPRICE").param_value)
    self.etc.dealCost = tonumber(getParamEx(self.etc.class, self.etc.asset, "EXCH_PAY").param_value)
    assert(self.etc.priceStepSize > 0, "priceStepSize(" .. self.etc.asset .. ") = " .. self.etc.priceStepSize)
    assert(self.etc.priceStepValue > 0, "priceStepValue(" .. self.etc.asset .. ") = " .. self.etc.priceStepValue)
end

function strategy:calcMargin()
    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    local settleprice = q_utils.getSettlePrice(self.etc.class, self.etc.asset)
    return counters.margin + counters.position*settleprice/self.etc.priceStepSize*self.etc.priceStepValue
end

function strategy:calcBalance()
    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    local settleprice = q_utils.getSettlePrice(self.etc.class, self.etc.asset)
    local balance = counters.margin - counters.comission - counters.contracts*self.etc.brokerComission
    balance = balance + counters.position*settleprice/self.etc.priceStepSize*self.etc.priceStepValue 
    return balance
end

function strategy:init()
    q_order.init()

    self.etc.account = q_utils.getAccount() or self.etc.account
    self.etc.firmid = q_utils.getFirmID() or self.etc.firmid

    self.etc.limit = self:getLimit()
    self.state =
            { halt = false   -- immediate stop
            , pause = true   -- temporary stop
            , cancel = true  -- closing current position

            , phase = PHASE_INIT

            -- profit/loss
            , balance =
                { atStart = 0
                , maxValue = 0
                , currValue = 0
                }

            -- market status
            , market =
                { bid = 0
                , offer = 0
                , mid = 0
                , avgMid = 0
                , trend = 0
                , trend2 = 0
                , dev_2 = 0     -- deviation^2
                , deviation = 0
                , trigger = 0
                }

            , targetPos = 0
            , position = 0
            
            , order = { }
            , state = "--"
            }
    self.state.order = q_order.create(self.etc.account, self.etc.class, self.etc.asset)
    self.state.refPrice = self.state.market.mid

    -- initial counters and position
    local settleprice = q_utils.getSettlePrice(self.etc.class, self.etc.asset)
    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    counters.position = q_utils.getPos(self.etc.asset)
    counters.margin = -counters.position*settleprice

    local balance = self:calcBalance()
    self.state.balance.atStart = balance
    self.state.balance.maxValue = balance
    self.state.balance.currValue = balance

    self:updateParams()

    -- walk through all trade
    local n = getNumberOf("all_trades")
    local first = math.max(0, n - HISTORY_TO_ANALYSE)

    local market = self.state.market
    local etc = self.etc

    market.avgMid = false
    market.trend = 0
    market.trend2 = 0
    market.dev_2 = 0

    for i = first, n - 1 do
        local trade = getItem("all_trades", i)
        self.now = os.time(trade.datetime)
        if trade.sec_code == self.etc.asset and trade.class_code == self.etc.class and self:checkSchedule(self.now) then
            self:calcMarketParams(trade.price, trade.price)
        end
    end
    Subscribe_Level_II_Quotes(self.etc.class, self.etc.asset)
    self.state.phase = PHASE_WAIT
    self:calcPlannedPos()
end

function strategy:onStartTrading()
    self.state.pause = false
    self.state.halt = false
    self.state.cancel = false
end

function strategy:isHalted()
    return self.state.halt
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
    local status, delay, err = q_order.onTransReply(reply)

    if delay then
        local k= 1/(1 + self.etc.avgFactorDelay)
        self.state.ordersDelay = self.state.ordersDelay or delay
        self.state.ordersDelay = self.state.ordersDelay + k*(delay - self.state.ordersDelay)
        local sigma = math.pow(self.state.ordersDelay - delay, 2)
        self.state.ordersDelayDev2 = self.state.ordersDelayDev2 or 0
        self.state.ordersDelayDev2 = self.state.ordersDelayDev2 + k*(sigma - self.state.ordersDelayDev2)
        self.state.ordersDelayDev = math.sqrt(self.state.ordersDelayDev2)
    end
    if not status then 
        self.ui_state.lastError = err
    end
    self:onMarketShift()
end

function strategy:onTrade(trade)
    self:Print(string.format("onTrade(%d@%f)", trade.qty, trade.price))
    self.now = os.time(trade.datetime)
    q_order.onTrade(trade)
end

function strategy:onAllTrade(trade)
    local receivedAt = quik_ext.gettime()
    local sentAt = os.time(trade.datetime) + trade.datetime.mcs/1e6
    local delay = receivedAt - sentAt

    local k= 1/(1 + self.etc.avgFactorDelay)
    self.state.tradesDelay = self.state.tradesDelay or delay
    self.state.tradesDelay = self.state.tradesDelay + k*(delay - self.state.tradesDelay)
    local sigma = math.pow(self.state.tradesDelay - delay, 2)
    self.state.tradesDelayDev2 = self.state.tradesDelayDev2 or 0
    self.state.tradesDelayDev2 = self.state.tradesDelayDev2 + k*(sigma - self.state.tradesDelayDev2)
    self.state.tradesDelayDev = math.sqrt(self.state.tradesDelayDev2)
end

function strategy:checkL2()
    local bid, offer, l2 = self:getQuoteLevel2()
    if not bid or not offer then
        return false
    end

    self:calcMarketParams(bid, offer, l2)
    return true
end

function strategy:onQuote(class, asset)
    assert(class)
    assert(asset)
    if class ~= self.etc.class or asset ~= self.etc.asset then
        return
    end

    if self:checkL2() then
        self:calcPlannedPos()
        self:onMarketShift()
    end
end

function strategy:onIdle(now)

    self.now = quik_ext.gettime()
    q_order.onIdle()
    self:onMarketShift()

    local state = self.state
    local ui_state = self.ui_state
    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    
    if state.order:isDeactivating() then
        -- discard deactivating order
        local order = q_order.create(self.etc.account, self.etc.class, self.etc.asset)
        -- preserve refernce data
        order.operation = state.order.operation
        order.price = state.order.price
        -- discard
        state.order = order
    end

    -- kill position
    if state.cancel then
        ui_state.state = "Ликвидация"

        local pending, active = self:checkOrders()
        
        if active and not pending then
            local res, err = self:killOrders()
            self:checkStatus(res, err)
        end

        if not active and not pending then
            if not self:checkSchedule() then
                state.state = "Остановка по расписанию"
            elseif counters.position > 0 then
                self.etc.minPrice = tonumber(getParamEx(self.etc.class, self.etc.asset, "PRICEMIN").param_value)
                assert(self.etc.minPrice > 0, "Неверная минимальная цена: " .. self.etc.minPrice .. "\n" .. debug.traceback())
                state.phase = HASE_CANCEL
                local res, err = state.order:send("S", self.etc.minPrice, counters.position)
                self:checkStatus(res, err)
                return
            elseif counters.position < 0 then
                self.etc.maxPrice = tonumber(getParamEx(self.etc.class, self.etc.asset, "PRICEMAX").param_value)
                assert(self.etc.maxPrice > 0, "Неверная максимальная цена: " .. self.etc.maxPrice .. "\n" .. debug.traceback())
                state.phase = PHASE_CANCEL
                local res, err = state.order:send("B", self.etc.maxPrice, -counters.position)
                self:checkStatus(res, err)
                return
            else
                if state.phase ~= PHASE_WAIT then
                    self:Print("switching to PHASE_WAIT")
                end
                state.phase = PHASE_WAIT
                state.cancel = false

            end
        end
    end

    ui_state.position = counters.position
    ui_state.targetPos = state.targetPos
    local format = "%.0f /%s"
    if self.etc.priceStepSize < 1e-6 then
        format = "%0.8f /%s"
    elseif self.etc.priceStepSize < 1e-5 then
        format = "%0.7f /%s"
    elseif self.etc.priceStepSize < 1e-4 then
        format = "%0.6f /%s"
    elseif self.etc.priceStepSize < 1e-3 then
        format = "%0.5f /%s"
    elseif self.etc.priceStepSize < 1e-2 then
        format = "%0.4f /%s"
    elseif self.etc.priceStepSize < 1e-1 then
        format = "%0.3f /%s"
    elseif self.etc.priceStepSize < 1 then
        format = "%0.2f / %s"
    end

    local function formatVal(val)
        val = val or 0
        if val == 0 then
            return "0"
        end
        local aval = math.abs(val)
        local fmt = "%.f"
        if aval < 1e-3 then
            fmt = "%.2e"
        elseif aval < 1e-2 then
            fmt = "%.4f"
        elseif aval < 1e-1 then
            fmt = "%.3f"
        elseif aval < 1 then
            fmt = "%.2f"
        elseif aval < 1e2 then
            fmt = "%.1f"
        end
        return string.format(fmt, val)
    end

    ui_state.spot = string.format(format, (state.market.avgMid or 0), formatVal(state.market.deviation))
    ui_state.trend = formatVal(state.market.trend2)

    if self:checkSchedule() and isConnected() ~= 0 then
        local balance = self:calcBalance()
        state.balance.maxValue = math.max(state.balance.maxValue, balance)
        state.balance.currValue = balance
    end

    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    ui_state.margin = self:calcMargin()
    ui_state.comission = counters.comission
    ui_state.lotsCount = counters.contracts
    ui_state.balance = string.format( "%.02f / %.02f"
                                    , state.balance.currValue - state.balance.atStart
                                    , state.balance.currValue - state.balance.maxValue
                                    )

    if pending then
        ui_state.state = "Отправка заявки"
    elseif active then
        ui_state.state = "Ожидание исполнения заявки"
    elseif state.pause then
        ui_state.state = "Пауза"
    elseif state.halt then
        ui_state.state = "Остановка"
    elseif not self:checkSchedule() then
        ui_state.state = "Остановка по расписанию"
    else
        ui_state.state = state.state
    end

    if state.ordersDelay then
        ui_state.ordersLatencies = string.format("%.0f / %.0f", state.ordersDelay*1000, (state.ordersDelayDev or 0)*1000)
    else
        ui_state.ordersLatencies = "-- / --"
    end

    ui_state.lastError = "--"
    self:Print("onIdle(): ui_state.state='%s'", ui_state.state)
end

function strategy:getQuoteLevel2()
    local l2 = getQuoteLevel2(self.etc.class, self.etc.asset)

    local function prepareQuotes(count, qq)
        count = tonumber(count)
        for i=1,count do
            qq[i].price = tonumber(qq[i].price)
            qq[i].quantity = tonumber(qq[i].quantity)
        end
        return count
    end
    l2.bid_count = prepareQuotes(l2.bid_count, l2.bid)
    l2.offer_count = prepareQuotes(l2.offer_count, l2.offer)

    if l2.bid_count == 0 or l2.offer_count == 0 then
        return
    end

    q_order.removeOwnOrders(l2)

    local bid = l2.bid[l2.bid_count].price
    local offer = l2.offer[1].price

    return bid, offer, l2
end

-- function calculates market parameters
function strategy:calcMarketParams(bid, offer, l2)

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
    
    market.mid = mid
    market.avgMid = market.avgMid + k1*(market.mid - market.avgMid)
    
    local trend = market.mid - market.avgMid
    market.trend = market.trend + k1*(trend - market.trend)
    
    local trend2 = trend - market.trend
    market.trend2 = market.trend2 + k1*(trend2 - market.trend2)


    local dev_2 = math.pow(trend, 2)
    market.dev_2 = market.dev_2 + k2*(dev_2 - market.dev_2)
    market.deviation = math.sqrt(market.dev_2)

    market.trigger = market.trigger + k1*(1 - market.trigger)
end

-- function returns operation, price
function strategy:calcPlannedPos()
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

    if market.trigger <= 0.5 then
        self.state.state = "Недостаточно данных"
        return
    end
    if not self.triggerReported then
        self.triggerReported = true
        self:Print("calcPlannedPos(): trigger activated")
    end
    if state.halt or state.pause or state.cancel then
        self:Print("calcPlannedPos(): state.halt=%s state.pause=%s state.cancel=%s",
            tostring(state.halt), tostring(state.pause), tostring(state.cancel))
        return
    end

    if not self:checkSchedule() or self:isEOD() then
        return
    end

    if market.trend2 > 0 then
        state.targetPos = 1
    elseif market.trend2 < 0 then
        state.targetPos = -1
    end

    state.targetPos = state.targetPos*self:getLimit()
end

function strategy:killOrders()
    local state = self.state
    local res, err = true, ""

    if state.order:isActive() then
        res, err = state.order:kill()
    end
    return res, err
end

function strategy:checkOrders()
    local state = self.state

    local pending = state.order:isPending()
    local active = state.order:isActive()
    return pending, active
end

function strategy:Print(fmt, ...)
--[[    local state = self.state
    local market = state.market
    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    local settleprice = market.mid--q_utils.getSettlePrice(self.etc.class, self.etc.asset)
    local balance = counters.margin - counters.comission - counters.contracts*self.etc.brokerComission
    balance = balance + counters.position*settleprice/self.etc.priceStepSize*self.etc.priceStepValue 
    local now = quik_ext.gettime()
    local ms = math.floor((now - math.floor(now))*1000)
    local args = {...}

    local preamble = string.format("%6.0f %s.%03d (%4.0f)", market.mid, os.date("%H:%M:%S", now), ms, balance)
    local message = string.format(fmt, unpack(args))
    print(string.format("%s: %s", preamble, message))]]
end

function strategy:onMarketShift()

    local etc = self.etc
    local state = self.state
    local market = state.market
    
    -- check halts and pending orders
    if self.state.halt or self.state.cancel or self.state.pause then
        self:Print("onMarketShift() exit due to halt cancel or pause")
        return
    end

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
        state.phase = PHASE_WAIT
        state.state = "Ожидание исполнения ордера"
        if (diff > 0 and state.order.operation == 'S') or (diff < 0 and state.order.operation == 'B') then
            res, err = self:killOrders()
            state.phase = PHASE_CANCEL
            state.state = "Отмена ордера из-за изменения тренда"
            self:Print("Cancel order due to trend changing")
        end
        self:checkStatus(res, err)
        -- wait while the order is canceled
        return
    elseif diff ~= 0 then
        state.phase = PHASE_WAIT
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

function strategy:onDisconnected()
end

function strategy:checkStatus(status, err)
    if not status then
        assert(err, "err is nil")
        self.ui_state.lastError = "Ошибка: " .. tostring(err)
        self.ui_state.state = "Приостановка (" .. self.state.state .. ")"
        self.state.halt = true
        return false
    end    
    self.ui_state.lastError = "OK"
    return true
end

function strategy:killPosition()
    self:Print("killPosition()")
    assert(false)
    self.state.cancel = true
end

return q_averager
