--[[
#
# Стратегия скальпер для Quik [Sixx]
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local etc = 
    { account           = "==SPBFUT005eC"
    , firmid            = "==SPBFUT589000"
    , sname             = "quik-scalper"

    , asset             = 'SiM7'
    , class             = "SPBFUT"
    , avgFactorSpot     = 100  -- коэффициент осреднения спот
    }

local scriptFolder = false

local quik_ext = false
local q_fname = false
local q_utils = false
local q_runner = false

function OnInit(scriptPath)

    if not LUA_PATH then
        LUA_PATH = ""
    end
    if LUA_PATH ~= "" then
        LUA_PATH = LUA_PATH .. ";"
    end

    local function rfind(s, subs)
        local pos = string.find(s, subs, 1, true)
        local nextPos = pos
        while nextPos do
            pos = nextPos
            nextPos = string.find(s, subs, pos + 1, true)
        end
        return pos
    end
    local pos = rfind(scriptPath, "\\") or rfind(scriptPath, "//")
    local folder = pos and string.sub(scriptPath, 1, pos) or scriptPath

    if LUA_PATH and LUA_PATH ~= "" then
        LUA_PATH = LUA_PATH .. ";"
    end
    LUA_PATH = LUA_PATH .. ".\\?.lua;" .. folder .. "?.lua"
    
    package.cpath = package.cpath .. ";.\\lib?.dll;?.dll;" .. folder .. "lib?.dll;" .. folder .. "?.dll"
    quik_ext = require("quik_ext")

    q_fname = require("qlib/quik-fname")
    q_fname.root = folder
    q_utils = require("qlib/quik-utils")
    q_runner = require("qlib/quik-l2-runner")

    local factory = require("qlib/" .. etc.sname)

    etc.account = q_utils.getAccount() or etc.account
    etc.firmid = q_utils.getFirmID() or etc.firmid

    local strategy = assert(factory.create(etc))

    strategyRunner = assert(q_runner.create(strategy, etc))
end

function OnAllTrade(trade)
    strategyRunner:onAllTrade(trade)
end

function OnTransReply(reply)
    strategyRunner:onTransReply(reply)
end

function OnTrade(trade)
    strategyRunner:onTrade(trade)
end

function OnQuote(class, asset)
    strategyRunner:onQuote(class, asset)
end

function main()
    while not strategyRunner:isClosed() do
        strategyRunner:onIdle()
        sleep(100)
    end
    strategyRunner:onClose()
end
