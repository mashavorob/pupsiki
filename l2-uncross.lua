#!/usr/bin/env luajit
-- vi: ft=lua:fenc=cp1251 
--[[
#
# Извлечение цен из записанных маркетных данных
#
# Пример использования:
#
# cat <l2-данные> | l2-prices.lua > prices.csv
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

q_persist = assert(require("qlib/quik-l2-persist"))

local lastBook = {}
local trades = {}

local function getBidAsk(ev)
    local bid, ask = nil
    bid = ev.l2.bid_count > 0 and ev.l2.bid[ev.l2.bid_count].price or false
    ask = ev.l2.offer_count > 0 and ev.l2.offer[1].price or false
    return bid, ask
end

local function isTradePossible(q_ev, t_ev)
    local bid, ask = getBidAsk(q_ev)
    if bit.band(t_ev.trade.flags, 1) ~= 0 then
        -- sell
        return (not bid or bid <= t_ev.trade.price) and (not ask or ask > t_ev.trade.price)
    end
    -- buy
    return (not ask or ask >= t_ev.trade.price) and (not bid or bid < t_ev.trade.price)
end

for line in io.stdin:lines() do
    local ev = q_persist.parseLine(line)

    if ev.event == "onParam" then
        print(line) -- do not decode
    elseif ev.event == "onLoggedTrade" then 
        print(line) -- do not decode
    elseif ev.event == "onQuote" then
        print(q_persist.toString(ev))
        while #trades > 0 and isTradePossible(ev, trades[1]) do
            print(q_persist.toString(trades[1]))
            table.remove(trades, 1)
        end
        lastQuote = ev
    elseif ev.event == "onTrade" then
        if #trades > 0 or not isTradePossible(lastQuote, ev) then
            table.insert(trades, ev)
        else
            print(q_persist.toString(ev))
        end
    end
end

