local bit = {}

-- 左移操作
function bit.lshift(x, n)
    return math.floor(x * (2 ^ n))
end

-- 右移操作
function bit.rshift(x, n)
    return math.floor(x / (2 ^ n))
end

-- 按位与操作
function bit.band(x, y)
    local result = 0
    local bitval = 1
    while x > 0 and y > 0 do
        if x % 2 == 1 and y % 2 == 1 then
            result = result + bitval
        end
        bitval = bitval * 2
        x = math.floor(x / 2)
        y = math.floor(y / 2)
    end
    return result
end

-- 按位或操作
function bit.bor(x, y)
    local result = 0
    local bitval = 1
    while x > 0 or y > 0 do
        if x % 2 == 1 or y % 2 == 1 then
            result = result + bitval
        end
        bitval = bitval * 2
        x = math.floor(x / 2)
        y = math.floor(y / 2)
    end
    return result
end

-- 按位异或操作
function bit.bxor(x, y)
    local result = 0
    local bitval = 1
    while x > 0 or y > 0 do
        if x % 2 ~= y % 2 then
            result = result + bitval
        end
        bitval = bitval * 2
        x = math.floor(x / 2)
        y = math.floor(y / 2)
    end
    return result
end

-- 按位取反操作
function bit.bnot(x)
    return math.floor(-x - 1)
end

-- 获取指定位的值
function bit.getbit(x, n)
    return bit.band(x, bit.lshift(1, n)) ~= 0 and 1 or 0
end

-- 设置指定位的值
function bit.setbit(x, n, value)
    if value == 0 then
        return bit.band(x, bit.bnot(bit.lshift(1, n)))
    else
        return bit.bor(x, bit.lshift(1, n))
    end
end

-- 清除指定位的值
function bit.clearbit(x, n)
    return bit.band(x, bit.bnot(bit.lshift(1, n)))
end

-- 获取最低位的1的位置
function bit.lowestbit(x)
    if x == 0 then return 0 end
    local n = 0
    while bit.band(x, 1) == 0 do
        x = bit.rshift(x, 1)
        n = n + 1
    end
    return n
end

-- 获取最高位的1的位置
function bit.highestbit(x)
    if x == 0 then return 0 end
    local n = 0
    while x > 0 do
        x = bit.rshift(x, 1)
        n = n + 1
    end
    return n - 1
end

-- 计算1的个数
function bit.count(x)
    local count = 0
    while x > 0 do
        if bit.band(x, 1) == 1 then
            count = count + 1
        end
        x = bit.rshift(x, 1)
    end
    return count
end

return bit
