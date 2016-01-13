--[[
#
# Расстановка меток на графиках терминала Quik
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

q_label = { }

function q_label.createLabel(tag, y, t, cr, img)
    local label = {
    }
    function label:init(tag, y, t, cr, img)
        local descr = {
            IMAGE_PATH = img,
            YVALUE = y,
            DATE = os.date("%Y%m%d", t),
            TIME = os.date("%H%M%S", t),
            R = cr.r,
            G = cr.g,
            B = cr.b,
            HINT = string.format("%.0f", y)
        }
        self.tag = tag
        self.id = AddLabel(tag, descr)
        self.cr = cr
        self.img = img
        return self.id
    end
    function label:remove()
        DelLabel(self.tag, self.id)
    end
    function label:update(y, t, cr, img)
        y = y or self.y
        t = t or self.t
        cr = cr or self.cr
        img = img or self.img
        local descr = {
            IMAGE_PATH = img,
            YVALUE = y,
            DATE = os.date("%Y%m%d", t),
            TIME = os.date("%H%M%S", t),
            R = cr.r,
            G = cr.g,
            B = cr.b,
            HINT = string.format("%.0f", y)
        }
        SetLabelParams(self.tag, self.id, descr)
    end
    if label:init(tag, y, t, cr, img) then
        return label
    end
end

function q_label.createFactory(tag, cr, img)
    local factory = {
        tag = tag,
        cr = cr,
        img = img,
    }
    function factory:add(y, t, cr, img)
        assert(y)
        assert(t)
        cr = cr or self.cr
        img = img or self.img
        return q_label.createLabel(self.tag, y, t, cr, img)
    end
    DelAllLabels(tag)
    return factory
end


