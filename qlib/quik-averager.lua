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

assert(require("qlib/quik-etc"))
assert(require("qlib/quik-avg"))
assert(require("qlib/quik-order"))
assert(require("qlib/quik-utils"))
assert(require("qlib/quik-time"))

local q_averager = 
    { etc =  -- master configuration
        -- Главные параметры, задаваемые в ручную
        { asset = "SiM6"                 -- бумага
        , class = "SPBFUT"               -- класс
        , title = "qaverager - [SiM6]"   -- заголовок таблицы

        -- Параметры вычисляемые автоматически
        , account = "SPBFUT005eC"
        , firmid =  "SPBFUT589000"

        , priceStepSize = 1              -- granularity of price (minimum price shift)
        , priceStepValue = 1             -- price of price step (price of minimal price shift)
        , dealCost = 2                   -- биржевой сбор

        -- Параметры задаваемые вручную
        , absPositionLimit = 1           -- максимальная приемлемая позиция (абсолютное ограничение)
        , relPositionLimit = 0.6         -- максимальная приемлемая позиция по отношению к размеру счета

        , maxLoss = 1000                 -- максимальная приемлимая потеря

        -- Параметры стратегии
        , avgFactorSpot  = 100            -- коэффициент осреднения спот
        , avgFactorTrend = 100            -- коэфициент осреднения тренда
        , enterThreshold = 1e-4          -- порог чувствительности для входа в позицию
        , exitThreshold  = 0             -- порог чувствительности для выхода из позиции

        -- Вспомогательные параметры
        , maxDeviation = 2
        , profitSpread = 1
        , minProfit = 3                  -- минимальный ожидаемый профит для входа в позицию (в стоимости контракта)
                                         --   стоимость открытия позиции + стоимость закрытия позиции + маржа
        , minSpread = false              -- вычисляется из minProfit

        
        , params = 
            { { name="avgFactorSpot",  min=1, max=1e32, step=50, precision=1 }
            , { name="avgFactorTrend", min=1, max=1e32, step=50, precision=1 }
            , { name="enterThreshold"
              , min=0
              , max=1e32
              , get_min = function (func) 
                    return func.exitThreshold
                end
              , step=1e-5
              , precision=1e-7 
              }
            , { name="exitThreshold"
              , min=0
              , max=1e32
              , get_max = function (func) 
                    return func.enterThreshold
                end
              , step=1e-5
              , precision=1e-7 
              }
            } 
        -- расписание работы
        , schedule = 
            { q_time.interval("10:01", "12:55") -- 10:01 - 12:55
            , q_time.interval("13:05", "13:58") -- 13:01 - 13:55
            , q_time.interval("14:05", "15:35") -- 14:16 - 15:35
            , q_time.interval("16:01", "18:50") -- 16:01 - 18:55
            , q_time.interval("19:01", "21:55") -- 19:01 - 21:55
            }
        }

        , ui_mapping =
            { { name="position", title="Позиция", ctype=QTABLE_DOUBLE_TYPE, width=10, format="%.0f" }
            , { name="targetPos", title="Рас. позиция", ctype=QTABLE_DOUBLE_TYPE, width=20, format="%.0f" }
            , { name="spot", title="Средняя цена", ctype=QTABLE_STRING_TYPE, width=20, format="%s" }
            , { name="trend", title="Средний тренд", ctype=QTABLE_DOUBLE_TYPE, width=20, format="%.5f" }
            , { name="balance", title="Доход/Потери", ctype=QTABLE_STRING_TYPE, width=15, format="%s" }
            , { name="state", title="Состояние", ctype=QTABLE_STRING_TYPE, width=40, format="%s" }
            , { name="lastError", title="Результат последней операции", ctype=QTABLE_STRING_TYPE, width=40, format="%s" }
        }
    }

_G["quik-averager"] = q_averager

local strategy = {}

local HISTORY_TO_ANALYSE    = 30000
local MIN_HISTORY           = 1000

