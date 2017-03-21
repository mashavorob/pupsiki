--[[
#
# Описание клинта, эмулятора биржи
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local client = {}

function client:pushOnAllTrade(trade)
    table.insert(self.events, { event="onAllTrade", data=trade })
end

function client:pushOnTransReply(transReply)
    table.insert(self.events, { event="onTransReply", data=transReply })
end

function client:pushOnQuote(class, asset)
    table.insert(self.events, { event="onQuote", data={class=class, asset=asset} })
end

function client:pushOnTrade(trade)
    table.insert(self.events, { event="onTrade", data=trade })
end

function client:pushOnTestOrder(order)
    table.insert(self.events, { event="onTestOrder", data=order })
end

function client:flushEvents()
    local events = self.events
    self.events = {}
    for _,ev in ipairs(events) do
        if ev.event == "onAllTrade" then
            self:fireOnAllTrade(ev.data)
        elseif ev.event == "onTransReply" then
            self:fireOnTransReply(ev.data)
        elseif ev.event == "onQuote" then
            self:fireOnQuote(ev.data.class, ev.data.asset)
        elseif ev.event == "onTrade" then
            self:fireOnTrade(ev.data)
        elseif ev.event == "onTestOrder" then
            self:fireOnTestOrder(ev.data)
        else
            assert(false, "Unknown event type")
        end
    end
end

function client:fireOnAllTrade(trade)
    self.cbs.onAllTrade(trade)
end

function client:fireOnTransReply(transReply)
    self.cbs.onTransReply(transReply)
end

function client:fireOnQuote(class, asset)
    self.cbs.onQuote(class, asset)
end

function client:fireOnTrade(trade)
    self.cbs.onTrade(trade)
end

function client:fireOnTestOrder(order)
    self.cbs.onTestOrder(order)
end

function client:getTable(tableName)
    local t = self.tables[tableName]
    if not t then
        t = self.book.getTable(tableName)
    end
    return t
end

function client:getOrders()
    return self:getTable("orders")
end

function client:getFuturesHoldings(class, asset)
    assert(class == "SPBFUT")
    local fh = self:getTable("futures_client_holding")
    for _, row in ipairs(fh) do
        if row.sec_code == asset then
            return row
        end
    end
    local row = 
        { firmid = self.firmid
        , trdaccid = self.account
        , sec_code = asset
        , ["type"] = ""
        , varmargin = 0
        , positionvalue = 0
        , totalnet = 0
        , cashflow = 0
        }
    table.insert(fh, row)
    return row
end

function client:getFuturesLimits()
    local fl = self:getTable("futures_client_limits")
    if #fl == 0 then
        local row = 
            { firmid = self.firmid
            , trdaccid = self.account
            , limit_type = 0
            , cbplimit = self.money.limit       -- Лимит откр. позиций/Текущий лимит
            , cbplused = 0                      -- Заблокировано под исполнение заявок
            , cbplplanned = self.money.limit    -- cbplimit - cbplused
            , varmargin = 0
            , accruedint = 0
            }
        table.insert(fl, row)
    end
    return fl[1]
end

function client:onQuoteChange(order, params, size)
    -- change reserve and limits
    local buydepo = params.BUYDEPO and tonumber(params.BUYDEPO.param_value)
    local selldepo = params.SELLDEPO and tonumber(params.SELLDEPO.param_value)
    if buydepo and selldepo then
        buydepo = buydepo > 0 and buydepo or selldepo
        selldepo = selldepo > 0 and selldepo or buydepo
    end
    assert(buydepo, string.format("BUYDEPO parameter is not defined for '%s':'%s'", order.CLASSCODE, order.SECCODE))
    assert(selldepo, string.format("SELLDEPO parameter is not defined for '%s':'%s'", order.CLASSCODE, order.SECCODE))

    local limits = self:getFuturesLimits()

    local diff = size*(order.OPERATION == 'B' and buydepo or selldepo)
    if limits.cbplused + diff > limits.cbplimit then
        return false
    end
    limits.cbplused = limits.cbplused + diff
    limits.cbplplanned = limits.cbplimit - limits.cbplused

    return true
end

-- when order filled (might be partially)
function client:onOrderFilled(order, price, diff)

    assert(order.OPERATION == 'B' and diff > 0 or order.OPERATION == 'S' and diff < 0,
        string.format("Unexpected sign of position change, operation='%s', change='%f'", order.OPERATION, diff))
    
    local holdings = self:getFuturesHoldings(order.CLASSCODE, order.SECCODE)
    local limits = self:getFuturesLimits()
    local params = self.book:getParams(order.CLASSCODE, order.SECCODE)
    
    local buydepo = params.BUYDEPO and tonumber(params.BUYDEPO.param_value)
    local selldepo = params.SELLDEPO and tonumber(params.SELLDEPO.param_value)
    local exchpay = params.EXCH_PAY and tonumber(params.EXCH_PAY.param_value) or 0
    if buydepo and selldepo then
        buydepo = buydepo > 0 and buydepo or selldepo
        selldepo = selldepo > 0 and selldepo or buydepo
    end
    assert(buydepo, string.format("BUYDEPO parameter is not defined for '%s':'%s'", order.CLASSCODE, order.SECCODE))
    assert(selldepo, string.format("SELLDEPO parameter is not defined for '%s':'%s'", order.CLASSCODE, order.SECCODE))

    local closeAmount = 0
    local openAmount = 0
    local numOfContracts = math.abs(diff)

    if diff*holdings.totalnet < 0 then
        closeAmount = math.min(math.abs(holdings.totalnet), math.abs(diff))
        openAmount = math.abs(diff) - closeAmount
    else
        closeAmount = 0
        openAmount = math.abs(diff)
    end

    local moneyToRelease = closeAmount*(holdings.totalnet > 0 and buydepo or selldepo)
    local moneyToReserve = openAmount*(diff > 0 and buydepo or selldepo)
    local moneyToPay = openAmount*exchpay + numOfContracts*g_brokerFee
    -- sold means reduced position(negative diff) and positive income
    -- bought means increased position(positive diff) and negative income (reduced balance)
    local cashflow = -price*diff - moneyToPay
    
    -- update reserves and positions
    limits.cbplused = limits.cbplused - moneyToRelease + moneyToReserve
    limits.cbplplanned = limits.cbplimit - limits.cbplused

    holdings.totalnet = holdings.totalnet + diff
    holdings.price = price
    holdings.cashflow = holdings.cashflow + cashflow
    holdings.positionvalue = holdings.totalnet*holdings.price
    holdings.varmargin = holdings.cashflow + holdings.positionvalue

    assert(limits.cbplplanned >=0)
    return moneyToPay
end

function client:getBalance()

    local ft = self:getFuturesLimits()
    assert(ft)
    local balance = self:getFuturesLimits().cbplimit

    local fh = self:getTable("futures_client_holding")
    
    for _, row in ipairs(fh) do
        balance = balance + row.varmargin
    end
    return balance
end

local factory = {
    }

local next_id = 0

function factory.create(book, strategy, limit)

    limit = limit or 30000

    strategy = strategy or 
        { etc = { account = "<UNLIM>", firmid = "<UNLIM>" }
        , onAllTrade = function() end
        , onTransReply = function() end
        , onQuote = function() end
        , onTrade = function() end
        }
        
    next_id = next_id + 1

    local self =
        { id = next_id
        , book = book
        , account = strategy.etc.account
        , firmid = strategy.etc.firmid
        , money =
            { limit = limit
            }
        , cbs =
            { onAllTrade = function(trade) strategy:onAllTrade(trade) end
            , onTransReply = function(reply) strategy:onTransReply(reply) end
            , onQuote = function(class, asset)
                  strategy:onQuote(class, asset) 
              end
            , onTrade = function(trade) strategy:onTrade(trade) end
            , onTestOrder = strategy["onTestOrder"] and function(order) strategy:onTestOrder(order) end or function() end
            }
        , tables = 
            { futures_client_holding = {}
            , futures_client_limits = {}
            , orders = {}
            }
        , events = {}
        }

    setmetatable(self, { __index = client })
    setmetatable(self.tables, { __index = book.tables })

    book:addClient(self)
    -- warming up
    self:getFuturesLimits()
    local assets = book:getAssetList("SPBFUT")
    for _,asset in ipairs(assets) do
        self:getFuturesHoldings("SPBFUT", asset)
    end
    
    return self
end

return factory
