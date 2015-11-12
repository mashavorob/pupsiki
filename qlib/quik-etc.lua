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

local keywords = { folder=true, title=true, params=true, class=true, asset=true }
local types = { string=true, number=true }

function config.create(etc)
    local conf = { }
    setmetatable(etc, { __index = conf } )

    function conf:getParams()
        if type(self.params) == "table" then
            return self.params
        end

        local params = {}

        for k,v in pairs(self) do
            if type(k) == "string" and 
               string.match(k, "[a-zA-Z_][a-zA-Z0-9_]*") and 
               not keywords[k] and
               types[type(v)] 
            then
                table.insert(params, {name=k})
            end
        end
        return params
    end
    function conf:merge(other)
        local params = self:getParams()
        for _,param in ipairs(params) do
            local v = other[param.name]
            if v ~= nil then
                self[param.name] = v
            end
        end
    end
    function conf:getTitle()
        assert(type(self.title) == "string")
        assert(type(self.asset) == "string")
        assert(type(self.class) == "string")
        return self.title .. "-[" .. self.class .. "-" .. self.asset .. "]"
    end
    function conf:getFileName()
        local fname = self:getTitle() .. ".conf"
        if type(self.folder) == "string" then
            fname = self.folder .. "/" .. fname
        end
        return fname 
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
            local code = "return { " .. config .. " }"
            local f = loadstring(code)
            f_etc = f()
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
        local params = self:getParams()

        for _,param in ipairs(params) do
            local v = self[param.name]
            if type(v) == "string" then
                code = code .. param.name .. " = '" .. v .. "',\n"
            elseif type(v) == "number" then
                code = code .. param.name .. ' = ' .. v .. ",\n"
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
        assert(etc.getParams ~= nil)
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
    function testSuite.mergeKeywords()
        local etc = config.create( { title = "title", asset = "asset", class = "class", params = "params", folder = "folder" } )
        assert(#etc == #keywords)
        etc:merge({title = 1, asset = 1, class = 1, params = 1, folder = 1})
        assert(etc.title == "title")
        assert(etc.asset == "asset")
        assert(etc.class == "class")
        assert(etc.params == "params")
        assert(etc.folder == "folder")
    end
    function testSuite.mergeParams()
        local etc = config.create( { a = 1
                                   , p = 2
                                   , params = { 
                                        { name = "p" }, 
                                     } 
                                   } )
        etc:merge( { a = 3, p = 4 } )
        assert(etc.a == 1)
        assert(etc.p == 4)
    end
    function testSuite.mergeArbitraryKeys()
        local function mktable(k, v, t)
            t = t or {}
            t[k] = v
            return t
        end
        local etc = config.create( mktable("123", 2, { a = "b"}) )
        etc:merge( mktable("123", 4, { a = 3 }) )
        assert(etc.a == 3)
        assert(etc["123"] == 2)
    end
    function testSuite.mergeMismatchedKeys()
        local etc = config.create( { a = 1 } )
        etc:merge( { b = 2 } )
        assert(etc.a == 1)
        assert(etc.b == nil)
    end
    function testSuite.title()
        local etc = config.create({asset="asset", class="class", title="title"})
        assert(etc:getTitle() == "title-[class-asset]")
    end
    function testSuite.getFileNameInFolder()
        local etc = config.create({asset="asset", class="class", title="title", folder="etc"}) 
        assert(etc:getFileName() == "etc/title-[class-asset].conf")
    end
    function testSuite.getFileName()
        local etc = config.create({asset="asset", class="class", title="title"}) 
        assert(etc:getFileName() == "title-[class-asset].conf")
    end
    function testSuite.load()
        local etc = config.create({asset="asset", class="class", title="title", folder=os.tmpname() .. "_folder", a=0, b=0})
       
        os.execute("rm -r " .. etc.folder .. " 2>/dev/null")
        os.execute("mkdir " .. etc.folder .. " 2>/dev/null")

        local fname = etc:getFileName()
        local f_out = io.open(fname, "w+")
        f_out:write("a=1, b='b'")
        f_out:close()

        assert(etc.a == 0)
        assert(etc.b == 0)
        assert(etc:load())
        assert(etc.a == 1)
        assert(etc.b == "b")
        assert(etc.asset == "asset")

        local f_out = io.open(fname, "w+")
        f_out:write("a=1 b='b'") -- syntax error: ',' is missing
        f_out:close()

        assert(not etc:load())
    end
    function testSuite.save()

        local etc = config.create({asset="asset", class="class", title="title", folder=os.tmpname() .. "_folder", a=1, b="b"}) 
        
        os.execute("rm -r " .. etc.folder .. " 2>/dev/null")
        os.execute("mkdir " .. etc.folder .. " 2>/dev/null")

        assert(etc:save())

        etc = config.create({asset="asset", class="class", title="title", folder=etc.folder, a = 0, b = 0}) 
        assert(etc.a == 0)
        assert(etc.b == 0)

        assert(etc:load())
        assert(etc.a == 1)
        assert(etc.b == "b")
    end
    return testSuite
end
