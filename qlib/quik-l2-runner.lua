--[[
#
# Исполнитель l2-стратегий 
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot q_runner:ad the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_config = require("qlib/quik-etc")
local q_fname = require("qlib/quik-fname")
local q_table = require("qlib/quik-table")

local q_runner = {}

function q_runner.create(strategy, etc)
    local self =
        { strategy = false
        , etc = q_config.create
            { asset = "RIZ5"
            , class = "SPBFUT"
            , account = "SPBFUT005B2"
            }
        , logFile = false
        , day = false
        , qtable = false
        }
    setmetatable(self, {__index = q_runner})

    self.strategy = strategy
    self.etc = q_config.create( self.etc )
    self.qtable = q_table.create(strategy.title .. ".wpos", strategy.title, strategy.ui_mapping)
    self.etc.logFileName = "logs/eventlog-" .. strategy.etc.class .. "-" .. strategy.etc.asset .. "-%Y-%m-%d.log"

    etc = etc or { }
    self.etc:merge(etc)

    local function onStartStopCallback()
        self.strategy:onStartStopCallback()
    end

    local function onHaltCallback()
        self.strategy:onHaltCallback()
    end

    self.qtable.setStartStopCallback(onStartStopCallback)
    self.qtable.setHaltCallback(onHaltCallback)
    self.strategy:init()
    return self
end

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

function q_runner:checkLogs()
    local fname = q_fname.normalize(os.date(self.etc.logFileName))
    if not self.logFile or not self.logFileName or self.logFileName ~= fname then
        if self.logFile then
            self.logFile:close()
        end
        self.logFileName = fname
        self.logFile = io.open(fname, "a")
    end
end

local lastHash = ""

function q_runner:logStatus()
    local state = {}
    local hash = ""
    for _, k in ipairs(self.strategy.ui_mapping) do
        local v = self.strategy.ui_state[k.name] or "--"
        state[k.name] = v
        hash = hash .. "[" .. k.name .. "=" .. v .. "]"
    end
    if hash ~= lastHash  then
        self.qtable.addRow(state)
        lastHash = hash
    end
end

function q_runner:onIdle()
    self.qtable.onIdle()
    self:checkLogs()
    self:logStatus()
    self.strategy:onIdle()
end

function q_runner:onAllTrade(trade)
    enrichRecord(trade)
    self.strategy:onAllTrade(trade)
end

function q_runner:onTransReply(reply)
    enrichRecord(reply)
    self.strategy:onTransReply(reply)
    if self.logFile then
        self.logFile:write(string.format("transReply trans_id=%d status=%d order_num=%s\n"
            , reply.trans_id
            , reply.status
            , tostring(reply.order_num)
            ))
    end
    self:logStatus()
end

function q_runner:onOrder(data)
    enrichRecord(data)
    self.strategy:onOrder(data)
    if self.logFile then
        self.logFile:write(string.format("onOrder %s %d@%.4f trans_id=%d order_num=%d balance=%d active=%s\n"
            , (bit.band(data.flags, 4) ~= 0) and "SELL" or "BUY"
            , data.qty
            , data.price
            , data.trans_id
            , data.order_num
            , data.balance
            , (bit.band(data.flags, 1) ~= 0) and "True" or "False"
            ))
    end
    self:logStatus()
end

function q_runner:onTrade(trade)
    enrichRecord(trade)
    self.strategy:onTrade(trade)
    
    if self.tstamp then
        trade["event-tstamp"] = self.tstamp
        trade.delay = os.time(trade.datetime) + trade.datetime.ms/1000 - self.tstamp
    end
    if self.logFile then
        self.logFile:write(string.format("trade %.0f@%.4f trans_id=%d order_num=%d trade_num=%d\n"
            , trade.qty, trade.price
            , trade.trans_id
            , trade.order_num
            , trade.trade_num
            ))
    end
end

function q_runner:onQuote(class, asset)
    self.strategy:onQuote(class, asset)
    self:logStatus()
end

function q_runner:onDisconnected()
    self.strategy:onDisconnected()
end

function q_runner:isClosed()
    return self.qtable.isClosed()
end

function q_runner:onClose()
    if self.logFile then
        self.logFile:close()
    end
end

return q_runner
