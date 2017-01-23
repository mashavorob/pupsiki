#!/usr/bin/env luajit
-- vi: ft=lua:fenc=cp1251 
--[[
#
# Перекодировка l2-записей в последовательность ордеров
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

local books = {}
local trades = {}

local maxTradeDelay = 0.05
local windowSize = 1000

local function makeCopy(t)
    if type(t) == "table" then
        local c = {}
        for k,v in pairs(t) do
            c[k] = makeCopy(v)
        end
        return c
    end
    return t
end

--
-- extract bid/ask from l2 update
--

local function getBidAsk(book)
    local bid, ask = nil, nil
    bid = book.bid_count > 0 and book.bid[book.bid_count].price or nil
    ask = book.offer_count > 0 and book.offer[1].price or nil
    return bid, ask
end

--
-- returns true if trade is possible (market not crossed) with current l2
--
local function isTradePossible(book, t_ev)
    local bid, ask = getBidAsk(book)
    local res = false
    if bit.band(t_ev.trade.flags, 1) ~= 0 then
        -- sell
        res = (bid and bid == t_ev.trade.price)
        return res
    else
        -- buy
        res = (ask and ask == t_ev.trade.price)
    end
    return res
end

--
-- returns true if trade will be possible in nearest time (no longer then maxTradeDelay from now)
--
local function canWait(t_ev, window)
    local t_time = t_ev.received_time
    for i=1,#window do
        local q_ev = window[i]
        if q_ev.event == "onQuote" then
            local q_time = q_ev.time 
            if q_time - t_time > maxTradeDelay then
                break
            end
            if isTradePossible(q_ev.l2, t_ev) then
                return true
            end
        end
    end
    return false
end

local function printOrder(order)
    local event =
        { order = order
        , event = "onOrder"
        , class = order.CLASSCODE
        , asset = order.SECCODE
        }
        
    print( q_persist.toString(event) )
end

local function getKey(event)
    return event.class .. ":" .. event.asset
end

local function getTrades(event)
    local key = getKey(event)
    local tt = trades[key]
    if not tt then
        tt = {}
        trades[key] = tt
    end
    return tt
end

local function getBook(event)
    local key = getKey(event)
    local book = books[key]
    if not book then
        book = { offer_count=0, bid_count=0 }
        books[key] = book
    end
    return book
end

local transIds = {}
local nextTransId = 1e7

local function makeOrder(event, op, action, condition, price, quantity)
    local key = string.format("%s-%s:%s@%f", event.class, event.asset, op, price)
    local id = transIds[key]
    if not id then
        id = tostring(nextTransId)
        nextTransId = nextTransId + 1
        transIds[key] = id
    end
    return
        { CLASSCODE = event.class
        , SECCODE = event.asset
        , TRANS_ID = id
        , OPERATION = op
        , ACTION = action
        , TYPE = "L"
        , EXECUTE_CONDITION = condition
        , PRICE = price and tostring(price) or nil
        , QUANTITY = quantity and tostring(quantity) or nil
        }
end

local side2op = { bid="B", offer="S" }

local function onBookSide(event, side, count, quotes, newCount, newQuotes)
    -- add new and correct existing
    local index = 1
    for i = 1,newCount do
        local newQuote = newQuotes[i]
        while index <= count and quotes[index].price < newQuote.price do
            index = index + 1
        end
        local order = false
        if index > count or quotes[index].price > newQuote.price then
            table.insert(quotes, index, newQuote)
            count = count + 1
            local order = makeOrder(event, side, "NEW_ORDER", "PUT_IN_QUEUE", newQuote.price, newQuote.quantity)
            printOrder(order)
        elseif quotes[index].quantity ~= newQuote.quantity then
            quotes[index].quantity = newQuote.quantity
            order = makeOrder(event, side, "CORRECT_ORDER", nil, newQuote.price, newQuote.quantity)
            printOrder(order)
        end
    end

    -- cancel removed
    index = 1
    local toRemove = {}
    for i = 1,count do
        local quote = quotes[i]
        while index <= newCount and newQuotes[index].price < quote.price do
            index = index + 1
        end
        if index > newCount or newQuotes[index].price > quote.price then
            table.insert(toRemove, 1, i)
            order = makeOrder(event, side, "KILL_ORDER", nil, quote.price, nil)
            printOrder(order)
        end
    end

    -- clear removed
    for _,i in ipairs(toRemove) do
        table.remove(quotes, i)
    end
    assert((count - #toRemove) == newCount)
    return newCount
end

local function onBook(event, oldBook, newBook)
    oldBook.bid = oldBook.bid or {}
    oldBook.offer = oldBook.offer or {}
    oldBook.bid_count = onBookSide(event, 'B', oldBook.bid_count or 0, oldBook.bid, newBook.bid_count or 0, newBook.bid)
    oldBook.offer_count = onBookSide(event, 'S', oldBook.offer_count or 0, oldBook.offer, newBook.offer_count or 0, newBook.offer)

    local function assertEq(_1, _2)
        assert(_1.c == _2.c)
        for i = 1,_1.c do
            assert(_1.q[i].price == _2.q[i].price)
            assert(_1.q[i].quantity == _2.q[i].quantity)
        end
    end

    assertEq( {c=oldBook.bid_count, q=oldBook.bid}, {c=newBook.bid_count, q=newBook.bid})
    assertEq( {c=oldBook.offer_count, q=oldBook.offer}, {c=newBook.offer_count, q=newBook.offer})
end

local function onQuote(event)
    local newBook = event.l2
    local oldBook = getBook(event)
    onBook(event, oldBook, newBook)
end

local function onTrade(event)
    local trade = event.trade

    local oldBook = getBook(event)
    local newBook = makeCopy(oldBook)

    -- check consistency between book and trade
    local tradeSide = (bit.band(trade.flags, 1) ~= 0) and 'S' or 'B'

    if tradeSide == 'S' then
        assert(newBook.offer_count)
        assert(newBook.offer_count == 0 or newBook.offer[1].price)
        assert(trade.price)
        while newBook.offer_count > 0 and trade.price >= newBook.offer[1].price do
            table.remove(newBook.offer, 1)
            newBook.offer_count = newBook.offer_count - 1
        end
        while newBook.bid_count > 0 and trade.price < newBook.bid[newBook.bid_count].price do
            table.remove(newBook.bid, newBook.bid_count)
            newBook.bid_count = newBook.bid_count - 1
        end
        if newBook.bid_count == 0 or trade.price ~= newBook.bid[newBook.bid_count].price then
            newBook.bid_count = newBook.bid_count + 1
            newBook.bid = newBook.bid or {}
            table.insert(newBook.bid, { price=trade.price, quantity=trade.qty })
        end
        if newBook.bid[newBook.bid_count].quantity < trade.qty then
            newBook.bid[newBook.bid_count].quantity = trade.qty
        end
    else
        while newBook.bid_count > 0 and trade.price <= newBook.bid[newBook.bid_count].price do
            table.remove(newBook.bid, newBook.bid_count)
            newBook.bid_count = newBook.bid_count - 1
        end
        while newBook.offer_count > 0 and trade.price > newBook.offer[1].price do
            table.remove(newBook.offer, 1)
            newBook.offer_count = newBook.offer_count - 1
        end
        if newBook.offer_count == 0 or trade.price ~= newBook.offer[1].price then
            newBook.offer_count = newBook.offer_count + 1
            newBook.offer = newBook.offer or {}
            table.insert(newBook.offer, 1, { price=trade.price, quantity=trade.qty })
        end
        if newBook.offer[1].quantity < trade.qty then
            newBook.offer[1].quantity = trade.qty
        end
    end
    onBook(event, oldBook, newBook)
    local order = makeOrder(event, tradeSide, 'NEW_ORDER', 'KILL_BALANCE', trade.price, trade.qty)
    printOrder(order)
end

local function processLine(window)

    local ev = window[1]
    table.remove(window, 1)

    local tt = getTrades(ev)

    -- it is neccessary to prevent crossing market before processing trades:
    -- normally trades arrive before quotes so we have to delay trades until
    -- they consist with market or maximum reasonable delay reached
    if ev.event == "onQuote" then 
        onQuote(ev)
        
        while #tt > 0 and isTradePossible(ev.l2, tt[1]) do
            onTrade(tt[1])
            table.remove(tt, 1)
        end
    elseif ev.event == "onTrade" then
        local book = getBook(ev)
        local count = #tt
        local p = isTradePossible(book, ev)
        local cw = canWait(ev, window)
        if #tt > 0 or ((not isTradePossible(book, ev)) and canWait(ev, window)) then
            table.insert(tt, ev)
        else
            onTrade(ev)
        end
    end
    print( q_persist.toString(ev) )
end

local window = {}

for line in io.stdin:lines() do
    local ev = q_persist.parseLine(line)
    table.insert(window, ev)
    while #window > windowSize do
        processLine(window)
    end
end

while #window > 0 do
    processLine(window)
end
