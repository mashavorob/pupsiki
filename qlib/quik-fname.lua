--[[
#
# Имена файлов Quik
#
# vi: ft=lua:fenc=cp1251 
#
# Если Вы можете прочитать эту строку то все нормально
# If you cannot read the line above you editor use wrong encoding
# The correct encoding is CP1251. In VIm you may use command:
#   :e ++enc=cp1251
# or enable modeline in your .vimrc
]]

q_fname = { root = false }

function q_fname.normalize(fname)
    local unixRoot = string.find(fname, '/', 1, true)
    if unixRoot then
        unixRoot = unixRoot == 1
    end
    local windowsRoot = string.find(fname, ':', 1, true)
    if windowsRoot then
        windowsRoot = windowsRoot == 2
    end
    if q_fname.root and not unixRoot and not windowsRoot  then
        fname = q_fname.root .. fname
    end
    return fname
end

