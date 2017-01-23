#!/usr/bin/lua 
-- vi: ft=lua:fenc=cp1251 
--[[
#
# Тестировщик стратегий
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

LUA_PATH = "./?.lua"

os.setlocale("C")

q_log = require("qlib/quik-logger")

numericMin = 2.22507e-308
numericMax = 1.79769e+308
numericEpsilon = 2.22045e-16
transactionCost = 6
numSteps = 2
maxAttempts = 10
delay = 0.3


local function usage(args)
    print(args[0] .. "<operation> <strategy> <log> [<log> [<log> ..]")
    print("where:")
    print("", "<operation> could be:")
    print("", "", "--run, -r      - just run the strategy using logs")
    print("", "", "--optimize, -o - optimize the strategy parameters") 
    print("", "<strategy> could be name of any .lua file from strategies/ subfolder (without path and extension)")
    print("", "<log> could be any log file collected by recorder")
    print("", "      Note: log file must include the same assets as strategy")
end

local function loadStrategy(sname, etc)
    assert(pcall(require, "strategies/" .. sname)) --, "Unable to load strategy '" .. sname .. "'")
    local factory = assert(_G[sname], "cannot find factory for strategy '" .. sname .. "'")
    return assert(factory.create(etc), "Unable to load strategy'" .. sname .. "'")
end

local function listFiles(lnames, logs, mask)
    for lname in io.popen('ls ' .. mask):lines() do
        if not lnames[lname] then
            lnames[lname] = true
            table.insert(logs, lname)
        end
    end
    return lnames, logs
end

local function parseArgs(args)
    local nargs, i = #args, 3
    local operation, sname = "", ""
    local lnames, logs = {}, {}

    if nargs < 3 then
        io.stderr:write("too few parameters\n")
        os.exit(2)
    end

    operation = args[1]
    sname = args[2]

    while i <= nargs do
        local mask = args[i]
        lnames, logs = listFiles(lnames, logs, mask)
        i = i + 1
    end
    table.sort(logs)
    return operation, sname, logs
end

local function decodeTrade(trade)
    local s = trade["date-time"]
    if not string.find(s, '.', 1, true) then
        s = s .. ".000"
    end
    local _1, _2, year, month, day, hour, min, sec, ms = string.find(s, "(%d+)-(%d+)-(%d+)T(%d+)-(%d+)-(%d+).(%d+)")
    local ms = ms or ""
    while string.len(ms) < 3 do
        ms = ms .. "0"
    end
    trade.datetime = {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec), 
        ms = tonumber(ms)
    }
    trade.tstamp = os.time(trade.datetime) + trade.datetime.ms/1000.
    trade.sec_code = trade.sec_code or trade.asset
    trade.class_code = trade.class_code or trade.class
    trade.qty = tonumber(trade.qty or trade.quantity)
    trade.price = assert(tonumber(trade.price))
    return trade
end

local function loadAllLogs(logs)
    local trades = {}
    for _, lname in ipairs(logs) do
        local reader = q_log.createReader(lname)
        for trade in reader.allLines() do
            trade = decodeTrade(trade)
            table.insert(trades, trade)
        end
    end
    return trades
end

local function runStrategy(sname, trades, etc)
    local pos, netPos = 0, 0, 0
    local strategy = loadStrategy(sname, etc)
    local dayDealCount, transactionCount = 0,0
    local ntrades = #trades

    local function getDate(trade)
        local date = trade.datetime
        return string.format("%02d-%02d-%04d", date.day, date.month, date.year)
    end

    io.stdout:write("processing " .. getDate(trades[1]) .. " ... ")
    local day = trades[1].datetime.day

    for i = 2,ntrades do
        local trade = trades[i]
        local tstamp = trade.tstamp
        local price = trade.price
        
        for j = i + 1,ntrades do
            local t = trades[j]
            price = t.price
            if t.tstamp >= tstamp + delay then
                break
            end
        end

        local newPos = strategy.onTrade(trade, trade.datetime)
        if newPos > 0 then
            newPos = 1
        elseif newPos < 0 then
            newPos = -1
        else
            newPos = 0
        end

        if newPos ~= pos then
            local actualPrice = price
            if newPos > pos then
                actualPrice = price - numSteps*strategy.etc.priceStep
            else
                actualPrice = price + numSteps*strategy.etc.priceStep
            end
            dayDealCount = dayDealCount + 1
            transactionCount = transactionCount + 1
            netPos = netPos - (pos - newPos)*actualPrice
            pos = newPos
        end

        if day ~= trade.datetime.day then
            print("OK transactions: " .. dayDealCount .. " postion at EOD: " .. (netPos - dayDealCount*transactionCost))
            io.stdout:write("processing " .. getDate(trade) .. " ... ")
            dayDealCount = 0
        end
        day = trade.datetime.day
        pos = newPos
    end
    netPos = netPos + pos*trades[ntrades].price
    netPos = netPos - transactionCost*transactionCount
    if transactionCount == 0 then
        netPos = -1e12 -- penalty
    end
    print("OK transactions: " .. dayDealCount .. " postion at EOD: " .. netPos)
    return netPos
