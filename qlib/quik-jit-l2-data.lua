--[[
#
# Нативное хранилище данных для преодоления ограничений luajit
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local BOOK_DEPTH = 20 -- must match with QBOOK

local cdecl = [[
    typedef double  sint_lua_t; // lua signed integer
    typedef double  uint_lua_t; // lua unsigned integer
    typedef double  fnum_lua_t; // lua floating point number

    typedef struct QTIMEtag
    {
        sint_lua_t year;   // 1970-...
        sint_lua_t month;  // 1-12
        sint_lua_t day;    // 1-31
        sint_lua_t week_day;
        sint_lua_t hour;   // 0-23
        sint_lua_t min;    // 0-59
        sint_lua_t sec;    // 0-59
        sint_lua_t ms;     // 0-999
        sint_lua_t mcs;    // 0-999999
    } QTIME;

    typedef struct QTRADEtag
    {
        uint_lua_t  repoterm;
        fnum_lua_t  price;      // price
        sint_lua_t  trade_num;  // trade identifier
        fnum_lua_t  yield;
        fnum_lua_t  value;      // value in money
        sint_lua_t  qty;        // size in lots
        fnum_lua_t  reporate;
        fnum_lua_t  repovalue;
        fnum_lua_t  accruedint;
        sint_lua_t  tradenum;  // trade identifier
        uint_lua_t  flags;      
        QTIME       datetime;
        sint_lua_t  period;
        fnum_lua_t  repo2value;
        fnum_lua_t  open_interest;

        sint_lua_t  exchange_code;
        sint_lua_t  class_code;
        sint_lua_t  sec_code;
        sint_lua_t  seccode;
        sint_lua_t  settlecode;
    } QTRADE;

    typedef struct QQUOTEtag
    {
        fnum_lua_t  price;
        sint_lua_t  quantity;
    } QQUOTE;

    typedef struct QBOOKtag
    {
        fnum_lua_t   time_stamp;
        sint_lua_t  class;
        sint_lua_t  asset;
        
        uint_lua_t  bid_count;
        QQUOTE      bid[20];
        
        uint_lua_t  offer_count;
        QQUOTE      offer[20];
    } QBOOK;

    typedef union QBOOK_QTRADEtag
    {
        QTRADE      trade;
        QBOOK       book;
    } QBOOK_QTRADE;

    typedef struct QRECORDtag
    {
        sint_lua_t      itemType;
        QBOOK_QTRADE    u;
    } QRECORD;

    typedef struct QCHUNKtag
    {
        QRECORD chunk[1];
    } QCHUNK;

    void* malloc(size_t);
    void free(void*);
]]

local function allocQRecords(ffi, celt)
    local ptr = ffi.C.malloc(ffi.sizeof("QRECORD")*celt)

    local finalizer = function()
        ffi.C.free(ptr)
    end

    local obj = ffi.cast("QCHUNK*", ptr)[0]
    obj = ffi.gc(obj, finalizer)
    return obj
end

local ffi_pool = {}

function ffi_pool.create(ffi)

    local self = 
        { ffi = ffi
        , chunkSize = 1000
        , chunks = {}
        , s_pool = {}
        , s_indices = {}
        , tailSize = 0
        }

    setmetatable(self, {__index = ffi_pool})

    self:appendChunk()
    self.onLoggedTrade = self:getIndexFromString("onLoggedTrade")
    self.onTrade = self:getIndexFromString("onTrade")
    self.onQuote = self:getIndexFromString("onQuote")

    return self
end

function ffi_pool:appendChunk()
    table.insert(self.chunks, allocQRecords(self.ffi, self.chunkSize))
    self.tailSize = 0
end

function ffi_pool:lookupIndexForString(s)
    return self.s_indices[s] or -1
end

function ffi_pool:getIndexFromString(s)
    local index = self.s_indices[s]
    if not index then
        table.insert(self.s_pool, s)
        index = #self.s_pool
        self.s_indices[s] = index
    end
    return index
end

function ffi_pool:getStringFromIndex(index)
    return self.s_pool[index]
end

function ffi_pool.storeBookSide(lua_src, c_dst, count)
    count = math.min(BOOK_DEPTH, math.max(0, count))
    for i = 1, count do
        local lua_q = lua_src[i]
        local c_q = c_dst[i - 1]
        c_q.price = tonumber(lua_q.price)
        c_q.quantity = tonumber(lua_q.quantity)
    end
    return count
end

function ffi_pool.storeBook(lua_src, c_dst)
    local bid_count = ffi_pool.storeBookSide(lua_src.bid, c_dst.bid, lua_src.bid_count)
    local offer_count = ffi_pool.storeBookSide(lua_src.offer, c_dst.offer, lua_src.offer_count)
    c_dst.bid_count = bid_count
    c_dst.offer_count = offer_count
end

function ffi_pool.extractBookSide(c_src, count)
    if count <= 0 then
        return -- just nothing
    end
    local res = {}
    for i = 0, math.max(BOOK_DEPTH, count) - 1 do
        local c_q = c_src[i]
        table.insert(res, { price = c_q.price, quantity = c_q.quantity })
    end
    return res
end

function ffi_pool.extractBook(c_book)
    local book =
        { bid_count = c_book.bid_count
        , offer_count = c_book.offer_count
        , bid = ffi_pool.extractBookSide(c_book.bid, c_book.bid_count)
        , offer = ffi_pool.extractBookSide(c_book.offer, c_book.offer_count)
        }
    return book
end

function ffi_pool:storeTrade(lua_src, c_dst)
    c_dst.repoterm = lua_src.repoterm
    c_dst.price = lua_src.price
    c_dst.trade_num = lua_src.trade_num
    c_dst.yield = lua_src.yield
    c_dst.value = lua_src.value
    c_dst.qty = lua_src.qty
    c_dst.reporate = lua_src.reporate
    c_dst.repovalue = lua_src.repovalue
    c_dst.accruedint = lua_src.accruedint
    c_dst.tradenum = lua_src.tradenum
    c_dst.flags = lua_src.flags
    c_dst.datetime.year = lua_src.datetime.year
    c_dst.datetime.month = lua_src.datetime.month
    c_dst.datetime.day = lua_src.datetime.day
    c_dst.datetime.week_day = lua_src.datetime.week_day
    c_dst.datetime.hour = lua_src.datetime.hour
    c_dst.datetime.min = lua_src.datetime.min
    c_dst.datetime.sec = lua_src.datetime.sec
    c_dst.datetime.ms = lua_src.datetime.ms
    c_dst.datetime.mcs = lua_src.datetime.mcs
    c_dst.period = lua_src.period
    c_dst.repo2value = lua_src.repo2value
    c_dst.open_interest = lua_src.open_interest
    
    c_dst.exchange_code = self:getIndexFromString(lua_src.exchange_code)
    c_dst.class_code = self:getIndexFromString(lua_src.class_code)
    c_dst.sec_code = self:getIndexFromString(lua_src.sec_code)
    c_dst.seccode = self:getIndexFromString(lua_src.seccode)
    c_dst.settlecode = self:getIndexFromString(lua_src.settlecode)
end

function ffi_pool:extractTrade(c_src)
    local trade =
        { repoterm = c_src.repoterm
        , price = c_src.price
        , trade_num = c_src.trade_num
        , yield = c_src.yield
        , value = c_src.value
        , qty = c_src.qty
        , reporate = c_src.reporate
        , repovalue = c_src.repovalue
        , accruedint = c_src.accruedint
        , tradenum = c_src.tradenum
        , flags = c_src.flags
        , datetime = 
            { year = c_src.datetime.year
            , month = c_src.datetime.month
            , day = c_src.datetime.day
            , week_day = c_src.datetime.week_day
            , hour = c_src.datetime.hour
            , min = c_src.datetime.min
            , sec = c_src.datetime.sec
            , ms = c_src.datetime.ms
            , mcs = c_src.datetime.mcs
            }
        , period = c_src.period
        , repo2value = c_src.repo2value
        , open_interest = c_src.open_interest
        
        
        , exchange_code = self:getStringFromIndex(c_src.exchange_code)
        , class_code = self:getStringFromIndex(c_src.class_code)
        , sec_code = self:getStringFromIndex(c_src.sec_code)
        , seccode = self:getStringFromIndex(c_src.seccode)
        , settlecode = self:getStringFromIndex(c_src.settlecode)
        }
    return trade
end

function ffi_pool:appendRecord()
    if self.tailSize == self.chunkSize then
        self:appendChunk()
    end

    local record = self.chunks[#self.chunks].chunk[self.tailSize]
    self.tailSize = self.tailSize + 1
    return record
end

function ffi_pool:append(item)
    if item.event == "onLoggedTrade" then
        local record = self:appendRecord()
        record.itemType = self.onLoggedTrade
        self:storeTrade(item.trade, record.u.trade)
    elseif item.event == "onQuote" then
        local record = self:appendRecord()
        record.itemType = self.onQuote
        record.u.book.time_stamp = item.tstamp or item.time or item.received_time
        record.u.book.class = self:getIndexFromString(item.class)
        record.u.book.asset = self:getIndexFromString(item.asset)
        self.storeBook(item.l2, record.u.book)
    elseif item.event == "onTrade" then
        local record = self:appendRecord()
        record.itemType = self.onTrade
        self:storeTrade(item.trade, record.u.trade)
    else
        assert(false, "Unexepected item type = '" .. item.event .. "'")
    end
end

function ffi_pool:size(index)
    return (#(self.chunks) - 1)*self.chunkSize + self.tailSize
end

function ffi_pool:item(index)
    if index < 1 or index > self:size() then
        -- out of range
        return
    end
    local chunkIndex = math.ceil(index/self.chunkSize)
    local indexInChunk = index - (chunkIndex - 1)*self.chunkSize - 1 -- zero based

    local ffiItem = self.chunks[chunkIndex].chunk[indexInChunk]
    local item = { event = self:getStringFromIndex(ffiItem.itemType) }
    if ffiItem.itemType == self.onLoggedTrade then
        item.trade = self:extractTrade(ffiItem.u.trade)
    elseif ffiItem.itemType == self.onQuote then
        item.tstamp = ffiItem.u.book.time_stamp
        item.class = self:getStringFromIndex(ffiItem.u.book.class)
        item.asset = self:getStringFromIndex(ffiItem.u.book.asset)
        item.l2 = ffi_pool.extractBook(ffiItem.u.book)
    elseif ffiItem.itemType == self.onTrade then
        item.trade = self:extractTrade(ffiItem.u.trade)
    end
    return item
end

function ffi_pool:items()
    local iter = function(pool, index)
        index = index + 1
        local item = pool:item(index)
        if item then
            return index, item
        end
    end
    return iter, self, 0
end

local lua_pool = {}

function lua_pool.create()
    local self = 
        { data = {} }
    setmetatable(self, { __index = lua_pool })
    return self
end

function lua_pool:append(item)
    table.insert(self.data, item)
end

function lua_pool:size(index)
    return #(self.data)
end

function lua_pool:item(index)
    return self.data[index]
end

function lua_pool:items()
    return ipairs(self.data)
end

local factory = {}

function factory:create_ffi_pool()
    return ffi_pool.create(self.ffi)
end

function factory:create_lua_pool()
    return lua_pool.create()
end

function factory.create()
    local status, ffi = pcall( require, "ffi" )
    local self = {ffi = ffi}

    if status then
        self.ffi.cdef(cdecl)
        self.createPool = factory.create_ffi_pool
    else
        self.createPool = factory.create_lua_pool
    end

    setmetatable(self, { __index = factory })
    return self
end

local tests = {}

local container = 
    { poolFactory = factory.create()
    }

function container.create()
    local self =
        { params = {}
        , preamble = assert(container.poolFactory:createPool())
        , data = assert(container.poolFactory:createPool())
        , preambleLocked = false
        }
    setmetatable(self, {__index=container})
    return self
end

function container.getTestSuite()
    return tests
end

function container:add(item)
    if item.event == "onParams" then
        if not self.preambleLocked then
            table.insert(self.params, item)
        end
    elseif item.event == "onLoggedTrade" then
        if not self.preambleLocked then
            self.preamble:append(item)
        end
    else
        self.preambleLocked = true
        self.data:append(item)
    end
end

local function compare(_1, _2, ctx)

    ctx = ctx or "root"
    
    if type(_1) ~= type(_2) then
        return false, string.format("%s: type mismatch, left is '%s', right is '%s'", ctx, type(_1), type(_2))
    end
    if type(_1) ~= "table" then
        if _1 == _2 then
            return true
        end
        return false, string.format("%s: value mismatch, left is '%s', right is '%s'", ctx, tostring(_1), tostring(_2))
    end

    for k,v_left in pairs(_1) do
        local inner_ctx = string.format("%s[(%s)%s]", ctx, type(k), tostring(k))
        
        local v_right = _2[k]
        if v_right == nil then
            return false, inner_ctx .. " is missing in the right table"
        end
        local res, msg = compare(v_left, v_right, inner_ctx)
        if not res then
            return false, msg
        end
    end
    return true
end

local function expect_eq(_1, _2)
    local res, msg = compare(_1, _2)
    if not res then
        print("Mismatch:", msg)
        print(debug.traceback())
        print()
        assert(false)
    end
end

local paramSiM6 = 
    { asset = "SiM6"
    , class = "SPBFUT"
    , event = "onParams"
    , params = 
        { STEPPRICE = 
            { param_type = "1"
            , param_value = "1.000000"
            , result = "1"
            , param_image = "1,000000"
            }
        , BUYDEPO = 
            { param_type = "2"
            , param_value = "5884.000000"
            , result = "1"
            , param_image = "5 884,00"
            }
        , PRICEMIN = 
            { param_type = "2"
            , param_value = "62434.000000"
            , result = "1"
            , param_image = "62 434"
            }
        , PRICEMAX = 
            { param_type = "2"
            , param_value = "68318.000000"
            , result = "1"
            , param_image = "68 318"
            }
        , SELDEPO = { param_type = "0"
            , param_value = "0.000000"
            , result = "0"
            , param_image = ""
            }
        , SEC_PRICE_STEP = 
            { param_type = "1"
            , param_value = "1.000000"
            , result = "1"
            , param_image = "1"
            }
        }   
    }

local paramRIM6 = 
    { asset = "RIM6"
    , class = "SPBFUT"
    , event = "onParams"
    , params =
        { STEPPRICE =
            { param_type = "1"
            , param_value = "13.428060"
            , result = "1"
            , param_image = "13,428060"
            }
        , BUYDEPO =
            { param_type = "2"
            , param_value = "14704.450000"
            , result = "1"
            , param_image = "14 704,45"
            }
        , PRICEMIN =
            { param_type = "2"
            , param_value = "84540.000000"
            , result = "1"
            , param_image = "84 540"
            }
        , PRICEMAX =
            { param_type = "2"
            , param_value = "93820.000000"
            , result = "1"
            , param_image = "93 820"
            }
        , SELDEPO =
            { param_type = "0"
            , param_value = "0.000000"
            , result = "0"
            , param_image = ""
            }
        , SEC_PRICE_STEP =
            { param_type = "1"
            , param_value = "10.000000"
            , result = "1"
            , param_image = "10"
            }
        }
    }

local loggedTrade =
    { event = "onLoggedTrade"
    , trade =
        { repoterm = 0
        , price = 90580
        , trade_num = 184749718
        , yield = 0
        , value = 121631.37
        , qty = 1
        , reporate = 0
        , class_code = "SPBFUT"
        , repovalue = 0
        , exchange_code = ""
        , accruedint = 0
        , tradenum = 184749718
        , flags = 2
        , datetime =
            { week_day = 1
            , hour = 10
            , ms = 808
            , mcs = 808000
            , day = 6
            , month = 6
            , sec = 28
            , year = 2016
            , min = 5
            }
        , sec_code = "RIM6"
        , seccode = "RIM6"
        , settlecode = ""
        , period = 1
        , repo2value = 0
        , open_interest = 0
        }
    }
local trade =
    { event = "onTrade", trade =
        { repoterm = 0
        , price = 66014
        , trade_num = 184757330
        , yield = 0
        , value = 264056
        , qty = 4
        , reporate = 0
        , class_code = "SPBFUT"
        , repovalue = 0
        , exchange_code = ""
        , accruedint = 0
        , tradenum = 184757330
        , flags = 2
        , datetime = 
            { week_day = 1, hour = 10, ms = 465, mcs = 465000, day = 6, month = 6, sec = 43, year = 2016, min = 25 }
        , sec_code = "SiM6"
        , seccode = "SiM6"
        , settlecode = ""
        , period = 1
        , repo2value = 0
        , open_interest = 0
        }
    }

local book =
    { tstamp = 279.863
    , class = "SPBFUT"
    , event = "onQuote"
    , asset = "RIM6"
    , l2 =
        { bid_count = 20.000000
        , offer_count = 20.000000
        , bid = 
            { [1]  = { price = 90490.000000, quantity = 3, }
            , [2]  = { price = 90500.000000, quantity = 4, }
            , [3]  = { price = 90510.000000, quantity = 27, }
            , [4]  = { price = 90520.000000, quantity = 3, }
            , [5]  = { price = 90530.000000, quantity = 1, }
            , [6]  = { price = 90550.000000, quantity = 2, }
            , [7]  = { price = 90560.000000, quantity = 10, }
            , [8]  = { price = 90570.000000, quantity = 29, }
            , [9]  = { price = 90580.000000, quantity = 2, }
            , [10] = { price = 90590.000000, quantity = 52, }
            , [11] = { price = 90600.000000, quantity = 2, }
            , [12] = { price = 90610.000000, quantity = 11, }
            , [13] = { price = 90620.000000, quantity = 23, }
            , [14] = { price = 90630.000000, quantity = 61, }
            , [15] = { price = 90640.000000, quantity = 9, }
            , [16] = { price = 90650.000000, quantity = 41, }
            , [17] = { price = 90660.000000, quantity = 12, }
            , [18] = { price = 90670.000000, quantity = 34, }
            , [19] = { price = 90690.000000, quantity = 1, }
            , [20] = { price = 90710.000000, quantity = 1, },
            }
        , offer =
            { [1]  = { price = 90730.000000, quantity = 10, }
            , [2]  = { price = 90740.000000, quantity = 2, }
            , [3]  = { price = 90770.000000, quantity = 41, }
            , [4]  = { price = 90780.000000, quantity = 19, }
            , [5]  = { price = 90790.000000, quantity = 9, }
            , [6]  = { price = 90800.000000, quantity = 5, }
            , [7]  = { price = 90820.000000, quantity = 1, }
            , [8]  = { price = 90840.000000, quantity = 19, }
            , [9]  = { price = 90850.000000, quantity = 1, }
            , [10] = { price = 90860.000000, quantity = 23, }
            , [11] = { price = 90870.000000, quantity = 3, }
            , [12] = { price = 90890.000000, quantity = 1, }
            , [13] = { price = 90900.000000, quantity = 33, }
            , [14] = { price = 90910.000000, quantity = 2, }
            , [15] = { price = 90920.000000, quantity = 7, }
            , [16] = { price = 90940.000000, quantity = 7, }
            , [17] = { price = 90950.000000, quantity = 12, }
            , [18] = { price = 90960.000000, quantity = 52, }
            , [19] = { price = 90970.000000, quantity = 10, }
            , [20] = { price = 90980.000000, quantity = 17, }
            }
        }
    }

function tests.testCreate()
    assert(container.create())
end

function tests.addParams()
    local c = assert(container.create())
    c:add(paramSiM6)
    assert(#c.params == 1)
    expect_eq(paramSiM6, c.params[1])
end

function tests.addLoggedTrades()
    local c = assert(container.create())
    c:add(loggedTrade)
    assert(c.preamble:size() == 1)
    expect_eq(loggedTrade, c.preamble:item(1))
end

function tests.addBook()
    local c = assert(container.create())
    assert(book)
    c:add(book)
    assert(c.data:size() == 1)
    expect_eq(book, c.data:item(1))
end

function tests.addTrade()
    local c = assert(container.create())
    c:add(trade)
    assert(c.data:size() == 1)
    expect_eq(trade, c.data:item(1))
end

function tests.lockPreamble1()
    local c = assert(container.create())
    c:add(book)
    c:add(loggedTrade)
    assert(c.preamble:size() == 0)
end

function tests.lockPreamble2()
    local c = assert(container.create())
    c:add(trade)
    c:add(loggedTrade)
    assert(c.preamble:size() == 0)
end

function tests.Iterator()
    local c = assert(container.create())
    c:add(trade)
    c:add(book)
    local t = {}
    for i, rec in c.data:items() do
        t[i] = rec
    end
    expect_eq(trade, t[1])
    expect_eq(book, t[2])
end

function tests.test2G() -- allocate 3Gb of oobjects
    local c = assert(container.create())
    local ffi = c.data.ffi
    if not ffi then
        print("ffi is inaccessible, nothing to test")
        return
    end
    local recSize = ffi.sizeof("QRECORD")
    local goodSize = 2*1024*1024*1024 -- far beyound luajit-2.0 restriction
    local recNum = math.ceil(goodSize/recSize/2)*2

    local count = 0
    for i = 1, recNum/2 do
        c:add(trade)
        c:add(book)
        count = count + 2
    end
    expect_eq(count, c.data:size())
end
return container
