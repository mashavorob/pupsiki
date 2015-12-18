--[[
#
# ������ � ��������
#
# vi: ft=lua:fenc=cp1251 
#
# ���� �� ������ ��������� ��� ������ �� ��� ���������
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local order = {
    asset = false,
    class = false,
    account = false,

    operation = false,

    id = false,        -- TRANS_ID
    key = false,       -- ORDER_NUM
    status = false,    -- STATUS

    balance = 0,       -- Quantity
    position = 0,      -- Generated position
}

local orderStatusSuccess = {}
-- see https://forum.quik.ru/forum10/topic604/
orderStatusSuccess[1] = true
orderStatusSuccess[3] = true -- completed
orderStatusSuccess[4] = true

local allOrders = {
    -- id -> order
}

q_order = { }

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
    local self = {}
    setmetatable(self, { __index = order })

    self.account = account
    self.class = class
    self.asset = asset

    return self
end

function q_order.onTransReply(reply)
    local orderObj = allOrders[reply.trans_id]
    if orderObj then
        local n = getNumberOf("orders")
        for i=1,n do
            local index = n - i
            local item = getItem("orders", index)
            if item.trans_id == reply.trans_id then
                orderObj:onTransReply(item)
                break
            end
        end
        orderObj:onTransReply(reply)
    end
end

function q_order.onTrade(trade)
    local report = "onTrade\n"
    for k, v in pairs(trade) do
        report = report .. k .. " = " .. type(v) .. "(" .. tostring(v) .. ")\n"
    end
    local lastTransId = getLastTransId()
    if lastTransId > transId then
        transId = lastTransId
    end
end

local once = false
local pcount = -1

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
        local order = reply.trans_id and allOrders[reply.trans_id]
        if order then
            order:onTransReply(reply)
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
    return self.id and not self.key
end

function order:isActive()
    return self.key
end

function order:kill()
    assert(self.class and self.asset and self.id and self.key, "order has not been sent")
    if not self:isActive() then
        return true
    end
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
    assert(not self:isActive(), "The order is active")
    
    self.id = self.getNextTransId()
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
    local res = sendTransaction(transaction)
    if res == "" then
        return true
    end
    allOrders[self.id] = nil
    self.id = nil
    self.size = 0
    self.balance = 0
    return false, res
end

function order:onTransReply(reply)
    if reply.trans_id == 0 then
        return
    end
    assert(reply.trans_id == self.id)
  
    if not self.key then
        self.key = reply.order_num
    end
    
    local inactive = bit.band(reply.flags, 1) == 0
    if inactive then
        allOrders[self.id] = nil
        self.id = nil
        self.key = false
    end
    
    -- ignore reply.balance == 0 and not inactive
    if (reply.balance ~= 0 or inactive) and reply.balance ~= self.balance then

        local offset = self.balance - reply.balance
        if bit.band(reply.flags, 4) ~= 0 then -- sell operation
            offset = -offset
        end
        self.position = self.position + offset
        self.balance = reply.balance
    end
end

function order:onDisconnected()
    allOrders[self.id] = nil
    self.id = nil
    self.key = false
end
