--[[
#
# Обертка для таблицы Quik
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]


--[[
  The function creates Quik table and inserts there requested columns
  The function also creates and shows window that corresponds to the table

  Parameters:
    posfile - file for saving window parameters
    title - window title
    cols - column that specifes columns to insert. The format is:
        {
            {name="asset", title="Бумага", ctype=QTABLE_STRING_TYPE, width=8, format="%s" },
            ...
        }
    where:
        name   - key to reverence the column
        title  - column title for user
        ctype  - type of the value, possible values are QTABLE_STRING_TYPE and QTABLE_DOUBLE_TYPE
        witdh  - initial width in units (1 unit ~ 8 DLU ~ 1 average character)
        format - format specification for string.format() 

    
  Return value:
    The function returns table with following fields:
    {
        isClosed=function(),                      - returns true if user closed the window
        setRow=function(index, row),              - updates specified row with new values
        addRow=function(row),                     - inserts a new row at the end of the table
        getNumRows=function(),                    - returns nuber of rows in the table
        onIdle=function(),                        - call this function as often as possible
        setOnStartStopCallback=function(handler), - set handler for start/stop event (pressing 'S' key)
        setOnHaltCallback=function(handler),      - set handler for halt event (pressing 'H' key)
    }

  where:
      index - 1-based index of row

      row   - table with key-values pair where keys should match with column names,
              unmatched pairs are ignored

      handler - function with no parameters and no return value

    

]]

local qtable = {}

local q_fname = require("qlib/quik-fname")

function qtable.create(posfile, title, cols)

    posfile = q_fname.normalize(posfile)

    local function Dummy() end
    local self = { 
        id=assert(AllocTable()),
        caption=title,
        columns=cols,
        colByName={},
        cfgFile=posfile,
        posCache="",
        onStartStop=Dummy,
        onHalt=Dummy
    }

    for i, col in ipairs(self.columns) do
        self.colByName[col.name] = i
    end

    for i=1, table.getn(self.columns) do
        local col = self.columns[i]
        local res = AddColumn(self.id, i - 1, col.title, true, col.ctype, col.width)
        if res == 0 then error("AddColumn ('" .. (i - 1) .. "," .. col.name .. "') returned bad status") end
    end

    local res = InsertRow(self.id, -1)
    assert(res > -1)
      
    local res = CreateWindow(self.id)
    if res == 0 then error("CreateWindow returned bad status") end
    assert(SetWindowCaption(self.id, self.caption), "SetWindowCaption() returned bad status")
    
    local f_cfg = io.open(self.cfgFile, 'r')
    if f_cfg then
        local ln = f_cfg:read("*line")
        if ln then
            local fn = loadstring("SetWindowPos(" .. self.id .. "," .. ln .. ")")
            pcall(fn)
        end
        f_cfg:close()
    end

    local t = {}

    function t.isClosed()
        return IsWindowClosed(self.id)
    end

    function t.setRow(row, data)
        for colName,val in pairs(data) do
            local colIndex = self.colByName[colName]
            if colIndex then
                local formatedVal = false
                if not pcall( function() formatedVal = string.format(self.columns[colIndex].format, val) end) then
                    formatedVal = val
                end
                SetCell(self.id, row, colIndex - 1, formatedVal)
            end
        end
    end

    function t.addRow(data)
        t.setRow(InsertRow(self.id, -1), data)
    end

    function t.getNumRows()
        return GetTableSize(self.id)
    end

    function t.onIdle()
        if t.isClosed() then
            return
        end

        local top, left, bottom, right = GetWindowRect(self.id)
        local x, y, dx, dy = left, top, right - left, bottom - top
        local ln = x .. "," .. y .. "," .. dx .. "," .. dy 

        if ln ~= self.posCache then
            local f_cfg = io.open(self.cfgFile, "w+")
            if f_cfg then
                f_cfg:write(ln)
                f_cfg:close() 
            end
        end
    end

    function t.onMessage(id, msg, param1, param2)
        if msg == QTABLE_VKEY then
            if param2 == 83 then
                self.onStartStop()      -- S key (start/stop)
            elseif param2 == 72 then 
                self.onHalt()           -- H key (halt)
            end
        end
    end

    function t.setStartStopCallback(fn)
        self.onStartStop = fn
    end

    function t.setHaltCallback(fn)
        self.onHalt = fn
    end

    local res = SetTableNotificationCallback(self.id, t.onMessage)
    assert(res, "SetTableNotificationCallback() returned bad status")

    return t;
end

return qtable
