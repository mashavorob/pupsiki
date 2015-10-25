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
]]

simple_ma = {
    etc = { -- master configuration
        asset = "RIZ5",
        class = "SPBFUT",

        -- tracking trend
        avgFactorFast = 5e-6,
        avgFactorSlow = 1e-06,

        -- tracking deviation
        avgFactor = 0.01672825,
        avgFactorM2 = 0.09,
        paramsInfo = {
            avgFactor = { min=2.2204460492503131e-16, max=1, step=0.1, relative=true },
            avgFactorFast = { min=2.2204460492503131e-16, max=1, step=0.1, relative=true },
            avgFactorSlow = { min=2.2204460492503131e-16, max=1, step=0.1, relative=true },
            avgFactorM2 = { min=2.2204460492503131e-16, max=1, step=0.1, relative=true },
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

function simple_ma.create(etc)

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
        }
    }
    -- copy master configuration
    copyValues(simple_ma.etc, self.etc, simple_ma.etc)
    -- overwrite parameters
    if etc then
        copyValues(etc, self.etc, self.etc)
    end

    local strategy = {
        ui_mapping = simple_ma.ui_mapping,
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

        state.lastPrice = trade.price
        state.avgPriceFast = average(state.avgPriceFast, price, etc.avgFactorFast)
        state.avgPriceSlow = average(state.avgPriceSlow, price, etc.avgFactorSlow)

        state.meanPrice = average(state.meanPrice, price, etc.avgFactor)
        local dispersion = (price - state.meanPrice)^2
        state.dispersion = average(state.dispersion, dispersion, etc.avgFactorM2)
        state.deviation = state.dispersion^0.5

        local charFunction = state.avgPriceFast - state.avgPriceSlow
        state.charFunction = charFunction

        -- Standard ration of deviations of two averaged values will be the same as
        -- ratio of their averaging factors. So the strategy threshold should be equal 
        -- to 3 sums of slow and fast deviations

        local threshold = 3*state.deviation*(etc.avgFactorFast + etc.avgFactorSlow)/etc.avgFactor
        local signal = 0
        if charFunction > threshold then
            signal = 1
        elseif charFunction < -threshold then
            signal = -1
        end

        -- update UI state
        copyValues(state, strategy.state, strategy.state)

        return signal
    end
    return strategy
end
