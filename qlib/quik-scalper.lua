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
require("qlib/quik-avg")
require("qlib/quik-order")
require("qlib/quik-labels")
require("qlib/quik-utils")

local q_scalper = {
    etc = { -- master configuration

        -- Главные параметры, задаваемые в ручную
        asset = "RIH6",         -- бумага
        class = "SPBFUT",       -- класс
        title = "qscalper - [RIH6]",     -- заголовок таблицы

        -- Параметры вычисляемые автоматически
        account = "SPBFUT005eC",
        firmid =  "SPBFUT589000",

        priceStepSize = 10,     -- granularity of price (minimum price shift)
        priceStepValue = 12,    -- price of price step (price of minimal price shift)
        minSpread = 1,          -- минимальный спрэд
        maxSpread = 2,          -- максимальный спрэд

        -- Параметры задаваемые вручную
        absPositionLimit = 1,   -- максимальная приемлемая позиция (абсолютное ограничение)
        relPositionLimit = 0.3, -- максимальная приемлемая позиция по отношению к размеру счета

        maxLoss = 700,          -- максимальная приемлимая потеря

        avgFactorFast = 30,     -- "быстрый" коэффициент осреднения
        avgFactorSlow = 150,    -- "медленный" коэфициент осреднения
        avgFactorLot = 200,     -- коэффициент осреднения размера лота (сделки)

        maxImbalance = 5,       -- максимально приемлимый дисбаланс стакана против тренда
        maxAverageLots = 40,    -- ставить позиции не далее этого количества средних лотов
                                -- от края стакана (средний размер сделки = средний лот)

        nearForecast = 12,      -- прогноз цены (открытие сделки)
        farForecast = 75,       -- прогноз цены (закрытие сделки)

        dealCost = 2,           -- биржевой сбор
        enterErrorThreshold = 1,-- предельная ошибка на входе (шагов цены)
        
        confBand = 0.5,         -- "доверительный диапазон" (в среднеквадратических отклонениях)
        trendThreshold = 0.8,   -- превышение величины тренда этого порога означает уверенный 
                                -- рост или снижение без вероятности скорого разворота
                                -- пороговое значение задается в стандартных отклонениях тренда

        params = {
            { name="avgFactorFast", min=1, max=1e32, step=1, precision=1e-4 },
            { name="avgFactorSlow", min=1, max=1e32, step=1, precision=1e-4 },
        },
        -- расписание работы
        schedule = {
            { from = { hour=10, min=01, sec=00 }, to = { hour=12, min=55, sec=00 } }, -- 10:01 - 12:55
            { from = { hour=13, min=01, sec=00 }, to = { hour=13, min=55, sec=00 } }, -- 13:01 - 13:55
            { from = { hour=14, min=16, sec=00 }, to = { hour=15, min=45, sec=00 } }, -- 14:16 - 15:45
            { from = { hour=16, min=01, sec=00 }, to = { hour=18, min=55, sec=00 } }, -- 16:01 - 18:55
            { from = { hour=19, min=01, sec=00 }, to = { hour=21, min=55, sec=00 } }, -- 19:01 - 21:55
        },
    },

    ui_mapping = {
        { name="control", title="Упавление", ctype=QTABLE_STRING_TYPE, width=12, format="%s" },
        { name="position", title="Позиция", ctype=QTABLE_DOUBLE_TYPE, width=10, format="%.0f" },
        { name="trend", title="Трэнд", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.3f" },
        { name="averages", title="Средние", ctype=QTABLE_STRING_TYPE, width=32, format="%s" },
        { name="deviations", title="Ст. отклонения", ctype=QTABLE_STRING_TYPE, width=25, format="%s" },
        { name="balance", title="Доход/Потери", ctype=QTABLE_STRING_TYPE, width=25, format="%s" },
        { name="spread", title="Cпред", ctype=QTABLE_STRING_TYPE, width=22, format="%s" },
        { name="state", title="Состояние", ctype=QTABLE_STRING_TYPE, width=40, format="%s" },
        { name="lastError", title="Результат последняя операции", ctype=QTABLE_STRING_TYPE, width=80, format="%s" }, 
    },
}

_G["quik-scalper"] = q_scalper

local strategy = {}

local PHASE_WAIT            = 0
local PHASE_ENTER           = 1
local PHASE_CLOSE           = 2
local PHASE_PRICE_CHANGE    = 3
local PHASE_CANCEL          = 4

local MAX_LABELS = 100
local INTERVAL = 60

function q_scalper.create(etc)

    local self = { 
        title = "scalper",
        etc = config.create(q_scalper.etc),
        ui_mapping = q_scalper.ui_mapping,
        ui_state = {
            position = 0,
            trend = "--",
            spread = "-- / --",
            status = "--",
            balance = "-- / --",
            lastError = "--", 
            averages = "-- / -- / --",
            deviations = "-- / -- / --",
        },
        state = {
            halt = false,   -- immediate stop
            pause = true,   -- temporary stop
            cancel = true,  -- closing current position

            phase = PHASE_WAIT,

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
                trend = 0,
                minPrice = 0,
                maxPrice = 0,
                fastPrice = 0,
            },

            fastPrice = { },
            slowPrice = { },
            lotSize = { },

            order = { },

            labelFactory = q_label.createFactory("RI-Price", {r=180,g=180,b=0}, q_fname.normalize("qpict/slow.bmp")),

            labels = { },
            lastLabel = 0,
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
    self.state.lotSize = q_avg.createEx(self.etc.avgFactorLot, 1)

    self.state.order = q_order.create(self.etc.account, self.etc.class, self.etc.asset)

    self.state.position = q_utils.getPos(self.etc.asset)

    self:updateParams()

    -- walk through all trade
    local first = 0
    local last = getNumberOf("all_trades")
    assert(last > 0, "Таблица всех сделок пустая, старт невозможен\n" .. debug.traceback())
    local n = last
    local d = getItem("all_trades", last - 1).datetime
    local startTime = os.time(d) - INTERVAL*MAX_LABELS

    while first < last - 2 do
        local m = math.floor((first + last)/2)
        local trade = getItem("all_trades", m)
        local tm = os.time(trade.datetime)
        if tm < startTime then
            first = m
        elseif tm > startTime then
            last = m
        else
            first = m
            last = m
        end
    end

    for i = first, n - 1 do
        local trade = getItem("all_trades", i)
        local currTime = os.time(trade.datetime)
        if trade.sec_code == self.etc.asset and trade.class_code == self.etc.class and self:checkSchedule(currTime) then
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
                l2.bid[1].price = l2.bid[1].price - 2*self.etc.priceStepSize
            else
                l2.offer[1].price = l2.offer[1].price + 2*self.etc.priceStepSize
            end

            local price = (l2.bid[1].price + l2.offer[1].price)/2

            self.state.fastPrice:onValue(price)
            self.state.slowPrice:onValue(price)

            self:calcMarketParams(l2)
            self.state.lotSize:onValue(trade.qty)

            self:updateLabels(currTime)
        end
    end
    Subscribe_Level_II_Quotes(self.etc.class, self.etc.asset)
end

function strategy:updatePosition()
    local state = self.state
    state.position = state.position + state.order.position
    state.order.position = 0
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
    self:updatePosition()
    self:onMarketShift()
end

function strategy:onAllTrade(trade)
    if trade.class_code ~= self.etc.class or trade.sec_code ~= self.etc.asset then
        return
    end
    self.state.lotSize:onValue(trade.qty)
end

local prevPrice = -1

function strategy:onQuote(class, asset)
    if class ~= self.etc.class or asset ~= self.etc.asset then
        return
    end

    local l2 = self:getQuoteLevel2()

    local bid = tonumber(l2.bid[l2.bid_count].price)
    local offer = tonumber(l2.offer[1].price)
    local price = (bid + offer)/2

    --if price ~= prevPrice then
        prevPrice = price

        self.state.fastPrice:onValue(price)
        self.state.slowPrice:onValue(price)

        self:updatePosition()
        self:onMarketShift(l2)
        self:updateLabels()
    --end
end

function strategy:onIdle()
    q_order.onIdle()
    self:updateLabels()

    local state = self.state
    local ui_state = self.ui_state

    self:updatePosition()

    local balance = q_utils.getBalance(self.etc.account)
    state.balance.maxValue = math.max(state.balance.maxValue, balance)
    state.balance.currValue = balance

    ui_state.balance = string.format( "%.0f / %.0f"
                                    , state.balance.currValue - state.balance.atStart
                                    , state.balance.currValue - state.balance.maxValue
                                    )

    ui_state.position = state.position
    ui_state.trend = state.fastPrice:getTrend()
    ui_state.lotSize = state.lotSize:getAverage()
    ui_state.averages = string.format( "%.2f / %.3f / %.4f"
                                     , state.fastPrice:getAverage(0)
                                     , state.fastPrice:getAverage(1)
                                     , state.fastPrice:getAverage(2)
                                     )

    ui_state.deviations = string.format( "%.2f / %.3f / %.4f"
                                       , state.fastPrice:getDeviation(0)
                                       , state.fastPrice:getDeviation(1)
                                       , state.fastPrice:getDeviation(2)
                                       )

    if state.cancel then
        ui_state.control = "Ликвидация"

        local active = state.order:isActive() or state.order:isPending()

        if state.phase ~= PHASE_CANCEL and state.order:isActive() then
            local res, err = state.order:kill()
            self:checkStatus(res, err)
        end

        if not active then
            if state.position > 0 then
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
    if state.pause then
        ui_state.control = "Пауза"
    elseif state.halt then
        ui_state.control = "Остановка"
    elseif not self:checkSchedule() then
        ui_state.control = "Остановка по расписанию"
    else
        ui_state.control = "Работа"
    end
    ui_state.lastError = "--"
end

local lastTime = 0

function strategy:updateLabels(currTime)
    local etc = self.etc
    local state = self.state
    local market = state.market

    local initial = false
    if currTime then
        currTime = currTime - 1
        initial = true
    else
        currTime = os.time()
    end
    local currTime = math.floor((currTime - 1)/INTERVAL)*INTERVAL
    if initial and (currTime == lastTime) then
        return
    end

    if currTime == lastTime and #state.labels > 0 then
        state.labels[#state.labels - 1]:update(market.maxPrice, currTime)
        state.labels[#state.labels - 0]:update(market.minPrice, currTime)
    else
        local factor = #state.labels

        table.insert(state.labels, self.state.labelFactory:add(market.maxPrice, currTime))
        table.insert(state.labels, self.state.labelFactory:add(market.minPrice, currTime))

        factor = #state.labels - factor

        while #state.labels > factor*MAX_LABELS do
            local label = state.labels[1]
            table.remove(state.labels, 1)
            label:remove()
        end
    end
    lastTime = currTime
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

function strategy:calcOfferDemand(l2)
    l2 = l2 or self:getQuoteLevel2()
    local demand, offer = 0, 0
    for i = 0, math.min(5, l2.bid_count) - 1 do
        local q = l2.bid[l2.bid_count - i]
        demand = demand + q.quantity
    end
    for i = 1, math.min(5, l2.offer_count) do
        local q = l2.offer[i]
        offer = offer + q.quantity
    end
    return offer, demand
end

function strategy:calcMinBidMaxOffer(l2)
    l2 = l2 or self:getQuoteLevel2()

    local maxVolume = self.state.lotSize.average*self.etc.maxAverageLots

    local demand = 0
    local minBid = l2.bid[l2.bid_count].price + self.etc.priceStepSize
    for i = 0, #l2.bid - 1 do
        local q = l2.bid[l2.bid_count - i]
        if demand + q.quantity > maxVolume then
            break
        end
        demand = demand + q.quantity
        minBid = q.price
    end
    local offer, maxOffer = 0, l2.offer[1].price - self.etc.priceStepSize
    for i = 1, l2.offer_count do
        local q = l2.offer[i]
        if offer + q.quantity > maxVolume then
            break
        end
        offer = offer + q.quantity
        maxOffer = q.price
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

    local slowDeviation = state.slowPrice:getDeviation()
    local slowPrice = state.slowPrice:getAverage()

    market.trend = state.fastPrice:getTrend()
    market.maxPrice = slowPrice + slowDeviation
    market.minPrice = slowPrice - slowDeviation
    if market.trend > etc.trendThreshold*state.fastPrice:getTrendDeviation() then
        market.minPrice = market.minPrice + slowDeviation*(1 - etc.confBand)
    elseif market.trend < -etc.trendThreshold then
        market.maxPrice = market.maxPrice - slowDeviation*(1 - etc.confBand)
    end
    market.maxPrice = math.floor(market.maxPrice/etc.priceStepSize)*etc.priceStepSize
    market.minPrice = math.ceil(market.minPrice/etc.priceStepSize)*etc.priceStepSize

    market.fastPrice = state.fastPrice:getAverage()
end

-- function returns operation, price
function strategy:calcEnterOp()

    local etc = self.etc
    local state = self.state
    local market = state.market
    local offerVol, demandVol = self:calcOfferDemand(l2)
    local confBand = state.fastPrice:getDeviation()*etc.confBand
    local maxBand = state.fastPrice:getDeviation()
    local mean = (market.bid + market.offer)/2

    self.ui_state.spread = "-- / -- (--)"

    if market.trend > 0 then
        if offerVol/demandVol >= etc.maxImbalance then
            self.ui_state.state = "Неблагоприятный дисбаланс"
            return
        end
        if mean > market.fastPrice + maxBand then
            self.ui_state.state = "Неблагоприятное отклонение"
            return 'W'
        end
    end

    if market.trend < 0 then
        if demandVol/offerVol >= etc.maxImbalance then
            self.ui_state.state = "Неблагоприятный дисбаланс"
            return
        end
        if mean < market.fastPrice - maxBand then
            self.ui_state.state = "Неблагоприятное отклонение"
            return 'W'
        end
    end

    local loss = state.balance.maxValue - state.balance.currValue
    if loss > etc.maxLoss then
        self.ui_state.state = string.format( "Превышение убытка (%.0f из %0f)"
                                           , loss
                                           , etc.maxLoss
                                           )
        return
    end

    if market.trend > 0 then
        local basePrice = math.min(market.fastPrice + maxBand, market.bid)
        local nearPrice = math.floor((basePrice + market.trend*etc.nearForecast)/etc.priceStepSize)*etc.priceStepSize
        local farPrice = math.floor((market.bid + market.trend*etc.farForecast)/etc.priceStepSize)*etc.priceStepSize
        farPrice = math.min(farPrice, nearPrice + etc.maxSpread)
        farPrice = math.min(farPrice, market.maxPrice)
        local spread = farPrice - nearPrice
        local profit = spread/etc.priceStepSize*etc.priceStepValue - etc.dealCost*2
        self.ui_state.spread = string.format("%.0f / %.0f (%.0f)", nearPrice, farPrice, spread)
        if (profit <= 0) or (spread < etc.minSpread) then
            self.ui_state.state = "Мониторинг"
            return
        end
        return 'B', nearPrice
    elseif market.trend < 0 then
        local basePrice = math.max(market.fastPrice - maxBand, market.offer)
        local nearPrice = math.ceil((basePrice + market.trend*etc.nearForecast)/etc.priceStepSize)*etc.priceStepSize
        local farPrice = math.ceil((market.offer + market.trend*etc.farForecast)/etc.priceStepSize)*etc.priceStepSize
        farPrice = math.max(farPrice, nearPrice - etc.maxSpread)
        farPrice = math.max(farPrice, market.minPrice)
        local spread = nearPrice - farPrice
        local profit = spread/etc.priceStepSize*etc.priceStepValue - etc.dealCost*2
        self.ui_state.spread = string.format("%.0f / %.0f (%.0f)", farPrice, nearPrice, spread)
        if (profit <= 0) or (spread < etc.minSpread) then
            self.ui_state.state = "Мониторинг"
            return
        end
        return 'S', nearPrice
    end
end

function strategy:onMarketShift(l2)

    l2 = l2 or self:getQuoteLevel2()

    -- when clearing is in progress l2 data might be empty
    if l2.bid_count <= 1 or l2.offer_count <= 1 then
        return
    end
    
    self:calcMarketParams(l2)

    -- calculate enter price and operation
    local enterOp, enterPrice = self:calcEnterOp()

    local etc = self.etc
    local state = self.state
    local market = state.market

    if self.state.halt or self.state.cancel or self.state.pause then
        return
    end

    if state.order:isPending() then
        self.ui_state.state = "Отправка заявки"
        return
    end

    if state.position == 0 then
        if enterOp == 'W' then
            return
        end
        if state.order:isActive() then
            local maxError = etc.enterErrorThreshold*etc.priceStepValue
            if not enterOp or 
                state.order.operation ~= enterOp or 
                math.abs(enterPrice - state.order.price) >= maxError
            then
                self.ui_state.state = "Изменение цены входа"
                local res, err = state.order:kill()
                self:checkStatus(res, err)
                --state.phase = PHASE_PRICE_CHANGE
                return
            end
        elseif not self:checkSchedule() then
            return
        elseif enterOp then
            state.phase = PHASE_ENTER
            self.ui_state.state = "Отправка заявки на вход в " .. (enterOp == 'B' and 'лонг' or 'шорт')
            local res, err = state.order:send(enterOp, enterPrice, self:getLimit())
            self:checkStatus(res, err)
        else
            state.phase = PHASE_WAIT
        end
    else
        local price = state.order.price + market.trend*etc.farForecast
        if state.order:isActive() then
            local kill = false
            if state.order.operation == 'B' then
                if state.order.price < market.minPrice then
                    kill = true
                end
            elseif state.order.operation == 'S' then
                if state.order.price > market.maxPrice then
                    kill = true
                end
            end
            if kill then
                self.ui_state.state = "Изменение цены"
                local res, err = state.order:kill()
                self:checkStatus(res, err)
                state.phase = PHASE_PRICE_CHANGE
            else
                self.ui_state.state = "Ожидание исполнения заявки"
            end
        elseif state.position > 0 then
            if state.order.price + etc.minSpread <= market.offer - etc.priceStepSize then
                price = market.offer - etc.priceStepSize
            else
                price = math.floor(price/etc.priceStepSize)*etc.priceStepSize
                price = math.max(price, state.order.price + etc.minSpread)
                price = math.min(price, state.order.price + etc.maxSpread)
            end
            price = math.min(price, market.maxPrice)
            if state.phase == PHASE_PRICE_CHANGE then
                price = market.bid
            end
            state.phase = PHASE_CLOSE
            self.ui_state.state = "Отправка заявки на закрытие"
            local res, err = state.order:send('S', price, state.position)
            self:checkStatus(res, err)
        else -- position is strictly negative
            if state.order.price - etc.minSpread >= market.bid + etc.priceStepSize then
                price = market.bid + etc.priceStepSize
            else
                price = math.ceil(price/etc.priceStepSize)*etc.priceStepSize
                price = math.min(price, state.order.price - etc.minSpread)
                price = math.max(price, state.order.price - etc.maxSpread)
            end
            price = math.max(price, market.minPrice)
            if state.phase == PHASE_PRICE_CHANGE then
                price = market.offer
            end
            state.phase = PHASE_CLOSE
            self.ui_state.state = "Отправка заявки на закрытие"
            local res, err = state.order:send('B', price, -state.position)
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
        assert(false, "Unknown order has been killed\n" .. debug.traceback())
    end
    return true 
end

function strategy:killPosition()
    self.state.cancel = true
end
