--[[
#
# ������ � ������ csv ����� ��� ������� Quik
#
# vi: ft=lua:fenc=cp1251 
#
# ���� �� ������ ��������� ��� ������ �� ��� ���������
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

csvlog = {}

--[[
    Creates CSV logger
    Parameters:
        fname - fname template. Substitutions are compatible with os.date:
                %m - month [01-12]
                %d - day of month [01-31]
                %H - hour [00-23]
                %M - minute [00-59]
                %Y - year [1970-2099]
                %y - 2 digit year [00-99]
    Return value:
        {
            write(record) - writes a new record to the log
                            record is a table, which keys must muatch with column names
            close()       - closes the log file
        }
]]
function csvlog.createWriter(fname, columns)
    fname = os.date(fname)
    local self = { 
        columns = columns,
        file = assert(io.open(fname, "w+"))
    }
    
    for i,n in ipairs(self.column) do
        local sep = (i == 1) and "" or ","
        self.file:write(sep, n)
    end

    local t = {
        write = function(record)
            for i,n in ipairs(self.column) do
                local sep = (i == 1) and "" or ","
                local val = record[n] or ""
                self.file:write(sep, val)
            end
            self.file:write("\n")
            self.file:flush()
        end,
        close = function()
            self.file:close()
        end,
    }
    return t;
end


function csvlog.createReader(fname)
    local self = {
        columns = {}, -- fill later
        file = assert(io.open(fname, "r"))
    }

    local function trim(s)
        return string.match(s, '^%s*(.*%S)') or ''
    end

    local function split(s, subs)
        subs = susbs or ","
        local res = { }
        local pos, beg, end_ = 1, string.find(s, subs)
        while beg do
          table.insert(res, trim(string.sub(s, pos, beg - 1)))
          pos = end_ + 1
          beg, end_ = string.find(s, subs, pos)
        end
        if pos == 1 and string.len(s) > 0 then
            table.insert(res, trim(s))
        else -- if pos > 1 then
            table.insert(res, trim(string.sub(s, pos)))
        end
        return res
    end

    local function build(arr, names)
        local res = { }
        for i, name in ipairs(names) do
            res[name] = arr[i]
        end
        return res
    end

    -- read headers
    local ln = assert(self.file:read("*line"), "CSV headers are expected in the first line of the file " .. fname)


    self.columns = split(ln)
    assert(#self.columns > 0, "At least one column must be present")

    local reader = { }

    function reader.loadLine()
        local ln = self.file:read("*line")
        if ln then
            return build(split(ln), self.columns)
        end
    end
    function reader.allLines()
        return reader.loadLine
    end
    function reader.close()
        self.file:close()
    end
    return reader
end
