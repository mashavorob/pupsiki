--[[
#
# Запись маркетных данных (уровень 2)
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

l2r = {
    log = {
        namePattern = "logs/l2-events-%Y-%m-%d.log",
        name = "",
        file = false,
    },
    title = "L2-Рекордер",
    qtable = false,
    ui_mapping = { 
        { name="state", title="Cостояние", ctype=QTABLE_STRING_TYPE, width=14, format="%s" },
    },
    state = {
        state = "Запись",
    },
}

function l2r:serializeItem(val)
    if type(val) == "string" then
        return "'" .. val .. "'"
    elseif type(val) == "number" then
        return tostring(val)
    elseif type(val) == "table" then
        local ln = "{ "
        for k,v in pairs(val) do
            ln = ln .. self:serializeItem(k) .. "=" .. self:serializeItem(v) .. ","
        end
        ln = ln .. "}"
        return ln
    elseif type(val) == "nil" then
        return "nil"
    end
    return "'unsupported type: " .. type(val) .. "'"
end

function l2r:checkLog()
    local name = os.date(self.log.namePattern)
    if name ~= self.log.name then
        if self.log.file then
            self.log.file:close()
        end
        self.log.name = name
        self.log.file = assert(io.open(name, "a+"))
    end
    if not self.log.file then
        message("name='" .. name .. "'", 3)
    end
end

function l2r:logItem(item)
    self:checkLog()
    if self.log.file then
        self.log.file:write( self:serializeItem(item) .. "\n" )
    end
end

function l2r:onInit()
    assert(require("qlib/quik-table"))
    self.qtable = qtable.create("conf/quik-l2-recorder.wpos", self.title, self.ui_mapping)
    self.qtable.addRow(self.state)
end

function l2r:onTrade(trade)
    self:logItem { event="onTrade", trade=trade }
end

function l2r:onQuote(class, asset)
    self:logItem { event="onQuote", class=class, asset=asset, tstamp=os.clock(), l2=getQuoteLevel2(class, asset) }
end

function l2r:onIdle()
    self.qtable.onIdle()
end

function l2r:onClose()
    if self.log.file then
        self.log.file:close()
        self.log.file = false
        self.log.name = ""
    end
end

function l2r:isClosed()
    return self.qtable.isClosed()
end

function l2r.create()
    local obj = { }
    setmetatable(obj, {__index=l2r})
    return obj
end

local recorder = false

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

    recorder = l2r.create()
    recorder:onInit()
end

function OnTrade(trade)
    recorder:onTrade(trade)
end

function OnQuote(class, asset)
    recorder:onQuote(class, asset)
end

function main()
    while not recorder:isClosed() do
        recorder:onIdle()
        sleep(100)
    end
    recorder:onClose()
end
