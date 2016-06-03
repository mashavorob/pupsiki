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

require("qlib/quik-etc")
require("qlib/quik-logger")
require("qlib/quik-table")
require("qlib/quik-fname")

q_runner = {}

function q_runner.create(strategy, etc)
    local self =
        { strategy = false
        , etc = config.create
            { asset = "RIZ5"
            , class = "SPBFUT"
            , logs =
                { -- ordersLog = "logs/orders[L2-SPBFUT-RIZ5]-2015-11-11.log",
                  -- replyLog  = "logs/orders-replies[L2-SPBFUT-RIZ5]-2015-11-11.log",
                  -- tradesLog = "logs/trade-events[L2-SPBFUT-RIZ5]-2015-11-11.log" ,
                  -- allTradesLog = "logs/all-trade-events[L2-SPBFUT-RIZ5]-2015-11-11.log" ,
                }
            , account = "SPBFUT005B2"
            }
        , logs =
            { ordersLog = false
            , replyLog = false
            , tradesLog = false
            , allTradesLog = false
            }
        , day = false
        , qtable = false
        }
    setmetatable(self, {__index = q_runner})

    self.strategy = strategy
    self.etc = config.create( q_runner.etc )
    self.qtable = qtable.create(strategy.title .. ".wpos", strategy.title, strategy.ui_mapping)
    self.etc.logs = {
        ordersLog = "logs/orders[L2-" .. strategy.etc.class .. "-" .. strategy.etc.asset .. "]-%Y-%m-%d.log",
        replyLog  = "logs/orders-replies[L2-" .. strategy.etc.class .. "-" .. strategy.etc.asset .. "]-%Y-%m-%d.log",
        tradesLog = "logs/trade-events[L2-" .. strategy.etc.class .. "-" .. strategy.etc.asset .. "]-%Y-%m-%d.log",
        allTradesLog = "logs/all-trade-events[L2-" .. strategy.etc.class .. "-" .. strategy.etc.asset .. "]-%Y-%m-%d.log",
    }

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

local logColumns = {
    ordersLog = {"date-time", "unix-time", 
        "TRANS_ID", "TRANS_CODE", "SECCODE", "CLASSCODE", "ACTION", "ACCOUNT", "TYPE", 
        "OPERATION", "EXECUTE_CONDITION", "QUANTITY", "PRICE", "status"},
    replyLog = {"date-time", "unix-time", "trans_id", "status", "time", "uid",
        "flags", "server_trans_id", "order_num", "price", "quantity", "balance", "account", 
        "class_code", "sec_code"},
    tradesLog = {"date-time", "unix-time", "event-tstamp", "delay",
        "trade_num", "order_num", "account", "price", "qty", "value", "accruedint", "yield", "settlecode",
        "flags", "price2", "block_securities", "block_securities", "exchange_comission", 
        "tech_center_comission", "sec_code", "class_code"},
    allTradesLog = {"date-time", "unix-time",
        "trade_num", "flags", "price", "qty", "value", "accruedint", "yield", "settlecode", 
        "sec_code", "class_code"},
}


function q_runner:checkLogs()
    for log, fname in pairs(self.etc.logs) do
        fname = q_fname.normalize(os.date(fname))
        if not self.logs[log] or fname ~= self.logs[log].getFileName() then
            local oldLog = self.logs[log]
            self.logs[log] = csvlog.create(fname, logColumns[log])
            if oldLog then
                oldLog.close()
            end
        end
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
    self.logs.allTradesLog.write(trade)
    self:logStatus()
end

function q_runner:onTransReply(reply)
    enrichRecord(reply)
    self.strategy:onTransReply(reply)
    self.logs.replyLog.write(reply)
end

function q_runner:onTrade(trade)
    enrichRecord(trade)
    self.strategy:onTrade(trade)
    
    if self.tstamp then
        trade["event-tstamp"] = self.tstamp
        trade.delay = os.time(trade.datetime) + trade.datetime.ms/1000 - self.tstamp
    end
    self.logs.tradesLog.write(trade)
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
    for _, log in pairs(self.logs) do
        if log then 
            log.close()
        end
    end
end


