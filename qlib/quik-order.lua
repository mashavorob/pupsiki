--[[
#
# Работа с заявками
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_order = 
    { counters = {}
    } 

local order =
    { operation = false
    , trans_id = false
    , order_num = false
    , pending = false   -- pending flag
    , active = false    -- active flag
    , ttl = 0
    } 

local orderStatusError =
    { [2] = "Ошибка передачи сообщения"
    , [4] = "Транзакция не выполнена"
    , [5] = "Транзакция не прошла проверку сервера QUIK"
    , [6] = "Транзакция не прошла проверку лимитов сервера QUIK"
    , [10] = "Транзакция не поддерживаеться системой"
    , [11] = "Транзакция не прошла проверку цифровой подписи"
    , [12] = "Истек таймаут ожидания"
    , [13] = "Транзакция отвергнута так как ее выполнение могло привести к кросс-сделке"
    }

local TIME_TO_LIVE = 5

-- trans_id -> order
local allOrders = {}

-- killer.trans_id -> victim.trans_id
local killTargets = {}

function q_order.getCounters(account, class, asset)
    local counters = q_order.counters[account]
    if not counters then
        counters = {}
        q_order.counters[account] = counters
    end
    local classCounters = counters[class]
    if not classCounters then
        classCounters = {}
        counters[class] = classCounters
    end
    local assetCounters = classCounters[asset]
    if not assetCounters then
        assetCounters = 
            { margin = 0
            , comission = 0
            , contracts = 0
            , position = 0
            }
        classCounters[asset] = assetCounters
    end
    return assetCounters
end

function q_order.create(account, class, asset)
    local self = 
        { account = account
        , class = class
        , asset = asset
        , counters = q_order.getCounters(account, class, asset)
        }
    setmetatable(self, { __index = order })
    return self
end

function q_order.onTransReply(reply)
    local order = allOrders[reply.trans_id]
    if order then
        return order:onTransReply(reply)
    end
    local trans_id = killTargets[reply.trans_id]
    if trans_id then
        order = allOrders[trans_id]
        killTargets[reply.trans_id] = nil
        if order then
            order:onKillReply(reply)
        end
    end
    return true, false, ""
end

function q_order.onTrade(trade)
    local order = allOrders[trade.trans_id]
    if not order then
        return
    end
    if order.trades[trade.trade_num] then
        return
    end
    
    --message(string.format("New Trade detected for: order_num=%s, trans_id=%d", tostring(order.order_num), order.trans_id), 2)
    order.trades[trade.trade_num] = true

    local counters = order.counters

    if order.operation == 'B' then
        counters.margin = counters.margin - trade.value
        counters.position = counters.position + trade.qty
    else
        counters.margin = counters.margin + trade.value
        counters.position = counters.position - trade.qty
    end
    counters.comission = counters.comission + trade.exchange_comission + trade.tech_center_comission
    counters.contracts = counters.contracts + trade.qty
    order.balance = order.balance - trade.qty
    if order.balance == 0 then
        order.pending = false
        order.active = false
        allOrders[order.trans_id] = nil
        --message(string.format("Order filled: order_num=%s, trans_id=%d", tostring(order.order_num), order.trans_id), 2)
    end
end

function q_order.onIdle()
    for trans_id,order in pairs(allOrders) do
        if order.active and order.balance == 0 then
            order.pending = false
            order.active = false
            order.ttl = 0
        end
        if order.active then
            order:updateIndex()
            if order.index then
                local item = getItem("orders", order.index)
                if bit.band(item.flags, 1) == 0 then
                    order.active = false
                    order.pending = false
                end
                if not order.active then
                    --message(string.format("Order deactivated: order_num=%s, trans_id=%d", tostring(order.order_num), order.trans_id), 2)
                    order.ttl = TIME_TO_LIVE
                end
            end
        end
        if not order.active then
            order.pending = false
            order.ttl = order.ttl - 1
            if order.ttl <= 0 then
                allOrders[order.trans_id] = nil
                order.ttl = 0
                --message(string.format("Order unlinked: order_num=%s, trans_id=%d", tostring(order.order_num), order.trans_id), 2)
            end
        end
    end
end

function q_order.removeOwnOrders(l2)

    local removeOrder = function(order, count, qq)
        for i=1,count do
            local q = qq[i]
            if q.price > order.price then
                break
            elseif q.price == order.price then
                if q.quantity > order.balance then
                    q.quantity = q.quantity - order.balance
                else
                    table.remove(qq, i)
                    count = count - 1
                end
                break
            end
        end
        return count
    end

    for _,order in pairs(allOrders) do
        if order:isActive() then
            local qq, count
            if order.operation == 'B' then
                l2.bid_count = removeOrder(order, l2.bid_count, l2.bid)
            else
                l2.offer_count = removeOrder(order, l2.offer_count, l2.offer)
            end
        end
    end

end

function q_order.init()
    allOrders = {}
    killTargets = {}
end

function order:updateIndex()
    if self.index or self.pending then
        return
    end

    local n = getNumberOf("orders")
    for i=1,n do
        local index = n - i
        local item = getItem("orders", index)
        if self.order_num == item.order_num then
            self.index = index
            self.pending = false
            --message(string.format("Index found: order_num=%s, trans_id=%d", tostring(self.order_num), self.trans_id), 2)
            return
        elseif self.order_num and self.order_num > item.order_num then
            break
        end
    end
end

function order.getNextTransId()
    return quik_ext.gettransid()
end

function order:isPending()
    return self.active and self.pending
end

function order:isActive()
    return self.active and not self.pending
end

function order:isDeactivating()
    return not self.active and not self.pending and self.ttl > 0
end

function order:kill()
    assert(self.class and self.asset and self.trans_id and self.order_num and self:isActive() and not self:isPending(), 
        "order has not been sent yet\n" .. debug.traceback())
    local now = quik_ext.gettime()
    local lastKill = self.lastKill or 0
    if now - lastKill < 5 then
        return true
    end
    self.lastKill = now

    local killerTransId = self.getNextTransId()

    local trans = {
        TRANS_ID=tostring(killerTransId),
        CLASSCODE=self.class,
        SECCODE=self.asset,
        ACTION="KILL_ORDER",
        ORDER_KEY=tostring(self.order_num),
    }
    local res = sendTransaction(trans)
    if res == "" then
        killTargets[killerTransId] = self.trans_id
        return true, res
    end
    return false, res
end

function order:send(operation, price, size)
    assert(not self:isActive(), "The order is active\n" .. debug.traceback())
    assert(not self:isPending(), "The order is pending\n" .. debug.traceback())
    assert(not self:isDeactivating(), "The order is pending\n" .. debug.traceback())

    if self.trans_id then
        allOrders[self.trans_id] = nil
    end
    
    self.trans_id = self.getNextTransId()
    self.ttl = 0
    self.order_num = nil
    self.index = nil
    self.pending = true
    self.active = true
    self.lastKill = nil
    self.operation = operation
    self.balance = size
    self.price = price
    self.size = size
    self.trades = {}

    allOrders[self.trans_id] = self

    local transaction = {
        TRANS_ID=tostring(self.trans_id),
        ACCOUNT=self.account,
        CLASSCODE=self.class,
        SECCODE=self.asset,
        ACTION="NEW_ORDER",
        TYPE="L",
        OPERATION=self.operation,
        EXECUTE_CONDITION="PUT_IN_QUEUE",
        PRICE=tostring(self.price),
        QUANTITY=tostring(self.size),
    }
    self.sentAt = quik_ext.gettime()
    local res = sendTransaction(transaction)
    if res == "" then
        return true, ""
    end
    allOrders[self.trans_id] = nil
    self.active = false
    self.pending = false
    self.size = 0
    self.balance = 0
    return false, res
end

function order:onTransReply(reply)
    if not reply.trans_id or reply.trans_id == 0 then
        return true, false, ""
    end
    assert(reply.trans_id == self.trans_id, "orders mismatch, expected " .. 
        tostring(self.trans_id) .. ", got " .. tostring(reply.trans_id))
    
    self.pending = false

    local status = true
    local delay = false
    if self.sentAt then
        delay = quik_ext.gettime() - self.sentAt
        self.sentAt = nil
    end

    local err = orderStatusError[reply.status]
    if err then
        status = false
        err = string.format("Ошибка транзакции: %s, %s", err, tostring(reply.result_msg))
        allOrders[self.trans_id] = nil
        self.active = false
        self.size = 0
        self.balance = 0
    else
        assert(reply.order_num)
        self.order_num = reply.order_num 
        err = ""
    end
    return status, delay, (err or "")
end

function order:onKillReply(reply)
    local err = orderStatusError[reply.status]
    if err then
        return
    end
    self.active = false
    self.pending = false
    self.ttl = TIME_TO_LIVE 
end

return q_order
