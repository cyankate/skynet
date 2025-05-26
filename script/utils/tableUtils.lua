local M = {}
local skynet = require "skynet"
local log = require "log"

function M.print_table(_tbl)
    indent = indent or 0
    local prefix = string.rep("  ", indent) -- 根据层级生成缩进
    if type(_tbl) ~= "table" then
        log.error(prefix .. tostring(_tbl)) -- 如果不是 table，直接打印值
        return
    end

    log.debug(prefix .. "{")
    for k, v in pairs(_tbl) do
        local key = tostring(k)
        if type(v) == "table" then
            log.debug(prefix .. "  " .. key .. " = ")
            M.print_table(v, indent + 1) -- 递归打印子表
        else
            log.debug(prefix .. "  " .. key .. " = " .. tostring(v))
        end
    end
    log.debug(prefix .. "}")
end 

function M.ssplit(input, delimiter)
    local result = {}
    for match in (input .. delimiter):gmatch("(.-)" .. delimiter) do
        table.insert(result, match)
    end
    return result
end

-- 将 table 序列化为字符串
function M.serialize_table(tbl)
    local function serialize(tbl)
        if type(tbl) ~= "table" then
            error("Input must be a table")
        end

        local result = {}
        for k, v in pairs(tbl) do
            local key = type(k) == "string" and string.format("[%q]", k) or string.format("[%s]", tostring(k))
            if type(v) == "table" then
                table.insert(result, string.format("%s=%s", key, serialize(v)))
            elseif type(v) == "string" then
                table.insert(result, string.format("%s=%q", key, v))
            else
                table.insert(result, string.format("%s=%s", key, tostring(v)))
            end
        end
        return "{" .. table.concat(result, ",") .. "}"
    end

    return "TBL:" .. serialize(tbl)
end

-- 将紧凑字符串反序列化为 table
function M.deserialize_table(str)
    -- 检查序列化标记
    if str:match("^TBL:") then
        -- 移除序列化标记
        str = str:sub(5)
    end
    local func, err = load("return " .. str, "deserialize", "t", {})
    if not func then
        error("Failed to deserialize string: " .. err)
    end
    return func()
end

-- 二分查找
-- @param arr: 有序数组
-- @param target: 要查找的目标值
-- @param compare: 比较函数，接受两个参数 (a, b)，返回负值表示 a < b，0 表示相等，正值表示 a > b
-- @return: 如果找到，返回目标值的索引；如果未找到，返回插入位置的索引
function M.binary_search(arr, target, compare, _obj)
    local low, high = 1, #arr
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local cmp = compare(_obj, target, arr[mid])
        if cmp == 0 then
            return mid -- 找到目标值，返回索引
        elseif cmp > 0 then
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return low -- 未找到，返回插入位置
end

-- 二分插入
-- @param arr: 有序数组
-- @param value: 要插入的值
-- @param compare: 比较函数，接受两个参数 (a, b)，返回负值表示 a < b，0 表示相等，正值表示 a > b
-- @return: 插入后的数组
function M.binary_insert(arr, value, compare)
    local pos = M.binary_search(arr, value, compare) -- 找到插入位置
    table.insert(arr, pos, value) -- 在指定位置插入值
    return arr
end

function M.deep_copy(obj)
    if type(obj) ~= "table" then
        return obj
    end
    local copy = {}
    for k, v in pairs(obj) do
        copy[k] = M.deep_copy(v)
    end
    return copy
end

-- 深拷贝表
function M.deep_copy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[M.deep_copy(orig_key)] = M.deep_copy(orig_value)
        end
        setmetatable(copy, M.deep_copy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

-- 合并两个表
function M.merge(t1, t2)
    for k, v in pairs(t2) do
        if type(v) == "table" and type(t1[k]) == "table" then
            M.merge(t1[k], v)
        else
            t1[k] = v
        end
    end
    return t1
end

-- 获取表大小（包括非整数键）
function M.table_size(t)
    if type(t) ~= "table" then
        return 0
    end
    
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

-- 检查表是否为空
function M.is_empty(t)
    if type(t) ~= "table" then
        return true
    end
    return next(t) == nil
end

-- 检查表中是否包含指定值
function M.contains_value(t, value)
    if type(t) ~= "table" then
        return false
    end
    
    for _, v in pairs(t) do
        if v == value then
            return true
        end
    end
    return false
end

-- 检查表中是否包含指定键
function M.contains_key(t, key)
    if type(t) ~= "table" then
        return false
    end
    return t[key] ~= nil
end

-- 获取表中的所有键
function M.keys(t)
    if type(t) ~= "table" then
        return {}
    end
    
    local keys = {}
    for k, _ in pairs(t) do
        table.insert(keys, k)
    end
    return keys
end

-- 获取表中的所有值
function M.values(t)
    if type(t) ~= "table" then
        return {}
    end
    
    local values = {}
    for _, v in pairs(t) do
        table.insert(values, v)
    end
    return values
end

-- 过滤表
function M.filter(t, filter_func)
    if type(t) ~= "table" or type(filter_func) ~= "function" then
        return {}
    end
    
    local result = {}
    for k, v in pairs(t) do
        if filter_func(v, k, t) then
            result[k] = v
        end
    end
    return result
end

-- 映射表
function M.map(t, map_func)
    if type(t) ~= "table" or type(map_func) ~= "function" then
        return {}
    end
    
    local result = {}
    for k, v in pairs(t) do
        result[k] = map_func(v, k, t)
    end
    return result
end

-- 数组转换为以元素值为键的表
function M.array_to_map(array, value_func)
    if type(array) ~= "table" then
        return {}
    end
    
    local result = {}
    for i, v in ipairs(array) do
        if value_func then
            result[v] = value_func(v, i)
        else
            result[v] = true
        end
    end
    return result
end

-- 合并两个数组
function M.concat_arrays(t1, t2)
    if type(t1) ~= "table" or type(t2) ~= "table" then
        return t1
    end
    
    local result = M.deep_copy(t1)
    for _, v in ipairs(t2) do
        table.insert(result, v)
    end
    return result
end

-- 获取数组的子集
function M.slice(array, start_idx, end_idx)
    if type(array) ~= "table" then
        return {}
    end
    
    start_idx = start_idx or 1
    end_idx = end_idx or #array
    
    if start_idx < 0 then
        start_idx = #array + start_idx + 1
    end
    
    if end_idx < 0 then
        end_idx = #array + end_idx + 1
    end
    
    local result = {}
    for i = start_idx, end_idx do
        table.insert(result, array[i])
    end
    return result
end

-- 移除数组中的指定元素
function M.remove_element(array, element)
    if type(array) ~= "table" then
        return false
    end
    
    for i, v in ipairs(array) do
        if v == element then
            table.remove(array, i)
            return true
        end
    end
    return false
end

return M