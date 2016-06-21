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
    assets = {
        { class='SPBFUT', asset='RIU6' },
        { class='SPBFUT', asset='SiU6' },
    },
}

function l2r:serializeItem(val)
    if type(val) == "string" then
        return string.format("%q", val)
    elseif type(val) == "number" then
        return tostring(val)
    elseif type(val) == "table" then
        local ln = "{ "
        for k,v in pairs(val) do
            ln = ln .. string.format("[%s] = %s, ", self:serializeItem(k), self:serializeItem(v))
        end
        ln = ln .. "}"
        return ln
    elseif type(val) == "nil" then
        return "nil"
    end
    return "'unsupported type: " .. type(val) .. "'"
end

local insideOnLogOpen = false

function l2r:onLogOpen()

    -- prevent recursion
    if insideOnLogOpen then
        return
    end
    insideOnLogOpen = true

    -- log params
    for _, item in ipairs(self.assets) do
        local params = 
            { SEC_PRICE_STEP = getParamEx(item.class, item.asset, "SEC_PRICE_STEP")
            , STEPPRICE = getParamEx(item.class, item.asset, "STEPPRICE")
            , BUYDEPO = getParamEx(item.class, item.asset, "BUYDEPO")
            , SELDEPO = getParamEx(item.class, item.asset, "SELDEPO")
            , PRICEMIN = getParamEx(item.class, item.asset, "PRICEMIN")
            , PRICEMAX = getParamEx(item.class, item.asset, "PRICEMAX")
            , EXCH_PAY = getParamEx(item.class, item.asset, "EXCH_PAY")
            }
        self:logItem { event="OnParams", class=item.class, asset=item.asset, params=params }
    end
    
    -- log historical trades
    local n = getNumberOf("all_trades")
    local first = 0
    local counts = { }
    local cc = 0
    local MIN_TRADES = 1000

    for _, item in ipairs(self.assets) do
        counts[ item.class .. item.asset] = { c = 0 }
        cc = cc + 1
    end

    for i = 1, n do
        local trade = getItem("all_trades", n - i)
        local c = counts[ trade.class_code .. trade.sec_code ]
        if c then
            c.c = c.c + 1
            if c.c == MIN_TRADES then
                cc = cc - 1
                if cc == 0 then
                    first = n - i
                    break
                end
            end
        end
    end
    for i = first,n - 1 do
        local trade = getItem("all_trades", i)
        local c = counts[ trade.class_code .. trade.sec_code ]
        if c then
            self:logItem { event="OnLoggedTrade", trade=trade }
        end
    end

    insideOnLogOpen = false
end

function l2r:checkLog()
    local name = q_fname.root .. os.date(self.log.namePattern)
    if name ~= self.log.name then
        if self.log.file then
            self.log.file:close()
        end
        self.log.name = name
        self.log.file = assert(io.open(name, "a+"))
        self:onLogOpen()
    end
    if not self.log.file then
        message("name='" .. name .. "'", 3)
    end
end

function l2r:logItem(item)
    self:checkLog()
    if self.log.file then
        self.log.file:write( self:serializeItem(item) .. ",\n" )
    end
end

function l2r:onInit()
    assert(require("qlib/quik-table"))
    self.qtable = qtable.create("conf/quik-l2-recorder.wpos", self.title, self.ui_mapping)
    self.qtable.addRow(self.state)
    for _,item in ipairs(self.assets) do
        Subscribe_Level_II_Quotes(item.class, item.asset)
    end
    self:onLogOpen()
end

function l2r:onTrade(trade)
    for _, item in ipairs(self.assets) do
        if trade.class_code == item.class and trade.sec_code == item.asset then
            self:logItem { event="onTrade", trade=trade }
            break
        end
    end
end

function l2r:onQuote(class, asset)
    for _, item in ipairs(self.assets) do
        if class == item.class and asset == item.asset then
            self:logItem { event="onQuote", class=class, asset=asset, tstamp=os.clock(), l2=getQuoteLevel2(class, asset) }
            break
        end
    end
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

    assert(require("qlib/quik-fname"))
    q_fname.root = folder

    recorder = l2r.create()
    recorder:onInit()
end

function OnAllTrade(trade)
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
