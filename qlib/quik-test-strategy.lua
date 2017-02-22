--[[
#
# Тестовая стратегия для эмулятора биржи
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local config = require("qlib/quik-etc")


local factory = {}
local masterEtc =  -- master configuration
    -- Главные параметры, задаваемые в ручную
    { asset = "SiU6"                 -- бумага
    , class = "SPBFUT"               -- класс

    -- Параметры вычисляемые автоматически
    , account = "SPBFUT005eC"
    , firmid =  "SPBFUT589000"

    -- Параметры стратегии
    , avgFactorSpot  = 30            -- коэффициент осреднения спот
    , avgFactorTrend = 30            -- коэфициент осреднения тренда
    , enterThreshold = 1e-7          -- порог чувствительности для входа в позицию
    , exitThreshold  = 0             -- порог чувствительности для выхода из позиции

    , params = 
        { { name="avgFactorSpot",  min=1, max=1e32, step=50, precision=1 }
        , { name="avgFactorTrend", min=1, max=1e32, step=50, precision=1 }
        , { name="enterThreshold"
          , min=0
          , max=1e32
          , get_min = function (func) 
                return func.exitThreshold
            end
          , step=1e-5
          , precision=1e-7 
          }
        , { name="exitThreshold"
          , min=0
          , max=1e32
          , get_max = function (func) 
                return func.enterThreshold
            end
          , step=1e-5
          , precision=1e-7 
          }
        } 
    }


local tester = {}

local function serializeItem(val)
    if type(val) == "string" then
        return string.format("%q", val)
    elseif type(val) == "number" then
        return tostring(val)
    elseif type(val) == "table" then
        local ln = "{  "
        for k,v in pairs(val) do
            ln = ln .. string.format("[%s] = %s, ", serializeItem(k, ctx), serializeItem(v, ctx))
        end
        ln = ln .. "}"
        return ln
    elseif type(val) == "nil" then
        return "nil"
    end
    return "'unsupported type: " .. type(val) .. "'"
end

function tester:init()
    local fname = os.getenv("OUT_F")
    if not fname or fname == "" then
        fname = "test-out.txt"
    end
    self.f_out = io.open(fname, "w")
end

function tester:logItem(item)
    self.f_out:write(serializeItem(item) .. "\n")
end

function tester:onAllTrade(trade)
    self:logItem 
        { event="onAllTrade"
        , class = trade.class_code
        , asset = trade.sec_code
        , trade = trade 
        }
end

function tester:onTransReply(reply)
    self:logItem
        { event="onTransReply"
        , reply = reply
        }
    self:logItem 
        { event="onQuote"
        , class = self.last.class
        , asset = self.last.asset
        , l2=getQuoteLevel2(self.last.class, self.last.asset) 
        }
end

function tester:onQuote(class, asset)
    self:logItem 
        { event="onQuote"
        , class = class
        , asset = asset
        , l2=getQuoteLevel2(class, asset) 
        }
end

function tester:onTrade(trade)
    self:logItem 
        { event="onTrade"
        , class = trade.class_code
        , asset = trade.sec_code
        , trade = trade 
        }
    self:logItem 
        { event="onQuote"
        , class = trade.class_code
        , asset = trade.sec_code
        , l2=getQuoteLevel2(trade.class_code, trade.sec_code) 
        }
end

local transid = 20000000

function tester:onTestOrder(order)
    print("tester:onTestOrder():")
    transid = transid + 1
    order.TRANS_ID = tostring(transid)
    for k,v in pairs(order) do
        print(string.format("order.%s = %s", k, tostring(v)))
    end
    self.last = { class=order.CLASSCODE, asset=order.SECCODE }
    self:logItem
        { event="onTestOrder"
        , order = order
        , res = res
        }
    local res = sendTransaction(order)
    print(string.format("sendTransaction() returned: '%s'", tostring(res)))
end

function tester:onStartTrading()
end

function factory.create(etc)
    local self = 
        { title = "averager"
        , etc = config.create(masterEtc)
        }
    setmetatable(self, {__index=tester})
    return self
 end

return factory
