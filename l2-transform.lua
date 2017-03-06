#!/usr/bin/env luajit
-- vi: ft=lua:fenc=cp1251 
--[[
#
# Перекодировка l2-записей для сравнения
#
# Пример использования:
#
# cat <l2-данные> | l2-rec2orders.lua > l2-orders.txt
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_persist = assert(require("qlib/quik-l2-persist"))

local function quotesToStr(qq, count)
    local s = false
    for i,q in ipairs(qq) do
        if (count > 0 and i <= count) or
           (count < 0 and i > (#qq + count))
        then
            s = s and s .. " " or ""
            s = s .. string.format("%s@%s", tostring(q.quantity), tostring(q.price))
        end
    end
    return s or "<EMPTY>"
end

local function formatTime(t)
    local ms = math.floor((t - math.floor(t))*1000 + 0.5)
    return os.date("%H:%M:%S", t) .. string.format(".%03d", ms)
end

local function onQuote(event)
    local recTm = event.time and formatTime(event.time) or "<NA>"
    local bid = event.l2.bid or {}
    local ask = event.l2.offer or {}
    print( string.format("q: %s %s = %s", recTm, quotesToStr(bid, -5), quotesToStr(ask, 5)) )
end

local function onTrade(event)
    local op = ((event.trade.flags % 2) == 0) and "BUY" or "SELL"
    local recTm = event.received_time and formatTime(event.received_time) or "<NA>"
    print( string.format("t: %s %s %s@%s", recTm, op, tostring(event.trade.qty), tostring(event.trade.price)) )
end

local ln = 1
for line in io.stdin:lines() do
    local success, ev = pcall(q_persist.parseLine, line)
    if success then
        if ev.event == "onQuote" then 
            onQuote(ev)
        elseif ev.event == "onAllTrade" then
            onTrade(ev)
        end
    else
        io.stderr:write( string.format("Error parsing line %d, erroneous line is:\n%s\n", ln, line) )
    end
    ln = ln + 1
end
