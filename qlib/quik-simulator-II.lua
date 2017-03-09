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
assert(require("qlib/quik-avd"))
local q_functor = require("qlib/quik-functor-II")
local q_book = require("qlib/quik-book-II")
local q_persist = require("qlib/quik-l2-persist")


local q_simulator = {}

local etc = 
    { account = "SPBFUT005eC"
    , firmid =  "SPBFUT589000"

    , asset = 'SiH7'
--    , asset = 'RIH7'
    , class = "SPBFUT"
    , maxPriceLevel = 8
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

local function makeCopy(a)
    if type(a) == "table" then
        local c = {}
        for k,v in pairs(a) do
            c[k] = copy(a)
        end
        return c
    end
    return a
end
function q_simulator.createStrategy(name, params, etc)
    require("qlib/" .. name)
    local factory = assert(_G[name])
    local etc_ = {}
    for key,value in pairs(etc) do
        etc_[key] = value
    end
    -- overwrite parameters values
    for _,descr in ipairs(params) do
        etc[descr.name] = descr.name
    end
    local strategy = assert(factory.create(etc))
    return strategy
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

return q_simulator
