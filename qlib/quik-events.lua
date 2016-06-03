--[[
#
# Симулятор очереди событий quik
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

q_events = 
    { strategy = nil 
    , silentMode = false
    , events = {}
    }

function q_events.create()
    local self = { }
    setmetatable(self, { __index = q_events })
    return self
end

function q_events:enqueueEvents(evs)
    for _, ev in ipairs(evs) do
        table.insert(self.events, ev)
    end
end

function q_events:flushEvents(tables)
    local events = self.events
    self.events = {}

    for _,ev in ipairs(events) do
        if ev.name == "OnQuote" then
            self.strategy:onQuote(ev.data.class, ev.data.asset)
        elseif ev.name == "OnAllTrade" then
            table.insert(tables.all_trades, ev.data)
            if #tables.all_trades > 5000 then
                table.remove(tables.all_trades, 1)
            end
            self.strategy:onAllTrade(ev.data)
        elseif ev.name == "OnTransReply" then
            self.strategy:onTransReply(ev.data)
        elseif ev.name == "OnTrade" then
            self.strategy:onTrade(ev.data)
        else
            print("Unknown event type: ", ev.name)
            assert(false)
        end
    end
    self:printState()
end

function q_events:printHeaders()
    if self.silentMode then
        return
    end
    io.stderr:write("# vi: ft=text:fenc=cp1251\n")
    local ln = nil
    for _,col in ipairs(self.strategy.ui_mapping) do
        ln = ((ln == nil and "") or (ln .. ",")) .. col.name
    end
    io.stderr:write(ln .. "\n")
end

function q_events:printEnd()
    if self.silentMode then
        return
    end
    io.stderr:write("end.\n\n")
end

function q_events:printState()
    if self.silentMode then
        return
    end
    self.strategy:onIdle()
    local ln = nil
    for _,col in ipairs(self.strategy.ui_mapping) do
        local val = self.strategy.ui_state[col.name]
        local s = nil
        pcall( function() s = string.format(col.format, val) end )
        ln = ((ln == nil and "") or (ln .. ",")) .. (s or tostring(val))
    end
    io.stderr:write(ln .. "\n")
end


