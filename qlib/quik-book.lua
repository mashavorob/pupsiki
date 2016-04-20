--[[
#
# Симулятор стакана (l2-book, quik specific)
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local book = {
    l2Snap = nil,  -- { bid_count=20, offer_count=20,  bid={ {price=1245, quantity="12"}, ...}, offer={...} },
    order = nil, -- { price=0, qty=0, flags=0 }
    originalL2Snap = { bid_count=0, offer_count=0,  bid={}, offer={} },

    l2 = false,
    pos = 0,
    paid = 0,
    deals = 0,
}

local tests = {
}

local emptyBook = { bid_count=0, offer_count=0, bid={}, offer={} }

q_book = { }

function q_book.getEmptyBook()
    return book.makeCopy(emptyBook, true)
end

function q_book.create(class, asset, priceStep, priceStepValue)
    local res = { class=class
                , asset=asset
                , priceStep=priceStep
                , priceStepValue=priceStepValue
                }
    setmetatable(res, { __index=book})
    return res
end

function q_book.getTestSuite()
    return tests
end

function book:getL2Snapshot()
    return book.makeCopy( self.l2Snap or emptyBook, true )
end

function book:onQuote(l2Snap)

    if l2Snap then
        setmetatable(l2Snap, { __index=emptyBook } )
    else
        l2Snap = emptyBook
    end

    self.originalL2Snap = l2Snap
    self.l2Snap = book.makeCopy(self.originalL2Snap)
    local evs = self:updateBookWithOrder(self.l2Snap, self.order)
    table.insert(evs, {name="OnQuote", data={class=self.class, asset=self.asset, l2Snap=book.makeCopy(self.l2Snap, true)}})
    if order and order.balance == 0 then
        self.order = nil
    end
    return evs
end

function book:onTrade(trade)
    local evs = { }
    local op = ((trade.flags % 2) == 1) and 'S' or 'B'
    local sellOrder = self.order and ((math.floor(self.order.flags/4) % 2) == 1)
    local buyOrder = self.order and ((math.floor(self.order.flags/4) % 2) == 0)
    local orderUpdated = false
    if op == 'S' then
        -- sell
        if buyOrder and (
            not self.originalL2Snap 
            or self.originalL2Snap.bid_count == 0 
            or self.originalL2Snap.bid[self.originalL2Snap.bid_count].price < self.order.price
            )
        then
            orderUpdated = true
            local size = math.min(trade.qty, self.order.balance)
            self.order.balance = self.order.balance - size
            table.insert(evs, {name="OnAllTrade", data=self:makeTrade(op, self.order.price, size)})
            trade.qty = trade.qty - size
            self.pos = self.pos + size
            self.paid = self.paid - quote.price/self.priceStep*self.priceStepValue*size
            self.deals = self.deals + size
        end
    else
        -- buy
        if sellOrder and (
            not self.originalL2Snap
            or self.originalL2Snap.offer_count == 0 
            or self.originalL2Snap.offer[1].price > self.order.price
            )
        then
            orderUpdated = true
            local size = math.min(trade.qty, self.order.balance)
            self.order.balance = self.order.balance - size
            table.insert(evs, {name="OnAllTrade", data=self:makeTrade(op, self.order.price, size)})
            trade.qty = trade.qty - size
            self.pos = self.pos - size
            self.paid = self.paid + quote.price/self.priceStep*self.priceStepValue*size
            self.deals = self.deals + size
        end
    end
    
    if trade.qty > 0 then
        table.insert(evs, {name="OnAllTrade", data=self:makeTrade(op, trade.price, trade.qty)})
    end
    if orderUpdated then
        table.insert(evs, {name="OnTransReply", data=self.order})
        if self.order.quantity == 0 then
            self.order.flags = math.floor(self.order.flags/2)*2
            self.order = nil
        end
        self.l2Snap = book.makeCopy(self.originalL2Snap)
        self:updateBookWithOrder(self.l2Snap, self.order)
        table.insert(evs, {name="OnQuote", data={class=self.class, asset=self.asset, l2Snap=book.makeCopy(self.l2Snap, true)}})
    end    
    return evs
end

function book:onOrder(trans)
    local evs = {}
    local msg = nil
    if trans.ACTION == "KILL_ORDER" then
        if self.order and self.order.order_num == tonumber(trans.ORDER_KEY) then
            self.order.flags = math.floor(self.order.flags/2)*2 -- inactive
            self.order.flags = self.order.flags + 2             -- canceled
            table.insert(evs, {name="OnTransReply", data=self:makeOrder(trans)})
            table.insert(evs, {name="OnTransReply", data=self.order})
            self.l2Snap = book.makeCopy(self.originalL2Snap)
            table.insert(evs, {name="OnQuote", data={class=self.class, asset=self.asset, l2Snap=book.makeCopy(self.l2Snap, true)}})
            self.order = nil
        else
            msg = string.format("Order with key %s does not exists", trans.ORDER_KEY)
        end
    elseif trans.ACTION == "NEW_ORDER" then
        assert(not self.order, "multiple orders are not supported")
        self.order = self:makeOrder(trans)
        self.l2Snap = book.makeCopy(self.originalL2Snap)
        local prevHoldings = { pos = self.pos, paid = self.paid, deals = self.deals }
        evs = self:updateBookWithOrder(self.l2Snap, self.order, true)
        if trans.EXECUTE_CONDITION=="KILL_OR_FILL" and self.order.balance > 0 then
            -- discard the order
            self.order = self:makeOrder(trans)
            self.order.flags = math.floor(self.order.flags/2)*2
            evs = { {name="OnTransReply", data=self.order} }
            self.order = nil
            self.pos, self.paid, self.deals = prevHoldigs.pos, prevHolding.paid, prevHoldigs.deals
        elseif trans.EXECUTE_CONDITION=="KILL_BALANCE" then
            self.order.flags = math.floor(self.order.flags/2)*2
            table.insert(evs, {name="OnTransReply", data=self.order})
            self.order = nil
        elseif trans.EXECUTE_CONDITION=="PUT_IN_QUEUE" or 
            trans.EXECUTE_CONDITION=="KILL_OR_FILL" and self.order.balance == 0 
        then
            table.insert(evs, {name="OnTransReply", data=self.order})
            table.insert(evs, {name="OnQuote", data={class=self.class, asset=self.asset, l2Snap=book.makeCopy(self.l2Snap, true)}})
            if self.order.balance == 0 then
                self.order.flags = math.floor(self.order.flags/2)*2
                self.order = nil
            end
        else
            assert(false, "Unknown transaction execute condition")
        end
    else
        assert(false, "Unsupported transaction ACTION")
    end
    return evs, msg
end

function book:updateBookWithOrder(l2Snap, order, blockTransReply)
    local evs = { }

    local onOrderReply = false

    local sell = order and (math.floor(order.flags/4) % 2) == 1
    local buy = order and not sell
     
    if sell then
        -- sell order
        while (l2Snap.bid_count > 0) 
            and (l2Snap.bid[l2Snap.bid_count].price >= order.price)
            and order.balance > 0
        do
            local quote = l2Snap.bid[l2Snap.bid_count]
            local size = math.min(order.balance, quote.quantity)
            order.balance = order.balance - size
            quote.quantity = quote.quantity - size
            if quote.quantity == 0 then
                table.remove(l2Snap.bid, l2Snap.bid_count)
                l2Snap.bid_count = l2Snap.bid_count - 1
            end
            table.insert(evs, {name="OnAllTrade", data=self:makeTrade('S', quote.price, size)})
            self.pos = self.pos - size
            self.paid = self.paid + quote.price/self.priceStep*self.priceStepValue*size
            onOrderReply = true
        end
        if order.balance > 0 then
            local index = 1
            while index <= l2Snap.offer_count 
                and order.price > l2Snap.offer[index].price
            do
                index = index + 1
            end
            if index > l2Snap.offer_count or l2Snap.offer[index].price ~= order.price then
                l2Snap.offer_count = l2Snap.offer_count + 1
                table.insert(l2Snap.offer, index, { price=order.price, quantity=0 })
            end
            l2Snap.offer[index].quantity = l2Snap.offer[index].quantity + order.balance
        end
    elseif buy then
        -- buy order

        while (l2Snap.offer_count > 0) 
            and (l2Snap.offer[1].price <= order.price)
            and order.balance > 0
        do
            local quote = l2Snap.offer[1]
            local size = math.min(order.balance, quote.quantity)
            order.balance = order.balance - size
            quote.quantity = quote.quantity - size
            if quote.quantity == 0 then
                table.remove(l2Snap.offer, 1)
                l2Snap.offer_count = l2Snap.offer_count - 1
            end
            table.insert(evs, {name="OnAllTrade", data=self:makeTrade('B', quote.price, size)})
            self.pos = self.pos + size
            self.paid = self.paid - quote.price/self.priceStep*self.priceStepValue*size
            onOrderReply = true
        end
        
        if order.balance > 0 then
            local index = 1
            while index <= l2Snap.bid_count 
                and order.price > l2Snap.bid[index].price
            do
                index = index + 1
            end
            if index > l2Snap.bid_count or l2Snap.bid[index].price ~= order.price then
                l2Snap.bid_count = l2Snap.bid_count + 1
                table.insert(l2Snap.bid, index, { price = order.price, quantity = 0 })
            end
            l2Snap.bid[index].quantity = l2Snap.bid[index].quantity + order.balance
        end
    end
    if onOrderReply then
        if order.balance == 0 then
            self.order.flags = math.floor(self.order.flags/2)*2
        end
        if not blockTransReply then
            table.insert(evs, {name="OnTransReply", data=order})
        end
    end
    return evs
end

function book.makeCopy(obj, stringize)
    if stringize and type(obj) == "number" then
        return tostring(obj)
    end
    if type(obj) ~= "table" then
        return obj
    end

    local copy = {}
    for k,v in pairs(obj) do
        copy[k] = book.makeCopy(v, stringize)
    end
    return copy
end

local tradeNum = 0
local orderNum = 0
local dummyDate = 
    { week_day=1
    , hour=1
    , ms=0
    , mcs=0
    , day=0
    , month=1
    , sec=1
    , year=1970
    , min=1
    }

function book:makeOrder(trans)
    orderNum = orderNum + 1

    local order = 
        { order_num=orderNum
        , flags= 
            1  +                                  -- 0x01 active
            (trans.OPERATION and trans.OPERATION == 'S' and 4 or 0) + -- 0x04 SELL or BUY
            8  +                                  -- 0x08 limited
            16                                    -- 0x10 allow trades with different prices
        , brokerref=""
        , userid=""
        , firmid=""
        , account=trans.ACCOUNT
        , price=trans.PRICE and tonumber(trans.PRICE) or nil
        , qty=trans.QUANTITY and tonumber(trans.QUANTITY) or nil
        , balance=tonumber(trans.QUANTITY) or nil
        , value=trans.PRICE and trans.QUANTITY and self:getValue(tonumber(trans.PRICE), tonumber(trans.QUANTITY)) or nil
        , accruedint=0
        , yield=0 
        , trans_id=trans.TRANS_ID and tonumber(trans.TRANS_ID) or nil
        , client_code=""
        , price2=0
        , settlecode=""
        , uid=0
        , exchange_code="SimX"
        , activation_time=0
        , linkedorder=0
        , expiry=0
        , sec_code=trans.SECCODE
        , class_code=trans.CLASSCODE
        , datetime = dummyDate
        , withdraw_datetime=nil
        , bank_acc_id=""
        , value_entry_type=0
        , repoterm=0
        , repo2value=0
        , repo_value_balance=0
        , start_discount=0
        , reject_reason=""
        , ext_order_flags=0
        , min_qty=0
        , exec_time=0
        , side_qualifier=0
        , acnt_type=0
        , capacity=0
        , passive_only_order=0
        }
    return order
end

function book:getValue(price, size)
    return math.floor(price/self.priceStep)*self.priceStepValue
end

function book:makeTrade(op, price, size)
    tradeNum = tradeNum + 1
    return 
        { repoterm=0
        , price=price
        , trade_num=tradeNum
        , yield=0
        , value=math.floor(price/self.priceStep)*self.priceStepValue
        , qty=size
        , reporate=0
        , class_code=self.class
        , sec_code=self.asset
        , repovalue=0
        , accruedint=0
        , flags = (op == 'S' and 1 or 2)
        , datetime = dummyDate
        , period=1
        , repo2value=0
        , settlecode=""
        }
end

function tests.testFirstBook()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count=2
        , offer_count=2 
        , bid=
            { {price=20, quantity=1}
            , {price=30, quantity=1}
            }
        , offer=
            { {price=40, quantity=1}
            , {price=50, quantity=1},
            } 
        }
    local evs = testee:onQuote(l2)
    assert(#evs == 1)
    assert(evs[1].name == "OnQuote")
end

function tests.testFirstTradeSell()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local t =
        { flags=1
        , qty=1 
        , price=20
        } 
    local evs = testee:onTrade(t)
    assert(#evs == 1)
    assert(evs[1].name == "OnAllTrade", evs[1].name)
    assert(evs[1].data.flags == t.flags)
    assert(evs[1].data.qty == t.qty)
    assert(evs[1].data.price == t.price)
end

function tests.testFirstTradeBuy()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local t = 
        { flags=2
        ,  qty=1 
        ,  price=20
        } 
    local evs = testee:onTrade(t)
    assert(#evs == 1)
    assert(evs[1].name == "OnAllTrade")
    assert(evs[1].data.flags == t.flags)
    assert(evs[1].data.qty == t.qty)
    assert(evs[1].data.price == t.price)
end

function tests.testFirstOrderBuy()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local o =
        { OPERATION="B"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="10" 
        , QUANTITY="1"
        , TRANS_ID=1
        , ACTION="NEW_ORDER"
        } 
    local evs = testee:onOrder(o)
    assert(#evs == 2)
    assert(evs[1].name == "OnTransReply")
    assert(evs[1].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[1].data.balance == tonumber(o.QUANTITY))
    assert(evs[2].name == "OnQuote")
    assert(evs[2].data.l2Snap.bid_count == "1")
    assert(evs[2].data.l2Snap.offer_count == "0")
    assert(evs[2].data.l2Snap.bid[1].price == o.PRICE)
    assert(evs[2].data.l2Snap.bid[1].quantity == o.QUANTITY)
end

function tests.testFirstOrderSell()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local o =
        { OPERATION="S"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="10" 
        , QUANTITY="1"
        , TRANS_ID="2"
        , ACTION="NEW_ORDER"
        } 
    local evs = testee:onOrder(o)
    assert(#evs == 2)
    assert(evs[1].name == "OnTransReply")
    assert(evs[1].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[1].data.balance == tonumber(o.QUANTITY))
    assert(evs[2].name == "OnQuote")
    assert(evs[2].data.l2Snap.bid_count == "0")
    assert(evs[2].data.l2Snap.offer_count == "1")
    assert(evs[2].data.l2Snap.offer[1].price == o.PRICE)
    assert(evs[2].data.l2Snap.offer[1].quantity == o.QUANTITY)
end

function tests.testOrderIntoBid()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count=3
        , offer_count=3
        , bid=
            { {price=10, quantity=1}
            , {price=20, quantity=1}
            , {price=30, quantity=1}
            }
        , offer=
            { {price=40, quantity=1}
            , {price=50, quantity=1}
            , {price=60, quantity=1}
            } 
        }
    testee:onQuote(l2)
    
    local o = 
        { OPERATION="B"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="30" 
        , QUANTITY="1"
        , TRANS_ID="3"
        , ACTION="NEW_ORDER"
        }    
    local evs = testee:onOrder(o)
    assert(#evs == 2)
    assert(evs[1].name == "OnTransReply")
    assert(evs[1].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[1].data.balance == tonumber(o.QUANTITY))
    assert(evs[2].name == "OnQuote")
    assert(evs[2].data.l2Snap.bid[1].quantity == "1")
    assert(evs[2].data.l2Snap.bid[2].quantity == "1")
    assert(evs[2].data.l2Snap.bid[3].quantity == "2", evs[2].data.l2Snap.bid[3].quantity)
    assert(evs[2].data.l2Snap.offer[1].quantity == "1")
    assert(evs[2].data.l2Snap.offer[2].quantity == "1")
    assert(evs[2].data.l2Snap.offer[3].quantity == "1")
end

function tests.testOrderIntoOffer()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 3
        , bid =
            { {price=10, quantity=1}
            , {price=20, quantity=1}
            , {price=30, quantity=1}
            }
        , offer = 
            { {price=40, quantity=1}
            , {price=50, quantity=1}
            , {price=60, quantity=1}
            } 
        }
    testee:onQuote(l2)
    
    local o = 
        { OPERATION="S"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="40" 
        , QUANTITY="1"
        , TRANS_ID="6"
        , ACTION="NEW_ORDER"
        } 
    local evs = testee:onOrder(o)
    assert(#evs == 2)
    assert(evs[1].name == "OnTransReply")
    assert(evs[1].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[1].data.balance == tonumber(o.QUANTITY))
    assert(evs[2].name == "OnQuote")
    assert(evs[2].data.l2Snap.bid[1].quantity == "1")
    assert(evs[2].data.l2Snap.bid[2].quantity == "1")
    assert(evs[2].data.l2Snap.bid[3].quantity == "1")
    assert(evs[2].data.l2Snap.offer[1].quantity == "2")
    assert(evs[2].data.l2Snap.offer[2].quantity == "1")
    assert(evs[2].data.l2Snap.offer[3].quantity == "1")
end

function tests.testOrderBuyIntoMiddle()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 3
        , bid =
            { {price=10, quantity=1}
            , {price=20, quantity=1}
            , {price=30, quantity=1}
            }
        , offer=
            { {price=50, quantity=1}
            , {price=60, quantity=1}
            , {price=70, quantity=1}
            } 
        }
    testee:onQuote(l2)
    
    local o = 
        { OPERATION="B"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="40" 
        , QUANTITY="1"
        , TRANS_ID="7"
        , ACTION="NEW_ORDER"
        } 
    local evs = testee:onOrder(o)
    assert(#evs == 2)

    assert(evs[1].name == "OnTransReply")
    assert(evs[1].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[1].data.balance == tonumber(o.QUANTITY))

    assert(evs[2].name == "OnQuote")
    
    assert(evs[2].data.l2Snap.bid_count == "4")
    assert(evs[2].data.l2Snap.offer_count == "3")

    assert(evs[2].data.l2Snap.bid[1].quantity == "1")
    assert(evs[2].data.l2Snap.bid[1].price == "10")
    assert(evs[2].data.l2Snap.bid[2].quantity == "1")
    assert(evs[2].data.l2Snap.bid[2].price == "20")
    assert(evs[2].data.l2Snap.bid[3].quantity == "1")
    assert(evs[2].data.l2Snap.bid[3].price == "30")
    assert(evs[2].data.l2Snap.bid[4].quantity == "1")
    assert(evs[2].data.l2Snap.bid[4].price == "40")
    assert(evs[2].data.l2Snap.offer[1].quantity == "1")
    assert(evs[2].data.l2Snap.offer[2].quantity == "1")
    assert(evs[2].data.l2Snap.offer[3].quantity == "1")
end

function tests.testOrderSellIntoMiddle()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 3
        , bid = 
            { {price=10, quantity=1}
            , {price=20, quantity=1}
            , {price=30, quantity=1}
            }
        , offer = 
            { {price=50, quantity=1}
            , {price=60, quantity=1}
            , {price=70, quantity=1}
            } 
        }
    testee:onQuote(l2)
    
    local o = 
        { OPERATION="S"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="40" 
        , QUANTITY="1"
        , TRANS_ID="8"
        , ACTION="NEW_ORDER"
        } 
    local evs = testee:onOrder(o)
    assert(#evs == 2)

    assert(evs[1].name == "OnTransReply")
    assert(evs[1].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[1].data.balance == tonumber(o.QUANTITY))
    
    assert(evs[2].name == "OnQuote")
    
    assert(evs[2].data.l2Snap.bid_count == "3")
    assert(evs[2].data.l2Snap.offer_count == "4", evs[2].data.l2Snap.offer_count)

    assert(evs[2].data.l2Snap.bid[1].quantity == "1")
    assert(evs[2].data.l2Snap.bid[2].quantity == "1")
    assert(evs[2].data.l2Snap.bid[3].quantity == "1")
    assert(evs[2].data.l2Snap.offer[1].quantity == "1")
    assert(evs[2].data.l2Snap.offer[1].price == "40")
    assert(evs[2].data.l2Snap.offer[2].quantity == "1")
    assert(evs[2].data.l2Snap.offer[2].price == "50")
    assert(evs[2].data.l2Snap.offer[3].quantity == "1")
    assert(evs[2].data.l2Snap.offer[3].price == "60")
    assert(evs[2].data.l2Snap.offer[4].quantity == "1")
    assert(evs[2].data.l2Snap.offer[4].price == "70")
end

function tests.testOrderBuyIntoSparse()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 3
        , bid = 
            { {price=10, quantity=1}
            , {price=20, quantity=1}
            , {price=40, quantity=1}
            }
        , offer = 
            { {price=50, quantity=1}
            , {price=60, quantity=1}
            , {price=70, quantity=1}
            } 
        }
    testee:onQuote(l2)
    
    local o = 
        { OPERATION="B"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="30" 
        , QUANTITY="1"
        , TRANS_ID="9"
        , ACTION="NEW_ORDER"
    } 
    local evs = testee:onOrder(o)
    assert(#evs == 2)

    assert(evs[1].name == "OnTransReply")
    assert(evs[1].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[1].data.balance == tonumber(o.QUANTITY))
    
    assert(evs[2].name == "OnQuote")
    
    assert(evs[2].data.l2Snap.bid_count == "4")
    assert(evs[2].data.l2Snap.offer_count == "3")

    assert(evs[2].data.l2Snap.bid[1].quantity == "1")
    assert(evs[2].data.l2Snap.bid[1].price == "10")
    assert(evs[2].data.l2Snap.bid[2].quantity == "1")
    assert(evs[2].data.l2Snap.bid[2].price == "20")
    assert(evs[2].data.l2Snap.bid[3].quantity == "1")
    assert(evs[2].data.l2Snap.bid[3].price == "30")
    assert(evs[2].data.l2Snap.bid[4].quantity == "1")
    assert(evs[2].data.l2Snap.bid[4].price == "40")
    assert(evs[2].data.l2Snap.offer[1].quantity == "1")
    assert(evs[2].data.l2Snap.offer[2].quantity == "1")
    assert(evs[2].data.l2Snap.offer[3].quantity == "1")
end

function tests.testOrderSellIntoSparse()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 3
        , bid = 
            { {price=10, quantity=1}
            , {price=20, quantity=1}
            , {price=30, quantity=1}
            }
        , offer = 
            { {price=40, quantity=1}
            , {price=60, quantity=1}
            , {price=70, quantity=1}
            } 
        }
    testee:onQuote(l2)
    
    local o = 
        { OPERATION="S"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="50" 
        , QUANTITY="1"
        , TRANS_ID="10"
        , ACTION="NEW_ORDER"
        } 
 
    local evs = testee:onOrder(o)
    assert(#evs == 2)

    assert(evs[1].name == "OnTransReply")
    assert(evs[1].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[1].data.balance == tonumber(o.QUANTITY))

    assert(evs[2].name == "OnQuote")
    
    assert(evs[2].data.l2Snap.bid_count == "3")
    assert(evs[2].data.l2Snap.offer_count == "4")

    assert(evs[2].data.l2Snap.bid[1].quantity == "1")
    assert(evs[2].data.l2Snap.bid[2].quantity == "1")
    assert(evs[2].data.l2Snap.bid[3].quantity == "1")
    assert(evs[2].data.l2Snap.offer[1].quantity == "1")
    assert(evs[2].data.l2Snap.offer[1].price == "40")
    assert(evs[2].data.l2Snap.offer[2].quantity == "1")
    assert(evs[2].data.l2Snap.offer[2].price == "50")
    assert(evs[2].data.l2Snap.offer[3].quantity == "1")
    assert(evs[2].data.l2Snap.offer[3].price == "60")
    assert(evs[2].data.l2Snap.offer[4].quantity == "1")
    assert(evs[2].data.l2Snap.offer[4].price == "70")
end

function tests.testOrderBuysFromBook()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 3
        , bid =
            { {price=10, quantity=5}
            , {price=20, quantity=5} 
            , {price=30, quantity=5}
            }
        , offer =
            { {price=40, quantity=5}
            , {price=50, quantity=5}
            , {price=60, quantity=5}
            } 
        }
    testee:onQuote(l2)

    local o = 
        { OPERATION="B"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="50" 
        , QUANTITY="8"
        , TRANS_ID="10"
        , ACTION="NEW_ORDER"
        }    
    local evs = testee:onOrder(o)

    assert(#evs == 4)

    assert(evs[1].name == "OnAllTrade")
    assert(evs[2].name == "OnAllTrade")
    assert(evs[3].name == "OnTransReply")
    assert(evs[3].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[3].data.balance == 0)
    assert(evs[4].name == "OnQuote")

    assert(evs[4].data.l2Snap.bid_count == "3")
    assert(evs[4].data.l2Snap.offer_count == "2")

    assert(evs[4].data.l2Snap.offer[1].quantity == "2")
    assert(evs[4].data.l2Snap.offer[1].price == "50")
    assert(evs[4].data.l2Snap.offer[2].quantity == "5")
    assert(evs[4].data.l2Snap.offer[2].price == "60")
end

function tests.testOrderSellsFromBook()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 3
        , bid =
            { {price=10, quantity=5}
            , {price=20, quantity=5}
            , {price=30, quantity=5}
            }
        , offer =
            { {price=40, quantity=5}
            , {price=50, quantity=5}
            , {price=60, quantity=5}
            } 
        }
    testee:onQuote(l2)

    local o = 
        { OPERATION = "S"
        , EXECUTE_CONDITION = "PUT_IN_QUEUE"
        , PRICE = "20" 
        , QUANTITY = "8"
        , ACTION = "NEW_ORDER"
        }    
    local evs = testee:onOrder(o)

    assert(#evs == 4)
    assert(evs[1].name == "OnAllTrade")
    assert(evs[2].name == "OnAllTrade")
    assert(evs[3].name == "OnTransReply")
    assert(evs[3].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[3].data.balance == 0)
    assert(evs[4].name == "OnQuote")

    assert(evs[4].data.l2Snap.bid_count == "2")
    assert(evs[4].data.l2Snap.offer_count == "3")

    assert(evs[4].data.l2Snap.bid[1].quantity == "5")
    assert(evs[4].data.l2Snap.bid[1].price == "10")
    assert(evs[4].data.l2Snap.bid[2].quantity == "2")
    assert(evs[4].data.l2Snap.bid[2].price == "20")
end

function tests.testTradeBuysFromBook()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 2
        , offer_count = 3 
        , bid =
            { {price=10, quantity=5}
            , {price=20, quantity=5}
            }
        , offer=
            { {price=40, quantity=5}
            , {price=50, quantity=5}
            , {price=60, quantity=5}
            } 
        }
    testee:onQuote(l2)

    local o = 
        { OPERATION = "B"
        , EXECUTE_CONDITION = "PUT_IN_QUEUE"
        , PRICE = "30" 
        , QUANTITY = "3"
        , TRANS_ID = "11"
        , ACTION = "NEW_ORDER"
        } 
    testee:onOrder(o)
    -- book: bid 8 at 30
    local t = 
        { flags=1 -- sell
        , qty=2 
        , price=20
        }
    local evs = testee:onTrade(t)

    assert(#evs == 3)
    assert(evs[1].name == "OnAllTrade")
    assert((evs[1].data.flags % 2) == 1) -- sell
    assert(evs[1].data.price == 30)
    assert(evs[1].data.qty == 2)

    assert(evs[2].name == "OnTransReply")
    assert(evs[2].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[2].data.balance == 1)

    assert(evs[3].name == "OnQuote")

    assert(evs[3].data.l2Snap.bid_count == "3")
    assert(evs[3].data.l2Snap.offer_count == "3")

    assert(evs[3].data.l2Snap.bid[1].quantity == "5")
    assert(evs[3].data.l2Snap.bid[1].price == "10")
    assert(evs[3].data.l2Snap.bid[2].quantity == "5")
    assert(evs[3].data.l2Snap.bid[2].price == "20")
    assert(evs[3].data.l2Snap.bid[3].quantity == "1")
    assert(evs[3].data.l2Snap.bid[3].price == "30")
end

function tests.testTradeSellsFromBook()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 2
        , bid =
            { {price=10, quantity=5}
            , {price=20, quantity=5} 
            , {price=30, quantity=5}
            }, 
        offer =
            { {price=50, quantity=5}
            , {price=60, quantity=5}
            } 
        }
    testee:onQuote(l2)

    local o = 
        { OPERATION = "S" 
        , EXECUTE_CONDITION = "PUT_IN_QUEUE"
        , PRICE = "40" 
        , QUANTITY = "3"
        , TRANS_ID = "12"
        , ACTION = "NEW_ORDER"
        } 
    testee:onOrder(o)
    -- book: offer 8 at 30
    local t = { flags=2 -- buy
              ,  qty=2 
              ,  price=50
    }
    local evs = testee:onTrade(t)

    assert(#evs == 3)
    assert(evs[1].name == "OnAllTrade")
    assert(evs[1].data.flags == 2) -- buy
    assert(evs[1].data.price == 40)
    assert(evs[1].data.qty == 2)

    assert(evs[2].name == "OnTransReply")
    assert(evs[2].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[2].data.balance == 1)

    assert(evs[3].name == "OnQuote")

    assert(evs[3].data.l2Snap.bid_count == "3")
    assert(evs[3].data.l2Snap.offer_count == "3")

    assert(evs[3].data.l2Snap.offer[1].quantity == "1")
    assert(evs[3].data.l2Snap.offer[1].price == "40")
    assert(evs[3].data.l2Snap.offer[2].quantity == "5")
    assert(evs[3].data.l2Snap.offer[2].price == "50")
    assert(evs[3].data.l2Snap.offer[3].quantity == "5")
    assert(evs[3].data.l2Snap.offer[3].price == "60")
end

function tests.testUncrossBid()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 2
        , offer_count = 3
        , bid = 
            { {price=30, quantity=5}
            , {price=40, quantity=5} 
            } 
        , offer = 
            { {price=60, quantity=5}
            , {price=70, quantity=5}
            , {price=80, quantity=5}
            } 
        }   
    testee:onQuote(l2)

    local o = 
        { OPERATION="B"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="50" 
        , QUANTITY="5"
        , TRANS_ID="11"
        , ACTION = "NEW_ORDER"
    } 
    testee:onOrder(o)

    local crossing_l2 = 
        { bid_count = 3
        , offer_count=3 
        , bid =
            { {price=20, quantity=5}
            , {price=30, quantity=5}
            , {price=40, quantity=5} 
            } 
        , offer =
            { {price=50, quantity=5}
            , {price=60, quantity=5}
            , {price=70, quantity=5}
            } 
        }
    local evs = testee:onQuote(crossing_l2)

    assert(#evs == 3)
    assert(evs[1].name == "OnAllTrade")
    assert(evs[1].data.price == 50)
    assert(evs[1].data.qty == 5)

    assert(evs[2].name == "OnTransReply")
    assert(evs[2].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[2].data.balance == 0)

    assert(evs[3].name == "OnQuote")
end

function tests.testUncrossOffer()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 2
        , bid =
            { {price=10, quantity=5}
            , {price=20, quantity=5}
            , {price=30, quantity=5}
            }
            , offer =
            { {price=50, quantity=5}
            , {price=60, quantity=5}
            } 
        }
    testee:onQuote(l2)

    local o =
        { OPERATION="S"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="40" 
        , QUANTITY="3"
        , TRANS_ID="12"
        , ACTION = "NEW_ORDER"
        }    
    testee:onOrder(o)

    local crossing_l2 =
        { bid_count = 3
        , offer_count = 3 
        , bid =
            { {price=20, quantity=5} 
            , {price=30, quantity=5} 
            , {price=40, quantity=5}
            } 
        , offer =
            { {price=50, quantity=5}
            , {price=60, quantity=5}
            , {price=70, quantity=5}
            } 
        }
    local evs = testee:onQuote(crossing_l2)

    assert(#evs == 3)
    assert(evs[1].name == "OnAllTrade")
    assert(evs[1].data.price == 40)
    assert(evs[1].data.qty == 3)

    assert(evs[2].name == "OnTransReply")
    assert(evs[2].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[2].data.balance == 0)

    assert(evs[3].name == "OnQuote")
end

function tests.testKillBalanceFull()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 3
        , bid =
            { {price=10, quantity=5}
            , {price=20, quantity=5}
            , {price=30, quantity=5}
            }
        , offer =
            { {price=40, quantity=5}
            , {price=50, quantity=5}
            , {price=60, quantity=5}
            } 
        }
    testee:onQuote(l2)

    local o = 
        { OPERATION = "S"
        , EXECUTE_CONDITION = "KILL_BALANCE"
        , PRICE = "20" 
        , QUANTITY = "8"
        , ACTION = "NEW_ORDER"
        }    
    local evs = testee:onOrder(o)

    assert(#evs == 3)
    assert(evs[1].name == "OnAllTrade")
    assert(evs[2].name == "OnAllTrade")
    assert(evs[3].name == "OnTransReply")
    assert(evs[3].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[3].data.balance == 0)
end

function tests.testKillBalancePartial()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 3
        , bid =
            { {price=10, quantity=5}
            , {price=20, quantity=5}
            , {price=30, quantity=5}
            }
        , offer =
            { {price=40, quantity=5}
            , {price=50, quantity=5}
            , {price=60, quantity=5}
            } 
        }
    testee:onQuote(l2)

    local o = 
        { OPERATION = "S"
        , EXECUTE_CONDITION = "KILL_BALANCE"
        , PRICE = "20" 
        , QUANTITY = "12"
        , ACTION = "NEW_ORDER"
        }    
    local evs = testee:onOrder(o)

    assert(#evs == 3)
    assert(evs[1].name == "OnAllTrade")
    assert(evs[2].name == "OnAllTrade")
    assert(evs[3].name == "OnTransReply")
    assert(evs[3].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[3].data.balance == 2)
    assert((evs[3].data.flags % 2) == 0)
    
end

function tests.testKillOrFillFull()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 3
        , bid =
            { {price=10, quantity=5}
            , {price=20, quantity=5}
            , {price=30, quantity=5}
            }
        , offer =
            { {price=40, quantity=5}
            , {price=50, quantity=5}
            , {price=60, quantity=5}
            } 
        }
    testee:onQuote(l2)

    local o = 
        { OPERATION = "S"
        , EXECUTE_CONDITION = "KILL_OR_FILL"
        , PRICE = "20" 
        , QUANTITY = "8"
        , ACTION = "NEW_ORDER"
        }    
    local evs = testee:onOrder(o)

    assert(#evs == 4)
    assert(evs[1].name == "OnAllTrade")
    assert(evs[2].name == "OnAllTrade")
    assert(evs[3].name == "OnTransReply")
    assert(evs[4].name == "OnQuote")
    assert(evs[3].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[3].data.balance == 0)

    assert(evs[4].data.l2Snap.bid_count == "2")
    assert(evs[4].data.l2Snap.offer_count == "3")

    assert(evs[4].data.l2Snap.bid[1].quantity == "5")
    assert(evs[4].data.l2Snap.bid[1].price == "10")
    assert(evs[4].data.l2Snap.bid[2].quantity == "2")
    assert(evs[4].data.l2Snap.bid[2].price == "20")
end

function tests.testKillOrFillPartial()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local l2 = 
        { bid_count = 3
        , offer_count = 3
        , bid =
            { {price=10, quantity=5}
            , {price=20, quantity=5}
            , {price=30, quantity=5}
            }
        , offer =
            { {price=40, quantity=5}
            , {price=50, quantity=5}
            , {price=60, quantity=5}
            } 
        }
    testee:onQuote(l2)

    local o = 
        { OPERATION = "S"
        , EXECUTE_CONDITION = "KILL_OR_FILL"
        , PRICE = "20" 
        , QUANTITY = "12"
        , ACTION = "NEW_ORDER"
        }    
    local evs = testee:onOrder(o)
    
    assert(#evs == 1)
    assert(evs[1].name == "OnTransReply")
    assert(evs[1].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[1].data.balance == 12)
    assert((evs[1].data.flags % 2) == 0)
    
end

function tests.testKillOrder()
    local testee = q_book.create("SPBFUT", "SIZ5", 1, 1)
    local o =
        { OPERATION="B"
        , EXECUTE_CONDITION="PUT_IN_QUEUE"
        , PRICE="10" 
        , QUANTITY="1"
        , TRANS_ID="1"
        , ACTION="NEW_ORDER"
        } 
    
    local key = testee:onOrder(o)[1].data.order_num

    local killer =
        { ORDER_KEY=tostring(key + 1) -- incorrect order key
        , TRANS_ID="11"
        , ACTION="KILL_ORDER"
        } 

    local evs,msg = testee:onOrder(killer)
    assert(#evs, 0)
    assert(type(msg) == "string")
    assert(msg ~= "")


    local killer2 =
        { ORDER_KEY=tostring(key)
        , TRANS_ID="12"
        , ACTION="KILL_ORDER"
        } 
    local evs,msg = testee:onOrder(killer2)

    assert(#evs == 3)
    assert(evs[1].name == "OnTransReply")
    assert(evs[2].name == "OnTransReply")
    assert(evs[2].data.trans_id == tonumber(o.TRANS_ID))
    assert(evs[2].data.balance == tonumber(o.QUANTITY))
    assert(evs[2].data.flags % 2 == 0)
    assert(evs[3].name == "OnQuote")
    assert(evs[3].data.l2Snap.bid_count == "0", evs[3].data.l2Snap.bid_count)
    assert(evs[3].data.l2Snap.offer_count == "0")
end
