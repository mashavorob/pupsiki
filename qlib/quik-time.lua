--[[
#
# Работа с временными отметками
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]


local q_time = {}

local q_timestamp = {}
local q_interval  = {}

function q_time.at(hhmmss) -- "12:53:00" or "12:53"
    local h,m,s = string.match(hhmmss, "(%d%d):(%d%d):(%d%d)")
    if not h then
        h, m = string.match(hhmmss, "(%d%d):(%d%d)")
        s = "00"
    end
    assert(h and m and s)
    local self =
        { hour = tonumber(h)
        , min  = tonumber(m)
        , sec  = tonumber(s)
        }
    assert(self.hour < 24)
    assert(self.hour >= 0)
    assert(self.min < 60)
    assert(self.min >= 0)
    assert(self.sec < 60)
    assert(self.sec >= 0)
    setmetatable(self, {__index = q_timestamp})
    return self
end

function q_time.interval(from, to)
    local self =
        { from = q_time.at(from)
        , to = q_time.at(to)
        }
    setmetatable(self, {__index = q_interval})
    return self
end

function q_timestamp:getTime(today)
    return os.time(
        { hour = self.hour
        , min = self.min
        , sec = self.sec
        , year = today.year
        , month = today.month
        , day = today.day
        })
end

function q_interval:isInside(now)
    now = now or os.time()
    local today = os.date("*t", now)
    return now >= self.from:getTime(today) and now <= self.to:getTime(today)
end

function q_interval:getTimeLeft(now)
    now = now or os.time()
    local today = os.date("*t", now)
    return self.to:getTime(today) - now
end

return q_time
