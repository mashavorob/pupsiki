#!/usr/bin/env luajit
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

%s <operation> <options> <strategy> <log-file> [log-file] ... [log-file]

Where
    <operation> could be:
    run         - run specified strategy
    optimize    - optimize specified strategy
    probe       - probe different values of a parameter
    --help,/?   - show this message
    
    <options>   - depend on command, see details:
        run       - supports no options
        optimize  - support no options
        probe     - following options are mandatory:
            -param <parameter> <from> <to> <step> - specifies name and range for parameter to probe
                                                    it is possible to specify many '-param' options
]]

assert(require("qlib/quik-jit"))
assert(require("qlib/quik-simulator"))
assert(require("qlib/quik-l2-persist"))

print("")
print("Level 2 Market Data Player (c) 2016")

if q_jit.isJIT() then
    print("LuaJIT detected")
else
    print("Lua interpreter detected")
end

print("")

local function printHelpAndExit(code)
    print(string.format(helpMessage, arg[0]))
    os.exit(code)
end

local function parseArgs()
    local numArgs = #arg

    if numArgs >= 1 and (arg[1] == "--help" or arg[1] == "/?") then
        printHelpAndExit(0)
    elseif numArgs < 3 then
        io.stderr:write("At least 3 arguments are expected\n")
        printHelpAndExit(1)
    end
    local op, i = arg[1], 2
    local options = {}

    if op == 'probe' then

        local asNum = function(name, value)
            local num = tonumber(value)
            if not num then
                io.stderr:write("Incorrect value is specified for parameter '" .. name .. "'\n")
                io.stderr:write("Number is expected, but found '" .. (value or 'nothing') .. "'\n")
                printHelpAndExit(1)
            end
            return num
        end

        while i < numArgs and arg[i] == '-param' do
            local name, from, to, step = arg[i+1], asNum('<from>', arg[i+2]), asNum('<to>', arg[i+3]), asNum('<step>', arg[i+4])
            if not name then
                io.stderr:write("Parameter name is not specified for '-param' option\n")
                printHelpAndExit(1)
            end
            if step <= 0 then
                io.stderr:write("Positive value is expected for '<step>' parameter\n")
                printHelpAndExit(1)
            end
            if from >= to then
                io.stderr:write("Value of '<from>' parameter must be strictly less then value of '<to>' parameter\n")
                printHelpAndExit(1)
            end

            table.insert(options, { param=name, from=from, to=to, step=step })
            i = i + 5
        end

        if #options < 1 then
            io.stderr:write("at least one '-param' option must be specifed for probe\n")
            printHelpAndExit(1)
        end
    end

    local strategy, logs = arg[i], { }

    for j = i + 1, numArgs do
        table.insert(logs, arg[j])
    end
    return op, options, strategy, logs
end

local function loadMarketData(logs)
    local data = nil

    for _, f in ipairs(logs) do
        data = q_persist.loadL2Log(f, data)
    end
    return data
end

local function runStrategy(strategy, container)
    local margin = q_simulator.runStrategy(strategy, container)
    print(string.format("total margin: %f", margin))
end

local function optimizeStrategy(strategy, container)
    local before, after, params = q_simulator.optimizeStrategy(strategy, container)

    if params == nil then
        print("Optimization did not find better paramters")
    else
        print("Optimal parameters are:")
        for k,v in pairs(params) do
            print(string.format("%s = %s", k, tostring(v)))
        end
        print(string.format("Margin before optimization: %f", before))
        print(string.format("Margin after  optimization: %f", after))
    end
end

local function paramsToString(params)
    local s = nil
    for _,p in ipairs(params) do
        s = s and (s .. " ") or ""
        s = s .. p.param .. "=" .. tostring(p.value)
    end
    return s
end


local function printResults1D(results)
    for _,p in ipairs(results) do
        print(paramsToString(p.params) .. ": " .. tostring(p.value))
    end
end

