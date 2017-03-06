#!/usr/bin/env luajit
-- vi: ft=lua:fenc=cp1251 
--[[
#
# ¬осстановление оригинальной последовательности событий после l2-normalizer.lua
#
# ѕример использовани€:
#
# cat <l2-данные> | l2-denormalizer.lua > l2-normalized-data.txt
#
# ≈сли ¬ы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

local q_persist = assert(require("qlib/quik-l2-persist"))

local windowSize = 1000
local window = {}
local ln = 0
local prev_seq_num = nil

local function processLine(window)
    
    ln = ln + 1
    if not lastQuote and ln % 50000 == 0 then
        io.stderr:write(string.format("%d: lines processed\n", ln))
    end

    local index = 1
    local ev = window[index]

    if ev.seq_num and
        prev_seq_num and
        ev.seq_num > prev_seq_num + 1 and
        ev.event == "onAllTrade"
    then
        for i = 2,#window do
            local n_ev = window[i]
            if n_ev.seq_num and n_ev.seq_num < ev.seq_num then
                ev = n_ev
                index = i
                break
            end
        end
    end
    prev_seq_num = ev.seq_num or prev_seq_num
    table.remove(window, index)
    print( q_persist.toString(ev) )
end

for line in io.stdin:lines() do
    local success, ev = pcall(q_persist.parseLine, line)
    if success then
        table.insert(window, ev)
        while #window > windowSize do
            processLine(window)
        end
    else
        io.stderr:write( string.format("Error parsing line %d, erroneous line is:\n%s\n", ln, line) )
    end
end
while #window > 0 do
    processLine(window)
end

