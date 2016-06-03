#!/usr/bin/env lua
--[[
# vi: ft=lua:fenc=cp1251 
#
# Юнит тест раннер для qlib
#
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

assert(require("qlib/quik-jit"))
assert(require("qlib/quik-logger"))
assert(require("qlib/quik-etc"))
assert(require("qlib/quik-avd"))
assert(require("qlib/quik-book"))

print("")
print("Quik library unit tests (c) 2016")

if q_jit.isJIT() then
    print("LuaJIT detected")
else
    print("Lua interpreter detected")
end
print("")


local unitTests = {
    csvlog = csvlog.getTestSuite(),
    config = config.getTestSuite(),
    avd = avd.getTestSuite(),
    book = q_book.getTestSuite(),
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
else
    print("\nAll tests passed")
end
