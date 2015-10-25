
local function CreateTable(title, cols)

  self = { 
    id=assert(AllocTable()),
    caption=title,
    columns=cols,
    colByName={}
  }

  for i, col in ipairs(self.columns) do
    self.colByName[col.name] = i
  end

  for i=1, table.getn(self.columns) do
    local col = self.columns[i]
    local res = AddColumn(self.id, i - 1, col.title, true, col.ctype, col.width)
    if res == 0 then error("AddColumn ('" .. col.name .. "') returned bad status" .. err) end
  end

  local res = InsertRow(self.id, -1)
  assert(res > -1)
  
  local res = CreateWindow(self.id)
  if res == 0 then error("CreateWindow returned bad status") end
  assert(SetWindowCaption(self.id, self.caption), "SetWindowCaption() returned bad status")

  local function func_isClosed()
    return IsWindowClosed(self.id)
  end

  local function func_setRow(row, data)
    for colName,val in pairs(data) do
      local colIndex = self.colByName[colName]
      local formatedVal = string.format(self.columns[colIndex].format, val)
      SetCell(self.id, row, colIndex - 1, formatedVal)
    end
  end

  local function func_addRow(data)
    func_setRow(InsertRow(self.id, -1), data)
  end

  local function func_getNumRows()
    local n = GetTableSize(self.id)
    return n
  end

  local t = {
    isClosed = func_isClosed,
    setRow = func_setRow,
    addRow = func_addRow,
    getNumRows = func_getNumRows,
  }
  return t;
end

