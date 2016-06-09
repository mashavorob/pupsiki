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

q_functor = { }

assert(require("qlib/quik-events"))
assert(require("qlib/quik-books"))
assert(require("qlib/quik-tables"))
assert(require("qlib/quik-params"))

local instance = nil

function q_functor.getInstance()
    return instance
end

function q_functor.create(name, data, etc)
    local self = 
        { q_tables = nil
        , q_books = nil
        , q_params = nil
        , q_events = nil
        , s_params = 
            { etc = {}
            , name = name
            , data = data
            }
        , params = {}
        }
    setmetatable(self, { __index = q_functor })
    
    -- merge parameters
    for name, value in pairs(etc) do
        self.s_params.etc[name] = value
    end
    self.s_params.etc.account = q_utils.getAccount() or self.s_params.etc.account
    self.s_params.etc.firmid = q_utils.getFirmID() or self.s_params.etc.firmid

    -- create a dummy instance of strategy and extract parameters
    local dummy = self:createStartegy()
    self.prams = { }
    for _,descr in ipairs(dummy.etc.params) do
        table.insert(self.params, descr)
        assert(dummy.etc[descr.name] ~= nil, string.format("Parameter %s is undefined", descr.name))
        self[descr.name] = dummy.etc[descr.name]
    end

    for _, info in ipairs(self.params) do
        self["get_" .. info.name] = function(obj)
            return obj[info.name]
        end
        self["set_" .. info.name] = function(obj, p)
            obj[info.name] = p
        end
    end

    return self
end

function q_functor:clone()
    
    local function makeCopy(o)
        if type(o) == "table" then
            local c = { }
            for k,v in pairs(o) do
                c[k] = makeCopy(v)
            end
            return c
        end
        return o
    end

    local clone = 
        { q_tables = nil
        , q_books = nil
        , q_params = nil
        , q_events = nil
        , s_params = 
            { etc = makeCopy(self.s_params.etc)
            , name = self.s_params.name
            , data = self.s_params.data
            }
        , params = makeCopy(self.params)
        }
    setmetatable(clone, { __index = q_functor })

    for _, info in ipairs(clone.params) do
        clone["get_" .. info.name] = function(obj)
            return obj[info.name]
        end
        clone["set_" .. info.name] = function(obj, val)
            obj[info.name] = val
        end
        assert(self[info.name] ~= nil, string.format("Parameter %s is undefined", info.name))
        clone[info.name] = self[info.name]
    end

    return clone
end

function q_functor:createStartegy()
    assert(require("qlib/" .. self.s_params.name))
    local factory = assert(_G[self.s_params.name])
    local etc = {}
    for key,value in pairs(self.s_params.etc) do
        etc[key] = value
    end
    -- overwrite parameters values
    for _,descr in ipairs(self.params) do
        etc[descr.name] = self[descr.name]
    end
    local strategy = assert(factory.create(etc))
    return strategy
end

function q_functor:func()
    instance = self
    -- reset state
    self.q_tables = q_tables.create(self.s_params.etc.firmid, self.s_params.etc.account)
    self.q_books = q_books.create()
    self.q_params = q_params.create()
    self.q_events = q_events.create()

    -- assume data starts with parameters and logged trades
    for _, rec in ipairs(self.s_params.data.params) do
        if rec.event == "OnParams" then
            self.q_params:updateParams(rec.class, rec.asset, rec.params)
            self.q_books:getBook(rec.class, rec.asset, self.q_params)
        end
    end
    for _, rec in self.s_params.data.preamble:items() do
        if rec.event == "OnLoggedTrade" then
            table.insert(self.q_tables.all_trades, rec.trade)
        end
    end
    -- synchronize books and tables
    self.q_tables:syncTables(self.q_books, self.q_params)

    self.q_events.strategy = assert(self:createStartegy())
    self.q_events.strategy:init()

    self.q_events:printHeaders()
    self.q_events:printState()

    self.q_events.strategy:onStartTrading()

    local count = 0

    for i, rec in self.s_params.data.data:items() do
        count = i
        if rec.event == "onQuote" then
            self.quoteTime = rec.tstamp
            if self.timeOffset then
                self.now = math.floor(self.quoteTime + self.timeOffset)
            end
            local book = self.q_books:getBook(rec.class, rec.asset, self.q_params)
            if book then
                local evs = book:onQuote(rec.l2)
                self.q_events:enqueueEvents(evs)
            end
        elseif rec.event == "onTrade" then
            self.now = os.time(rec.trade.datetime)
            if self.quoteTime then
                self.timeOffset = math.floor(self.now - self.quoteTime)
                self.quoteTime = nil
            end
            local book = self.q_books:getBook(rec.trade.class_code, rec.trade.sec_code, self.q_params)
            if book then
                local evs = book:onTrade(rec.trade)
                self.q_events:enqueueEvents(evs)
            end
        --[[
        elseif rec.event == "OnParams" then
            -- just ignore
        elseif rec.event == "OnLoggedTrade" then
            -- just ignore
        ]]
        else
            print("Unknown event type: ", rec.event)
            assert(false)
        end

        self.q_events.strategy:onIdle(self.now)
       
        self.q_events:flushEvents(self.q_tables)
        if self.q_events.strategy:isHalted() then
            break
        end

        if i % 10 == 0 then
            self.q_tables:syncTables(self.q_books, self.q_params)
        end
    end
    self.q_tables:syncTables(self.q_books, self.q_params)

    self.q_events:printEnd()

    local margin = self.q_tables:getMargin()
    if self.q_events.strategy:isHalted() and count > 0 then
        margin = margin*#self.s_params.data/count
    end

    instance = nil

    return margin
end
