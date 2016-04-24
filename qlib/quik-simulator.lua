--[[
#
# Симулятор для стратегий 
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot q_runner:ad the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

assert(require("qlib/quik-book"))
assert(require("qlib/quik-fname"))
assert(require("qlib/quik-utils"))

q_simulator = {}

local etc = {
    account = "SPBFUT005eC",
    firmid =  "SPBFUT589000",
    sname = "quik-scalper",

    asset = 'SiH6',
    class = "SPBFUT",
}


local tables = 
    { futures_client_holding = 
        { 
            { sec_code = "SiH6"             -- бумага
            , totalnet = 0                  -- позиция
            }
        }
    , limit = 100000
    , fee = 2
    , futures_client_limits =
        {
            { firmid =      "SPBFUT589000"  -- код фирмы
            , trdaccid =    "SPBFUT005B2"   -- счет
            , cbplimit =    100000          -- лимит открытых позиций
            , varmargin =   0               -- вариационная маржа
            , accruedint =  0               -- накопленный доход
            }
        }
    , orders = 
        {
        }
    , all_trades =
        {
        }
    }

local params =
    { SPBFUT = 
        { SiH6 =
            { SEC_PRICE_STEP    = { param_value = 1      } -- минимальный шаг цены
            , STEPPRICE         = { param_value = 1      } -- стоимость шага цены
            , BUYDEPO           = { param_value = 6000   } -- гарантийное обеспечение продавца
            , SELDEPO           = { param_value = 6000   } -- гарантийное обеспечение покупателя
            , PRICEMIN          = { param_value = 28000  } -- максимальная цена
            , PRICEMAX          = { param_value = 280000 } -- минимальная цена 
            }
        }
    }

local books = 
    { classes = 
        { SPBFUT =
            { }
        }
    }

function tables:syncTables()
    local orders = { }
    local holdings = { }
    local depo = 0
    local margin = 0
    local deals = 0
    for class, listOfBooks in pairs(books.classes) do
        for asset, book in pairs(listOfBooks) do
            table.insert(orders, book.order)
            table.insert(holdings, {class_code=class, sec_code=asset, totalnet=book.pos})
            local price = 0
            if book.pos > 0 then
                depo = depo + book.pos*params[class][asset].BUYDEPO.param_value
                if book.l2Snap.bid_count > 0 then
                    price = book.l2Snap.bid[book.l2Snap.bid_count].price
                end
            elseif book.pos < 0 then
                depo = depo - book.pos*params[class][asset].SELLDEPO.param_value
                local price = 0
                if book.l2Snap.offer_count > 0 then
                    price = book.l2Snap.offer[1].price
                end
            end
            marging = margin + book.pos*price/book.priceStep*book.priceStepValue - book.paid
            deals = deals + book.deals
        end
    end
    tables.orders = orders
    tables.futures_client_holdings = holdings
    tables.futures_client_limits.cbplimit = self.limit - depo 
    tables.futures_client_limits.varmargin = margin
    tables.futures_client_limits.accruedint = -deals*self.fee
end

function tables:getMargin()
    return tables.futures_client_limits.varmargin + tables.futures_client_limits.accruedint
end

function books:getBook(class, asset, create)
    local booksGroup = self.classes[class]
    local book = nil
    if booksGroup then
        book = booksGroup[asset]
        if book == nil and create then
            local paramsGroup = params[class] or { }
            local paramList = paramsGroup[asset]
            if paramList then
                book = q_book.create(class, asset, paramList.SEC_PRICE_STEP.param_value, paramList.STEPPRICE.param_value)
                booksGroup[asset] = book
            end
        end
    end
    return book
end

local evQueue =
    { events = {}
    , strategy = nil
    }

function evQueue:enqueueEvents(evs)
    for _, ev in ipairs(evs) do
        table.insert(self.events, ev)
    end
end

function evQueue:flushEvents()
    for _,ev in ipairs(self.events) do
        if ev.name == "OnQuote" then
            self.strategy:onQuote(ev.data.class, ev.data.asset)
        elseif ev.name == "OnAllTrade" then
            table.insert(tables.all_trades, ev.data)
            self.strategy:onAllTrade(ev.data)
        elseif ev.name == "OnTransReply" then
            self.strategy:onTransReply(ev.data)
        elseif ev.name == "OnTrade" then
            self.strategy:onTrade(ev.data)
        else
            print("Unknown event type: ", ev.name)
            assert(false)
        end
    end
    self:printState()
    self.events = {}
end

function evQueue:printHeaders()
    local ln = nil
    for _,col in ipairs(self.strategy.ui_mapping) do
        ln = ((ln == nil and "") or (ln .. ",")) .. col.name
    end
    io.stderr:write(ln .. "\n")
end

function evQueue:printEnd()
    io.stderr:write("end.\n\n")
end

QTABLE_DOUBLE_TYPE = 1
QTABLE_INT64_TYPE = 2
QTABLE_STRING_TYPE = 3
QTABLE_CACHED_STRING_TYPE = 4

local numericTypes = 
    { [QTABLE_DOUBLE_TYPE] = true
    , [QTABLE_INT64_TYPE] = true
    }

local stringTypes =
    { [QTABLE_STRING_TYPE] = true
    , [QTABLE_CACHED_STRING_TYPE] = true
    }

function evQueue:printState()
    local ln = nil
    for _,col in ipairs(self.strategy.ui_mapping) do
        local val = self.strategy.ui_state[col.name]
        local s = nil
        pcall( function() s = string.format(col.format, val) end )
        ln = ((ln == nil and "") or (ln .. ",")) .. (s or tostring(val))
    end
    io.stderr:write(ln .. "\n")
end

function Subscribe_Level_II_Quotes(class, asset)
    print(string.format("Subscribe_Level_II_Quotes(%s, %s)", class, asset))
end

function getNumberOf(tname)
    local t = tables[tname] or { }
    return #t
end

function getItem(tname, index)
    local t = tables[tname] or { }
    return t[index + 1]    
end

function getParamEx(class, asset, pname)
    local assets = params[class] or { }
    local paramsTable = assets[asset] or { }
    return paramsTable[pname]
end

function getQuoteLevel2(class, asset)
    local book = books:getBook(class, asset)
    return book and book:getL2Snapshot() or q_book.getEmptyBook()
end

function sendTransaction(trans)
    print(string.format("sendTransaction(%s, %s)", trans.class_code, trans.sec_code))
    local book = books:getBook(trans.class_code, trans.sec_code)
    assert(book)
    local evs, msg = book:onOrder(trans)
    if evs then
        evQueue:enqueueEvents(evs)
    end
    return msg
end

bit = {}

function bit.band(n, f)
    local mult = 1
    local res = 0
    n = math.floor(n)
    f = math.floor(f)
    while n ~= 0 and f ~= 0 do
        if (n % 2) ~= 0 and (f % 2) ~= 0 then
            res = res + mult
        end
        mult = mult*2
        n = math.floor(n/2)
        f = math.floor(f/2)
    end
    return res
end

function q_simulator.runStrategy(sname, data)

    print(string.format("q_simulator.runStrategy(%s, %s)", tostring(sname), tostring(data)))

    etc.sname = sname or etc.sname

    assert(require("qlib/" .. etc.sname))

    etc.account = q_utils.getAccount() or etc.account
    etc.firmid = q_utils.getFirmID() or etc.firmid

    local factory = assert(_G[etc.sname])
    evQueue.strategy = assert(factory.create(etc))
    evQueue.strategy:init()

    evQueue:printHeaders()
    evQueue:printState()

    evQueue.strategy:onStartTrading()

    evQueue:printState()

    for i, rec in ipairs(data) do
        if rec.event == "onQuote" then
            local book = books:getBook(rec.class, rec.asset, true)
            if book then
                local evs = book:onQuote(rec.l2)
                evQueue:enqueueEvents(evs)
            end
        elseif rec.event == "onTrade" then
            local book = books:getBook(rec.trade.class_code, rec.trade.sec_code, true)
            if book then
                local evs = book:onTrade(rec.trade)
                evQueue:enqueueEvents(evs)
            end
        else
            print("Unknown event type: ", rec.event)
            assert(false)
        end
        evQueue:flushEvents()
        if i % 10 == 0 then
            tables:syncTables()
        end
    end
    tables:syncTables()

    evQueue:printEnd()

    return tables:getMargin()
end
