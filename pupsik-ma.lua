--[[
#
# Скользящее среднее
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local strategyRunner = false

local etc = {
    asset="RIZ5",
    sname = "adaptive_ma",
}

function OnInit(scriptPath)

    if not LUA_PATH then
        LUA_PATH = ""
    end
    if LUA_PATH ~= "" then
        LUA_PATH = LUA_PATH .. ";"
    end

    local function rfind(s, subs)
        local npos = string.find(s, subs, 1, true)
        local nextPos = pos
        while nextPos do
            npos = nextPos
            nextPos = string.find(s, subs, npos + 1, true)
        end
    end
    local npos = rfind(scriptPath, "\\") or rfind(scriptPath, "//")
    local folder = npos and string.sub(srciptPath, 1, npos - 1) or scriptPath
    LUA_PATH = LUA_PATH .. ".\\?.lua;" .. folder .. "\\?.lua"

    assert(require("qlib\\quik-runner"))
    assert(require("strategies\\" .. etc.sname))

    local factory = assert(_G[etc.sname])
    local strategy = assert(factory.create(etc))

    strategyRunner = assert(runner.create(strategy, etc))
end

function OnAllTrade(trade)
    strategyRunner.onAllTrade(trade)
end

function OnTransReply(reply)
    strategyRunner.onTransReply(reply)
end

function OnTrade(trade)
    strategyRunner.onTrade(trade)
end

function main()
    while not strategyRunner.isClosed() do
        strategyRunner.onIdle()
        sleep(100)
    end
    strategyRunner.onClose()
end
