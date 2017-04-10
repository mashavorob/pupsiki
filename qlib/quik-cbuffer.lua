--[[
#
# Циклический буфер
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_cbuffer = {}

function q_cbuffer.create(size)
    assert(size > 1)

    local self = { buff = {}
                 , head = 0
                 , size = 0
                 }
    for _=1,size do
        table.insert(self.buff, 0)
    end
    setmetatable(self, {__index = q_cbuffer})
    return self
end

function q_cbuffer:push_back(v)
    self.head = self:getNext(self.head)
    self.buff[self.head] = v
    self.size = (self.size < #self.buff) and (self.size + 1) or self.size
end

function q_cbuffer:reset(v)
    self.head = #self.buff
    self.size = #self.buff
    for i = 1,#self.buff do
        self.buff[i] = v
    end
end

function q_cbuffer:isEmpty()
    return (self.size == 0)
end

function q_cbuffer:getSize()
    return self.size
end

function q_cbuffer:getCapacity()
    return #self.buff
end

function q_cbuffer:getNext(i)
    return (i == #self.buff) and 1 or (i + 1)
end

function q_cbuffer:getAt(i)
    i = self.head - i + 1
    if i <= 0 then
        i = i + #self.buff
    end
    return self.buff[i]
end

return q_cbuffer
