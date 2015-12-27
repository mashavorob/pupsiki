--[[
#
# Скользящее среднее
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

q_avg = { }

local avg = {
    m = false,
    m2 = 0,
    average = 0,
    deviation = 0,
    alpha = 0,
}

local function getAlpha(factor)
    return 2/(1 + factor)
end

function q_avg.create(factor)
    factor = factor or 19         -- alpha = 0.1

    local self = {
        alpha = getAlpha(factor),
    }
    setmetatable(self, { __index = avg })
    return self
end

function avg:onValue(val)
    self.m = self.m or val
    self.m = self.m + self.alpha*(val - self.m)
    local d = math.pow(self.m - val, 2)
    self.m2 = self.m2 + self.alpha*(d - self.m2)
    --self.deviation = self.deviation + self.alpha*(math.abs(val - self.m) - self.deviation)
    self.average = self.m
    self.deviation = math.pow(self.m2, 0.5)
end

