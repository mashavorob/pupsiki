--[[
#
# Симулятор таблиц quik
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

q_tables = { }

function q_tables.create(firmid, account)
    local self = { }
    setmetatable(self, {__index = tables})
    
    firmid = firmid or "SPBFUT589000"
    account = account or "SPBFUT005B2"

    local limit = 100000

    self = 
        { futures_client_holding = {}
        , fee = 2
        , limit = limit
        , futures_client_limits =
            {
                { firmid = firmid or "SPBFUT589000"
                , trdaccid = account or "SPBFUT005B2"
                , cbplimit = limit
                , varmargin = 0
                , accruedint = 0
                }
            }
        , orders = {}
        , all_trades = {}
        }
    setmetatable(self, {__index = q_tables})
    return self
end

function q_tables:syncTables(books, params)
    local orders = { }
    local res = { }
    local holdings = { }
    local depo = 0
    local margin = 0
    local deals = 0
    for class, listOfBooks in pairs(books.classes) do
        for asset, book in pairs(listOfBooks) do
            table.insert(orders, book.order)
            table.insert(holdings, {class_code=class, sec_code=asset, totalnet=book.pos})
            local price = 0
            if book.pos > 0 then
                depo = depo + book.pos*params[class][asset].BUYDEPO.param_value
                if book.l2Snap.bid_count > 0 then
                    price = book.l2Snap.bid[book.l2Snap.bid_count].price
                end
            elseif book.pos < 0 then
                depo = depo - book.pos*params[class][asset].SELLDEPO.param_value
                if book.l2Snap.offer_count > 0 then
                    price = book.l2Snap.offer[1].price
                end
            end
            margin = margin + book.pos*price/book.priceStep*book.priceStepValue + book.paid
            deals = deals + book.deals
        end
    end
    self.orders = orders
    self.futures_client_holdings = holdings

    --self.futures_client_limits[1].cbplimit = self.limit - depo
    self.futures_client_limits[1].varmargin = margin
    self.futures_client_limits[1].accruedint = -deals*self.fee
end

function q_tables:getMargin()
    return self.futures_client_limits[1].varmargin + self.futures_client_limits[1].accruedint
end


