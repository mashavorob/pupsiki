#!/usr/bin/env luajit
-- vi: ft=lua:fenc=cp1251 
--[[
#
# Обрезка l2-квот до заданного количества уровней
#
# Пример использования:
#
# cat <l2-данные> | ./l2-striper.lua [n] >result
#
# где n - не обязательный параметр задающий желаемое количество уровней l2, по умолчанию 5
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_persist = assert(require("qlib/quik-l2-persist"))

local function FPrint(fmt, ...)
    local args = {...}

    print( string.format(fmt, unpack(args)) )
end

local function EPrint(fmt, ...)
    local args = {...}

    local message = string.format(fmt, unpack(args)) .. "\n"
    io.stderr:write(message)
end


local helpMsg = [[
    remove unnecessary book levels. Usage:

    cat <l2-data> | ./l2-striper.lua [n] >result

    where n is optional parameter to set desirable number of book levels, default value is %d
]]

local maxLevel = 5

if #arg == 2 then
    local param = arg[2]
    if param == '-h' or param == '--help' then
        FPrint(helpMsg, maxLevel)
        return 0
    end
    maxLevel = tonumber(arg[2])
    if not maxLevel or maxLevel < 1 then
        EPrint(
            "Incorrect number of book levels specified. " ..
            "Expected number grater or equal 1, got '%s'"
            , param
            )
        return -1
    end
elseif #arg > 2 then
    EPrint( "Unexpected parameter(s) specified, please use -h parameter to see help" )
    return -1
end

local function quotesToStr(qq)
    local s = ""
    for i,q in ipairs(qq or {}) do
        s = s .. string.format("[%d]={%f@%f}", i, q.quantity, q.price)
    end
    return s
end

local function getHash(ev)
    return string.format("bid={%s}, offer={%s}", quotesToStr(ev.l2.bid), quotesToStr(ev.l2.offer))
end

local function getKey(ev)
    return string.format("%s:%s", ev.class, ev.asset)
end

for line in io.stdin:lines() do

    local hashes = {}

    local success, ev = pcall(q_persist.parseLine, line)
    if success then
        if ev.event == "onQuote" then
            local bid = ev.l2.bid or {}
            local offer = ev.l2.offer or {}
            while #bid > maxLevel do
                table.remove(bid, 1)
            end
            while #offer > maxLevel do
                table.remove(offer, #offer)
            end
            ev.l2.bid = ev.l2.bid and bid
            ev.l2.bid_count = #bid
            ev.l2.offer = ev.l2.offer and offer
            ev.l2.offer_count = #offer

            local key = getKey(ev)
            local hash = getHash(ev)

            if not hashes[key] or hashes[key] ~= hash then
                hashes[key] = hash
                line = q_persist.toString(ev)
                print( line )
            end
        else
            print( line )
        end
    else
        EPrint("Error parsing line %d, erroneous line is:\n%s\n", ln, line)
    end
end
