--[[
#
# Совместимость с LuaJIT 
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot q_runner:ad the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

-- check compatibility with Lua 5.2 and LuaJIT

local jit = false

if bit == nil then
    if bit32 == nil then
        assert(false, "Lua 5.2 is required (bit32 module)")
    end
    bit = {}
    setmetatable(bit, {__index=bit32})
else
    jit = true
end

local q_jit = {}

function q_jit.isJIT()
    return jit
end

return q_jit



