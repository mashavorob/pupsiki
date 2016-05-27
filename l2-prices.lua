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

assert(require("qlib/quik-l2-persist"))

local data = q_persist.loadL2Log()

print("loaded: ", #data)
print("time, bid, offer")

local prevBid = false
local prevOffer = false

for _,rec in ipairs(data) do
    if rec.event == "onQuote" then
        local l2 = rec.l2
        l2.bid_count = tonumber(l2.bid_count)
        l2.offer_count = tonumber(l2.offer_count)

        local bid = prevBid
        local offer = prevOffer

        if l2.bid_count > 0 then
            bid = tonumber(l2.bid[l2.bid_count].price)
        end
        if l2.offer_count > 0 then
            offer = tonumber(l2.offer[1].price)
        end
        if (bid and offer) and (bid ~= prevBid or offer ~= prevOffer) then
            print(string.format("%f, %f, %f", rec.tstamp, bid, offer))
        end
        prevBid = bid
        prevOffer = offer
    end
     
end

