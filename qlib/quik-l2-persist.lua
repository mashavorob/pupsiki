--[[
#    
# Cериализация маркетных данных (уровень 2)
#
#  vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]


q_persist = {}

function q_persist.loadL2Log(fname)
    local file = fname and assert(io.open(fname,"r")) or io.stdin
    local data = {}
    for line in file:lines() do
        local text = "return {" .. line .. "}"
        local fn, message = loadstring(text)
        assert(fn, message)
        local status, rec = pcall(fn)
        assert(status)
        table.insert(data, rec[1])
    end
    assert(#data > 1)
    return data
end
