#!/usr/bin/env luajit
--[[
# vi: ft=lua:fenc=cp1251 
#
# ���� ���� ������ ��� qlib
#
#
# ���� �� ������ ��������� ��� ������ �� ��� ���������
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_jit = require("qlib/quik-jit")
local q_config = require("qlib/quik-etc")
local q_log = require("qlib/quik-logger")
assert(require("qlib/quik-avd"))
assert(require("qlib/quik-book"))
local q_container = assert(require("qlib/quik-jit-l2-data"))

print("")
print("Quik library unit tests (c) 2016")

if q_jit.isJIT() then
    print("LuaJIT detected")
else
    print("Lua interpreter detected")
end
print("")


local unitTests = {
    csvlog = q_log.getTestSuite(),
    config = q_config.getTestSuite(),
    avd = avd.getTestSuite(),
    book = q_book.getTestSuite(),
    q_container = q_container.getTestSuite(), 
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
            test()
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
