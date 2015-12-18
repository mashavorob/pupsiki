--[[
#
# Запись и чтение csv логов для роботов Quik
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
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
            close()       - closes the log file_
        }
]]

require("qlib/quik-fname")

function csvlog.create(fname, columns)
    fname = q_fname.normalize(os.date(fname))

    local unixRoot = string.find(fname, '/', 1, true)
    if unixRoot then
        unixRoot = unixRoot == 1
    end
    local windowsRoot = string.find(fname, ':', 1, true)
    if windowsRoot then
        windowsRoot = windowsRoot == 2
    end
    if scriptFolder and not unixRoot and not windowsRoot  then
        fname = scriptFolder .. fname
    end


    local self = { 
        columns = columns,
        fname = fname,
        file_ = assert(io.open(fname, "a+"))
    }
    
    for i,n in ipairs(self.columns) do        
        local sep = (i == 1) and "" or ","
        self.file_:write(sep ..  n)
    end
    self.file_:write("\n")
    self.file_:flush()

    local t = {}
    function t.write(record)
        for i,n in ipairs(self.columns) do
            local sep = (i == 1) and "" or ","
            local val = record[n] or ""
            self.file_:write(sep, val)
        end
        self.file_:write("\n")
        self.file_:flush()
    end
    function t.close()
        self.file_:close()
    end
    function t.getFileName()
        return self.fname
    end
    return t;
end


function csvlog.createReader(fname)
    local self = {
        columns = {}, -- fill later
        file_ = assert(io.open(fname, "r"))
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
        elseif pos > 1 then
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

    local function loadLineFromFile()
        local ln = self.file_:read("*line")
        if ln then
            return trim(ln)
        end
    end

    -- read headers
    local ln = assert(loadLineFromFile(), "CSV headers are expected in the first line of the file_ " .. fname)

    self.columns = split(ln)
    self.header = ln
  
    assert(#self.columns > 0, "At least one column must be present")

    local t = { }
    function t.loadLine()
        local ln = loadLineFromFile()
        while (ln and (ln == self.header)) do
            ln = loadLineFromFile()
        end
        if ln then
            return build(split(ln), self.columns)
        end
    end
    function t.allLines()
        return t.loadLine
    end
    function t.close()
        self.file_:close()
    end
    return t
end

function csvlog.getTestSuite()
    local testSuite = { }
    function testSuite.emptyFile()
        local fname = os.tmpname()

        -- create empty file
        local f = assert(io.open(fname, "w"))
        f:close()

        if pcall(csvlog.createReader, fname) then
            assert()
        end
    end
    function testSuite.noHeader()
        local fname = os.tmpname()

        -- create empty file
        local f = assert(io.open(fname, "w"))
        f:write("\n1,2,3\n")
        f:close()

        if pcall(csvlog.createReader, fname) then
            assert()
        end
        return true
    end
    function testSuite.oneHeader()
        local fname = os.tmpname()

        -- create empty file
        local f = assert(io.open(fname, "w"))
        f:write("a,b,c\n")
        f:close()

        assert(csvlog.createReader(fname))
    end
    function testSuite.oneHeaderOneCol()
        local fname = os.tmpname()

        -- create empty file
        local f = assert(io.open(fname, "w"))
        f:write("a")
        f:close()

        assert(csvlog.createReader(fname))
    end
    function testSuite.oneColOneLine()
        local fname = os.tmpname()

        -- create empty file
        local f = assert(io.open(fname, "w"))
        f:write("a\n1")
        f:close()

        local parser = assert(csvlog.createReader(fname))

        local row = assert(parser.loadLine())
        assert(row.a == "1")
        assert( not parser.loadLine())
    end
    function testSuite.oneLine()
        local fname = os.tmpname()

        -- create empty file
        local f = assert(io.open(fname, "w"))
        f:write("a,b\n1,2")
        f:close()

        local parser = assert(csvlog.createReader(fname))

        local row = assert(parser.loadLine())
        assert(row.a == "1")
        assert(row.b == "2")
        assert( not parser.loadLine())
    end
    function testSuite.iterateThroughLines()
        local fname = os.tmpname()

        -- create empty file
        local f = assert(io.open(fname, "w"))
        f:write("a,b\n1,2\n2,3\n3,4\n")
        f:close()

        local parser = assert(csvlog.createReader(fname))
        local count = 0

        for row in parser.allLines() do
            count = count + 1
            assert(tonumber(row.a) == count)
            assert(tonumber(row.b) == count + 1)
        end
        assert(count == 3)
    end
    function testSuite.duplicatedHeader()
        local fname = os.tmpname()

        -- create empty file
        local f = assert(io.open(fname, "w"))
        f:write("a,b\n1,2\n2,3\na,b\n3,4\n")
        f:close()

        local parser = assert(csvlog.createReader(fname))
        local count = 0

        for row in parser.allLines() do
            count = count + 1
            assert(tonumber(row.a) == count)
            assert(tonumber(row.b) == count + 1)
        end
        assert(count == 3)
    end
    function testSuite.writeRead()
        local fname = os.tmpname()
        if os.rename(fname, fname) then
            os.remove(fname)
        end

        local logger = assert(csvlog.create(fname, { 'a', 'b' }))

        logger.write( {a=1, b=2} )
        logger.write( {a=2, b=3} )
        logger.write( {a=3, b=4} )
        logger.write( {a=4, b=5} )
        logger.close()

        local parser = assert(csvlog.createReader(fname))
        local count = 0

        for row in parser.allLines() do
            count = count + 1
            assert(tonumber(row.a) == count)
            assert(tonumber(row.b) == count + 1)
        end
        assert(count == 4)
    end
    function testSuite.writeReadManyLogs()
        local fname = os.tmpname()
        local fname1 = fname .. ".log-1"
        local fname2 = fname .. ".log-2"
        if os.rename(fname1, fname1) then
            os.remove(fname1)
        end
        if os.rename(fname2, fname2) then
            os.remove(fname2)
        end

        local logger1 = assert(csvlog.create(fname1, { 'a', 'b' }))
        local logger2 = assert(csvlog.create(fname2, { 'c', 'd' }))

        logger1.write( {a=1, b=2} )
        logger1.write( {a=2, b=3} )
        logger2.close()
        logger1.write( {a=3, b=4} )
        logger1.write( {a=4, b=5} )
        logger1.close()

        local parser = assert(csvlog.createReader(fname1))
        local count = 0

        for row in parser.allLines() do
            count = count + 1
            assert(tonumber(row.a) == count)
            assert(tonumber(row.b) == count + 1)
        end
        assert(count == 4)
    end
   return testSuite
end
