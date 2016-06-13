--[[
#
# Alternating-variable descent (Метод покоординатного спуска)
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

avd = {}

local function hashParams(func)
    local hash = ""
    for _,info in ipairs(func.params) do
        hash = hash .. info.name .. ":" .. tostring( func["get_" .. info.name](func) ) .. " "
    end
    return hash
end

local function roundStep(info, step)
    if not step then
        step = info.step
        if info.relative then
            step = step*(info.max - info.min)
        end
    end
    local prec = info.precision
    if info.relative then
        prec = prec*(info.max - info.min)
    end
    assert(prec > 0)
    return math.floor(step/prec)*prec
end

local function maximizeParam(cache, func, max, index)
    local info = func.params[index]

    local direction = 1
    local step = roundStep(info)
    assert(step > 0)

    local function getParam(self)
        return self["get_" .. info.name](self)
    end
    local function setParam(self, p)
        self["set_" .. info.name](self, p)
    end

    if info.get_max == nil then
        info.get_max = function() return info.max end
    end
    if info.get_min == nil then
        info.get_min = function() return info.min end
    end

    print("Optimizing parameter:", info.name)
    print(" Initial param value:", getParam(func))
    print("      Function value:", max)
    print("                Step:", step)
    print("")

    cache[hashParams(func)] = max

    while step > 0 do
        local val = max
        for i = 1,2 do
            -- make clone
            local clone = func:clone()
            local param = getParam(func) + step*direction
            local lower = info.get_min(func)
            local upper = info.get_max(func)
            if param < lower then
                param = lower
            elseif param > upper then
                param = upper
            end
            setParam(clone, param)
            local hash = hashParams(clone)
            print(info.name .. " = " .. getParam(clone))
            if param ~= getParam(func) then
                local cachedVal = cache[hash]
                if cachedVal ~= nil then
                    val = cachedVal
                    print("cached value found")
                else
                    val = clone:func()
                    cache[hash] = val
                end
                if val > max then
                    print(string.format("result: %f, best was %f|%s=%f (improved)", val, max, info.name, getParam(func)))
                    setParam(func, getParam(clone))
                    break
                end
            else
                print("Value calculated on one of the previous steps is used") 
            end
            print(string.format("result: %f, best is: %f|%s=%f (try other direction if possible)", val, max, info.name, getParam(func)))
            direction = direction*(-1)
        end
        
        if val > max then
            print("following the same direction")
            max = val
        else
            step = roundStep(info, step/2)
            print("Step has been reduced:", step)
        end
        print("")
    end
    return max
end

local function makeClone(func)
    for _, info in ipairs(func.params) do
        local get_param = "get_" .. info.name
        local set_param = "set_" .. info.name
        if func[get_param] == nil then
            func[get_param] = function(self)
                return self[info.name]
            end
        end
        if func[set_param] == nil then
            func[set_param] = function(self, val)
                self[info.name] = val
            end
        end
    end

    for _,info in ipairs(func.params) do
        assert( type(func["get_" .. info.name]) == "function"
              , string.format("type(get_%s)=%s", info.name, type(func["get_" .. info.name])) )
        assert( type(func["set_" .. info.name]) == "function"
              , string.format("type(set_%s)=%s", info.name, type(func["set_" .. info.name])) )
    end
 
    if type(func.clone) == "function" then
        return func:clone()
    end

    local clone = { }

    setmetatable(clone, { __index = func })

    function clone:clone()
        local c = {}
        setmetatable(c, { __index = self })
        return c
    end

    return clone
end

local function printParams(func)
    local val = func:func()
    print("Parameters:")
    for _, info in ipairs(func.params) do
        print(string.format("%15s: ", info.name) .. func["get_" .. info.name](func))
    end
    print(string.format("%15s: ", "result") .. val)
end

local function maximizeAllParams(func)
    print("calculate central value")
    local before = func:func()
    print("central value is:", before)
    local max, newMax = before, before
    local clone = makeClone(func)
    local found = false
    local cache = {}

    while true do

        for i,_ in ipairs(func.params) do
            newMax = maximizeParam(cache, clone, newMax, i)
        end
        if newMax <= max then
            break
        end
        found = true
        max = newMax
    end

    if found then
        print("Better parameters found.")
        print("original parameters:")
        printParams(func)
        print("")
        print("Optimized parameters:")
        printParams(clone)
    else
        print("Better parameters not found")
        return
    end
    return before, max, clone
end

--[[
    The func must look like this:

        local func = {
            x = 0,
            params = {
                { name="x", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
                { name="y", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
            },
        }
        function func:func()
            local res = 1 - self.x^2 - self.y^2
            print(string.format("f(%.3f) = %.3f", self.x, res))
        end

    The function could have any number of parameters from zero up to infinity.
 
]]

function avd.maximize(func)
    return maximizeAllParams(makeClone(func))
end

function avd.getTestSuite()
    local testSuite = {}
    function testSuite.test_1d_optimal()
        local func = {
            x = 0,
            params = {
                { name="x", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
            },
        }
        function func:func()
            local res = 1 - self.x^2
            print(string.format("f(%.3f) = %.3f", self.x, res))
            return res
        end

        local before, after, res = avd.maximize(func)
        assert(nil == res)
        assert(0 == func.x)
    end
    function testSuite.test_1d_1()
        local func = {
            x = 1,
            params = {
                { name="x", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
            },
        }
        function func:func()
            local res = 1 - self.x^2
            print(string.format("f(%.3f) = %.3f", self.x, res))
            return res
        end

        local before, after, res = avd.maximize(func)
        assert(nil ~= res)
        assert(math.abs(res.x) <= func.params[1].precision)
    end
    function testSuite.test_1d_m1()
        local func = {
            x = -1,
            params = {
                { name="x", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
            },
        }
        function func:func()
            local res = 1 - self.x^2
            print(string.format("f(%.3f) = %.3f", self.x, res))
            return res
        end

        local before, after, res = avd.maximize(func)
        assert(nil ~= res)
        assert(math.abs(res.x) <= func.params[1].precision)
    end
    function testSuite.test_1d_right_optimal()
        local func = {
            x = 1,
            params = {
                { name="x", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
            },
        }
        function func:func()
            local res = 1 - (self.x - 2)^2
            print(string.format("f(%.3f) = %.3f", self.x, res))
            return res
        end

        local before, after, res = avd.maximize(func)
        assert(nil == res)
    end
    function testSuite.test_1d_right()
        local func = {
            x = 0,
            params = {
                { name="x", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
            },
        }
        function func:func()
            local res = 1 - (self.x - 2)^2
            print(string.format("f(%.3f) = %.3f", self.x, res))
            return res
        end

        local before, after, res = avd.maximize(func)
        assert(nil ~= res)
        assert(math.abs(res.x - 1) < func.params[1].precision)
    end
    function testSuite.test_1d_left_optimal()
        local func = {
            x = -1,
            params = {
                { name="x", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
            },
        }
        function func:func()
            local res = 1 - (self.x + 2)^2
            print(string.format("f(%.3f) = %.3f", self.x, res))
            return res
        end

        local before, after, res = avd.maximize(func)
        assert(nil == res)
    end
    function testSuite.test_1d_left()
        local func = {
            x = 0,
            params = {
                { name="x", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
            },
        }
        function func:func()
            local res = 1 - (self.x + 2)^2
            print(string.format("f(%.3f) = %.3f", self.x, res))
            return res
        end

        local before, after, res = avd.maximize(func)
        assert(nil ~= res)
        assert(math.abs(res.x + 1) < func.params[1].precision)
    end
    function testSuite.test_2d()
        local func = {
            x = 0.5,
            y = -0.5,
            params = {
                { name="x", min = -1, max = 1, step = 0.1, relative = true, precision=1e-2, },
                { name="y", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
            },
        }
        function func:func()
            local res = 1 - self.x^2 - self.y^2
            print(string.format("f(%.3f, %.3f) = %.3f", self.x, self.y, res))
            return res
        end

        local before, after, res = avd.maximize(func)
        assert(nil ~= res)
        assert(math.abs(res.x) < func.params[1].precision)   
        assert(math.abs(res.y) < func.params[2].precision)   
    end
    function testSuite.test_2d_func_fail()
        local func = {
            x = 0,
            y = 0,
            params = {
                { name="x", min = -1, max = 1, step = 0.1, relative = true, precision=1e-2, },
                { name="y", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
            },
        }
        function func:func()
            local res = 1 - self.x^2 - self.y^2
            print(string.format("f(%.3f, %.3f) = %.3f", self.x, self.y, res))
            return res
        end
        function func:clone()
            local c = { }
            setmetatable(c, { __index = self })
            return c
        end

        local before, after, res = avd.maximize(func)
        assert(not res)
    end
    function testSuite.test_2d_func()
        local func = {
            x_ = 0.5,
            y_ = -0.5,
            params = {
                { name="x", min = -1, max = 1, step = 0.1, relative = true, precision=1e-2, },
                { name="y", min = -1, max = 1, step = 0.1, relative = true, precision=1e-3, },
            },
        }
        function func:func()
            local res = 1 - self.x_^2 - self.y_^2
            print(string.format("f(%.3f, %.3f) = %.3f", self.x_, self.y_, res))
            return res
        end
        function func:clone()
            local c = { }
            setmetatable(c, { __index = self })
            return c
        end
        function func:get_x()
            return self.x_
        end
        function func:set_x(x)
            self.x_ = x
        end
        function func:get_y()
            return self.y_
        end
        function func:set_y(y)
            self.y_ = y
        end

        local before, after, res = avd.maximize(func)
        assert(nil ~= res)
        assert(math.abs(res:get_x()) < func.params[1].precision)   
        assert(math.abs(res:get_y()) < func.params[2].precision)   
    end
    return testSuite
end
