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

local book =
    { params =
        { classes = {}
        , }
    , tables = {}
    , clients = {}
    , orders = {}
    , books =
        { bid = {}
        , offer = {} 
        }
    }

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

function book:getParams(class, asset)
    return book.findOrCreate(self.params, class, asset)
end

function book:getTable(tableName)
    return self.findOrCreate(self.tables, tableName)
end

function book:getOrders(class, asset)
    return self.findOrCreate(self.orders, class, asset)
end

function book:getBook(class, asset)
    return self.findOrCreate(self.books, class, asset)
end

function book.findPriceLevel(bookSide, price)
    local l, r = 1, #bookSide
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
    local params = self:getParams(class, asset)
    for n,v in params do
        params[n] = v
    end
end

function book:onLoggedTrade(trade)
    local all_trades = self:getTable("all_trades")
    table.insert(all_trades, trade)
end

function book:onKillOrder(client, order)
    self:onCorrectOrder(client, {TRANS_ID=order.TRANS_ID, QUANTITY="0"})
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

function book:onCorrectOrder(client, order)
    local q_order = self.orders[order.TRANS_ID]
    assert(q_order)
    assert(q_order.PRICE == order.PRICE or not order.PRICE)
    assert(q_order.client.id == client.id)
    local b = self:getBook(order.CLASSCODE, order.SECCODE)
    local bookSide = q_order.OPERATION == 'B' and b.bid or b.offer
    local index = self.findPriceLevel(bookSide, q_order.price)
    assert(bookSide[index] and bookSide[index].price == q_order.price)
    local qty = tonumber(order.QUANTITY)
    if qty <= q_order.balance then
        qty = q_order.balance
    end
    local diff = q_order.quantity - qty
    local params = getParams(q_order.CLASSCODE, q_order.SECCODE)
    if not q_order.client:onQuoteChange(q_order, params, diff) then
        q_order.client:fireTransReply( { trans_id = order.trans_id
                                       , status = 6 
                                       , result_msg = "Not enough money"
                                       , flags = q_order.flags
                                       , balance = order.balance
                                       }
                                     )
        return
    end
    q_order.balance = q_order.balance - diff
    bookSide[index].quantity = bookSide[index].quantity - diff
    if q_order.balance == 0 then
        q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
        q_order.status = 3
        local found = false
        for i,o in ipairs(bookSide[index].orders) do
            if o.TRANS_ID == order.TRANS_ID then
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
        order.flags = bit.band(order.flags, bit.bnot(1))
    else
        assert(bookSide[index].quantity > 0)
    end
    q_order.client:fireTransReply( { trans_id = q_order.trans_id
                                   , status = q_order.status
                                   , result_msg=""
                                   , flags = q_order.flags
                                   , balance = order.balance
                                   }
                                 )
end

local trade_num = 1

