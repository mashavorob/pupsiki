--[[
#
# Простейшая стратегия основанная на скользящих средних
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc

New parameters found:   Yes
Total income before optimization:   31012
Total income after optimization:    74128
Best parameters are:
    'avgFactor1' = 0.39088183765051
    'avgFactor2' = 0.15874429247025

]]

require("qlib/quik-etc")

simple_ma = {
    etc = { -- master configuration
        asset = "RIZ5",
        class = "SPBFUT",
        title = "adaptive-ma",
        confFolder = "conf",

        priceStep= 10,

        -- tracking trend
        avgFactor1 = 0.39088183765051,
        avgFactor2 = 0.15874429247025,

        -- wait for stat
        ignoreFirst = 10,

        paramsInfo = {
            avgFactor1 = { min=2.2204460492503131e-16, max=1, step=1, relative=true },
            avgFactor2 = { min=2.2204460492503131e-16, max=1, step=1, relative=true },
        },
        schedule = {
            { from = { hour=10, min=0 }, to = { hour = 21, min = 45 } } 
        }
    },

    ui_mapping = {
        {name="asset", title="Бумага", ctype=QTABLE_STRING_TYPE, width=8, format="%s" },
        {name="lastPrice", title="Цена", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="avgPrice1", title="Средняя цена 1", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="avgPrice2", title="Средняя цена 2",  ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="charFunction", title="Трэнд", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
    }
}

function simple_ma.create(etc)

    local self = {
        etc = config.create(simple_ma.etc),

        state = {
            lastPrice = false,
            avgPrice1 = 0,
            avgPrice2 = 0,
            charFunction = 0,
            tradeCount = 0,
        }
    }

    local strategy = {
        title = "simple-ma-[" .. self.etc.class .. "-" .. self.etc.asset .. "]",
        ui_mapping = simple_ma.ui_mapping,
        etc = self.etc,
        state = {
            asset = self.etc.asset,
            lastPrice = 0,
            avgPrice1 = 0,
            avgPrice2 = 0,
            charFunction = 0,
        }
    }

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
            state.avgPrice1 = price
            state.avgPrice2 = price
        end

        local function average(v0, v1, k)
            return v0 + k*(v1 - v0)
        end

        state.lastPrice = trade.price
        state.avgPrice1 = average(state.avgPrice1, price, etc.avgFactor1)
        state.avgPrice2 = average(state.avgPrice2, price, etc.avgFactor2)

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
            status = "Рынок закрыт"
        end
        return signal, status
    end
    return strategy
end
