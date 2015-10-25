--[[
#
# Простейшая стратегия основанная на скользящих средних
# с параболлической адаптацией
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

adaptive_ma = {
    etc = { -- master configuration
        asset = "RIZ5",
        class = "SPBFUT",

        adaptiveFactor = 1.5e-3,

        -- tracking trend
        avgFactorFast = 0.0001,
        avgFactorSlow = 1.0434375e-05,

        -- tracking deviation
        avgFactor = 0.01415019375,        -- tracking trend
        avgFactorM2 = 0.01,

        -- how many trades ignore in very beggining
        ignoreFirst = 300,
        paramsInfo = {
            avgFactor = { min=2.2204460492503131e-16, max=1, step=0.01, relative=true },
            avgFactorFast = { min=2.2204460492503131e-16, max=1, step=0.01, relative=true },
            avgFactorSlow = { min=2.2204460492503131e-16, max=1, step=0.01, relative=true },
            adaptiveFactor = { min=2.2204460492503131e-16, max=1, step=0.01, relative=true },  
        },
    },

    ui_mapping = {
        {name="asset", title="Бумага", ctype=QTABLE_STRING_TYPE, width=8, format="%s" },
        {name="lastPrice", title="Цена", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="avgPriceFast", title="Средняя цена 1", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="avgPriceSlow", title="Средняя цена 2",  ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="deviation",title="Стд. Отклонение", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.2f" },
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
            lastPrice = 0,
            avgPriceFast = 0,
            avgPriceSlow = 0,
            deviation = 0,
            charFunction = 0,

            meanPrice = nil,    -- super fast average
            dispersion = 0,
            deviation = 0,

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
        ui_mapping = adaptive_ma.ui_mapping,
        etc = { }, -- readonly
        state = {
            asset = self.etc.asset,
            lastPrice = 0,
            avgPriceFast = 0,
            avgPriceSlow = 0,
            deviation = 0,
            charFunction = 0,
        }
    }

    copyValues(self.etc, strategy.etc, self.etc)

    -- the main function: accepts trade market data flow  on input 
    -- returns target position:
    --   0 - do not hold
    --   1 - long
    --  -1 - short
    function strategy.onTrade(trade)
        -- filter out alien trades
        local etc = self.etc
        if trade.sec_code ~= etc.asset or trade.class_code ~= etc.class then
            return
        end
    
        -- process averages
        local price = trade.price
        local state = self.state
        if not state.meanPrice then
            -- the very first trade
            state.avgPriceFast = price
            state.avgPriceSlow = price
            state.meanPrice = price
        end

        local function average(v0, v1, k)
            return v0 + k*(v1 - v0)
        end

        local function adaptiveAverage(v0, v1, k)
            local adaptedK = k + math.min(etc.avgFactor - k, ((state.meanPrice - v0)/price)^2*etc.adaptiveFactor)
            return average(v0, v1, adaptedK)
        end

        state.lastPrice = trade.price
        state.tradeCount = state.tradeCount + 1

        -- super fast moving average and deviation
        state.meanPrice = average(state.meanPrice, price, etc.avgFactor)
        local dispersion = (price - state.meanPrice)^2
        state.dispersion = average(state.dispersion, dispersion, etc.avgFactorM2)
        state.deviation = state.dispersion^0.5

        -- fast avergage
        state.avgPriceFast = adaptiveAverage(state.avgPriceFast, price, etc.avgFactorFast)
        state.avgPriceSlow = adaptiveAverage(state.avgPriceSlow, price, etc.avgFactorSlow)

        local charFunction = state.avgPriceFast - state.avgPriceSlow
        state.charFunction = charFunction

        -- Standard ration of deviations of two averaged values will be the same as
        -- ratio of their averaging factors. So the strategy threshold should be equal 
        -- to 3 sums of slow and fast deviations

        local signal = 0
        if state.tradeCount > etc.ignoreFirst then
            local threshold = 3*state.deviation*(etc.avgFactorFast + etc.avgFactorSlow)/etc.avgFactor
            if charFunction > threshold then
                signal = 1
            elseif charFunction < -threshold then
                signal = -1
            end
        end

        -- update UI state
        copyValues(state, strategy.state, strategy.state)

        return signal
    end
    return strategy
end
