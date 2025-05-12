local M = {}
local skynet = require "skynet"
local log = require "log"

function M.print_table(_tbl)
    indent = indent or 0
    local prefix = string.rep("  ", indent) -- 根据层级生成缩进
    if type(_tbl) ~= "table" then
        log.info(prefix .. tostring(_tbl)) -- 如果不是 table，直接打印值
        return
    end

    log.info(prefix .. "{")
    for k, v in pairs(_tbl) do
        local key = tostring(k)
        if type(v) == "table" then
            log.info(prefix .. "  " .. key .. " = ")
            M.print_table(v, indent + 1) -- 递归打印子表
        else
            log.info(prefix .. "  " .. key .. " = " .. tostring(v))
        end
    end
    log.info(prefix .. "}")
end 

function M.ssplit(input, delimiter)
    local result = {}
    for match in (input .. delimiter):gmatch("(.-)" .. delimiter) do
        table.insert(result, match)
    end
    return result
end

-- 将 table 序列化为紧凑字符串
function M.serialize_table_compact(tbl)
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
function M.deserialize_table_compact(str)
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

-- 将 table 序列化为字符串
function M.serialize_table(tbl)
    local function serialize(tbl, indent)
        indent = indent or 0
        local result = {}
        local prefix = string.rep("  ", indent)

        if type(tbl) ~= "table" then
            error("Input must be a table")
        end

        table.insert(result, "{\n")
        local first = true
        for k, v in pairs(tbl) do
            if not first then
                table.insert(result, ",\n")
            end
            first = false
            
            local key = type(k) == "string" and string.format("[%q]", k) or string.format("[%s]", tostring(k))
            if type(v) == "table" then
                table.insert(result, string.format("%s  %s = %s", prefix, key, serialize(v, indent + 1)))
            elseif type(v) == "string" then
                table.insert(result, string.format("%s  %s = %q", prefix, key, v))
            else
                table.insert(result, string.format("%s  %s = %s", prefix, key, tostring(v)))
            end
        end
        table.insert(result, "\n" .. prefix .. "}")
        return table.concat(result)
    end

    return M.serialize_table_compact(tbl)
end

-- 将字符串反序列化为 table
function M.deserialize_table(str)
    -- print("deserialize_table", str)
    -- local func, err = load("return " .. str, "deserialize", "t", {})
    -- if not func then
    --     error("Failed to deserialize string: " .. err)
    -- end
    return M.deserialize_table_compact(str)
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


return M