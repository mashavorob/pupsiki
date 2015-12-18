--[[
#
# Стратегия скальпер для Quik [RIZ5]
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local etc = {
    asset = "RIH6",
    class = "SPBFUT",
    title = "qscalper",

    account = "SPBFUT005eC",
    firmid =  "SPBFUT589000",

}

local strategy = {
    etc = false,
    title = "Orders tester",
    ui_mapping = {
        { name="asset", title="Бумага", ctype=QTABLE_STRING_TYPE, width=8, format="%s" },
        { name="position", title="Позиция", ctype=QTABLE_DOUBLE_TYPE, width=10, format="%s" },
        { name="message", title="Сообщение", ctype=QTABLE_STRING_TYPE, width=20, format="%.0f" },
        { name="lastErr", title="Ошибка", ctype=QTABLE_STRING_TYPE, width=20, format="%.0f" },
    },
    ui_state = {
        asset = etc.asset,
        position = 0,
        message = "",
        lastErr = "",
    },
    minPrice = false,
    maxPrice = false,
    order = false,
}

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

    assert(require("qlib/quik-etc"))
    assert(require("qlib/quik-order"))
    assert(require("qlib/quik-table"))
    assert(require("qlib/quik-l2-runner"))
    assert(require("qlib/quik-utils"))

    strategy.etc = config.create(etc)
    strategy.order = q_order.create(etc.account, etc.class, etc.asset)
    strategyRunner = assert(q_runner.create(strategy, etc))
    strategy.minPrice = tonumber(getParamEx(etc.class, etc.asset, "PRICEMIN").param_value)
    strategy.maxPrice = tonumber(getParamEx(etc.class, etc.asset, "PRICEMAX").param_value)
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

function OnDisconnected()
    strategyRunner:onDisconnected()
end

function main()
    while not strategyRunner:isClosed() do
        strategyRunner:onIdle()
        sleep(100)
    end
    strategyRunner:onClose()
end

function strategy:init()

    self.etc.account = q_utils.getAccount() or self.etc.account
    self.etc.firmid = q_utils.getFirmID() or self.etc.firmid

    self.ui_state.asset = self.etc.asset

end

function strategy:onTestAction(operation, price)
    local msg, res, err = "", false, "not-sent"
    if self.order:isPending() then
    elseif self.order:isActive() then
        msg = "Kill order"
        res, err = self.order:kill()
    else
        msg = "Send order"
        res, err = self.order:send(operation, price, 1)
    end
    self.ui_state.message = msg
    self.ui_state.lastErr = err
end

function strategy:onStartStopCallback()
    self:onTestAction('B', self.minPrice)
end

function strategy:onHaltCallback()
    if self.ui_state.position > 0 then
        self:onTestAction('S', self.minPrice)
    else
        self:onTestAction('B', self.maxPrice)
    end
end

function strategy:onTransReply(reply)
    q_order.onTransReply(reply)
end

function strategy:onTrade(trade)
    q_order.onTrade(trade)
end

function strategy:onAllTrade(trade)
end

function strategy:onQuote(class, asset)
end

function strategy:onIdle()
    if self.order.position ~= 0 then
        self.ui_state.position = self.ui_state.position + self.order.position
        self.order.position = 0
    end
    q_order.onIdle()
    if self.order:isPending() then
        self.ui_state.message = "pending"
    elseif self.order:isActive() then
        self.ui_state.message = "active"
    else
        self.ui_state.message = "inactive"
    end
    q_order.onIdle()
end

function strategy:onDisconnected()
    q_order.onDisconnected()
end

function strategy:onQuoteOrTrade(l2)
end

