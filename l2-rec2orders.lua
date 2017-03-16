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
            local q_time = q_ev.time or q_ev.received_time 
            if q_time - t_time > maxTradeDelay then
                return false
            end
            if isTradePossible(q_ev.l2, t_ev) then
                return false
            end
        end
    end
    return true
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
    if not event.class and event.trade then
        event.class = event.trade.class_code
        event.asset = event.trade.sec_code
    end
    return event.class .. "-" .. event.asset
end
local function getTradesNumber()
    local order = {}
    local n = 0
    for key,tt in pairs(trades) do
        n = n + #tt
        table.insert(order, key)
    end
    table.sort(order, function(a, b) return #(trades[a]) > #(trades[b]) end)
    local s = ""
    for i,k in ipairs(order) do
        if i > 3 then
            break
        end
        s = s .. string.format("%s:%d, ", k, #(trades[k]))
    end
    return string.format("total %d, %s", n, s)
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

local nextTransId = 1e7

local function makeOrder(event, op, action, condition, price, quantity, trans_id)
    local newOrder = false
    if not trans_id then
        newOrder = true
        trans_id = tostring(nextTransId)
        nextTransId = nextTransId + 1
    end
    return
        { CLASSCODE = event.class
        , SECCODE = event.asset
        , TRANS_ID = trans_id
        , OPERATION = op
        , ACTION = action
        , TYPE = "L"
        , EXECUTE_CONDITION = condition
        , PRICE = price and tostring(price) or nil
        , QUANTITY = quantity and tostring(quantity) or nil
        }
end

local side2op = { bid="B", offer="S" }

local function cancelObsoleteOrders(event, side, quotes, newQuotes)
    -- cancel removed
    local index = 1
    local toRemove = {}

    for i,quote in ipairs(quotes) do
        while index <= #newQuotes and newQuotes[index].price < quote.price do
            index = index + 1
        end
        if index > #newQuotes or newQuotes[index].price > quote.price then
            for _,order in ipairs(quote.orders) do
                local order_key = order.TRANS_ID
                order = makeOrder(event, side, "KILL_ORDER", nil, nil, nil)
                order.ORDER_KEY = order_key
                printOrder(order)
            end
            table.insert(toRemove, 1, i)
        end
    end

    -- clear removed
    for _,i in ipairs(toRemove) do
        table.remove(quotes, i)
    end
end

local function onSendNewOrders(event, side, quotes, newQuotes)

    -- add new and correct existing
    local index = 1
    for i,newQuote in ipairs(newQuotes) do
        while index <= #quotes and quotes[index].price < newQuote.price do
            index = index + 1
        end
        if index > #quotes or quotes[index].price > newQuote.price then
            table.insert(quotes, index, newQuote)
            local order = makeOrder(event, side, "NEW_ORDER", "PUT_IN_QUEUE", newQuote.price, newQuote.quantity)
            quotes[index].orders = { order } 
            printOrder(order)
        elseif quotes[index].quantity < newQuote.quantity then
            local q = quotes[index]
            local diff = newQuote.quantity - q.quantity
            local order = makeOrder(event, side, "NEW_ORDER", "PUT_IN_QUEUE", q.price, diff)
            q.quantity = q.quantity + diff
            table.insert(q.orders, #quotes[index].orders, order)
            printOrder(order)
        else
            local q = quotes[index]
            while q.quantity > newQuote.quantity do
                local diff = q.quantity - newQuote.quantity
                local tail = q.orders[#q.orders]
                assert(tail.TRANS_ID)
                local tailQuantity = tonumber(tail.QUANTITY)
                if tailQuantity <= diff then
                    diff = tailQuantity
                    table.remove(q.orders, #q.orders)
                    local order = makeOrder(event, side, "KILL_ORDER", nil, nil, nil)
                    order.ORDER_KEY=tail.TRANS_ID
                    printOrder(order)
                else
                    tailQuantity = tailQuantity - diff
                    tail.QUANTITY = tostring(tailQuantity)
                    local order = makeOrder(event, side, "CORRECT_ORDER", nil, newQuote.price, newQuote.quantity)
                    order.ORDER_KEY=tail.TRANS_ID
                    printOrder(order)
                end
                q.quantity = q.quantity - diff
            end
        end
    end

    assert(#quotes == #newQuotes)
end

local function onBook(event, oldBook, newBook)
    oldBook.bid = oldBook.bid or {}
    oldBook.offer = oldBook.offer or {}
    newBook.bid = newBook.bid or {}
    newBook.offer = newBook.offer or {}
    -- cancel old orders
    cancelObsoleteOrders(event, 'B', oldBook.bid, newBook.bid) 
    cancelObsoleteOrders(event, 'S', oldBook.offer, newBook.offer) 
    onSendNewOrders(event, 'B', oldBook.bid, newBook.bid) 
    onSendNewOrders(event, 'S', oldBook.offer, newBook.offer)
    oldBook.bid_count = #oldBook.bid
    oldBook.offer_count = #oldBook.offer

    local function assertEq(_1, _2)
        assert(_1.c == _2.c)
        for i = 1,_1.c do
            assert(_1.q[i].price == _2.q[i].price)
            assert(_1.q[i].quantity == _2.q[i].quantity, string.format("expected %d, found %d", _1.q[i].quantity, _2.q[i].quantity))
        end
    end

    assertEq( {c=oldBook.bid_count, q=oldBook.bid}, {c=newBook.bid_count, q=newBook.bid})
    assertEq( {c=oldBook.offer_count, q=oldBook.offer}, {c=newBook.offer_count, q=newBook.offer})
end

local lastQuote = false 

local function onQuote(event)
    lastQuote = event.time or event.received_time
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
        if newBook.bid[newBook.bid_count].quantity < trade.qty + 1 then
            newBook.bid[newBook.bid_count].quantity = trade.qty + 1
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
        if newBook.offer[1].quantity < trade.qty + 1 then
            newBook.offer[1].quantity = trade.qty + 1
        end
    end

    onBook(event, oldBook, newBook)
    local order = makeOrder(event, tradeSide, 'NEW_ORDER', 'KILL_BALANCE', trade.price, trade.qty)
    printOrder(order)

    -- correct book after trade
    local book = getBook(event)
    local q = (tradeSide == 'S') and book.bid[newBook.bid_count] or book.offer[1]
    q.quantity = q.quantity - trade.qty
end

local function stripOrders(o)
    if type(o) == "table" then
        local c = {}
        for k,v in pairs(o) do
            if k ~= 'orders' then
                c[k] = stripOrders(v)
            end
        end
        return c
    end
    return o
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
        print( q_persist.toString(stripOrders(ev)) )
        
        while #tt > 0 and (isTradePossible(ev.l2, tt[1]) or not canWait(tt[1], window)) do
            onTrade(tt[1])
            table.remove(tt, 1)
        end
    elseif ev.event == "onAllTrade" then
        while #tt > 0 do
            onTrade(tt[1])
            table.remove(tt, 1)
        end
        local book = getBook(ev)
        if not isTradePossible(book, ev) then
            table.insert(tt, ev)
        else
            onTrade(ev)
        end
        print( q_persist.toString(ev) )
    else
        print( q_persist.toString(ev) )
    end
    
end

local window = {}
local ln = 1
local prevQuote = 0

for line in io.stdin:lines() do
    local success, ev = pcall(q_persist.parseLine, line)
    if success then
        table.insert(window, ev)
        while #window > windowSize do
            processLine(window)
        end
    else
        io.stderr:write( string.format("Error parsing line %d, erroneous line is:\n%s\n", ln, line) )
    end
    ln = ln + 1
    if lastQuote and lastQuote - prevQuote > 180 then
        prevQuote = lastQuote
        local ts = os.date('%Y%m%d-%H:%M', lastQuote)
        io.stderr:write(string.format("%d: last quote time %s\n", ln, ts))
    elseif not lastQuote and ln % 50000 == 0 then
        io.stderr:write(string.format("%d: lines processed\n", ln))
    end
end

while #window > 0 do
    processLine(window)
end
