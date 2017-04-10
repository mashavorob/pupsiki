--[[
#
# Симулятор стакана v2 (l2-book, quik specific)
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_client = require("qlib/quik-book-client")

local book = {}
local clients = {} 

function book.findOrCreate(coll, ...)
    for _, key in ipairs({...}) do
        local t = coll[key]
        if t == nil then
            t = {}
            coll[key] = t
        end
        coll = t
    end
    return coll
end

function book.reset()
    clients = {}
end

function book:addClient(client)
    table.insert(clients, client)
end

function book:getAssetList(class)
    local params = book.findOrCreate(self.params, class)
    local assets = {}
    for asset,_ in pairs(assets) do
        table.insert(assets, asset)
    end
    return assets
end

function book:getParams(class, asset)
    return book.findOrCreate(self.params, class, asset)
end

function book:getTable(tableName)
    return book.findOrCreate(self.tables, tableName)
end

function book:getBook(class, asset)
    local b = book.findOrCreate(self.books, class, asset)
    b.bid = b.bid or {}
    b.offer = b.offer or {}
    return b
end

function book.findPriceLevel(bookSide, price)
    local l, r = 1, #bookSide + 1
    while l < r do
        local m = math.floor((l + r)/2)
        if bookSide[m].price < price then
            l = m + 1
        elseif bookSide[m].price > price then
            r = m
        else
            return m
        end
    end
    return l
end

function book:onParams(class, asset, params)
    local paramsTable = self:getParams(class, asset)
    for n,v in pairs(params) do
        paramsTable[n] = v
    end
end

function book:onLoggedTrade(trade)
    local all_trades = self:getTable("all_trades")
    table.insert(all_trades, trade)
    while #all_trades > 5 do
        table.remove(all_trades, 1)
    end
end

function book:onKillOrder(client, order)
    self:onCorrectOrder(client, {TRANS_ID=order.TRANS_ID, QUANTITY="0", ORDER_KEY=order.ORDER_KEY}, true)
end

local mask =
    { flags =
        { ACTIVE         = 0x1 
        , CANCELED       = 0x2 
        , SELL           = 0x4
        , LIMITED        = 0x8 
        , KILL_BALANCE   = 0x100
        }
    , operation =
        { S = 0x4
        , B = 0x0
        }
    , condition =
        { PUT_IN_QUEUE = 0
        , KILL_OR_FILL = 0
        , KILL_BALANCE = 0x100
        }
    }

function book:onCorrectOrder(client, order, kill)
    local trans_id = tonumber(order.TRANS_ID)
    local q_order = client.orders[order.ORDER_KEY]
    if not q_order then
        print("*Error: order not found, order list is:")
        for order_key, _ in pairs(client.orders) do
            print(string.format("    order_key = %s", order_key))
        end
        print(string.format("requested ORDER_KEY = %s", order.ORDER_KEY))
        for k,v in pairs(order) do
            print(string.format("  order.%s='%s'", k, v))
        end
        print()
        client:pushOnTransReply( { trans_id = trans_id
                                 , status = 4
                                 , result_msg = "Order not found"
                                 }
                               )
        assert(false)
        return
    end
    assert(q_order)
    assert(q_order.PRICE == order.PRICE or not order.PRICE)
    local b = self:getBook(q_order.CLASSCODE, q_order.SECCODE)
    local bookSide = q_order.OPERATION == 'B' and b.bid or b.offer
    local index = self.findPriceLevel(bookSide, q_order.price)

    if not bookSide[index] then
        assert(q_order.balance == 0)
    elseif bookSide[index].price ~= q_order.price then
        assert(q_order.balance == 0)
    end
    
    if q_order.balance == 0 then
        q_order.client:pushOnTransReply( { trans_id = trans_id
                                         , status = 3
                                         , result_msg = "Order is inactive"
                                         }
                                       )
        return
    end

    assert(bookSide[index] and bookSide[index].price == q_order.price)
    local qty = tonumber(order.QUANTITY)
    local diff = qty - q_order.quantity
    -- limit amount reduction by order balance
    if (q_order.balance + diff) < 0 then
        diff = -q_order.balance
        qty = q_order.quantity + diff
    end

    local params = self:getParams(q_order.CLASSCODE, q_order.SECCODE)
    if not q_order.client:onQuoteChange(q_order, params, diff) then
        q_order.client:pushOnTransReply( { trans_id = trans_id
                                         , status = 6 
                                         , result_msg = "Not enough money"
                                         }
                                       )
        return
    end
    if not kill then
        q_order.balance = q_order.balance + diff
        q_order.quantity = q_order.quantity + diff
        q_order.QUANTITY = tostring(q_order.quantity)
    end

    bookSide[index].quantity = bookSide[index].quantity + diff
    if q_order.balance == 0 or kill then
        q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
        if kill then
            q_order.flags = bit.bor(q_order.flags, mask.flags.CANCELED)
        end
        q_order.status = 3
        local found = false
        for i,o in ipairs(bookSide[index].orders) do
            if o == q_order then
                table.remove(bookSide[index].orders, i)
                found = true
                break
            end
        end
        assert(found)
        assert(bookSide[index].quantity >= 0)
        if bookSide[index].quantity == 0 then
            table.remove(bookSide, index)
        end
        client.orders[tostring(q_order.order_num)] = nil
        client.ordersByTransId[q_order.TRANS_ID] = nil
    else
        assert(bookSide[index].quantity > 0)
    end
    q_order.client:pushOnTransReply( { trans_id = trans_id
                                     , status = 3
                                     , result_msg=""
                                     }
                                   )
    q_order:fireOnOrder()
end

local trade_num = 1

local Order = {}

function Order:fireOnOrder()
    self.client:pushOnOrder( { trans_id = self.trans_id
                             , self_num = self.self_num
                             , flags = self.flags
                             , balance = self.balance
                             , price = self.price
                             , qty = self.size
                             , sec_code = self.seccode
                             , class_code = self.classcode
                             }
                           )
end

function book:createOrder(client, order)
    -- make a copy
    local q_order = {}
    for k,v in pairs(order) do
        q_order[k] = v
    end

    self.order_num = self.order_num and self.order_num + 1 or 1
    q_order.client = client
    q_order.price = tonumber(q_order.PRICE)
    q_order.order_num = self.order_num
    q_order.trans_id = tonumber(q_order.TRANS_ID)
    q_order.classcode = q_order.CLASSCODE
    q_order.seccode = q_order.SECCODE
    q_order.quantity = tonumber(q_order.QUANTITY)
    q_order.balance = q_order.quantity
    q_order.status = 0
    setmetatable(q_order, {__index=Order})

    return q_order
end

function book:onNewOrder(client, order)
    local q_order = self:createOrder(client, order)

    -- validate order, check limits
    local params = self:getParams(q_order.CLASSCODE, q_order.SECCODE)
    assert(mask.condition[q_order.EXECUTE_CONDITION], string.format("Unknown execute condition '%s'", q_order.EXECUTE_CONDITION))
    assert(mask.operation[q_order.OPERATION], string.format("Unknown operation '%s'", q_order.OPERATION))
    q_order.flags = bit.bor( mask.flags.LIMITED
                           , mask.flags.ACTIVE
                           , mask.operation[q_order.OPERATION]
                           , mask.flags.LIMITED
                           , mask.condition[q_order.EXECUTE_CONDITION]
                           )
    q_order.status = 1

    if not q_order.client:onQuoteChange(q_order, params, q_order.quantity) then
        q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
        q_order.status = 6
        q_order.client:pushOnTransReply( { trans_id = q_order.trans_id
                                         , order_num = q_order.order_num
                                         , status = 6
                                         , result_msg = "Not enough money"
                                         , balance = 0
                                         }
                                       )
        return
    end
    q_order.client:pushOnTransReply( { trans_id = q_order.trans_id
                                     , order_num = q_order.order_num
                                     , status = 0
                                     , result_msg = ""
                                     , balance = q_order.balance
                                     }
                                   )
    -- put order to table
    local orders = q_order.client:getOrders()
    table.insert(orders, q_order)

    -- process a new order
    local b = self:getBook(q_order.CLASSCODE, q_order.SECCODE)

    local bookSide = nil
    if q_order.OPERATION == 'B' then
        bookSide = b.bid
        if "KILL_OR_FILL" == q_order.EXECUTE_CONDITION then
            local amount = 0
            for i = 1,#b.offer do
                if b.offer[i].price > q_order.price then
                    break
                end
                amount = amount + b.offer[i].quantity
            end
            if q_order.quantity > amount then
                -- deactivate and return
                q_order.client:onQuoteChange(q_order, params, -q_order.quantity)
                q_order.status = 3
                q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
                q_order:fireOnOrder(q_order)
                return
            end
        end
        -- uncross orders
        assert( q_order.balance )
        while q_order.balance > 0 and #b.offer > 0 do
            if b.offer[1].price > q_order.price then
                break
            end
            
            trade_num = trade_num + 1
            local q = b.offer[1]
            local crossOrder = q.orders[1]
            local size = math.min(q_order.balance, crossOrder.balance)
            q.quantity = q.quantity - size
            -- update cross order
            crossOrder.balance = crossOrder.balance - size
            if crossOrder.balance == 0 then
                crossOrder.flags = bit.band(crossOrder.flags, bit.bnot(mask.flags.ACTIVE))
                crossOrder.status = 3
                table.remove(q.orders, 1)
                if #q.orders == 0 then
                    assert(q.quantity == 0)
                    table.remove(b.offer, 1)
                else
                    assert(q.quantity ~= 0)
                end
            else
                assert(q.quantity ~= 0)
            end
            crossOrder.client:onQuoteChange(crossOrder, params, -size)
            local exchange_comission = crossOrder.client:onOrderFilled(crossOrder, crossOrder.price, -size)
            crossOrder.client:pushOnTrade( { trade_num = trade_num
                                           , order_num = crossOrder.order_num
                                           , account = crossOrder.client.account
                                           , price = crossOrder.price
                                           , qty = size
                                           , value = size*crossOrder.price
                                           , flags = crossOrder.flags
                                           , sec_code = crossOrder.SECCODE
                                           , class_code = crossOrder.CLASSCODE
                                           , exchange_comission = exchange_comission
                                           , tech_center_comission = 0
                                           , trans_id = crossOrder.trans_id
                                           }
                                         )
            -- update order
            q_order.balance = q_order.balance - size
            if q_order.balance == 0 then
                q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
                q_order.status = 3
            end
            q_order.client:onQuoteChange(q_order, params, -size)
            local exchange_comission = q_order.client:onOrderFilled(q_order, crossOrder.price, size)
            q_order.client:pushOnTrade( { trade_num = trade_num
                                        , order_num = q_order.order_num
                                        , account = q_order.client.account
                                        , price = crossOrder.price
                                        , qty = size
                                        , value = size*crossOrder.price
                                        , flags = q_order.flags
                                        , sec_code = q_order.SECCODE
                                        , class_code = q_order.CLASSCODE
                                        , exchange_comission = exchange_comission
                                        , tech_center_comission = 0
                                        , trans_id = q_order.trans_id
                                        }
                                      )
        end
    elseif q_order.OPERATION == 'S' then
        bookSide = b.offer
        if "KILL_OR_FILL" == q_order.EXECUTE_CONDITION then
            local amount = 0
            for i = 1,#b.bid do
                local index = #b.bid - i + 1

                if b.bid[index].price < q_order.price then
                    break
                end
                amount = amount + b.bid[index].quantity
            end
            if q_order.quantity > amount then
                -- deactivate and return
                q_order.client:onQuoteChange(q_order, params, -q_order.quantity)
                q_order.status = 3
                q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
                q_order:fireOnOrder()
                return
            end
        end
        -- uncross orders
        while q_order.balance > 0 and #b.bid > 0 do
            if b.bid[#b.bid].price < q_order.price then
                break
            end
            trade_num = trade_num + 1
            local q = b.bid[#b.bid]
            local crossOrder = q.orders[1]
            local size = math.min(q_order.balance, crossOrder.balance)
            q.quantity = q.quantity - size
            -- update cross order
            crossOrder.balance = crossOrder.balance - size
            if crossOrder.balance == 0 then
                crossOrder.flags = bit.band(crossOrder.flags, bit.bnot(mask.flags.ACTIVE))
                crossOrder.status = 3
                table.remove(q.orders, 1)
                if #q.orders == 0 then
                    assert(q.quantity == 0)
                    table.remove(b.bid, #b.bid)
                else
                    assert(q.quantity ~= 0)
                end
            else
                assert(q.quantity ~= 0)
            end
            crossOrder.client:onQuoteChange(crossOrder, params, -size)
            local exchange_comission = crossOrder.client:onOrderFilled(crossOrder, crossOrder.price, size)
            crossOrder.client:pushOnTrade( { trade_num = trade_num
                                           , order_num = crossOrder.order_num
                                           , account = crossOrder.client.account
                                           , price = crossOrder.price
                                           , qty = size
                                           , value = size*crossOrder.price
                                           , flags = crossOrder.flags
                                           , sec_code = crossOrder.SECCODE
                                           , class_code = crossOrder.CLASSCODE
                                           , exchange_comission = exchange_comission
                                           , tech_center_comission = 0
                                           , trans_id = crossOrder.trans_id
                                           }
                                         )
            crossOrder:fireOnOrder()
            -- update order
            q_order.balance = q_order.balance - size
            if q_order.balance == 0 then
                q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
                q_order.status = 3
            end
            q_order.client:onQuoteChange(q_order, params, -size)
            local exchange_comission = q_order.client:onOrderFilled(q_order, crossOrder.price, -size)
            q_order.client:pushOnTrade( { trade_num = trade_num
                                        , order_num = q_order.order_num
                                        , account = q_order.client.account
                                        , price = crossOrder.price
                                        , qty = size
                                        , value = size*crossOrder.price
                                        , flags = q_order.flags
                                        , sec_code = q_order.SECCODE
                                        , class_code = q_order.CLASSCODE
                                        , exchange_comission = exchange_comission
                                        , tech_center_comission = 0
                                        , trans_id = q_order.trans_id
                                        }
                                      )
            q_order:fireOnOrder()
        end
    else
        -- report error
        assert(false, string.format("Unsupported operation: '%s'", order.OPERATION))
    end

    if "KILL_BALANCE" == q_order.EXECUTE_CONDITION then
        q_order.client:onQuoteChange(q_order, params, -q_order.balance)
        q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
        q_order.status = 3
        q_order.balance = 0
        q_order:fireOnOrder()
        return
    end
    client.orders = client.orders or {}
    client.ordersByTransId = client.ordersByTransId or {}
    client.orders[tostring(q_order.order_num)] = q_order
    client.ordersByTransId[q_order.TRANS_ID] = q_order

    if q_order.balance > 0 then
        local index = self.findPriceLevel(bookSide, q_order.price)
        assert(not bookSide[index] or bookSide[index].price >= q_order.price)
        if not bookSide[index] or bookSide[index].price ~= q_order.price then
            table.insert(bookSide, index, { price = q_order.price, quantity = 0, orders = {} })
        end
        bookSide[index].quantity = bookSide[index].quantity + q_order.balance
        table.insert(bookSide[index].orders, q_order)
    end
    -- the order has not been reported yet
    q_order:fireOnOrder()
end

function book:onOrder(client, order)
    local class, asset = order.CLASSCODE, order.SECCODE
    if order.ACTION == 'KILL_ORDER' then
        self:onKillOrder(client, order)
    elseif order.ACTION == 'CORRECT_ORDER' then
        self:onCorrectOrder(client, order)
    elseif order.ACTION == 'NEW_ORDER' then
        self:onNewOrder(client, order)
    end
end

function book:broadcastEvent(ev)
    for _,c in ipairs(clients) do
        if ev.event == "onQuote" then
            c:pushOnQuote(ev.class, ev.asset)
        elseif ev.event == "onTestOrder" then
            c:pushOnTestOrder(ev.order)
        elseif ev.event == "onAllTrade" then
            c:pushOnAllTrade(ev.trade)
        else
            assert(false, string.format("Error: unknown event type: %s", ev.event))
        end
    end
end

function book:flushEvents()
    for _,c in ipairs(clients) do
        c:flushEvents()
    end
end

function book:onEvent(client, ev)
    if ev.event == "onParams" then
        self:onParams(ev.class, ev.asset, ev.params)
    elseif ev.event == "onLoggedTrade" then
        self:onLoggedTrade(ev.trade)
    elseif ev.event == "onOrder" then
        if ev.order.ORDER_KEY then
            local q_order = client.ordersByTransId[ev.order.ORDER_KEY]
            if q_order then
                ev.order.ORDER_KEY = tostring(q_order.order_num)
                self:onOrder(client, ev.order)
            end
        else
            self:onOrder(client, ev.order)
        end
    else
        self:broadcastEvent(ev)
    end
end

local factory = {}

function factory.create()
    local self =
        { params =
            { classes = {}
            , }
        , tables = {}
        , orders = {}
        , books =
            { bid = {}
            , offer = {} 
            }
        }
    setmetatable(self, { __index = book })
    return self
end

return factory
