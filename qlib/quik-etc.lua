--[[
#
# Операции над конфигурационными файлами
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc

New parameters found:   Yes
Total income before optimization:   31012
Total income after optimization:    74128
Best parameters are:
    'avgFactor1' = 0.39088183765051
    'avgFactor2' = 0.15874429247025

]]

config = {}

function config.create(etc)
    local conf = { etc = etc }
    setmetatable(etc, { __index = conf } )

    function conf:merge(other)
        for k,_ in pairs(self.etc) do
            local v = other[k]
            if v then
                self.etc[k] = v
            end
        end
    end

    function conf:getTitle()
        assert(type(self.etc.title) == "string")
        assert(type(self.etc.asset) == "string")
        assert(type(self.etc.class) == "string")

        return self.etc.title .. "-[" .. self.etc.class .. "-" .. self.etc.asset .. "]"
    end

    function conf:getFileName()
        assert(type(etc.etc.confFolder) == "string")
        return self.etc.confFolder .. "/" .. self:getTitle() .. ".conf"
    end

    function conf:load()
        local fname = self:getFileName()
        local f_conf = io.open(fname, "r")
        if not f_conf then
            return
        end

        local f_etc = false
        local config = f_conf:read("*all")
        f_conf:close()

        local function decode()
            local code = "f_etc = { " .. config .. " }"
            local f = loadstring(code)
            f()
        end

        if not pcall( decode ) then
            f_etc = false
        end

        if f_etc then
            self:merge(f_etc)
            return true
        end
    end

    function conf:save()
        local code = ""

        for k,v in pairs(self.etc) do
            if type(k) == "string" then 
                if type(v) == "string" then
                    code = code .. k .. " = '" .. v .. "',\n"
                elseif type(v) == "number" then
                    code = code .. k .. ' = ' .. v .. ",\n"
                end
            end
        end

        local fname = self:getFileName()
        local f_conf = io.open(fname, "w+")
        if not f_conf then
            return
        end
        f_conf:write(code)
        f_conf:close()
        return true
    end
    return etc
end

function config.getTestSuite()
    local testSuite = {}
    function testSuite.create()
        local template = { param = 1 }
        local etc = config.create(template)
        assert(etc.param == 1)
        assert(etc.merge ~= nil)
        assert(etc.load ~= nil)
        assert(etc.save ~= nil)
    end
    function testSuite.merge()
        local template = { a = 1, b = 2 }
        local etc = config.create(template)
        assert(etc.a == 1)
        assert(etc.b == 2)
        etc:merge({ a = "b" })
        assert(etc.a == "b")
        assert(etc.b == 2)
    end
    function testSuite.title()
        local etc = config.create({asset="asset", class="class", title="title"})
        assert(etc:getTitle() == "title-[class-asset]")
    end
    function testSuite.getFileName()
        local etc = config.create({asset="asset", class="class", title="title", confFolder="conf"}) 
        assert(etc:getFileName() == "conf/title-[class-asset].conf")
    end
    function testSuite.load()
        os.execute("mkdir conf")
        local etc = config.create({asset="asset", class="class", title="title", confFolder="conf"}) 
        local fname = etc:getFileName()
        local f_out = io.open(fname, "w+")
        f_out:write(f_out, "a=1, b='b'")
        f_out:close()

        assert(etc.a == nil)
        assert(etc.b == nil)
        assert(etc:load())
        assert(etc.a == 1)
        assert(etc.b == "b")
        assert(etc.asset == "asset")

        local f_out = io.open(fname, "w+")
        f_out:write(f_out, "a=1 b='b'") -- syntax error: ',' is missing
        f_out:close()

        assert(not etc:load())
    end
    function testSuite.load()
        os.execute("mkdir conf")

        local etc = config.create({asset="asset", class="class", title="title", confFolder="conf", a=1, b="b"}) 
        assert(etc:save())

        etc = config.create({asset="asset", class="class", title="title", confFolder="conf"}) 
        assert(etc.a == nil)
        assert(etc.b == nil)

        assert(etc:load())
        assert(etc.a == 1)
        assert(etc.b == "b")
    end
    return testSuite
end