function CreateMarket(flt)

  columns = {
    {name="Asset", title="Бумага", ctype=QTABLE_STRING_TYPE, width=8, format="%s" },
    {name="Price", title="Цена", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.0f" },
    {name="Deviation", title="Отклонение", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.2f" },
    {name="Trend", title="Трэнд", ctype=QTABLE_STRING_TYPE, width=9, format="%s" },
    {name="TradeSpeed", title="Объем/сек", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.2f" },
    {name="BuySpeed", title="Покупка/сек", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.2f" },
    {name="SellSpeed", title="Продажа/сек", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.2f" },
    {name="DemandSpeed", title="Cпрос/сек", ctype=QTABLE_DOUBLE_TYPE, width=15, format="%.2f" },
  }

  t = CreateTable(flt.title, columns)
  
  local maxLines = 50

  local self = {
    filter = flt,
    qtable = t,
    meanPrice = 0,
    dispersion = 0,
    prevPrice = 0,
    trade  = { },
    buy    = { },
    sell   = { },
    demand = { },
  }

  local function calcAverage( pred )
    local count = 0
    local summ = 0
    local n = getNumberOf("all_trades")

    for i = 1, n do
      index = n - i
      ln = getItem("all_trades", index)
      if ln.sec_code == self.filter.asset and ln.class_code == self.filter.class then
        summ = summ + pred(ln)
        count = count + 1
        if count > maxLines then
          break
        end
      end
    end
    if count > 0 then summ = summ/count end
    return summ
  end

  local function getSpeed( data )
    if data.firstTime == nil or data.firstTime == data.lastTime then
      return 0
    end
    v1 = data.volume/(data.lastTime - data.firstTime)
    if data.v == nil then
      return v1
    end
    return data.v + self.filter.avgFactor4Speed*(v1 - data.v)
  end

  local function updateSpeed(tstamp, value, data)
    if data.firstTime == nil then
      data.firstTime = tstamp
      data.lastTime = tstamp
      return
    end
    if data.firstTime == tstamp or data.lastTime > tstamp then
      return
    end
    if data.lastTime == tstamp then
      data.volume = data.volume + value
      return
    end
    data.v = getSpeed(data)
    data.firstTime = data.lastTime
    data.lastTime = tstamp
    data.volume = value
  end

  local function calcSpeed(pred)
    local count = 0
    local n = getNumberOf("all_trades")
    local acc = { }

    local tprev = 0
    local index = 0
    local tstamp = 0
    -- pass 1: find the first trade
    for i = 1, n do
      index = n - i
      ln = getItem("all_trades", index)
      if ln.sec_code == self.filter.asset and ln.class_code == self.filter.class then
        local val = pred(ln)
        tstamp = os.time(ln.datetime)
        if tstamp ~= tprev then
          tprev = tstamp
          count = count + 1
          if count > maxLines then
            break
          end
        end
      end
    end
    -- pass 2: accumulate results
    for i = index, n do
      ln = getItem("all_trades", i)
      if ln.sec_code == self.filter.asset and ln.class_code == self.filter.class then
        local val = pred(ln)
        local tstamp = os.time(ln.datetime)
        updateSpeed(tstamp, val, acc)
      end
    end
    return acc
  end

  self.meanPrice = calcAverage( function(x) return x.price end )
  self.dispersion = calcAverage( function(x) return (x.price - self.meanPrice)^2 end )
  self.prevPrice = self.meanPrice
  self.trade = calcSpeed( function(trade) return trade.qty end )
  self.buy = calcSpeed( function(trade) return (trade.flags == 2) and trade.qty or 0 end)
  self.sell = calcSpeed( function(trade) return (trade.flags == 1) and trade.qty or 0 end)
  self.demand = calcSpeed( function(trade) return (trade.flags == 2) and trade.qty or -trade.qty end)

  local function getLogFileName(suffix)
    return getScriptPath() .. "\\" .. "log-" 
      .. self.filter.asset .. "-" .. self.filter.class .. "-" .. suffix .. "-"
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
      , "asset, class, date-time, unix-time-stamp, price, standard deviation, trade/sec, buy/sec, sell/sec, demand/sec"
      , function(handle)
          handle:write(
             self.filter.asset .. ","
          .. self.filter.class .. ","
          .. date .. ","
          .. tstamp .. ","
          .. self.meanPrice .. ","
          .. self.dispersion^0.5 .. ","
          .. getSpeed(self.trade) .. ","
          .. getSpeed(self.buy) .. ","
          .. getSpeed(self.sell) .. ","
          .. getSpeed(self.demand)
          .. "\n"
          )
        end
     )
  end

  local function reportState()
    local tick = "--"
    if self.meanPrice > self.prevPrice then
      tick = "up"
    elseif self.meanPrice < self.prevPrice then
      tick = "down"
    end
    self.qtable.addRow( {
      Asset=self.filter.asset,
      Price=self.meanPrice, 
      Deviation=self.dispersion^0.5, 
      Trend=tick,
      TradeSpeed=getSpeed(self.trade),
      BuySpeed=getSpeed(self.buy),
      SellSpeed=getSpeed(self.sell),
      DemandSpeed=getSpeed(self.demand),
    } )
    logState()
  end

  local m = {
    onTrade = function(trade, tstamp)
      if trade.sec_code ~= self.filter.asset or trade.class_code ~= self.filter.class then
        return
      end
      logTrade(trade)
      tstamp = tstamp or os.time(trade.datetime)
      local k = self.filter.avgFactor4Price
      self.prevPrice = self.meanPrice
      self.meanPrice = self.meanPrice + k*(trade.price - self.meanPrice)
      self.dispersion = self.dispersion + k*((self.meanPrice - trade.price)^2 - self.dispersion)
      updateSpeed(tstamp, trade.qty, self.trade)
      if trade.flags == 2 then
        updateSpeed(tstamp, trade.qty, self.buy)
        updateSpeed(tstamp, 0, self.sell)
        updateSpeed(tstamp, trade.qty, self.demand)
      else
        updateSpeed(tstamp, 0, self.buy)
        updateSpeed(tstamp, trade.qty, self.sell)
        updateSpeed(tstamp, -trade.qty, self.demand)
      end
      reportState() 
    end,
    isClosed = function()
      return self.qtable.isClosed()
    end,
  }
  reportState()
  return m
end

function OnAllTrade(trade)
  if own then
    own.onTrade(trade)
  end
end

function main()
  local params = { 
    title="Пупсик - РТС",
    asset='RIZ5',    -- asset code
    class='SPBFUT',  -- class code
    avgFactor4Price=0.2,
    avgFactor4Speed=0.2,
    
    enterThreshold=2,
    leaveThreshold=0.5,
    
    
  }
  own = CreateMarket(params)
  while not own.isClosed() do
    sleep(10)
  end
end