local function printResults2D(results, startIndex)
    startIndex = startIndex or 1

    if #results < startIndex then
        return #results
    end

    local paramCount = #results[startIndex].params

    -- calculate line width
    local startValue = nil
    local cx = 0
    local header = results[startIndex].params[paramCount - 1].param

    for i=startIndex,#results do
        local item = results[i]

        if startValue == item.params[paramCount].value then
            break
        end
        startValue = startValue or item.params[paramCount].value

        header = header .. "," .. item.params[paramCount].value
        cx = cx + 1
    end

    print("," .. results[startIndex].params[paramCount].param)
    print(header)

    startValue = nil
    local i = startIndex
    while i < #results do
        local params = results[i].params
        if startValue == params[paramCount - 1].value then
            return i
        end
        startValue = startValue or params[paramCount - 1].value

        
        local line = tostring(params[paramCount - 1].value)
        for j = 1,cx do
            line = line .. "," .. tostring(results[i].value)
            i = i + 1
        end
        print(line)
    end
    return #results
end

local function printResults(results)
    assert(#results > 0)
    if #results < 1 then
        return
    end
    local count = #results[1].params

    if count == 1 then
        printResults1D(results)
        return
    end

    local i = 1
    while i < #results do
        for j = 1,count-2 do
            local params = results[i].params
            print(params[j].param .. " = " .. tostring(params[j].value))
        end
        i = printResults2D(results, i)
        print()
    end
end

local function probeParam(strategy, container, options, ctx)

    if not ctx then
        print("Probbing following parameters:")
        for _,p in ipairs(options) do
            print(string.format("Parameter: '%s' from %s to %s, step %s", p.param, tostring(p.from), tostring(p.to), tostring(p.step)))
        end
    end

    ctx = ctx or {}

    if #options == 0 then
        print("running startegy for: ")
        print(paramsToString(ctx))

        local function copy(t)
            if type(t) == 'table' then
                local c = {}
                for k,v in pairs(t) do
                    c[copy(k)] = copy(v)
                end
                t = c
            end
            return t
        end

        local result = 
            { params = copy(ctx)
            , value = q_simulator.runStrategy(strategy, container, ctx)
            }

        print("Result:", result.value)
        print()

        return { result }
    end

    local inner_options = {}

    for i = 2,#options do
        table.insert(inner_options, options[i])
    end
    
    local inner_ctx = {}
    
    for _,p in ipairs(ctx) do
        table.insert(inner_ctx, p)
    end

    local param =
        { param = options[1].param
        , value = options[1].from
        }
    local to = options[1].to
    local step = options[1].step

    table.insert(inner_ctx, param)

    local results = {}

    while param.value <= to do

        --table.insert(inner_ctx, { param=param.param, value=param.value })

        local inner_results = probeParam(strategy, container, inner_options, inner_ctx)

        for _,r in ipairs(inner_results) do
            table.insert(results, r)
        end
        
        param.value = param.value + step
    end

    if #ctx == 0 then
        print("Results:")
        print()
        printResults(results)
    end
    return results
end

-- Parse command line
local op, options, strategy, logs = parseArgs()
local ll = ""
for i, l in ipairs(logs) do
    ll = string.format("%s logs[%d]=%s", ll, i, l)
end
print(string.format("op=%s strategy=%s%s", op, strategy, ll))

print("loading market data")
local container = loadMarketData(logs)

print("preprocessing market data")
container = q_simulator.preProcessData(container)
collectgarbage()

if op == "run" then
    print(string.format("Running %s", strategy))
    runStrategy(strategy, container)
elseif op == "optimize" then
    print(string.format("Optimizing %s", strategy))
    optimizeStrategy(strategy, container)
elseif op == "probe" then
    print(string.format("Probbing %s for %d parameters"
        , strategy, #options))
    probeParam(strategy, container, options)
else
    assert(false, "Operation '" .. op .. "' is not supported")
end

print("Done.")