local PHASE_INIT                = 1
local PHASE_WAIT                = 2
local PHASE_HOLD                = 3
local PHASE_CLOSE               = 4
local PHASE_PRICE_CHANGE        = 5
local PHASE_CANCEL              = 6

function q_averager.create(etc)

    local self = 
        { title = "averager"
        , etc = config.create(q_averager.etc)
        , ui_mapping = q_averager.ui_mapping
        , ui_state =
            { position = 0
            , targetPos = 0
            , spot = "--"
            , trend = "--"
            , balance = "-- / --"
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
                , avgTrend = 0
                , dev_2 = 0     -- deviation^2
                , deviation = 0
                }

            , targetPos = 0
            , position = 0
            
            , order = { }
            , state = "--"
            , count = -1000
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

    return self
end

function strategy:checkSchedule()
    local now = self.now or os.time()
    for _,period in ipairs(self.etc.schedule) do
        if period:isInside(now) then
            return true
        end
    end
    return false
end

function strategy:isEOD()
    local now = self.now or os.time()
    local timeLeft = self.etc.schedule[#self.etc.schedule]:getTimeLeft(now)
    return timeLeft < 60*5
end

function strategy:getLimit(absLimit, relLimit)
    
    absLimit = absLimit or self.etc.absPositionLimit
    relLimit = relLimit or self.etc.relPositionLimit

    assert(absLimit)
    assert(relLimit)
    local val = q_utils.getMoneyLimit(self.etc.account)
    assert(val)
    local moneyLimit = q_utils.getMoneyLimit(self.etc.account)*relLimit
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
    self.etc.minSpread = math.ceil(self.etc.dealCost*self.etc.minProfit/self.etc.priceStepValue)*self.etc.priceStepSize
    assert(self.etc.priceStepSize > 0, "priceStepSize(" .. self.etc.asset .. ") = " .. self.etc.priceStepSize .. "\n" .. debug.traceback())
    assert(self.etc.priceStepValue > 0, "priceStepValue(" .. self.etc.asset .. ") = " .. self.etc.priceStepValue)
end

function strategy:init()

    self.etc.account = q_utils.getAccount() or self.etc.account
    self.etc.firmid = q_utils.getFirmID() or self.etc.firmid

    self.etc.limit = self:getLimit()

    local balance = q_utils.getBalance(self.etc.account)
    self.state.balance.atStart = balance
    self.state.balance.maxValue = balance
    self.state.balance.currValue = balance

    self.state.order = q_order.create(self.etc.account, self.etc.class, self.etc.asset)
    self.state.position = q_utils.getPos(self.etc.asset)

    self:updateParams()

    -- walk through all trade
    local n = getNumberOf("all_trades")
    local first = math.max(0, n - HISTORY_TO_ANALYSE)

    local market = self.state.market
    local etc = self.etc

    market.avgMid = false
    market.avgTrend = 0
    market.dev_2 = false

    for i = first, n - 1 do
        local trade = getItem("all_trades", i)
        self.now = os.time(trade.datetime)
        if trade.sec_code == self.etc.asset and trade.class_code == self.etc.class and self:checkSchedule(self.now) then
            self:calcMarketParams(trade.price, trade.price)
            self.state.count = self.state.count + 1
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

function strategy:onStartTrading()
    self.state.pause = false
    self.state.halt = false
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
    local err = q_order.onTransReply(reply)
    if err then 
        self.ui_state.lastError = err
    end
    self:updatePosition()
    self:onMarketShift()
end

function strategy:onTrade(trade)
    self.now = os.time(trade.datetime)
    q_order.onTrade(trade)
end

function strategy:onAllTrade(trade)
end

function strategy:checkL2()
    local bid, offer = self:getQuoteLevel2()
    if not bid or not offer then
        return false
    end

    self.state.count = self.state.count + 1
    self:calcMarketParams(bid, offer)
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
        self:updatePosition()
        self:onMarketShift()
    end
end

function strategy:onIdle(now)
    self.now = now or os.time()
    q_order.onIdle()
    self:updatePosition()

    local state = self.state
    local ui_state = self.ui_state

    -- kill position
    if state.cancel then
        ui_state.state = "Ликвидация"

        local active = state.order:isActive() or state.order:isPending()

        if state.phase ~= PHASE_CANCEL and state.order:isActive() then
            local res, err = state.order:kill()
            self:checkStatus(res, err)
        end

        if not active then
            if not self:checkSchedule() then
                state.state = "Остановка по расписанию"
            elseif state.position > 0 then
                self.etc.minPrice = tonumber(getParamEx(self.etc.class, self.etc.asset, "PRICEMIN").param_value)
                assert(self.etc.minPrice > 0, "Неверная минимальная цена: " .. self.etc.minPrice .. "\n" .. debug.traceback())
                state.phase = PHASE_CANCEL
                local res, err = state.order:send("S", self.etc.minPrice, self.state.position)
                self:checkStatus(res, err)
                return
            elseif state.position < 0 then
                self.etc.maxPrice = tonumber(getParamEx(self.etc.class, self.etc.asset, "PRICEMAX").param_value)
                assert(self.etc.maxPrice > 0, "Неверная максимальная цена: " .. self.etc.maxPrice .. "\n" .. debug.traceback())
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
    ui_state.targetPos = state.targetPos
    ui_state.spot = string.format("%.0f /%.0f", state.market.avgMid or 0, state.market.deviation)
    ui_state.trend = state.market.avgTrend

    local balance = q_utils.getBalance(self.etc.account)
    state.balance.maxValue = math.max(state.balance.maxValue, balance)
    state.balance.currValue = balance

    ui_state.balance = string.format( "%.0f / %.0f"
                                    , state.balance.currValue - state.balance.atStart
                                    , state.balance.currValue - state.balance.maxValue
                                    )

    if state.order:isPending() then
        ui_state.state = string.format("Отправка заявки (%s: %s %s)", state.state, state.order.operation, state.order.price)
    elseif state.order:isActive() then
        ui_state.state = string.format("Ожидание исполнения заявки (%s: %s %s)", state.state, state.order.operation, state.order.price)
    elseif state.pause then
        ui_state.state = "Пауза"
    elseif state.halt then
        ui_state.state = "Остановка"
    elseif not self:checkSchedule() then
        ui_state.state = "Остановка по расписанию"
    else
        ui_state.state = state.state
    end

    ui_state.lastError = "--"
end

function strategy:getQuoteLevel2()
    local l2 = getQuoteLevel2(self.etc.class, self.etc.asset)

    l2.bid_count = tonumber(l2.bid_count)
    l2.offer_count = tonumber(l2.offer_count)

    if l2.bid_count == 0 or l2.offer_count == 0 then
        return
    end

    local bid = tonumber(l2.bid[l2.bid_count].price)
    local offer = tonumber(l2.offer[1].price)

    return bid, offer
end

-- function calculates market parameters
function strategy:calcMarketParams(bid, offer)

    local etc = self.etc
    local state = self.state
    local market = state.market

    market.bid = bid
    market.offer = offer
    local mid = (bid + offer)/2
    
    local k1 = 1/(1 + etc.avgFactorSpot)
    local k2 = 1/(1 + etc.avgFactorTrend)

    market.mid = mid
    market.avgMid = market.avgMid or market.mid

    local trend = k1*(market.mid - market.avgMid)
    market.avgMid = market.avgMid + trend
    market.avgTrend = market.avgTrend + k2*(trend - market.avgTrend)

    local dev_2 = math.pow(market.mid - market.avgMid, 2)
    market.dev_2 = market.dev_2 or dev_2
    market.dev_2 = market.dev_2 + k1*(dev_2 - market.dev_2)
    market.deviation = math.sqrt(market.dev_2)
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
        return
    end

    if self.state.count <= 0 then
        self.state.state = "Недостаточно данных"
        return
    end

    if state.halt or state.pause or state.cancel then
        return
    end

    if not self:checkSchedule() or self:isEOD() then
        return
    end

    if state.targetPos < 0 and market.avgTrend > -etc.exitThreshold then
        state.targetPos = 0
    elseif state.targetPos > 0 and market.avgTrend < etc.exitThreshold then
        state.targetPos = 0
    end

    if state.targetPos == 0 then
        if market.avgTrend > etc.enterThreshold 
--            and market.deviation*etc.profitSpread > etc.minSpread 
        then
            state.targetPos = 1
        elseif market.avgTrend < -etc.enterThreshold 
--            and market.deviation*etc.profitSpread > etc.minSpread 
        then
            state.targetPos = -1
        end
    end
    state.targetPos = state.targetPos*self:getLimit()
end

function strategy:onMarketShift()

    local etc = self.etc
    local state = self.state
    local market = state.market
    
    -- check halts and pending orders
    if self.state.halt or self.state.cancel or self.state.pause or state.order:isPending() then
        return
    end

    if state.order:isPending() then
        -- order is being sent to the venue
        -- nothing can be done until operation finishes
        state.phase = PHASE_WAIT
        state.state = "Отправка ордера"
        return
    end

    local diff = state.targetPos - state.position
    if state.order:isActive() then
        state.phase = PHASE_WAIT
        state.state = "Ожидание исполнения ордера"
        local res, err = true, ""
        if diff > 0 and state.order.operation == 'B' then
            -- check deviation
            if state.order.price < market.bid - market.deviation*etc.maxDeviation then
                -- price went tooo far, cancel the order
                res, err = state.order:kill()
                state.phase = PHASE_CANCEL
                state.state = "Отмена ордера из-за отклонения цены" 
            end
        elseif diff < 0 and state.order.operation == 'S' then
            -- check deviation
            if state.order.price > market.offer + market.deviation*etc.maxDeviation then
                -- price went tooo far, cancel the order
                res, err = state.order:kill()
                state.phase = PHASE_CANCEL
                state.state = "Отмена ордера из-за отклонения цены" 
            end
        elseif (diff > 0 and state.order.operation == 's') or (diff < 0 and state.order.operation == 'B') then
            local res, err = state.order:kill()
            state.phase = PHASE_CANCEL
            state.state = "Отмена ордера из-за изменения тренда" 
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
        if diff < 0 then
            state.state = state.targetPos == 0 and "Закрытие позиции" or "Открытие шорт"
            local price = math.floor(market.mid/etc.priceStepSize)*self.etc.priceStepSize
            price = math.max(price, market.offer)
            res, err = state.order:send('S', price, lotSize)
        else
            state.state = state.targetPos == 0 and "Закрытие позиции" or "Открытие лонг"
            local price = math.ceil(market.mid/etc.priceStepSize)*self.etc.priceStepSize
            price = math.min(price, market.bid)
            res, err = state.order:send('B', price, lotSize)
        end
        self:checkStatus(res, err)
    elseif state.position > 0 then
        -- try to sell with profit
        local price = math.ceil((market.mid + market.deviation*etc.profitSpread)/etc.priceStepSize)*self.etc.priceStepSize
        price = math.max(price, market.offer)
        local res, err = state.order:send('S', price, state.position)
        state.state = "Удержание позиции"
        self:checkStatus(res, err)
    elseif state.position < 0 then
        -- try to buy with profit
        local price = math.floor((market.mid - market.deviation*etc.profitSpread)/etc.priceStepSize)*self.etc.priceStepSize
        price = math.min(price, market.bid)
        local res, err = state.order:send('B', price, -state.position)
        state.state = "Удержание позиции"
        self:checkStatus(res, err)
    end
end

function strategy:onDisconnected()
    q_order.onDisconnected()
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
    self.state.cancel = true
end

