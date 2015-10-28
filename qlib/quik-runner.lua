--[[
#
# Простейший исполнитель стратегий 
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

runner = {}

function runner.create(strategy, etc)
    require("qlib/quik-logger")
    require("qlib/quik-table")

    local extra_ui_mapping = { 
        {name="state", title="Cостояние", ctype=QTABLE_STRING_TYPE, width=14, format="%s" },
    }

    local ui_mapping = {}
    for _, col in ipairs(strategy.ui_mapping) do
        table.insert(ui_mapping, col)
    end

    for _, col in ipairs(extra_ui_mapping) do
        table.insert(ui_mapping, col)
    end

    local self = {
        strategy = strategy,
        etc = {
            asset = strategy.etc.asset,
            class = strategy.etc.class,

            ordersLog = "logs/orders-%Y-%m-%d.log",
            replyLog  = "logs/orders-replies-%Y-%m-%d.log",
            tradesLog = "logs/trade-events-%Y-%m-%d.log",
            allTradesLog = "logs/all-trade-events-%Y-%m-%d.log",
            account = "SPBFUT005Z5",

            limit = 0.3, -- 30% from money limit

            depoSell = 0,
            depoBuy = 0,
            priceMin = 0,
            priceMax = 0,
        },
        logs = {
            ordersLog = false,
            replyLog = false,
            tradesLog = false,
            allTradesLog = false,
        },
        day = false,
        pos = 0,
        tradingEnabled = false,
        manualHalt = false,
        ui_mapping = ui_mapping,
        qtable = qtable.create(strategy.title .. ".wpos", strategy.title, ui_mapping),
        state = {
            state = "--",
            err = false,
        },
    }
    etc = etc or { }
    etc, self.etc = self.etc, etc -- swap

    setmetatable( self.etc, { __index = etc } )

    local ordersLogColumns = {"date-time", "unix-time", 
            "TRANS_ID", "TRANS_CODE", "SECCODE", "CLASSCODE", "ACTION", "ACCOUNT", "TYPE", 
            "OPERATION", "EXECUTE_CONDITION", "QUANTITY", "PRICE", "status"}

    local replyLogColumns = {"date-time", "unix-time", "trans_id", "status", "result_msg", "time", "uid",
            "flags", "server_trans_id", "order_num", "price", "quantity", "balance", "account", 
            "class_code", "sec_code"}

    local tradesLogColumns = {"date-time", "unix-time",
            "trade_num", "order_num", "account", "price", "qty", "value", "accruedint", "yield", "settlecode",
            "flags", "price2", "block_securities", "block_securities", "exchange_comission", 
            "tech_center_comission", "sec_code", "class_code"}

    local function dateTimeAsStr(unixTime, ms)
        ms = ms and string.format("%02d", ms) or ""
        return os.date("%Y-%m-%dT%H-%M-%S", math.floor(unixTime)) .. ms
    end

    local function enrichRecord(record)
        local datetime = record.datetime
        local ms = datetime and datetime.ms or nil
        local tstamp = os.time(datetime)
        record["date-time"] = dateTimeAsStr(tstamp, ms)
        record["unix-time"] = tstamp
    end

    local function checkLogs()
        local day = math.floor(os.time()/3600/24)

        if day ~= self.day then
            for _, log in pairs(self.logs) do
                if log then 
                    log.close()
                end
            end
            self.logs.ordersLog = csvlog.create(self.etc.ordersLog, ordersLogColumns)
            self.logs.replyLog =  csvlog.create(self.etc.replyLog, replyLogColumns)
            self.logs.tradesLog = csvlog.create(self.etc.tradesLog, tradesLogColumns)
            self.logs.allTradesLog = csvlog.create(self.etc.allTradesLog, tradesLogColumns)
        end
    end

    local function getMaxPos(expected)
        local n = getNumberOf("futures_client_limits")
        local moneyLimit = 0
        local lastAcc = ''
        for i = 0, n - 1 do
            local row = getItem("futures_client_limits", i)
            if row.trdaccid == self.etc.account then
                moneyLimit = row.cbplimit*self.etc.limit
                break
            end
        end
   
        if expected < 0 then
            expected = -math.floor(moneyLimit/self.etc.depoSell)
        else
            expected =  math.floor(moneyLimit/self.etc.depoBuy)
        end
        return expected
    end

    local function executePos(targetPos)
        if self.manualHalt then
            return
        end

        if not self.tradingEnabled then
            targetPos = 0
        end
    
        local diffPos = math.floor(targetPos - self.pos)

        local quantity, price, operation = 0, 0, ""

        if diffPos > 0 then
            quantity = diffPos
            price = self.etc.priceMax -- - self.params.priceStep
            operation = "B"
        elseif diffPos == 0 then
            return -- sanity check
        else -- diffPos < 0
            quantity = -diffPos
            price = self.etc.priceMax -- + self.params.priceStep
            operation = "S"
        end
        local transId = 1
        local n = getNumberOf("orders")
        if n > 0 then
            transId = getItem("orders", n - 1).trans_id + 10
        end
        local order = {
            TRANS_ID=string.format("%.0f", transId),
            CLASSCODE=self.etc.class,
            SECCODE=self.etc.asset,
            ACTION="NEW_ORDER",
            ACCOUNT=self.etc.account,
            TYPE="L",
            OPERATION=operation,
            EXECUTE_CONDITION="KILL_OR_FILL",
            QUANTITY=string.format("%.0f", quantity),
            PRICE=string.format("%0.f", price),
        }
        local res = "suicide" --sendTransaction(order)
        local tstamp = os.time()
        enrichRecord(order)
        order.status = res
        self.logs.ordersLog.write(order)
        if res == "" then
            self.pos = self.pos + diffPos
        end
    end

    local r = { }

    local lastHash = ""

    local function logStatus()
        -- calculate status
        if self.manualHalt then
            self.state.state = "Ручная остановка"
        elseif not self.tradingEnabled then
            self.state.state = "Держать 0"
        elseif self.err then
            self.state.state = self.err
        else
            self.state.state = "Торговля"
        end

        local state = {}
        local hash = ""
        for _, k in ipairs(self.ui_mapping) do
            local v = self.state[k.name] or self.strategy.state[k.name] or "--"
            state[k.name] = v
            hash = hash .. "[" .. k.name .. "=" .. v .. "]"
        end
        if hash ~= lastHash  then
            --message("addrow " .. hash, 3)
            self.qtable.addRow(state)
            lastHash = hash
        end
    end

    local function updateDepoAndPrices()
        self.etc.depoBuy = getParamEx(self.etc.class, self.etc.asset, "BUYDEPO").param_value
        self.etc.depoSell = getParamEx(self.etc.class, self.etc.asset, "SELLDEPO").param_value
        self.etc.priceMin = getParamEx(self.etc.class, self.etc.asset, "PRICEMIN").param_value
        self.etc.priceMax = getParamEx(self.etc.class, self.etc.asset, "PRICEMAX").param_value
    end

    local function onStartStopCallback()
        self.tradingEnabled = not self.tradingEnabled
    end

    local function onHaltCallback()
        self.manualHalt = not self.manualHalt
    end

    function r.onIdle()
        self.qtable.onIdle()
        checkLogs()
        
        logStatus()
        updateDepoAndPrices()
    end

    function r.onAllTrade(trade)
        enrichRecord(trade)
        self.logs.tradesLog.write(trade)

        local signal, err = strategy.onTrade(trade)
        if err and type(err) == "string" then
            self.state.err = err
        else
            self.state.err = false
        end
        if not signal then
           return
        end
        if signal > 0 then
            signal = 0
        elseif signal < 0 then
            signal = 0
        end
        local expectedPos = getMaxPos(signal)
        executePos(expectedPos)
    end

    function r.onTransReply(reply)
        enrichRecord(reply)
        self.logs.replyLog.write(reply)
    end

    function r.onTrade(trade)
        enrichRecord(trade)
        self.logs.tradesLog.write(trade)
    end

    function r.isClosed()
        return self.qtable.isClosed()
    end

    checkLogs()
    updateDepoAndPrices()
    self.qtable.setStartStopCallback(onStartStopCallback)
    self.qtable.setHaltCallback(onHaltCallback)

    local n = getNumberOf("futures_client_holding")
    for i = 0,n-1 do
        local row = getItem("futures_client_holding", i)
        if row.sec_code == self.params.asset then
            self.pos = row.totalnet
            break
        end
    end

    return r
end
