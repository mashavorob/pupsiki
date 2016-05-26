--[[
#
# Коллекция стаканов quik
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

q_books = {}

function q_books.create()
    local self = { classes = {} }
    setmetatable(self, { __index = q_books })
    return self
end

function q_books:getBook(class, asset, params)
    local booksGroup = self.classes[class]
    if not booksGroup and params then
        booksGroup = { }
        self.classes[class] = booksGroup
    end

    local book = nil
    if booksGroup then
        book = booksGroup[asset]
        if book == nil and params then
            local paramsGroup = params[class] or { }
            local paramList = paramsGroup[asset]
            if paramList then
                book = q_book.create(class, asset, paramList.SEC_PRICE_STEP.param_value, paramList.STEPPRICE.param_value)
                booksGroup[asset] = book
            end
        end
    end
    return book
end


