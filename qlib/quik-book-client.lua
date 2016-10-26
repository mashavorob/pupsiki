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

local client =
    { id = 0
    , cbs =
        { onAllTrade = function() end
        , onTransReply = function() end
        , onQuote = function() end
        , onTrade = function() end
        }
    , tables = 
        {}
    }

local function findOrCreate(coll, ...)
    local newItem = false
    for _, key in ipairs({...}) do
        local t = coll[key]
        if t == nil then
            t = {}
            coll[key] = t
            newItem = true
        end
        coll = t
    end
    return coll, newItem
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

function client:getTable(table)
    return findOrCreate(self.tables, table)
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
        }
    table.insert(fh, row)
    return row
end

function client:getFuturesLimits()
    local fl, newTable = self:getTable("futures_client_limits")
    if newTable then
        local row = 
            { firmid = self.firmid
            , trdaccid = self.account
            , limit_type = 0
            , cbplimit = 0      -- Лимит откр. позиций/Текущий лимит
            , cbplused = 0      -- Заблокировано под исполнение заявок
            , cbplplanned = 0   -- cbplimit - cbplused
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
    assert(buydepo, string.format("BUYDEPO parameter is not defined for '%s':'%s'", q_order.CLASSCODE, q_order.SECCODE))
    assert(selldepo, string.format("SELLDEPO parameter is not defined for '%s':'%s'", q_order.CLASSCODE, q_order.SECCODE))
    
    local limits = self:getFuturesLinits()
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
    
    -- sold means reduced position(negative diff) and positive income
    -- bought means increased position(positive diff) and negative income (reduced balance)
    local income = -price*diff

    local limits = self:getFuturesLimits()
    limits.cbplimit = limits.cbplimit + income
    limits.cbplplanned = limits.cbplimit - limits.cbplused

    local holdings = self:getFuturesHoldings(order.CLASSCODE, order.SECCODE)
    holdings.totalnet = holdings.totalnet + diff
end

local q_client = {
    }

local next_id = 0

function q_client.create(account, firmid)
    next_id = next_id + 1
    local self =
        { id = next_id
        , account = account
        , firmid = firmid
        , money =
            { limit = 0
            , position = 0
            , reserve = 0
            }
        , cbs =
            { onAllTrade = function() end
            , onTransReply = function() end
            , onQuote = function() end
            , onTrade = function() end
            }
        , tables = 
            {}
        }
    setmetatable(self, { __index = client })
    
    return self
end

return q_client
