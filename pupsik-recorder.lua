--[[
#
# Запись маркетных данных
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local mdRecorder = false

local etc = {
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

    assert(require("qlib\\quik-recorder"))

    mdRecorder = assert(recorder.create(strategy, etc))
end

function OnAllTrade(trade)
    mdRecorder.onAllTrade(trade)
end

function main()
    while not mdRecorder.isClosed() do
        mdRecorder.onIdle()
        sleep(100)
    end
    mdRecorder.onClose()
end
