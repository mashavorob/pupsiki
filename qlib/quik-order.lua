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

q_order = {}

local order = { }

local orderStatusSuccess =
    -- see https://forum.quik.ru/forum10/topic604/
    { [1] = true
    , [3] = true -- completed
    , [4] = true
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


-- id -> order
local allOrders = {}

local transId = false

local function getLastTransId()
    local lastTransId = 0
    local n = getNumberOf("orders")
    for i = 1, n-1 do
        local index = n -i
        local id = getItem("orders", index).trans_id
        if id > 0 then 
            lastTransId = math.ceil(id/10)*10
            break
        end
    end
    return lastTransId
end

function q_order.create(account, class, asset)
    local self = 
        { account = account
        , class = class
        , asset = asset

        , operation = false

        , id = false        -- TRANS_ID
        , key = false       -- ORDER_NUM
        , status = false    -- STATUS

        , balance = 0       -- Quantity
        , position = 0      -- Generated position
        ,  
        }
    setmetatable(self, { __index = order })
    return self
end

function q_order.onTransReply(reply)
    local orderObj = allOrders[reply.trans_id]
    if orderObj then
        return orderObj:onTransReply(reply)
    end
    return true, false, ""
end

function q_order.onTrade(trade)
    local lastTransId = getLastTransId()
    if not transId or lastTransId > transId then
        transId = lastTransId
    end
end

function q_order.onIdle()
    local n = getNumberOf("orders")
    local count = 0
    for k,v in pairs(allOrders) do
        count = count + 1
    end
    for i=1,n do
        if count <= 0 then
            break
        end
        local index = n - i
        local reply = getItem("orders", index)
        local obj = reply.trans_id and allOrders[reply.trans_id]
        if obj then
            obj:onTransReply(reply)
            count = count - 1
        end
    end
end

function q_order.onDisconnected()
    local pendingOrders = { }
    for _, orderObj in pairs(allOrders) do
        if orderObj:isPending() then
            table.insert(pendingOrders, orderObj)
        end
    end
    for _, orderObj in ipairs(pendingOrders) do
        orderObj:onDisconnected()
    end
end

function order.getNextTransId()
    transId = transId or getLastTransId()
    transId = transId + 1
    return transId
end

function order:isPending()
    return ((self.id and true) or false) and not self:isActive()
end

function order:isActive()
    return (self.key and true) or false
end

function order:kill()
    assert(self.class and self.asset and self.id and self.key, 
        "order has not been sent\n" .. debug.traceback())
    if not self:isActive() then
        return true
    end
    local now = os.time()
    local lastKill = self.lastKill or 0
    if now - lastKill < 5 then
        return true
    end
    self.lastKill = now
    local trans = {
        TRANS_ID=tostring(self.getNextTransId()),
        CLASSCODE=self.class,
        SECCODE=self.asset,
        ACTION="KILL_ORDER",
        ORDER_KEY=tostring(self.key),
    }
    local res = sendTransaction(trans)
    if res == "" then
        return true, res
    end
    return false, res
end

function order:send(operation, price, size)
    assert(not self:isActive(), "The order is active\n" .. debug.traceback())
    assert(not self:isPending(), "The order is pending\n" .. debug.traceback())
    
    self.id = self.getNextTransId()
    self.key = nil
    self.lastKill = nil
    self.operation = operation
    self.balance = size
    self.price = price
    self.size = size

    allOrders[self.id] = self

    local transaction = {
        TRANS_ID=tostring(self.id),
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
    allOrders[self.id] = nil
    self.id = nil
    self.size = 0
    self.balance = 0
    return false, res
end

function order:onTransReply(reply)
    if reply.trans_id == 0 then
        return true, false, ""
    end
    assert(reply.trans_id == self.id, "orders mismatch, expected " .. 
        tostring(self.id) .. ", got " .. tostring(reply.trans_id))

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
    end
  
    if not self.key then
        self.key = reply.order_num
    end
    
    local inactive = (bit.band(reply.flags, 1) == 0) or err
    if inactive then
        allOrders[self.id] = nil
        self.id = nil
        self.key = false
    end
    
    -- ignore reply.balance == 0 and not inactive
    if (reply.balance ~= 0 or inactive) and reply.balance ~= self.balance then

        local offset = self.balance - reply.balance
        if err then
            offset = 0
        elseif bit.band(reply.flags, 4) ~= 0 then -- sell operation
            offset = -offset
        end
        self.position = self.position + offset
        self.balance = reply.balance
    end
    return status, delay, (err or "")
end

function order:onDisconnected()
    allOrders[self.id] = nil
    self.id = nil
    self.key = false
end
