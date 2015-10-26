#!/usr/bin/lua 

--[[
#
# Тестировщик стратегий
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

LUA_PATH = "./?.lua"

os.setlocale("C")

require("qlib/quik-logger")

numericMin = 2.22507e-308
numericMax = 1.79769e+308
numericEpsilon = 2.22045e-16

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
    trade.sec_code = trade.sec_code or trade.asset
    trade.class_code = trade.class_code or trade.class
    trade.qty = tonumber(trade.qty or trade.quantity)
    trade.price = assert(tonumber(trade.price))
    return trade
end

local function loadAllLogs(logs)
    local trades = {}
    for _, lname in ipairs(logs) do
        local reader = csvlog.createReader(lname)
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
    local trade = trades[1]
    local dayDealCount = 0

    local function getDate(trade)
        local date = trade.datetime
        return string.format("%02d-%02d-%04d", date.day, date.month, date.year)
    end

    io.stdout:write("processing " .. getDate(trade) .. " ... ")

    for i = 2,#trades do
        local nextTrade = trades[i]
        local price = nextTrade.price
        local newPos = strategy.onTrade(trade, trade.datetime)
        if newPos > 0 then
            newPos = 1
        elseif newPos < 0 then
            newPos = -1
        else
            newPos = 0
        end

        if newPos ~= pos then
            dayDealCount = dayDealCount + 1
            netPos = netPos + (pos - newPos)*price
            pos = newPos
        end

        if nextTrade.datetime.day ~= trade.datetime.day then
            print("OK deals: " .. dayDealCount .. " postion at EOD: " .. netPos)
            io.stdout:write("processing " .. getDate(nextTrade) .. " ... ")
            dayDealCount = 0
        end
        trade = nextTrade
        pos = newPos
    end
    netPos = netPos + pos*trade.price
    print("OK deals: " .. dayDealCount .. " postion at EOD: " .. netPos)
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

    local attempt, maxAttempts = 0, 5
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
            factor = factor/2
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
    return income, etc, originalIncome
end

local function OptimizeParams(sname, trades, etc)
    local income, incomeAtStart = false, false

    income, etc, incomeAtStart = doDescent(sname, trades, etc)

    print("")
    print("New parameters found: ", (income > incomeAtStart) and "Yes" or "No")
    print("Total income before optimization: ", incomeAtStart)
    print("Total income after optimization: ", income)
    print("Best parameters are:")

    for pname,_ in pairs(etc.paramsInfo) do
        print("", "'" .. pname .. "' = " .. etc[pname])
    end
end

local function KickOff(sname, logs, operation)
    local trades = loadAllLogs(logs)
    local strategy = loadStrategy(sname)
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
    io.stderr.write("Operation '" .. operation .. "' is not supported\n")
    usage()
    os.exit(2)
end
KickOff(sname, logs, operation)
