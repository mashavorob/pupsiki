#!/usr/bin/lua 

--[[
#
# Юнит тест раннер для qlib
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

require("quik-logger")
require("quik-etc")
require("quik-avd")

local unitTests = {
    csvlog = csvlog.getTestSuite(),
    config = config.getTestSuite(),
    avd = avd.getTestSuite(),
}

local failed = { }

for uname,units in pairs(unitTests) do
    for tname, test in pairs(units) do
        io.write(string.format("%s.%s - ", uname, tname))
        io.flush()
        local prn = _G.print
        _G.print = function() end
        local res = pcall( test )
        _G.print = prn
        if res then
            io.write("OK\n")
        else
            io.write("Failed\n")
            -- test()
            table.insert(failed, uname .. "." .. tname)
        end
        io.flush()
    end
end

if failed[1] then
    print("\nFailed tests:")
    for i, name in ipairs(failed) do
        print(name)
    end
end
