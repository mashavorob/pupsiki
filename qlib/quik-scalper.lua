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

assert(require("qlib/quik-etc"))
assert(require("qlib/quik-avg"))
assert(require("qlib/quik-order"))
assert(require("qlib/quik-utils"))

local q_scalper = {
    etc = { -- master configuration

        -- Главные параметры, задаваемые в ручную
        asset = "SiH6",                 -- бумага
        class = "SPBFUT",               -- класс
        title = "qscalper - [SiH6]",    -- заголовок таблицы

        -- Параметры вычисляемые автоматически
        account = "SPBFUT005eC",
        firmid =  "SPBFUT589000",

        priceStepSize = 1,              -- granularity of price (minimum price shift)
        priceStepValue = 1,             -- price of price step (price of minimal price shift)
        minSpread = 6,                  -- минимальный спрэд
        maxSpread = 20,                 -- максимальный спрэд

        -- Параметры задаваемые вручную
        absPositionLimit = 3,           -- максимальная приемлемая позиция (абсолютное ограничение)
        relPositionLimit = 0.5,         -- максимальная приемлемая позиция по отношению к размеру счета

        maxLoss = 1000,                 -- максимальная приемлимая потеря

        avgFactorFast = 80,             -- "быстрый" коэффициент осреднения
        avgFactorSlow = 700,            -- "медленный" коэфициент осреднения
        avgFactorLot = 200,             -- коэффициент осреднения размера лота (сделки)

        maxAverageLots = 100,           -- ставить позиции не далее этого количества средних лотов
                                        -- от края стакана (средний размер сделки = средний лот)

        nearForecast = 12,              -- прогноз цены (открытие сделки)
        farForecast = 75,               -- прогноз цены (закрытие сделки)

        dealCost = 2,                   -- биржевой сбор
        enterErrorThreshold = 1,        -- предельная ошибка на входе (шагов цены)
        
        confBand = 0.5,                 -- "доверительный диапазон" (в среднеквадратических отклонениях)
        trendThreshold = 0.8,           -- превышение величины тренда этого порога означает уверенный 
                                        -- рост или снижение без вероятности скорого разворота
                                        -- пороговое значение задается в стандартных отклонениях тренда
        maxTrend = 10.2,                 -- предельная волотильность
        volQuiteTime = 3,               -- продолжительность паузы при волатильности (в колебаниях тренда)
        maxQuiteTime = 5,               -- максимальное время ожидания

        params = {
            { name="avgFactorFast", min=1, max=1e32, step=1, precision=1e-4 },
            { name="avgFactorSlow", min=1, max=1e32, step=1, precision=1e-4 },
        },
        -- расписание работы
        schedule = {
            { from = { hour=10, min=01, sec=00 }, to = { hour=12, min=55, sec=00 } }, -- 10:01 - 12:55
            { from = { hour=13, min=05, sec=00 }, to = { hour=13, min=55, sec=00 } }, -- 13:01 - 13:55
            { from = { hour=14, min=16, sec=00 }, to = { hour=15, min=35, sec=00 } }, -- 14:16 - 15:35
            { from = { hour=16, min=01, sec=00 }, to = { hour=18, min=50, sec=00 } }, -- 16:01 - 18:55
            { from = { hour=19, min=01, sec=00 }, to = { hour=21, min=55, sec=00 } }, -- 19:05 - 21:55
        },
    },

    ui_mapping = {
        { name="position", title="Позиция", ctype=QTABLE_DOUBLE_TYPE, width=10, format="%.0f" },
        { name="trends", title="Трэнды", ctype=QTABLE_STRING_TYPE, width=25, format="%.3f" },
        { name="averages", title="Средние", ctype=QTABLE_STRING_TYPE, width=45, format="%.3f" },
        { name="deviations", title="Отклонения", ctype=QTABLE_STRING_TYPE, width=20, format="%.3f" },
        { name="spread", title="Cпред", ctype=QTABLE_STRING_TYPE, width=22, format="%s" },
        { name="volume", title="Объем: Покупка/Продажа/Всего", ctype=QTABLE_STRING_TYPE, width=35, format="%s" },
        { name="balance", title="Доход/Потери", ctype=QTABLE_STRING_TYPE, width=15, format="%s" },
        { name="state", title="Состояние", ctype=QTABLE_STRING_TYPE, width=65, format="%s" },
        { name="lastError", title="Результат последняя операции", ctype=QTABLE_STRING_TYPE, width=80, format="%s" }, 
    },
}

