#!/usr/bin/lua
-- vi: ft=lua:fenc=cp1251 

--[[
#
# Проигрывание записанных маркетных данных (уровень 2)
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local helpMessage = [[
l2-player is for playback previously recorded market data and optimize strategies' parameters
Usage:

%s <operation> <strategy> <log-file> [log-file] ... [log-file]

Where
    <operation> could be:
    run         - run specified strategy
    optimize    - optimize specified strategy
    --help,/?   - show this message
]]

require("qlib/quik-simulator")

local function printHelpAndExit(code)
    print(string.format(helpMessage, arg[0]))
    os.exit(code)
end

local function parseArgs()
    local numArgs = #arg

    if numArgs >= 1 and (arg[1] == "--help" or arg[1] == "/?") then
        printHelpAndExit(0)
    elseif numArgs < 3 then
        print("At least 3 arguments are expected")
        printHelpAndExit(1)
    end
    local op, strategy, logs = arg[1], arg[2], { }

    for i = 3, numArgs do
        table.insert(logs, arg[i])
    end
    return op, strategy, logs
end

local function loadLogFile(fname)
    local file = assert(io.open(fname,"r"))
    local text = "data = {" .. file:read("*all") .. "}"
    local fn = loadstring(text)
    local res = { }
    setfenv(fn, res)
    if pcall(fn) then
        return res.data
    end
end

local function loadMarketData(logs)
    local container = {}

    for _, f in ipairs(logs) do
        local fdata = loadLogFile(f)
        for _,item in ipairs(fdata) do
            table.insert(container, item)
        end
    end

    return container
end

local function runStrategy(strategy, container)

    local margin = q_simulator.runStrategy(strategy, container)
    print(string.format("total margin: %f", margin))
end

print("Level 2 Market Data Player (c) 2016\n")

-- Parse command line
local op, strategy, logs = parseArgs()
local ll = ""
for i, l in ipairs(logs) do
    ll = string.format("%s logs[%d]=%s", ll, i, l)
end
print(string.format("op=%s strategy=%s%s", op, strategy, ll))

print("loading market data")
local container = loadMarketData(logs)

if op == "run" then
    print(string.format("Running %s", strategy))
    runStrategy(strategy, container)
elseif op == "optimize" then
    assert(false, "Optimization is not implemented yet")
else
    assert(false, "Operation '" .. op .. "' is not supported")
end
print("Done.")
