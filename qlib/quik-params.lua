--[[
#
# Симулятор параметров quik
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

q_params = {}

function q_params.create()
    local self = { }
    setmetatable(self, {__index = q_params})
    return self
end

function q_params:updateParams(class, asset, pp)
    local assetList = self[class]
    if not assetList then
        assetList = {}
        self[class] = assetList
    end
    assetList[asset] = pp
end


