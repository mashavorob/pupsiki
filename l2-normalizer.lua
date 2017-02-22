#!/usr/bin/env luajit
-- vi: ft=lua:fenc=cp1251 
--[[
#
# ѕодготовка l2-записей дл€ преобразовани€ в последовательность ордеров:
#    - удалить "старые" сделки
#    - упор€дочить сделки и котировки (сначала сделка, потом котировка)
#    - удалить param_image пол€ (содержат недопустимые символы)
#
# ѕример использовани€:
#
# cat <l2-данные> | l2-normalizer.lua > l2-normalized-data.txt
#
# ≈сли ¬ы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_persist = assert(require("qlib/quik-l2-persist"))

local function getTimeOfDay(t)
    if not t then
        return t
    end
    if type(t) == "table" then
        t = os.time { year=1970, month=1, day=1, hour=t.hour or 0, min=t.min or 0, sec=t.sec or 0 }
    end
    return math.floor(t) % (24*3600)
end

local windowSize = 1000

local startFrom = getTimeOfDay {hour=11}
local endAt = getTimeOfDay {hour=19}

local function makeCopy(t)
    if type(t) == "table" then
        local c = {}
        for k,v in pairs(t) do
            if k ~= "param_image" then
                c[k] = makeCopy(v)
            end
        end
        return c
    end
    return t
end

local delayTolerance = 1
local minDelay = 10
local window = {}
local ln = 0

local function printEvent(ev)
    local t = getTimeOfDay(ev.time or ev.received_time)
    if t and (t < startFrom or t > endAt) then
        return
    end
    print( q_persist.toString(ev) )
end

local function printTrade(ev)
    local delay = ev.received_time - ev.exchange_time
    if delay < minDelay + delayTolerance then
        printEvent(ev)
    end
end

local function processLine(window)
    
    ln = ln + 1
    if not lastQuote and ln % 50000 == 0 then
        io.stderr:write(string.format("%d: lines processed\n", ln))
    end

    local ev = window[1]
    table.remove(window, 1)

    if ev.event == "onQuote" then
       
        -- check if there are trades in the window
        local i = 1
        local count = #window
        while i < count do
            local n_ev = window[i]
            if n_ev.asset == ev.asset and n_ev.class == ev.class then
                if n_ev.event == "onAllTrade" then
                    printTrade(n_ev)
                    table.remove(window, i)
                    i = i - 1
                    count = count - 1
                elseif n_ev.event == "onQuote" then
                    break
                end
            end
            i = i + 1
        end
        printEvent(ev)
    elseif ev.event == "onAllTrade" then
        printTrade(ev)
    else
        printEvent(ev)
    end
end

for line in io.stdin:lines() do
    local success, ev = pcall(q_persist.parseLine, line)
    if success then
        local t = getTimeOfDay(ev.time)
        if t and t > endAt then
            io.stderr:write( string.format("Stopping at: %d (%d)", t, endAt) )
            break
        end
        if ev.event == "onAllTrade" then
            local delay = ev.received_time - ev.exchange_time
            minDelay = math.min(minDelay, delay) 
        end
        table.insert(window, ev)
        while #window > windowSize do
            processLine(window)
        end
    else
        io.stderr:write( string.format("Error parsing line %d, erroneous line is:\n%s\n", ln, line) )
    end
end
while #window > 0 do
    processLine(window)
end