function book:onNewOrder(client, order)
    -- make a copy
    local q_order = {}
    for k,v in pairs(order) do
        q_order[k] = v
    end

    self.order_num = self.order_num and self.order_num + 1 or 1
    q_order.client = client
    q_order.price = tonumber(q_order.price)
    q_order.order_num = self.order_num
    q_order.trans_id = tonumber(q_order.TRANS_ID)
    q_order.classcode = q_order.CLASSCODE
    q_order.seccode = q_order.SECCODE
    q_order.qunatity = tonumber(q_order.QUANTITY)
    q_order.balance = q_order.qunatity
    q_order.client = client
    q_order.status = 0

    -- validate order, check limits
    local params = getParams(q_order.CLASSCODE, q_order.SECCODE)
    assert(mask.conditions[q_order.EXECUTE_CONDITION], string.format("Unknown execute condition '%s'", q_order.EXECUTE_CONDITION))
    assert(mask.operation[q_order.OPERATION], string.format("Unknown operation '%s'", q_order.OPERATION))
    q_order.flags = bit.bor( mask.flags.ORDER_LIMITED
                           , mask.flags.ACTIVE
                           , mask.operations[q_order.OPERATION]
                           , mask.flags.LIMITED
                           , mask.conditions[q_order.EXECUTE_CONDITION]
                           )
    q_order.status = 1

    if not q_order.client:onQuoteChange(q_order, params, q_order.quantity) then
        q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
        q_order.status = 6
        q_order.client:fireTransReply( { trans_id = q_order.trans_id
                                       , status = 6
                                       , result_msg = "Not enough money"
                                       , flags = 0
                                       , balance = 0
                                       }
                                     )
        return
    end
    -- put order to table
    local orders = q_order.client:getOrders()
    table.insert(orders, q_order)

    -- process a new order
    local b = self:getBook(q_order.CLASSCODE, q_order.SECCODE)
    local bookSide = nil
    if q_order.OPERATION == 'B' then
        bookSide = b.bid
        local amount = 0
        for i = 1,#b.offer do
            if b.offer[i].price > q_order.price then
                break
            end
            amount = amount + b.offer[i].quantity
        end
        if "KILL_OR_FILL" == q_order.EXECUTE_CONDITION and q_order.quantity > amount then
            -- deactivate and return
            q_order.client:onQuoteChange(q_order, params, -q_order.quantity)
            q_order.status = 3
            q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
            q_order.client:fireOnTransReply( { trans_id = q_order.trans_id
                                             , status = q_order.status
                                             , result_msg=""
                                             , flags = q_order.flags
                                             , balance = q_order.balance
                                             }
                                           )
            return
        end
        -- uncross orders
        while q_order.balance > 0 and #b.offer > 0 and b.offer[1].price <= q_order.price do
            trade_num = trade_num + 1
            local q = b.offer[1]
            local crossOrder = q.orders[1]
            local size = math.min(q_order.balance, crossOrder.balance)
            q.quantity = q.qantity - size
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
            crossOrder.client:onOrderFilled(crossOrder, crossOrder.price, -size)
            crossOrder.client:fireOnTrade( { trade_num = trade_num
                                           , order_num = crossOrder.order_num
                                           , account = crossOrder.client.account
                                           , price = crossOrder.price
                                           , qty = size
                                           , value = size*crossOrder.price
                                           , flags = crossOrder.flags
                                           , sec_code = crossOrder.SECCODE
                                           , class_code = crossOrder.CLASSCODE
                                           , trans_id = crossOrder.trans_id
                                           }
                                         )
            crossOrder.client:fireOnTransReply( { trans_id = crossOrder.trans_id
                                                , status = crossOrder.status
                                                , result_msg=""
                                                , flags = crossOrder.flags
                                                , balance = order.balance
                                                }
                                              )

            -- update order
            q_order.balance = q_order.balance - size
            if q_order.balance == 0 then
                q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
                q_order.status = 3
            end
            q_order.client:onQuoteChange(q_order, params, -size)
            q_order.client:onOrderFilled(q_order, crossOrder.price, size)
            q_order.client:fireOnTrade( { trade_num = trade_num
                                        , order_num = q_order.order_num
                                        , account = q_order.client.account
                                        , price = crossOrder.price
                                        , qty = size
                                        , value = size*crossOrder.price
                                        , flags = q_order.flags
                                        , sec_code = q_order.SECCODE
                                        , class_code = q_order.CLASSCODE
                                        , trans_id = q_order.trans_id
                                        }
                                      )
            q_order.client:fireOnTransReply( { trans_id = q_order.trans_id
                                             , status = q_order.status
                                             , result_msg=""
                                             , flags = q_order.flags
                                             , balance = order.balance
                                             }
                                           )
        end
    elseif q_order.OPERATION == 'S' then
        bookSide = b.offer
        local amount = 0
        for i = 1,#b.bid do
            local index= #b.bid - i + 1
            if b.bid[index].price < q_order.price then
                break
            end
            amount = amount + b.bid[index].quantity
        end
        if "KILL_OR_FILL" == q_order.EXECUTE_CONDITION and q_order.quantity > amount then
            -- deactivate and return
            q_order.client:onQuoteChange(q_order, params, -q_order.quantity)
            q_order.status = 3
            q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
            q_order.client:fireOnTransReply( { trans_id = q_order.trans_id
                                             , status = q_order.status
                                             , result_msg=""
                                             , flags = q_order.flags
                                             , balance = q_order.balance
                                             }
                                           )
            return
        end
        -- uncross orders
        while q_order.balance > 0 and #b.bid > 0 and b.bid[#b.bid].price >= q_order.price do
            trade_num = trade_num + 1
            local q = b.bid[#b.bid]
            local crossOrder = q.orders[1]
            local size = math.min(q_order.balance, crossOrder.balance)
            q.quantity = q.qantity - size
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
            crossOrder.client:onOrderFilled(crossOrder, crossOrder.price, size)
            crossOrder.client:fireOnTrade( { trade_num = trade_num
                                           , order_num = crossOrder.order_num
                                           , account = crossOrder.client.account
                                           , price = crossOrder.price
                                           , qty = size
                                           , value = size*crossOrder.price
                                           , flags = crossOrder.flags
                                           , sec_code = crossOrder.SECCODE
                                           , class_code = crossOrder.CLASSCODE
                                           , trans_id = crossOrder.trans_id
                                           }
                                         )
            crossOrder.client:fireOnTransReply( { trans_id = crossOrder.trans_id
                                                , status = crossOrder.status
                                                , result_msg=""
                                                , flags = crossOrder.flags
                                                , balance = order.balance
                                                }
                                              )

            -- update order
            q_order.balance = q_order.balance - size
            if q_order.balance == 0 then
                q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
                q_order.status = 3
            end
            q_order.client:onQuoteChange(q_order, params, -size)
            q_order.client:onOrderFilled(q_order, crossOrder.price, -size)
            q_order.client:fireOnTrade( { trade_num = trade_num
                                        , order_num = q_order.order_num
                                        , account = q_order.client.account
                                        , price = crossOrder.price
                                        , qty = size
                                        , value = size*crossOrder.price
                                        , flags = q_order.flags
                                        , sec_code = q_order.SECCODE
                                        , class_code = q_order.CLASSCODE
                                        , trans_id = q_order.trans_id
                                        }
                                      )
            q_order.client:fireOnTransReply( { trans_id = q_order.trans_id
                                             , status = q_order.status
                                             , result_msg=""
                                             , flags = q_order.flags
                                             , balance = order.balance
                                             }
                                           )
        end
    else
        -- report error
        assert(false, string.format("Unsupported operation: '%s'", order.OPERATION))
    end

    if "KILL_BALANCE" == q_order.EXECUTE_CONDITION then
        q_order.flags = bit.band(q_order.flags, bit.bnot(mask.flags.ACTIVE))
        q_order.status = 3
        q_order.client:fireOnTransReply( { trans_id = q_order.trans_id
                                         , status = q_order.status
                                         , result_msg=""
                                         , flags = q_order.flags
                                         , balance = order.balance
                                         }
                                       )
        return
    end
    local index = self.findPriceLevel(bookSide, q_order.price)
    if not bookSide[index] or bookSide[index].price ~= q_order.price then
        table.insert(bookSide, index, { price = q_order.price, quantity = 0, orders = {} })
    end
    bookSide[index].quantity = bookSide[index].quantity + q_order.qunatity
    table.insert(bookSide.orders, q_order)
    self.orders[q_order.TRANS_ID] = q_order
    if q_order.balance == q_order.qunatity then
        -- the order has not been reported yet
        q_order.client:fireOnTransReply( { trans_id = q_order.trans_id
                                         , status = q_order.status
                                         , result_msg=""
                                         , flags = q_order.flags
                                         , balance = order.balance
                                         }
                                       )
    end
end

function book:onOrder(client, order)
    if order.ACTION == 'KILL_ORDER' then
        self:onKillOrder(client, order)
    elseif order.ACTION == 'CORRECT_ORDER' then
        self:onCorrectOrder(client, order)
    elseif order.ACTION == 'NEW_ORDER' then
        self:onNewOrder(client, order)
    end
end

function book:fireEvent(client, ev)
end

function book:onEvent(client, ev)
    if ev.event == "OnParams" then
        self:onParams(ev.class, ev.asset, ev.params)
    elseif ev.event == "OnLoggedTrade" then
        self:onLoggedTrade(ev.trade)
    elseif ev.event == "onOrder" then
        self:onOrder(client, ev.order)
    else
        self:fireEvent(client, ev)
    end
    
end

return q_book
