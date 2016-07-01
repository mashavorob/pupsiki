--[[
#
# Вспомогательные функции
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

q_utils = { }

function q_utils.getMoneyLimit(account)
    local n = getNumberOf("futures_client_limits")
    assert(n>0)
    for i = 0, n - 1 do
        local row = getItem("futures_client_limits", i)
        if row.trdaccid == account then
            return row.cbplimit
        end
    end
    return 0
end

function q_utils.getBalance(account)
    local n = getNumberOf("futures_client_limits")
    for i = 0, n - 1 do
        local row = getItem("futures_client_limits", i)
        if row.trdaccid == account then
            return row.cbplimit + row.varmargin + row.accruedint
        end
    end
    return 0
end

function q_utils.getPos(asset)
    local n = getNumberOf("futures_client_holding")
    for i = 0,n-1 do
        local row = getItem("futures_client_holding", i)
        if row.sec_code == asset then
            return row.totalnet
        end
    end
    return 0
end

function q_utils.getSettlePrice(class, asset)
    return tonumber(getParamEx(class, asset, "SETTLEPRICE").param_value)
end

function q_utils.getStepPrice(class, asset)
    return tonumber(getParamEx(class, asset, "STEPPRICE").param_value)
end

function q_utils.getBuyDepo(class, asset)
    return tonumber(getParamEx(class, asset, "BUYDEPO").param_value)
end

function q_utils.getSellDepo(class, asset)
    return tonumber(getParamEx(class, asset, "SELLDEPO").param_value)
end

function q_utils.getMinPrice(class, asset)
    return tonumber(getParamEx(class, asset, "PRICEMIN").param_value)
end

function q_utils.getMaxPrice(class, asset)
    return tonumber(getParamEx(class, asset, "PRICEMAX").param_value)
end

function q_utils.getAccount()
    local n = getNumberOf("futures_client_limits")
    for i = 0, n - 1 do
        local row = getItem("futures_client_limits", i)
        return row.trdaccid
    end
end

function q_utils.getFirmID()
    local n = getNumberOf("futures_client_limits")
    for i = 0, n - 1 do
        local row = getItem("futures_client_limits", i)
        return row.firmid
    end
end

