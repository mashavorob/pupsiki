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

New parameters found:   Yes
Total income before optimization:   31012
Total income after optimization:    74128
Best parameters are:
    'avgFactor1' = 0.39088183765051
    'avgFactor2' = 0.15874429247025

]]

avd = {}

local function maximizeParam(func, max, index)
    local info = func.params[index]

    local direction = 1
    local step = info.step
    local precision = info.precision
    if info.relative then
        step = step*(info.max - info.min)
        precision = precision*step
    end

    local function getParam(self)
        return self["get_" .. info.name](self)
    end
    local function setParam(self, p)
        self["set_" .. info.name](self, p)
    end

    print("Optimizing '" .. info.name .. "':\n")

    while step > precision do
        local val = max
        for i = 1,2 do
            -- make clone
            local clone = func:clone()
            local param = getParam(func) + step*direction
            if param < info.min then
                param = info.min
            elseif param > info.max then
                param = info.max
            end
            setParam(clone, param)
            print(info.name .. " = " .. getParam(clone))
            if param ~= getParam(func) then
                val = clone:func()
                if val > max then
                    print("result: " .. val .. " (improved)")
                    setParam(func, getParam(clone))
                    break
                end
            else
                print("Value calculated on one of the previous steps is used") 
            end
            print("result: " .. val .. " (try other direction if possible)")
            direction = direction*(-1)
        end
        
        if val > max then
            print("following the same direction")
            max = val
        else
            print("try to reduce step")
            step = step/2
        end
        print("")
    end
    return max
end

local function makeClone(func)

    if type(func.clone) == "function" then
        for _,info in ipairs(func.params) do
            assert( type(func["get_" .. info.name]) == "function", "get_" .. info.name )
            assert( type(func["set_" .. info.name]) == "function", "set_" .. info.name )
        end
        return func:clone()
    end

    local clone = { }

    setmetatable(clone, { __index = func })

    for _, info in ipairs(func.params) do
        clone["get_" .. info.name] = function(self)
            return self[info.name]
        end
        clone["set_" .. info.name] = function(self, p)
            self[info.name] = p
        end
    end
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
    local max = func:func()
    local newMax = max
    local clone = makeClone(func)
    local found = false

    while true do

        for i,_ in ipairs(func.params) do
            newMax = maximizeParam(clone, newMax, i)
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
    return clone
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

        local res = avd.maximize(func)
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

        local res = avd.maximize(func)
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

        local res = avd.maximize(func)
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

        local res = avd.maximize(func)
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

        local res = avd.maximize(func)
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

        local res = avd.maximize(func)
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

        local res = avd.maximize(func)
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

        local res = avd.maximize(func)
        assert(nil ~= res)
        assert(math.abs(res.x) < func.params[1].precision)   
        assert(math.abs(res.y) < func.params[2].precision)   
    end
    function testSuite.test_2d_func_fail()
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
        function func:clone()
            local c = { }
            setmetatable(c, { __index = self })
            return c
        end

        local res = pcall(avd.maximize, func)
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

        local res = avd.maximize(func)
        assert(nil ~= res)
        assert(math.abs(res:get_x()) < func.params[1].precision)   
        assert(math.abs(res:get_y()) < func.params[2].precision)   
    end
    return testSuite
end
