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
assert(require("qlib/quik-functor"))
assert(require("qlib/quik-avd"))

q_simulator = {}

local etc = {
    account = "SPBFUT005eC",
    firmid =  "SPBFUT589000",

    asset = 'SiM6',
    class = "SPBFUT",

    maxPriceLevel = 8,
}

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

function Subscribe_Level_II_Quotes(class, asset)
end

function getNumberOf(name)
    local functor = q_functor.getInstance()
    local t = functor and functor.q_tables[name] or { }
    return #t
end

function getItem(name, index)
    local functor = q_functor.getInstance()
    local t = functor and functor.q_tables[name] or { }
    local row = t[index + 1]
    return row
end

function getParamEx(class, asset, pname)
    local functor = q_functor.getInstance()
    local assets = functor and functor.q_params[class] or { }
    local paramsTable = assets[asset] or { }
    return paramsTable[pname]
end

function getQuoteLevel2(class, asset)
    local functor = q_functor.getInstance()
    local book = functor and functor.q_books:getBook(class, asset) or nil
    return book and book:getL2Snapshot() or q_book.getEmptyBook()
end

function sendTransaction(trans)
    local functor = q_functor.getInstance()
    assert(functor)
    
    local book = functor.q_books:getBook(trans.CLASSCODE, trans.SECCODE)
    assert(book)
    local evs, msg = book:onOrder(trans)
    if evs then
        functor.q_events:enqueueEvents(evs)
    end
    return msg or ""
end

bit = {}

function bit.band(a, b)
    return bit32.band(a, b)
end


function q_simulator.preProcessData(data)
    
    local emptyQuote = 
        { price = 0
        , quantity = 0 
        }

    local function hashQuote(q)

        local h = ""
        local bid_count = tonumber(q.bid_count)
        for i = 1,etc.maxPriceLevel do
            local bid = (q.bid or {})[tonumber(bid_count) - i + 1] or emptyQuote
            local offer = (q.offer or {})[i] or emptyQuote
            h = h .. 
                "b" .. tostring(bid.price) .. ":" .. tostring(bid.quantity) .. 
                "q" .. tostring(offer.price) .. ":" .. tostring(offer.quantity) .. "-"
        end
        return h
    end

    local newData = {}
    local prevQuoteHash = nil

    for i, rec in ipairs(data) do
        if rec.event == "OnLoggedTrade" and rec.trade.sec_code ~= etc.asset then 
            -- filter out
        elseif rec.event == "onTrade" and rec.trade.sec_code ~= etc.asset then 
            -- filter out
        elseif rec.event == "onQuote" and rec.asset ~= etc.asset then
            -- filter out
        elseif rec.event == "onQuote" then
            local l2 = rec.l2
            l2.bid_count = tonumber(l2.bid_count)
            l2.offer_count = tonumber(l2.offer_count)

            for i = 1,l2.bid_count do
                local q = l2.bid[i]
                q.price = tonumber(q.price)
                q.quantity = tonumber(q.quantity)
            end
            for i = 1,l2.offer_count do
                local q = l2.offer[i]
                q.price = tonumber(q.price)
                q.quantity = tonumber(q.quantity)
            end

            local hash = hashQuote(l2)
            if hash ~= prevQuoteHash then
                prevQuoteHash = hash
                table.insert(newData, rec)
            end
        else
            table.insert(newData, rec)
        end
    end

    print("Original data was: ", #data)
    print("Filtered data was: ", #newData)
    print(string.format("ratio:\t%.1f%%", (#data - #newData)*100/#data))
    return newData
end

function q_simulator.runStrategy(name, data)

    print(string.format("q_simulator.runStrategy(%s, %s)", tostring(name), tostring(data)))

    local functor = q_functor.create(name, data, etc)
    local res = functor:func()
    return res
end

function q_simulator.optimizeStrategy(name, data)

    print(string.format("q_simulator.optimizeStrategy(%s, %s)", tostring(name), tostring(data)))
    
    local functor = q_functor.create(name, data, etc)
    local before, after, clone = avd.maximize(functor)
    if clone == nil then
        return
    end
    return before, after, clone.params
end