_G["quik-scalper"] = q_scalper

local strategy = {}

local PHASE_INIT                = 1
local PHASE_WAIT                = 2
local PHASE_HOLD                = 3
local PHASE_CLOSE               = 4
local PHASE_PRICE_CHANGE        = 5
local PHASE_CANCEL              = 6

local HISTORY_TO_ANALYSE    = 30000
local MIN_HISTORY           = 1000

function q_scalper.create(etc)

    local self = { 
        title = "scalper",
        etc = config.create(q_scalper.etc),
        ui_mapping = q_scalper.ui_mapping,
        ui_state = {
            position = 0,
            trends = "-- / -- (--)",
            averages = "-- / -- (--)",
            deviations = "-- / --",
            spread = "-- / --",
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
                minPrice = 0,
                maxPrice = 0,
                minBid = 0,
                maxOffer = 0,
                fastPrice = 0,
                slowPrice = 0,
                fastTrend = 0,
                slowTrend = 0,
                fastTrend2 = 0,
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
    self.state.slowPrice = q_avg.createEx(self.etc.avgFactorSlow, 2)
    self.state.lotSize = q_avg.createEx(self.etc.avgFactorLot, 0)

    self.state.order = q_order.create(self.etc.account, self.etc.class, self.etc.asset)

    self.state.position = q_utils.getPos(self.etc.asset)

    self:updateParams()

    -- walk through all trade
    local n = getNumberOf("all_trades")
    local first = math.max(0, n - HISTORY_TO_ANALYSE)
    --assert(n > 0, "Таблица всех сделок пустая, старт невозможен\n")
    --assert(n - first > MIN_HISTORY, "Недостаточно исторических данных, старт невозможен\n")
    
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
                -- сделка на продажу
                l2.offer[1].price = l2.offer[1].price + 2*self.etc.priceStepSize
            else
                -- сделка на покупку
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

function strategy:onStartTrading()
    self.state.pause = false
    self.state.halt = false
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
        -- продажа
        sellVolume = sellVolume + trade.qty
    else
        -- покупка
        buyVolume = buyVolume + trade.qty
    end
end

local prevPrice = -1

function strategy:checkL2(update)
    local l2 = self:getQuoteLevel2()
    if l2.bid_count <= 1 or l2.offer_count <= 1 then
        return
    end

    local bid = tonumber(l2.bid[l2.bid_count].price)
    local offer = tonumber(l2.offer[1].price)

    local price = 0
    local count = 0

    for i = 1,math.min(5, math.min(l2.bid_count, l2.offer_count)) do
        local o, b = l2.offer[i], l2.bid[l2.bid_count - i + 1]
        price = price + (o.price*o.quantity + b.price*b.quantity)/i
        count = count + (o.quantity + b.quantity)/i
    end
    price = price/count

    if update or price ~= prevPrice then
        prevPrice = price

        self.state.fastPrice:onValue(price)
        self.state.slowPrice:onValue(price)

        self:calcMarketParams(l2)

        return true
    end
end

function strategy:onQuote(class, asset)
    if class ~= self.etc.class or asset ~= self.etc.asset then
        return
    end

    if self:checkL2() then
        self:updatePosition()
        self:onMarketShift()
    end
end

function strategy:onIdle()
    q_order.onIdle()
    self:updatePosition()

    if self:checkL2() then
        self:onMarketShift()
    end

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
            if state.position ~= 0 and not self:checkSchedule() then
                state.state = "Закрытие позиции: перерыв"
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
    ui_state.trends = string.format( "%.3f / %.3f (%.3f)"
                                   , state.fastPrice:getTrend()
                                   , state.slowPrice:getTrend()
                                   , state.market.fastPrice - state.market.slowPrice
                                   )
    ui_state.averages = string.format( "%.3f / %.3f / %.0f - %.0f"
                                     , state.fastPrice:getAverage()
                                     , state.slowPrice:getAverage()
                                     , state.market.bid, state.market.offer
                                     )
    ui_state.deviations = string.format( "%.3f / %.3f"
                                       , state.fastPrice:getDeviation()
                                       , state.slowPrice:getDeviation()
                                       )
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
    ui_state.volume = string.format( "%.0f / %.0f / %.0f"
                                   , buyVolume - sellVolume
                                   , buyVolume
                                   , sellVolume
                                   )
                                   
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

function strategy:calcMinBidMaxOffer(l2)
    l2 = l2 or self:getQuoteLevel2()

    local maxVolume = self.state.lotSize:getAverage()*self.etc.maxAverageLots

    local demand = 0
    local minBid = l2.bid[l2.bid_count].price + self.etc.priceStepSize
    for i = 0, #l2.bid - 1 do
        local q = l2.bid[l2.bid_count - i]
        demand = demand + q.quantity
        minBid = q.price
        if demand + q.quantity > maxVolume then
            break
        end
    end
    local offer, maxOffer = 0, l2.offer[1].price - self.etc.priceStepSize
    for i = 1, l2.offer_count do
        local q = l2.offer[i]
        offer = offer + q.quantity
        maxOffer = q.price
        if offer + q.quantity > maxVolume then
            break
        end
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

    market.fastPrice = state.fastPrice:getAverage()
    market.slowPrice = state.slowPrice:getAverage()
    local slowDeviation = state.slowPrice:getDeviation()

    market.fastTrend = state.fastPrice:getTrend()
    market.slowTrend = state.slowPrice:getTrend()
    market.fastTrend2 = state.fastPrice:getTrend2()

    market.maxPrice = market.slowPrice + slowDeviation
    market.minPrice = market.slowPrice - slowDeviation
    if market.fastTrend > etc.trendThreshold*state.fastPrice:getTrendDeviation() then
        market.minPrice = market.minPrice + slowDeviation*(1 - etc.confBand)
    elseif market.fastTrend < -etc.trendThreshold then
        market.maxPrice = market.maxPrice - slowDeviation*(1 - etc.confBand)
    end
    market.maxPrice = math.floor(market.maxPrice/etc.priceStepSize)*etc.priceStepSize
    market.minPrice = math.ceil(market.minPrice/etc.priceStepSize)*etc.priceStepSize

    market.minBid, market.maxOffer = self:calcMinBidMaxOffer(l2)
 end

function strategy:getForwardPrice(shift)
    return self.state.market.fastTrend*shift + self.state.market.fastTrend2*math.pow(shift, 2)/2
end

local lastTrend = 0
local volCount = 0
local prevVolCount = 0

-- function returns operation, price
function strategy:calcPlannedPos()

    local etc = self.etc
    local state = self.state
    local market = state.market
    local confBand = state.fastPrice:getDeviation()*etc.confBand
    local maxBand = state.fastPrice:getDeviation()
    local mean = (market.bid + market.offer)/2

    local loss = state.balance.maxValue - state.balance.currValue
    if loss > etc.maxLoss then
        self.state.state = string.format( "Превышение убытка (%.0f из %0f)"
                                        , loss
                                        , etc.maxLoss
                                        )
        state.plannedPos.op = false
        return
    end

    local nearShift = self:getForwardPrice(etc.nearForecast)
    local farShift = self:getForwardPrice(etc.nearForecast + etc.farForecast)

    if market.fastTrend > 0.25 then
        local basePrice = math.min(market.fastPrice + confBand, market.bid)
        local nearPrice = math.floor((basePrice + nearShift)/etc.priceStepSize)*etc.priceStepSize
        nearPrice = math.max(nearPrice, market.minBid + etc.priceStepSize)
        nearPrice = math.max(nearPrice, market.minPrice)
        local farPrice = math.floor((market.bid + farShift)/etc.priceStepSize)*etc.priceStepSize
        farPrice = math.min(farPrice, nearPrice + etc.maxSpread)
        farPrice = math.min(farPrice, market.maxOffer - etc.priceStepSize)
        farPrice = math.min(farPrice, market.maxPrice)
        
        local spread = farPrice - nearPrice
        local profit = spread/etc.priceStepSize*etc.priceStepValue - etc.dealCost*2
        state.plannedPos = { op = 'B', buyPrice = nearPrice, sellPrice = farPrice }
    elseif market.fastTrend < -0.25 then
        local basePrice = math.max(market.fastPrice - confBand, market.offer)
        local nearPrice = math.ceil((basePrice + nearShift)/etc.priceStepSize)*etc.priceStepSize
        nearPrice = math.min(nearPrice, market.maxOffer - etc.priceStepSize)
        nearPrice = math.min(nearPrice, market.maxPrice)
        local farPrice = math.ceil((market.offer + farShift)/etc.priceStepSize)*etc.priceStepSize
        farPrice = math.max(farPrice, nearPrice - etc.maxSpread)
        farPrice = math.max(farPrice, market.minBid + etc.priceStepSize)
        farPrice = math.max(farPrice, market.minPrice)
        local spread = nearPrice - farPrice
        local profit = spread/etc.priceStepSize*etc.priceStepValue - etc.dealCost*2
        state.plannedPos = { op = 'S', buyPrice = farPrice, sellPrice = nearPrice }
    else
        state.plannedPos = { op = false, buyPrice = market.bid, sellPrice = market.offer }
        self.state.state = "Не выраженный тренд"
    end

    if math.abs(market.fastTrend) > etc.maxTrend then
        lastTrend = market.fastTrend
        if prevVolCount > volCount or volCount == 0 then
            volCount = math.min(etc.maxQuiteTime, volCount + etc.volQuiteTime)
            prevVolCount = volCount
        end
    end

    local volIndicator = lastTrend*market.fastTrend
    if volIndicator <= 0 then
        prevVolCount = volCount
        volCount = (volCount > 0) and (volCount - 1) or 0
        lastTrend = (volCount > 0) and market.fastTrend or 0
    end
    if volIndicator > 0 or volCount > 0 then
        state.plannedPos.op = false
        self.state.state = "Высокая волатильность (" .. volCount .. ")"
    end

    if state.plannedPos.op then
        local spread = state.plannedPos.sellPrice - state.plannedPos.buyPrice
        local profit = spread/etc.priceStepSize*etc.priceStepValue - etc.dealCost*2
        if (profit <= 0) or (spread < etc.minSpread) then
            self.state.state = "Мониторинг"
            -- spread is not good enough to make profit 
            state.plannedPos.op = false
        end
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

    -- calculate enter price and operation
    self:calcPlannedPos()
    local maxError = etc.enterErrorThreshold*etc.priceStepValue

    if state.phase == PHASE_WAIT then

        if state.order:isActive() then
            local enterPrice = state.plannedPos.op == 'B' and state.plannedPos.buyPrice or state.plannedPos.sellPrice
            local bestOrder = (state.order.operation == 'B' and state.order.price >= market.bid) or
                              (state.order.operation == 'S' and state.order.price <= market.offer)
                
            if not state.plannedPos.op or 
                state.order.operation ~= state.plannedPos.op or 
                ((math.abs(enterPrice - state.order.price) >= maxError) and not bestOrder)
                or state.position ~= 0 and ( 
                    state.order.operation == 'B' and (market.offer > state.order.price + etc.priceStepSize) or
                    state.order.operation == 'S' and (market.bid < state.order.price - etc.priceStepSize)
                )
            then
                state.phase = PHASE_HOLD
                self.state.state = "Изменение цены входа"
                local res, err = state.order:kill()
                self:checkStatus(res, err)
                return
            end
        elseif state.plannedPos.op then
            local price, res, err = false, true, ""
            
            if state.plannedPos.op == 'B' then
                self.state.state = "Открытие лонг"
                res, err = state.order:send('B', state.plannedPos.buyPrice, self:getLimit())
            elseif state.plannedPos.op == 'S' then
                self.state.state = "Открытие шорт"
                res, err = state.order:send('S', state.plannedPos.sellPrice, self:getLimit())
            else
                res, err = false, "Запланирована недопустимая операция: " .. state.plannedPos.op .. 
                  string.format("(покупка: %.0f, продажа: %.0f)", state.plannedPos.buyPrice, state.plannedPos.sellPrice)
            end
            self:checkStatus(res, err)
        end
    elseif state.phase == PHASE_CLOSE then
        local price = state.order.price + self:getForwardPrice(etc.nearForecast + etc.farForecast)
        if state.order:isActive() then
            local kill = false
            if state.order.operation == 'B' then
                if state.order.price < market.minPrice or state.order.price < market.minBid then
                    kill = (state.order.price < market.bid)
                end
            elseif state.order.operation == 'S' then
                if state.order.price > market.maxPrice or state.order.price > market.maxOffer then
                    kill = (state.order.price > etc.priceStepSize)
                end
            end
            if kill then
                self.state.state = "Изменение цены"
                local res, err = state.order:kill()
                self:checkStatus(res, err)
                state.phase = PHASE_PRICE_CHANGE
            end
        elseif state.position > 0 then
            if state.order.price + etc.minSpread < market.offer then
                price = market.offer - etc.priceStepSize
            else
                price = math.floor(price/etc.priceStepSize)*etc.priceStepSize
                price = math.max(price, state.order.price + etc.minSpread)
                price = math.min(price, state.order.price + etc.maxSpread)
                price = math.min(price, market.maxOffer - etc.priceStepSize)
                price = math.max(price, market.offer - 2*etc.priceStepSize)
            end
            price = math.min(price, market.maxPrice)
            self.state.state = "Закрытие позиции"
            local res, err = state.order:send('S', price, state.position)
            self:checkStatus(res, err)
        else -- position is strictly negative
            if state.order.price - etc.minSpread > market.bid then
                price = market.bid + etc.priceStepSize
            else
                price = math.ceil(price/etc.priceStepSize)*etc.priceStepSize
                price = math.min(price, state.order.price - etc.minSpread)
                price = math.max(price, state.order.price - etc.maxSpread)
                price = math.max(price, market.minBid + etc.priceStepSize)
                price = math.min(price, market.bid + 2*etc.priceStepSize)
            end
            price = math.max(price, market.minPrice)
            self.state.state = "Закрытие позиции"
            local res, err = state.order:send('B', price, -state.position)
            self:checkStatus(res, err)
        end
    elseif state.phase == PHASE_PRICE_CHANGE then
        local sellPrice = market.offer - etc.priceStepSize
        local buyPrice =  market.bid + etc.priceStepSize
        local maxPrice = market.offer + state.fastPrice:getDeviation()/2
        local minPrice = market.bid - state.fastPrice:getDeviation()/2
        if math.abs(market.fastTrend) > etc.maxTrend then
            sellPrice = market.bid
            buyPrice = market.offer
        end
        if state.order:isActive() then
            local kill = false
            if state.order.operation == 'B' then
                if (state.order.price < minPrice) and (state.order.price < (buyPrice - etc.priceStepSize)) or
                    state.order.price < market.minBid 
                then
                    kill = true
                end
            elseif state.order.operation == 'S' then
                if (state.order.price > maxPrice) and (state.order.price > (sellPrice + etc.priceStepSize)) or 
                    state.order.price > market.maxOffer
                then
                    kill = true
                end
            end
            if kill then
                self.state.state = "Изменение цены"
                local res, err = state.order:kill()
                self:checkStatus(res, err)
            end
        else
            local res, err = true, ""
            if state.position > 0 then
                res, err = state.order:send('S', sellPrice, state.position)
            elseif state.position < 0 then
                res, err = state.order:send('B', buyPrice, -state.position)
            end
            state.phase = PHASE_CLOSE
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
        self.ui_state.lastError = "Ошибка: " .. err
        self.ui_state.state = "Приостановка (" .. self.state.state .. ")"
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
