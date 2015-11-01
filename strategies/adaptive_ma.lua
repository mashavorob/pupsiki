--[[
# ���������� ��������� ���������� �� ���������� �������
# � ��������������� ����������
#
# vi: ft=lua:fenc=cp1251 
#
# ���� �� ������ ��������� ��� ������ �� ��� ���������
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc

New parameters found:   Yes
Total income before optimization:   15972
Total income after optimization:    16112
Best parameters are:
    'adaptiveFactor' = 1
    'avgFactor1' = 0.038824708287165
    'avgFactor' = 0.037525081989791
    'avgFactor2' = 0.037309139191311
]]

require("qlib/quik-etc")

adaptive_ma = {
    etc = { -- master configuration
        asset = "RIZ5",
        class = "SPBFUT",
        title = "adaptive-ma",
        confFolder = "conf",

        avgFactor = 0.037525081989791,
        adaptiveFactor= 2,

        -- tracking trend
        avgFactor1 = 0.038824708287165,
        avgFactor2 = 0.037309139191311,

        -- wait for stat
        ignoreFirst = 10,

        paramsInfo = {
            avgFactor = { min=2.2204460492503131e-16, max=1, step=1, relative=true },
            adaptiveFactor = { min=2.2204460492503131e-16, max=1, step=1, relative=true },
            avgFactor1 = { min=2.2204460492503131e-16, max=1, step=1, relative=true },
            avgFactor2 = { min=2.2204460492503131e-16, max=1, step=1, relative=true },

        },
        schedule = {
            { from = { hour=10, min=30 }, to = { hour=21, min=00 } } 
        }
    },

    ui_mapping = {
        {name="asset", title="������", ctype=QTABLE_STRING_TYPE, width=8, format="%s" },
        {name="lastPrice", title="����", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="avgPrice1", title="������� ���� 1", ctype=QTABLE_DOUBLE_TYPE, width=17, format="%.0f" },
        {name="avgPrice2", title="������� ���� 2",  ctype=QTABLE_DOUBLE_TYPE, width=17, format="%.0f" },
        {name="charFunction", title="�����", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
    }
}

function adaptive_ma.create(etc)

    local self = {
        etc = config.create(adaptive_ma.etc),

        state = {
            asset = "",
            class = "",
            lastPrice = false,
            meanPrice = 0,
            avgPrice1 = 0,
            avgPrice2 = 0,
            charFunction = 0,
            tradeCount = 0,
        }
    }

    self.etc:load()
    if ( etc ) then
        self.etc:merge(etc)
    end

    local strategy = {
        title = self.etc.title .. "-[" .. self.etc.class .. "-" .. self.etc.asset .. "]",
        ui_mapping = adaptive_ma.ui_mapping,
        etc = self.etc,
        state = self.state,
    }
    self.state.asset = self.etc.asset

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
            status = "H���� ������"
        end
        return signal, status
    end
    return strategy
end
