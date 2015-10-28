--[[
#
# Скользящее среднее
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local strategyRunner = false

local etc = {
    asset="RIZ5",
    sname = "adaptive_ma",
}

function OnInit(scriptPath)

    if not LUA_PATH then
        LUA_PATH = ""
    end
    if LUA_PATH ~= "" then
        LUA_PATH = LUA_PATH .. ";"
    end

    local function rfind(s, subs)
        local npos = string.find(s, subs, 1, true)
        local nextPos = pos
        while nextPos do
            npos = nextPos
            nextPos = string.find(s, subs, npos + 1, true)
        end
    end
    local npos = rfind(scriptPath, "\\") or rfind(scriptPath, "//")
    local folder = npos and string.sub(srciptPath, 1, npos - 1) or scriptPath
    LUA_PATH = LUA_PATH .. ".\\?.lua;" .. folder .. "\\?.lua"

    assert(require("qlib\\quik-runner"))
    assert(require("strategies\\" .. etc.sname))

    local factory = assert(_G[etc.sname])
    local strategy = assert(factory.create(etc))

    strategyRunner = assert(runner.create(strategy, etc))
end

function OnAllTrade(trade)
    strategyRunner.onAllTrade(trade)
end

function OnTransReply(reply)
    strategyRunner.onTransReply(reply)
end

function OnTrade(trade)
    strategyRunner.onTrade(trade)
end

function main()
    while not strategyRunner.isClosed() do
        strategyRunner.onIdle()
        sleep(100)
    end
end

--[[dofile("qlib\\quik-table.lua" )

today = os.date("*t")

local function getCurrTimeOfDay()
    return os.time() % (24*3600)
end

local function getTimeOfDay(val)
    local utime = os.time({year=today.year, month=today.month, day=today.day,
        hour=val.hour, min=val.min, sec=val.sec})
    return utime % (24*3600)
end

function CreateStrategy(params)

    columns = {
        {name="asset", title="Бумага", ctype=QTABLE_STRING_TYPE, width=8, format="%s" },
        {name="lastPrice", title="Цена", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="avgPriceFast", title="Ср. цена 1", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="avgPriceSlow", title="Ср. Цена 2",  ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="deviation",title="Стд. отклонение", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.2f" },
        {name="charFunction", title="Очарование", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="currPos", title="Позиция", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="targetPos", title="Рсч. Позиция", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
        {name="status", title="Состояние", ctype=QTABLE_STRING_TYPE, width=15, format="%s" },
        {name="message", title="Дополнительно", ctype=QTABLE_STRING_TYPE, width=64, format="%s" },
    }

    t = qtable.create(params.confFolder, params.title, columns)
  
    local maxLines = 50

    local self = {
        params=params,
        qtable=t,
        
        asset=params.asset,
        lastPrice=0,
        avgPriceFast=0,
        avgPriceSlow=0,
        dispersion=0,
        deviation=0,
        charFunction=0,
        currPos=0,
        targetPos=0,
        status="Подготовка",
        message="",
        tradeCount=0,
        pendingOrder=0,
      }

      local function onStartStop()
            self.params.manualHalt = not self.params.manualHalt
      end

      self.qtable.setStartStopCallback(onStartStop)

      local function getLogFileName(suffix)
            local folder = self.params.logFolder 
            return folder .. "\\" .. "log-" .. suffix .. "-"
                .. os.date("%Y-%m-%d") .. ".txt"
      end

      local function logRecordToFile(suffix, header, pred)
            local fname = getLogFileName(suffix)
            self.logs = self.logs or {}
            self.logs[suffix] = self.logs[suffix] or {}
            if self.logs[suffix].fname  ~= fname then
                local h = self.logs[suffix].fhandle
                if h then
                    h:close()
                end  
                self.logs[suffix] = {
                    fname = fname,
                    fhandle = assert(io.open(fname, "a"))
                }
                self.logs[suffix].fhandle:write(header .. "\n")
            end
            local h = self.logs[suffix].fhandle
            pred(h)
            h:flush()
        end

    local function logTrade(trade)
        logRecordToFile(
              "trades"
            , "asset, class, date-time, unix-time-stamp, flags (1=sell, 0=buy), quantity"
        , function(handle)
            handle:write(
                 trade.sec_code .. ","
              .. trade.class_code .. ","
              .. trade.datetime.year .. "-" .. trade.datetime.month .. "-" .. trade.datetime.day 
              .. "T" .. trade.datetime.hour .. "-" .. trade.datetime.min .. "-" .. (trade.datetime.sec + trade.datetime.ms/1000) .. ","
              .. os.time(trade.datetime) .. ","
              .. trade.flags .. ","
              .. trade.qty
              .. "\n"
              )
          end
        )
    end
    
    local function logState()
        local tstamp = os.time()
        local date = os.date("%Y-%m-%dT%H-%M-%S", tstamp)
            logRecordToFile(
                  "data"
                , "asset, class, date-time, unix-time-stamp, last price, average price fast, average price slow, char function"
                , function(handle)
                        handle:write(
                               self.params.asset .. ","
                            .. self.params.class .. ","
                            .. date .. ","
                            .. tstamp .. ","
                            .. self.lastPrice .. ","
                            .. self.avgPriceFast .. ","
                            .. self.avgPriceSlow .. ","
                            .. self.charFunction
                            .. "\n"
                            )
                    end
            )
    end

    local function reportState()
        self.qtable.addRow( self )
        logState()
    end

    local function updateStatus(newStatus, newMessage)
        local status = newStatus or self.status
        local msg = newMessage or self.message
        if status ~= self.status or msg ~= self.message then
            self.status = status
            self.message = (newMessage or "")
            reportState()
        end
    end

    local function calcMA(prevAvg, value, avgFactor)
        return prevAvg + avgFactor*(value - prevAvg)
    end

    local function getMaxPos(expected)
        local n = getNumberOf("futures_client_limits")
        local moneyLimit = 0
        local lastAcc = ''
        for i = 0, n - 1 do
            local row = getItem("futures_client_limits", i)
            if row.trdaccid == self.params.account then
                moneyLimit = row.cbplimit*self.params.limit
                break
            end
        end
   
        if expected < 0 then
            expected = -math.floor(moneyLimit/self.params.depoSell)
        else
            expected =  math.floor(moneyLimit/self.params.depoBuy)
        end
        return expected
    end

    local function calcPosition()
        local targetPos = 0
        local charFunction = self.charFunction
        local threshold = self.params.threshold
    
        if charFunction > threshold then
            targetPos = 1 
        elseif charFunction < -threshold then
            targetPos = -1
        end
        self.targetPos = getMaxPos(targetPos)
    end

    local function checkSchedule()
        local now = getCurrTimeOfDay()

        for k, period in ipairs(self.params.schedule) do
            if now >= period.from and now < period.to then
                return true,          -- market open
                       period.trading -- trading enabled
            end
        end
        return false, false    
    end

    local function executePos()
        if self.pedingOrder then
            return
        end

        local open, tradingEnabled = checkSchedule()
        if not open then
            updateStatus("Рынок закрыт")
            return
        end

        local currPos = self.currPos
        local targetPos = self.targetPos
    
        if not tradingEnabled or self.params.manualHalt then
            targetPos = 0
        end
    
        local diffPos = math.floor(targetPos - self.currPos)

        if self.params.manualHalt then
            updateStatus("Остановка")
        elseif not tradingEnabled then
            updateStatus("Закрытие")
        elseif diffPos == 0 then
            updateStatus("Удержание")
            return
        else
            updateStatus("Торговля")
        end
        local quantity, price, operation = 0, 0, ""

        if diffPos > 0 then
            quantity = diffPos
            price = getParamEx(self.params.class, self.params.asset, "PRICEMAX").param_value -- - self.params.priceStep
            operation = "B"
        elseif diffPos == 0 then
            return -- sanity check
        else -- diffPos < 0
            quantity = -diffPos
            price = getParamEx(self.params.class, self.params.asset, "PRICEMIN").param_value -- + self.params.priceStep
            operation = "S"
        end
        local transId = 1
        local n = getNumberOf("orders")
        if n > 0 then
            transId = getItem("orders", n - 1).trans_id + 10
        end
        local order = {
            TRANS_ID=string.format("%.0f", transId),
            CLASSCODE=self.params.class,
            SECCODE=self.params.asset,
            ACTION="NEW_ORDER",
            ACCOUNT=self.params.account,
            TYPE="L",
            OPERATION=operation,
            EXECUTE_CONDITION="KILL_BALANCE",
            QUANTITY=string.format("%.0f", quantity),
            PRICE=string.format("%0.f", price),
            COMMENT="pupsik-ma",
        }
        local res = sendTransaction(order)
        local msg="Заявка отправлена(" .. diffPos .."): "
        if res ~= "" then
            updateStatus(false, msg .. res)
            assert(false)
        else
            self.currPos = self.currPos + diffPos
            updateStatus(false, msg .. "OK")
        end
    end

    local s = { }
    function s.onTrade(trade, tstamp)
        if trade.sec_code ~= self.params.asset or trade.class_code ~= self.params.class then
            return
        end
        logTrade(trade)
        tstamp = tstamp or os.time(trade.datetime)

        -- calculate characteristics
        local price = trade.price
        self.lastPrice = price
        if self.tradeCount == 0 then
            self.avgPriceFast, self.avgPriceSlow = price, price
        end
        self.avgPriceFast = calcMA(self.avgPriceFast, price, self.params.avgFactorFast)
        self.avgPriceSlow = calcMA(self.avgPriceSlow, price, self.params.avgFactorSlow)
        local dispersion = (self.avgPriceFast - price)^2
        self.dispersion = calcMA(self.dispersion, dispersion, self.params.avgFactorM2)
        self.deviation = self.dispersion ^ 0.5
        self.charFunction = self.avgPriceFast - self.avgPriceSlow
        self.tradeCount = self.tradeCount + 1

        calcPosition()

        reportState() 
    end
    function s.isClosed()
        return self.qtable.isClosed()
    end
  
    function s.onIdle()
        executePos()
        self.qtable.onIdle()
    end
    function s.onTransReply(reply)
        local trans_id = reply.trans_id
        local n = getNumberOf("orders")
        for i=1,n do
            local index = n - i
            local order = getItem("orders", index)
            if order.trans_id == trans_id then
                local flags = order.flags
                if bit.band(flags, 1) ~= 0 then
                    message("Заявка не исполнена", 3)
                    assert(false, "Заявка не исполнена вовремя", 3)
                end
                if bit.band(flags, 2) ~= 0 then
                    updateStatus(false, "Заявка снята")
                    return
                end
                local diff = order.qty - order.balance
                if bit.band(flags, 4) ~= 0 then
                    diff = -diff -- sell order
                end
                self.currPos = self.currPos + diff
                self.pendingOrder = false
                message("qty: " .. order.qty .. " balance: " .. order.balance .. " diff: " .. diff, 3)
                assert(false, "halt")
                return
            end
        end
        message("order not found", 3)
        assert(false, "order not found")
    end

    local n = getNumberOf("futures_client_holding")
    for i = 0,n-1 do
        local row = getItem("futures_client_holding", i)
        if row.sec_code == self.params.asset then
            self.currPos = row.totalnet
        end
    end

    local n = getNumberOf("all_trades")
    local c = 0
    local trades = {}
    for i = 1, n do
        local index = n - i
        local trade = getItem("all_trades", index)
        if trade.sec_code == self.params.asset and trade.class_code == self.params.class then
            c = c + 1
            trades[c] = trade
            if c > self.params.minTrades then
                break
            end
        end
    end
    for i = 0, c-1 do
        local index = c - i
        local trade = trades[index]
        s.onTrade(trade, trade.datetime)
    end 
    return s
end

function OnAllTrade(trade)
    if own then
        own.onTrade(trade)
    end
end

function OnTransReply(reply)
    --own.onTransReply(reply)
end

function main()
    local params = { 
        title="Пупсик - скользящее среднее [РТС]",
        name="pupsik-ma",
        asset="RIZ5",    -- asset code
        class="SPBFUT",  -- class code
        account="SPBFUT005Z5",
        priceStep=0,     -- see below
        limit=0.3,       -- maximum position (relative to deposit)

        avgFactorFast=0.01,
        avgFactorSlow=0.005,
        avgFactorM2=0.05,
    
        threshold=0.2,   -- multiplier to standart deviation

        pendingOrder=false,

        schedule = {
            {from=getTimeOfDay({hour=10, min=00, sec=00}), to=getTimeOfDay({hour=21, min=45, sec=00}), trading=true},
            {from=getTimeOfDay({hour=21, min=45, sec=00}), to=getTimeOfDay({hour=22, min=00, sec=00}), trading=false},
        },
        manualHalt=true,
        minTrades=100,
    }

    params.priceStep=getParamEx(params.class, params.asset, "SEC_PRICE_STEP").param_value
    params.depoBuy=getParamEx(params.class, params.asset, "BUYDEPO").param_value
    params.depoSell=getParamEx(params.class, params.asset, "SELLDEPO").param_value
  
    local suffix = params.name .. "-" .. params.asset .. "-" .. params.class 
    params.logFolder=getScriptPath() .. "\\logs-" .. suffix
    params.confFolder=getScriptPath() .. "\\conf-" .. suffix
    local own = CreateStrategy(params)
    while not own.isClosed() do
        sleep(100)
        own.onIdle()
    end
end]]
