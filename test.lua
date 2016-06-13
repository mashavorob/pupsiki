#!/usr/bin/env luajit


local function str(t)
    local s = "{ "
    for i,v in ipairs(t) do
        s = s .. "[" .. tostring(i) .. "]=" .. tostring(v) .. ", "
    end
    return s .. "}"
end

local t1 = { 1,2,3,4,5 }

local t2 = {}

table.insert(t2, 1, table.unpack(t1))

print("t2: ", str(t2))
