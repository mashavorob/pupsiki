--[[
#
# Простейшая стратегия основанная на скользящих средних
# с парраболической адаптацией
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc

New parameters found:   Yes
Total income before optimization:   20220
Total income after optimization:    30820
Best parameters are:
    'avgFactor' = 0.038510508617885
    'adaptiveFactor' = 1
    'avgFactor2' = 0.037163967443485
    'avgFactor1' = 0.038824708287165
]]

adaptive_ma = {
    etc = { -- master configuration
        asset = "RIZ5",
        class = "SPBFUT",

        avgFactor = 0.038510508617885,
        adaptiveFactor= 1,

        -- tracking trend
        avgFactor1 = 0.038824708287165,
        avgFactor2 = 0.037163967443485,

        -- wait for stat
        ignoreFirst = 10,

        paramsInfo = {
            avgFactor = { min=2.2204460492503131e-16, max=1, step=1, relative=true },
            adaptiveFactor = { min=2.2204460492503131e-16, max=1, step=1, relative=true },
            avgFactor1 = { min=2.2204460492503131e-16, max=1, step=1, relative=true },
            avgFactor2 = { min=2.2204460492503131e-16, max=1, step=1, relative=true },

        },
        schedule = {
            { from = { hour=9, min=30 }, to = { hour=21, min=00 } } 
        }
    },

    ui_mapping = {
        {name="asset", title="Бумага", ctype=QTABLE_STRING_TYPE, width=8, format="%s" },
        {name="lastPrice", title="Цена", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="avgPrice1", title="Средняя цена 1", ctype=QTABLE_DOUBLE_TYPE, width=17, format="%.0f" },
        {name="avgPrice2", title="Средняя цена 2",  ctype=QTABLE_DOUBLE_TYPE, width=17, format="%.0f" },
        {name="charFunction", title="Очарование", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
    }
}

function adaptive_ma.create(etc)

    local function copyValues(src, dst, master)
        for k, v in pairs(master) do
            local v1 = src[k] 
            if v1 then
                dst[k] = v1
            end
        end
    end

    local self = {
        etc = { },

        state = {
            lastPrice = false,
            meanPrice = 0,
            avgPrice1 = 0,
            avgPrice2 = 0,
            charFunction = 0,
            tradeCount = 0,
        }
    }
    -- copy master configuration
    copyValues(adaptive_ma.etc, self.etc, adaptive_ma.etc)
    -- overwrite parameters
    if etc then
        copyValues(etc, self.etc, self.etc)
    end

    local strategy = {
        title = "adaptive--[" .. self.etc.class .. "-" .. self.etc.asset .. "]",
        ui_mapping = adaptive_ma.ui_mapping,
        etc = { }, -- readonly
        state = self.state,
    }
    self.state.asset = self.etc.asset

    copyValues(self.etc, strategy.etc, self.etc)

    -- the main function: accepts trade market data flow  on input 
    -- returns target position:
    --   0 - do not hold
    --   1 - long
    --  -1 - short
    function strategy.onTrade(trade, datetime)
        -- filter out alien trades
        local etc = self.etc
        if trade.sec_code ~= etc.asset or trade.class_code ~= etc.class then
            return
        end

        datetime = datetime or trade.datetime

        -- process averages
        local price = trade.price
        local state = self.state
        if not state.lastPrice then
            -- the very first trade
            state.meanPrice = price
            state.avgPrice1 = price
            state.avgPrice2 = price
        end

        local function average(v0, v1, k)
            return v0 + k*(v1 - v0)
        end

        local function adaptiveAverage(v0, v1, k)
            local diff = (state.meanPrice - v0)/state.meanPrice
            local ak = math.min(etc.avgFactor, k + diff^2*etc.adaptiveFactor)
            return v0 + ak*(v1 - v0)
        end

        state.lastPrice = trade.price
        state.meanPrice = average(state.meanPrice, price, etc.avgFactor)
        state.avgPrice1 = adaptiveAverage(state.avgPrice1, price, etc.avgFactor1)
        state.avgPrice2 = adaptiveAverage(state.avgPrice2, price, etc.avgFactor2)

        local charFunction = state.avgPrice1 - state.avgPrice2
        state.charFunction = charFunction

        state.tradeCount = state.tradeCount + 1
        local signal = 0
        if state.tradeCount > etc.ignoreFirst then
            if charFunction > 0 then
                signal = 1
            elseif charFunction < 0 then
                signal = -1
            end
        end

        -- update UI state
        strategy.state = state

        -- check schedule
        local function makeTimeStamp(datetime)
            return datetime.hour*3600 + (datetime.min or 0)*60 + (datetime.sec or 0)
        end

        local currTime = makeTimeStamp(datetime)
        local tradingAllowed = false
        local status = false
        
        for _, row in ipairs(etc.schedule) do
            local from = makeTimeStamp(row.from)
            local to = makeTimeStamp(row.to)
            --print(currtime, from, to)
            if currTime >= from and currTime < to then
                tradingAllowed = true
                break
            end
        end

        if not tradingAllowed then
            signal = 0
            status = "Hынок закрыт"
        end
        return signal, status
    end
    return strategy
end
