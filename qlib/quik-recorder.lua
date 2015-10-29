--[[
#
# Запись маркетных данных 
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

recorder = {}

function recorder.create(etc)
    require("qlib/quik-logger")
    require("qlib/quik-table")

    local self = {
        strategy = strategy,
        etc = {
            logs = {
                allTradesLog = "logs/all-trade-events-%Y-%m-%d.log",
            },
        },
        logs = {
            allTradesLog = false,
        },
        day = false,
        ui_mapping = { 
            {name="state", title="Cостояние", ctype=QTABLE_STRING_TYPE, width=14, format="%s" },
        },
        state = {
            state = "Запись",
        },
        qtable = false,
    }
    etc = etc or { }
    etc, self.etc = self.etc, etc -- swap
    setmetatable( self.etc, { __index = etc } )

    self.qtable = qtable.create("quik-recorder.wpos", "Рекордер", self.ui_mapping)

    local function dateTimeAsStr(unixTime, ms)
        ms = ms and string.format(".%03d", ms) or ""
        return os.date("%Y-%m-%dT%H-%M-%S", math.floor(unixTime)) .. ms
    end

    local function enrichRecord(record)
        local datetime = record.datetime
        local ms = datetime and datetime.ms or nil
        local tstamp = os.time(datetime)
        record["date-time"] = dateTimeAsStr(tstamp, ms)
        record["unix-time"] = tstamp
    end

    local logColumns = {
        allTradesLog = {"date-time", "unix-time",
            "trade_num", "flags", "price", "qty", "value", "accruedint", "yield", "settlecode", 
            "sec_code", "class_code"},
    }

    local function checkLogs()
        for log, fname in pairs(self.etc.logs) do
            fname = os.date(fname)
            if not self.logs[log] or fname ~= self.logs[log].getFileName() then
                local oldLog = self.logs[log]
                self.logs[log] = csvlog.create(fname, logColumns[log])
                if oldLog then
                    oldLog.close()
                end
            end
        end
    end

    local r = { }

    local lastHash = ""

    local function logStatus()
        local state = {}
        local hash = ""
        for _, k in ipairs(self.ui_mapping) do
            local v = self.state[k.name] or self.strategy.state[k.name] or "--"
            state[k.name] = v
            hash = hash .. "[" .. k.name .. "=" .. v .. "]"
        end
        if hash ~= lastHash  then
            self.qtable.addRow(state)
            lastHash = hash
        end
    end

    function r.onIdle()
        self.qtable.onIdle()
        checkLogs()
        logStatus()
    end

    function r.onAllTrade(trade)
        enrichRecord(trade)
        self.logs.allTradesLog.write(trade)
    end

    function r.isClosed()
        return self.qtable.isClosed()
    end

    function r.onClose()
        for _, log in pairs(self.logs) do
            if log then 
                log.close()
            end
        end
    end

    checkLogs()

    return r
end
