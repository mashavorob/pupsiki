--[[
#
# Фанктор-обертка для стратегии quik
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_functor = { }

local q_book = require("qlib/quik-book-II")
local q_persist = require("qlib/quik-l2-persist")
local q_client = require("qlib/quik-book-client")
local q_utils = require("qlib/quik-utils")
local q_order = require("qlib/quik-order")
--local ProFi = require("ProFi")
local simTime = 0
local simTransId = 1000000


local instance = nil

local function makeCopy(o, ctx)
    ctx = ctx or {}
    if type(o) == "table" then
        local c = ctx[o]
        if c then
            return c
        end
        c = {}
        ctx[o] = c
        for k,v in pairs(o) do
            c[k] = makeCopy(v, ctx)
        end
        return c
    end
    return o
end

function q_functor.getInstance()
    return instance
end

function q_functor.create(name, data, etc)
    local self = 
        { s_params = 
            { etc = {}
            , values = {}
            , descrs = {}
            , name = name
            , data = data
            }
        , book = nil
        , client = nil
        , superClient = nil
        }

    setmetatable(self, { __index = q_functor })
    
    -- merge parameters
    for name, value in pairs(etc) do
        self.s_params.etc[name] = value
    end

    self.s_params.etc.account = self.s_params.etc.account
    self.s_params.etc.firmid = self.s_params.etc.firmid


    -- create a dummy instance of strategy and extract parameters
    local dummy = self:createStrategy()
    for _,descr in ipairs(dummy.etc.params) do
        table.insert(self.s_params.descrs, descr)
        assert(dummy.etc[descr.name] ~= nil, string.format("Parameter %s is undefined", descr.name))
        self.s_params.values[descr.name] = dummy.etc[descr.name]
    end

    for _, descr in ipairs(self.s_params.descrs) do
        self["get_" .. descr.name] = function(obj)
            return obj.s_params.values[descr.name]
        end
        self["set_" .. descr.name] = function(obj, p)
            obj.s_params.values[descr.name] = p
        end
    end

    return self
end

function q_functor:clone()

    local clone = 
        { s_params = 
            { etc = makeCopy(self.s_params.etc)
            , values = makeCopy(self.s_params.values)
            , descrs = makeCopy(self.s_params.descrs)
            , name = self.s_params.name
            , data = self.s_params.data
            }
        }
    setmetatable(clone, { __index = q_functor })

    for _, descr in ipairs(self.s_params.descrs) do
        clone["get_" .. descr.name] = self["get_" .. descr.name]
        clone["set_" .. descr.name] = self["set_" .. descr.name]
        assert(self.s_params.values[descr.name] ~= nil, string.format("Parameter %s is undefined", descr.name))
        clone.s_params.values[descr.name] = self.s_params.values[descr.name]
    end

    return clone
end

function q_functor:createStrategy()
    local factory = require("qlib/" .. self.s_params.name)
    local etc = {}
    for key,value in pairs(self.s_params.etc) do
        etc[key] = value
    end
    -- overwrite parameters values
    for _,descr in ipairs(self.s_params.descrs) do
        etc[descr.name] = self.s_params.values[descr.name]
    end
    local strategy = assert(factory.create(etc))
    return strategy
end

function q_functor:freeStrategy()
    q_order.reset()
end

function q_functor:runDay(day)
    local res = self:runDayIsolated(day)
    collectgarbage()
    collectgarbage()
    return res
end

function q_functor:runDayIsolated(day)
    local env = {}
    setmetatable(env, {__index=_G})
    local _ENV = env
    self.book = q_book.create()
    self.strategy = nil
    self.client = nil
    self.superClient = q_client.create(self.book, nil, 1e19) 
    
    instance = self
    -- reset state


    --ProFi:start("many")

    local headers = 
        { onParams = true
        , onLoggedTrade = true
        }
    local balanceAtStart = 0
    local file = assert(io.open(day,"r"))
    local reportPeriod = 30
    local reportTime = os.clock() - reportPeriod - 1
    local stopTime
    for line in file:lines() do
        local success, rec = pcall(q_persist.parseLine, line)
        if success then
            local now = os.clock()
            local rec_time = rec.time or rec.received_time
            simTime = rec_time or simTime
            if rec_time and not stopTime then
                stopTime = q_stopAt:getTime(os.date('*t', rec_time))
            end
            if rec_time and rec_time > stopTime then
                break
            end
            if rec_time and now >= reportTime + reportPeriod and self.client then
                reportTime = now
                local margin = self.client:getBalance(book) - balanceAtStart
                io.stderr:write(string.format("processing %s, margin: %.0f\n", os.date('%Y%m%d-%H:%M:%S', rec_time), margin))
            end
            if not self.strategy and not headers[rec.event] then
                self.strategy = self:createStrategy()
                self.client = q_client.create(self.book, self.strategy, 30000)
                self.strategy:init()
                self.strategy:onStartTrading()
                balanceAtStart = self.client:getBalance()
            end
            self.book:onEvent(self.superClient, rec)
            self.book:flushEvents()
        end
    end
    file:close()
    
    --ProFi:stop()
    --ProFi:writeReport()

    local margin = self.client:getBalance(book) - balanceAtStart

    instance = nil
    self:freeStrategy()
    self.book.reset()
    return margin
end


function q_functor:func()
    -- check limits
    for _,info in ipairs(self.s_params.descrs) do

        local value = self["get_" .. info.name](self)
        local upper, lower = nil, nil

        if info.get_min then
            lower = info.get_min(self.s_params.values)
        else
            lower = info.min
        end
        if info.get_max then
            upper = info.get_max(self.s_params.values)
        else
            upper = info.max
        end

        if value > upper or value < lower then
            print(string.format("parameter '%s' is out of range, value = %s, expected interval (%s, %s)",
                info.name, tostring(value), tostring(lower), tostring(upper)))
            return 0
        end
    end

    local margin = 0

    for _,day in ipairs(self.s_params.data) do
        local clone = self:clone()
        margin = margin + clone:runDay(day)
    end

    return margin
end

function Subscribe_Level_II_Quotes(class, asset)
end

function getNumberOf(name)
    local t = instance.client:getTable(name)
    return #t
end

function getItem(name, index)
    local t = instance.client:getTable(name)
    local row = t[index + 1]
    return row
end

function getParamEx(class, asset, pname)
    local pp = instance.book:getParams(class, asset)
    return pp[pname] or { param_value=0 }
end

function getQuoteLevel2(class, asset)
    local function copyOrders(oo)
        local c = {}
        for _,o in ipairs(oo) do
            table.insert(c, { TRANS_ID=o.TRANS_ID, balance=o.balance, quantity=o.quantity })
        end
        return c
    end
    local function copyBookSide(side)
        if not side or #side == 0 then
            return 0, nil
        end
        local c = {}
        for _,q in ipairs(side) do
            table.insert(c, { price = q.price, quantity = q.quantity, orders = copyOrders(q.orders) })
        end
        return #c, c
    end

    local b = instance.book:getBook(class, asset)
    local c = { }
    c.bid_count, c.bid = copyBookSide(b.bid)
    c.offer_count, c.offer = copyBookSide(b.offer)
    return c
end

function sendTransaction(trans)
    instance.book:onOrder(instance.client, trans)
    return ""
end

quik_ext = {}

function quik_ext.gettime()
    return simTime
end

function quik_ext.gettransid()
    simTransId = simTransId + 1
    return simTransId
end

return q_functor