end

-- creates a 'shallow' copy of specified table
local function makeCopy(t)
    local c = {}
    for k,v in pairs(t) do
        c[k] = v
    end
    return c
end
    
local function optimizeParam(sname, etc, trades, cincome, pname)

    local attempt = 0
    local factor = 1
    local direction = 1

    local info = assert(etc.paramsInfo[pname], "error: There is no information on parameter named '" .. pname .. "'")
    local min = info.min or -numericMax
    local max = info.max or numericMax
    local res = false

    while attempt < maxAttempts do

        local cvalue =  assert(etc[pname], "error: There is no parameter named '" .. pname .. "' the strategy configuration")
        local step = info.step
        if info.relative then
            step = cvalue*step
        end
        step = step*factor
        local found = false

        for i=1,2 do
            local value = cvalue + direction*step
            if value < min then
                value = min
            elseif value > max then
                value = max
            end

            if value ~= cvalue then
                local shifted_etc = makeCopy(etc)
                shifted_etc[pname] = value
                print("running '" .. pname .. "' = " .. value)
                local income = runStrategy(sname, trades, shifted_etc)
                if income > cincome then
                    print("Better parameter found")
                    cincome, etc = income, shifted_etc
                    zeroCount = 0
                    res = true
                    found = true
                    break
                end
            end
            direction = direction*(-1)
        end
        if not found then
            factor = factor*0.5
            attempt = attempt + 1
            print("Reducing shift, attempt " .. attempt .. " of " .. maxAttempts)
        end
        print("")
    end
    print("---")
    return cincome, etc, res
end

-- alternating-variable descent method
local function doDescent(sname, trades, etc)
    -- build list of params
    local pnames = { }
    local infos = etc.paramsInfo

    for pname,_ in pairs(infos) do
        table.insert(pnames, pname)
    end

    -- calculate central income
    print("Running with unshifted parameters:")
    local income = runStrategy(sname, trades, etc)
    print("")
    local originalIncome = income
   
    local function optimizeAllParams(income, etc)
        local res = false
        for _, pname in ipairs(pnames) do
            local flag = false
            income, etc, flag = optimizeParam(sname, etc, trades, income, pname)
            res = res or flag
        end
        return income, etc, res
    end
   
    local flag = true
    while flag do
        income, etc, flag = optimizeAllParams(income, etc)
    end

    print("\nRunning with Optimal parameters:")
    runStrategy(sname, trades, etc)

    return income, etc, originalIncome
end

local function OptimizeParams(sname, trades, etc)
    local income, incomeAtStart = false, false

    print("Unshifted parameters:")

    local etc0 = loadStrategy(sname, etc).etc
    for pname,_ in pairs(etc.paramsInfo) do
        print("", "'" .. pname .. "' = " .. etc0[pname])
    end

    print("")

    income, etc, incomeAtStart = doDescent(sname, trades, etc)

    print("")
    print("New parameters found: ", (income > incomeAtStart) and "Yes" or "No")
    print("Total income before optimization: ", incomeAtStart)
    print("Total income after optimization: ", income)
    print("Best parameters are:")

    for pname,_ in pairs(etc.paramsInfo) do
        print("", "'" .. pname .. "' = " .. etc[pname])
    end
    if income > incomeAtStart then
        print("")
        io.stdout:write("Saving parameters ... ")
        if loadStrategy(sname, etc).etc:save() then
            print("OK")
        else
            print("failed")
        end
    end
end

local function KickOff(sname, logs, operation)
    local strategy = loadStrategy(sname)
    local trades = loadAllLogs(logs)
    local etc = makeCopy(strategy.etc)
    strategy = nil
    operation(sname, trades, etc)
end

local operation, sname, logs = parseArgs(arg)
if operation == "--run" or operation == "-r" then
    operation = runStrategy
elseif operation == "--optimize" or operation == "-o" then
    operation = OptimizeParams
else
    io.stderr:write("Operation '" .. operation .. "' is not supported\n")
    usage()
    os.exit(2)
end
KickOff(sname, logs, operation)
