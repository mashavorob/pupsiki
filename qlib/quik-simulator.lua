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

local q_fname = require("qlib/quik-fname")
local q_utils = require("qlib/quik-utils")
assert(require("qlib/quik-book"))
assert(require("qlib/quik-avd"))

local q_functor = require("qlib/quik-functor")
local q_l2_data = require("qlib/quik-jit-l2-data")

q_simulator = {}

local etc = {
    account = "SPBFUT005eC",
    firmid =  "SPBFUT589000",

    asset = 'SiU6',
--    asset = 'RIU6',
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

function q_simulator.preProcessData(data)
    local filter = function(rec)
        if rec.event == "onLoggedTrade" and rec.trade.sec_code ~= etc.asset then 
            -- filter out
            return false
        elseif rec.event == "onTrade" and rec.trade.sec_code ~= etc.asset then 
            -- filter out
            return false
        elseif rec.event == "onQuote" and rec.asset ~= etc.asset then
            -- filter out
            return false
        end
        return true
    end

    local newData = {}
    for _,fdata in ipairs(data) do
    
        local newFData = q_l2_data.create()

        newFData.params = fdata.params


        for _,rec in fdata.preamble:items() do
            if filter(rec) then
                newFData:add(rec)
            end
        end
        for _,rec in fdata.data:items() do
            if filter(rec) then
                newFData:add(rec)
            end
        end

        table.insert(newData, newFData)
    end

    return newData
end

function q_simulator.runStrategy(name, data, params)
    local functor = q_functor.create(name, data, etc)
    params = params or {}
    for _,p in ipairs(params) do
        local set_param = functor['set_' .. p.param]
        if set_param then
            set_param(functor, p.value)
        else
            functor[p.param] = p.value
        end
    end
    return functor:func()
end

function q_simulator.optimizeStrategy(name, data)

    print(string.format("q_simulator.optimizeStrategy(%s, %s)", tostring(name), tostring(data)))
    
    local functor = q_functor.create(name, data, etc)
    instance = nil
    local before, after, clone = avd.maximize(functor)
    if clone == nil then
        return
    end
    return before, after, clone.params
end
