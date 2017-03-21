--[[
#
# Базовый класс для стратегий
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

local q_base_strategy =
    -- master configuration 
    -- Главные параметры, задаваемые в ручную
    { etc = { asset = "SiM7"                 -- бумага
    --[[ 
        Коды контрактов:
            Si - USDRUB
            RI - RTS Index
        Коды месяцев:
            H - март
            M - июнь
            U - сентябрь
            Z - декабрь
    ]]
            , class = "SPBFUT"               -- класс
            , title = "qscalper - [SiH7]"    -- заголовок таблицы

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

            -- расписание работы
            -- [[ UAT
            , schedule = { q_time.interval("10:01", "12:55") -- 10:01 - 12:55
                         , q_time.interval("13:05", "13:55") -- 13:05 - 13:55
                         , q_time.interval("14:10", "15:40") -- 14:10 - 15:40
                         , q_time.interval("16:01", "18:50") -- 16:01 - 18:50
                         , q_time.interval("19:01", "21:55") -- 19:01 - 21:55
                         }
            -- ]]
            --[[ PROD
            , schedule = { q_time.interval("10:01", "13:55") -- 10:00 - 14:00 -- Основная сессия (утро)
                         , q_time.interval("14:06", "18:40") -- 14:05 - 18:45 -- Основная сессия (вечер)
                         , q_time.interval("19:06", "23:40") -- 19:00 - 23:50 -- Вечерняя дополнительная сессия
                         }
            --]]
            }

    , ui_mapping = {}

    , PHASE_INIT   = 1
    , PHASE_READY  = 2
    , PHASE_CANCEL = 3

    }

local function mergeConfig(src, dst)
    for k,v in pairs(src) do
        if type(v) == 'table' and type(dst[k]) == 'table' then
            mergeConfig(v, dst[k])
        else
            dst[k] = v
        end
    end
    return dst
end

function q_base_strategy.create(title, etcDerived, etcClient)

    local etc = mergeConfig(etcDerived, mergeConfig(q_base_strategy.etc, {}))
    local self = 
        { etc = q_config.create(etc)
        , ui_mapping = {}
        , ui_state = { position = 0
                     , margin = 0
                     , comission = 0
                     , lotsCount = 0
                     , balance = 0
                     , state = "Запуск"
                     , lastError = "" 
                     }
        , state = { halt = false   -- immediate stop
                  , pause = true   -- temporary stop
                  , cancel = true  -- closing current position
                  , phase = q_base_strategy.PHASE_INIT

                  -- profit/loss
                  , balance = { atStart = 0
                              , maxValue = 0
                              , currValue = 0
                              }

                  , order = { }
                  }
        }

    if etcClient then
        self.etc.account = etcClient.account or self.etc.account
        self.etc.firmid = etcClient.firmid or self.etc.firmid
        self.etc.asset = etcClient.asset or self.etc.asset
        self.etc.class = etcClient.class or self.etc.class
        self.etc:merge(etcClient)
    end

    setmetatable(self, { __index = q_base_strategy })

    self.title = string.format( "%s - [%s]"
                              , title
                              , self.etc.asset
                              )
    if global_suffix then
        self.title = self.title .. "-" .. tostring(global_suffix)
    end

    return self
end

function q_base_strategy:checkSchedule()
    local now = quik_ext.gettime()
    for _,period in ipairs(self.etc.schedule) do
        if period:isInside(now) then
            return true
        end
    end
    return false
end

function q_base_strategy:isEOD()
    local now = quik_ext.gettime()
    local timeLeft = self.etc.schedule[#self.etc.schedule]:getTimeLeft(now)
    return timeLeft < 60*5
end

function q_base_strategy:getLimit(absLimit, relLimit)
    absLimit = absLimit or self.etc.absPositionLimit
    relLimit = math.min(1, relLimit or self.etc.relPositionLimit)
    local moneyLimit = q_utils.getMoneyLimit(self.etc.account)
    assert(absLimit)
    assert(relLimit)
    assert(moneyLimit)
    
    moneyLimit = moneyLimit*relLimit
    local buyLimit = math.floor(moneyLimit/q_utils.getBuyDepo(self.etc.class, self.etc.asset))
    local sellLimit = math.floor(moneyLimit/q_utils.getBuyDepo(self.etc.class, self.etc.asset))
    return math.min(absLimit, math.min(buyLimit, sellLimit))
end

function q_base_strategy:updateParams()
    self.etc.priceStepSize = tonumber(getParamEx(self.etc.class, self.etc.asset, "SEC_PRICE_STEP").param_value)
    self.etc.priceStepValue = tonumber(getParamEx(self.etc.class, self.etc.asset, "STEPPRICE").param_value)
    self.etc.dealCost = tonumber(getParamEx(self.etc.class, self.etc.asset, "EXCH_PAY").param_value)
    assert(self.etc.priceStepSize > 0, "priceStepSize(" .. self.etc.asset .. ") = " .. self.etc.priceStepSize)
    assert(self.etc.priceStepValue > 0, "priceStepValue(" .. self.etc.asset .. ") = " .. self.etc.priceStepValue)
end

function q_base_strategy:calcMargin()
    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    local settleprice = q_utils.getSettlePrice(self.etc.class, self.etc.asset)
    return counters.margin + counters.position*settleprice/self.etc.priceStepSize*self.etc.priceStepValue
end

function q_base_strategy:calcBalance()
    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    local settleprice = q_utils.getSettlePrice(self.etc.class, self.etc.asset)
    local balance = counters.margin - counters.comission - counters.contracts*self.etc.brokerComission
    balance = balance + counters.position*settleprice/self.etc.priceStepSize*self.etc.priceStepValue 
    return balance
end

function q_base_strategy:init()
    q_order.init()

    self.etc.account = q_utils.getAccount() or self.etc.account
    self.etc.firmid = q_utils.getFirmID() or self.etc.firmid

    self.etc.limit = self:getLimit()

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

    Subscribe_Level_II_Quotes(self.etc.class, self.etc.asset)
    self.state.phase = q_base_strategy.PHASE_READY
end

function q_base_strategy:onStartTrading()
    self.state.pause = false
    self.state.halt = false
    self.state.cancel = false
end

function q_base_strategy:isHalted()
    return self.state.halt
end

function q_base_strategy:onStartStopCallback()
    self.state.pause = not self.state.pause
    if self.state.pause then
        self.state.cancel = true
    end
end

function q_base_strategy:onHaltCallback()
    self.state.halt = not self.state.halt
end

function q_base_strategy:onTransReply(reply)
    local status, delay, err = q_order.onTransReply(reply)

    if not status then 
        self.ui_state.lastError = err
    end
end

function q_base_strategy:onTrade(trade)
    self:Print(string.format("onTrade(%d@%f)", trade.qty, trade.price))
    q_order.onTrade(trade)
end

function q_base_strategy:onIdle(now)
    self.now = quik_ext.gettime()
    q_order.onIdle()
    self:updatePosition()

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
    
    local pending, active = self:checkOrders()

    -- kill position
    if state.cancel then
        ui_state.state = "Ликвидация"

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
                state.phase = q_base_strategy.PHASE_CANCEL
                local res, err = state.order:send("S", self.etc.minPrice, counters.position)
                self:checkStatus(res, err)
                return
            elseif counters.position < 0 then
                self.etc.maxPrice = tonumber(getParamEx(self.etc.class, self.etc.asset, "PRICEMAX").param_value)
                assert(self.etc.maxPrice > 0, "Неверная максимальная цена: " .. self.etc.maxPrice .. "\n" .. debug.traceback())
                state.phase = q_base_strategy.PHASE_CANCEL
                local res, err = state.order:send("B", self.etc.maxPrice, -counters.position)
                self:checkStatus(res, err)
                return
            else
                if state.phase ~= q_base_strategy.PHASE_READY then
                    self:Print("switching to PHASE_READY")
                end
                state.phase = q_base_strategy.PHASE_READY
                state.cancel = false
            end
        end
    end

    if self:checkSchedule() and isConnected() ~= 0 then
        local balance = self:calcBalance()
        state.balance.maxValue = math.max(state.balance.maxValue, balance)
        state.balance.currValue = balance
    end

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

    ui_state.lastError = "--"
    self:Print("onIdle(): ui_state.state='%s'", ui_state.state)
end

function q_base_strategy:getQuoteLevel2()
    local l2 = getQuoteLevel2(self.etc.class, self.etc.asset)
    
    l2.bid_count = self.prepareQuotes(l2.bid_count, l2.bid)
    l2.offer_count = self.prepareQuotes(l2.offer_count, l2.offer)

    if l2.bid_count == 0 or l2.offer_count == 0 then
        return
    end

    q_order.removeOwnOrders(l2)

    local bid = l2.bid[l2.bid_count].price
    local offer = l2.offer[1].price

    return bid, offer, l2
end

function q_base_strategy:Print(fmt, ...)
  --[[
    local state = self.state
    local market = state.market
    local counters = q_order.getCounters(self.etc.account, self.etc.class, self.etc.asset)
    local settleprice = market.mid--q_utils.getSettlePrice(self.etc.class, self.etc.asset)
    local balance = counters.margin - counters.comission - counters.contracts*self.etc.brokerComission
    balance = balance + counters.position*settleprice/self.etc.priceStepSize*self.etc.priceStepValue 
    local now = quik_ext.gettime()
    local ms = math.floor((now - math.floor(now))*1000)
    local args = {...}

    local preamble = string.format("%6.0f %s.%03d (%4.0f, %2d)", market.mid, os.date("%H:%M:%S", now), ms, balance, counters.position)
    local message = string.format(fmt, unpack(args))
    print(string.format("%s: %s", preamble, message))
    -- ]]
end

function q_base_strategy:onDisconnected()
end

function q_base_strategy:checkStatus(status, err)
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

function q_base_strategy:killPosition()
    self:Print("killPosition()")
    assert(false)
    self.state.cancel = true
end

function q_base_strategy:getPriceFormat()
    local format = "%.0f"
    if self.etc.priceStepSize < 1e-6 then
        format = "%0.8f"
    elseif self.etc.priceStepSize < 1e-5 then
        format = "%0.7f"
    elseif self.etc.priceStepSize < 1e-4 then
        format = "%0.6f"
    elseif self.etc.priceStepSize < 1e-3 then
        format = "%0.5f"
    elseif self.etc.priceStepSize < 1e-2 then
        format = "%0.4f"
    elseif self.etc.priceStepSize < 1e-1 then
        format = "%0.3f"
    elseif self.etc.priceStepSize < 1 then
        format = "%0.2f"
    end
    return format
end

function q_base_strategy.formatValue(val)
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

function q_base_strategy.prepareQuotes(count, qq)
    count = tonumber(count)
    for i=1,count do
        qq[i].price = tonumber(qq[i].price)
        qq[i].quantity = tonumber(qq[i].quantity)
    end
    return count
end

--
-- Overrides
--
function q_base_strategy:checkOrders()
    assert(false, "q_base_strategy:checkOrders() - pure virtual call")
end

function q_base_strategy:onMarketShift()
end

return q_base_strategy
