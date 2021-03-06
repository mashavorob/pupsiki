--[[
#
# ���������� �������
#
# vi: ft=lua:fenc=cp1251 
#
# ���� �� ������ ��������� ��� ������ �� ��� ���������
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_avg = { }

local avg = {}

local avgEx = {}

local function getAlpha(factor)
    return 2/(1 + factor)
end

function q_avg.create(factor)
    factor = factor or 19         -- alpha = 0.1

    local self =
        { average = false
        , dispersion = 0
        , deviation = 0
        , alpha = getAlpha(factor),
        }
    setmetatable(self, { __index = avg })
    return self
end

function avg:onValue(val)
    self.average = self.average or val
    self.average = self.average + self.alpha*(val - self.average)
    local d = math.pow(self.average - val, 2)
    self.dispersion = self.dispersion + self.alpha*(d - self.dispersion)
end

function q_avg.createEx(factor, n)
    factor = factor or 19         -- alpha = 0.1
    n = n or 2                    -- include the second deviation

    local self =
        { alpha = getAlpha(factor)
        , average = {}
        , dispersion = {}
        , deviation = 0
        }
    for _ = 1,n do
        table.insert(self.average, 0)
        table.insert(self.dispersion, 0)
    end
    setmetatable(self, { __index = avgEx })
    return self
end

function avgEx:onValue(val)
    if not self.average[0] then
        self.average[0] = val
        self.dispersion[0] = 0
    end
    
    self.average[0] = self.average[0] + self.alpha*(val - self.average[0])

    local v = { }
    v[0] = val;

    for i = 1,#self.average do
        v[i]  = (v[i - 1] - self.average[i - 1])*self.alpha
        self.average[i] = self.average[i] + self.alpha*(v[i] - self.average[i])
    end

    for i = 0,#self.dispersion do
        local d = math.pow(self:getAverage(i) - v[i], 2)
        self.dispersion[i] = self.dispersion[i] + self.alpha*(d - self.dispersion[i])
    end
end

function avgEx:getAverage(n)
    n = n or 0
    if n > #self.average then
        return 0
    end
    return self.average[n] + self:getAverage(n + 1)/self.alpha
end

function avgEx:getTrend()
    return self:getAverage(1)
end

function avgEx:getTrend2()
    return self:getAverage(2)
end

function avgEx:getDeviation(n)
    n = n or 0
    if n > #self.average then
        return 0
    end
    if not self.dispersion[n] then
        return 0
    end
    return math.pow(self.dispersion[n], 0.5)
end

function avgEx:getTrendDeviation()
    return self:getDeviation(1)
end

return q_avg
