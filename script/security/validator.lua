local log = require "log"

local validator = {}

-- 基本类型验证
function validator.is_string(value)
    return type(value) == "string"
end

function validator.is_number(value)
    return type(value) == "number"
end

function validator.is_boolean(value)
    return type(value) == "boolean"
end

function validator.is_table(value)
    return type(value) == "table"
end

function validator.is_function(value)
    return type(value) == "function"
end

function validator.is_nil(value)
    return value == nil
end

-- 特定规则验证
function validator.is_integer(value)
    return type(value) == "number" and math.floor(value) == value
end

function validator.is_positive(value)
    return type(value) == "number" and value > 0
end

function validator.is_non_negative(value)
    return type(value) == "number" and value >= 0
end

function validator.is_in_range(value, min, max)
    return type(value) == "number" and value >= min and value <= max
end

function validator.is_empty(value)
    if type(value) == "string" then
        return value == ""
    elseif type(value) == "table" then
        return next(value) == nil
    end
    return false
end

function validator.is_not_empty(value)
    return not validator.is_empty(value)
end

function validator.has_length(value, len)
    if type(value) == "string" or type(value) == "table" then
        return #value == len
    end
    return false
end

function validator.min_length(value, min)
    if type(value) == "string" or type(value) == "table" then
        return #value >= min
    end
    return false
end

function validator.max_length(value, max)
    if type(value) == "string" or type(value) == "table" then
        return #value <= max
    end
    return false
end

function validator.matches_pattern(value, pattern)
    if type(value) ~= "string" then
        return false
    end
    return string.match(value, pattern) ~= nil
end

-- 常用模式检查
function validator.is_email(value)
    if type(value) ~= "string" then
        return false
    end
    -- 简化的电子邮件验证模式
    local pattern = "^[%w%.%%%+%-]+@[%w%.%%%+%-]+%.%w%w%w?%w?$"
    return string.match(value, pattern) ~= nil
end

function validator.is_url(value)
    if type(value) ~= "string" then
        return false
    end
    -- 简化的URL验证模式
    local pattern = "^https?://[%w-_%.%?%.:/%+=&]+$"
    return string.match(value, pattern) ~= nil
end

function validator.is_alphanumeric(value)
    if type(value) ~= "string" then
        return false
    end
    return string.match(value, "^[%w]+$") ~= nil
end

function validator.is_alpha(value)
    if type(value) ~= "string" then
        return false
    end
    return string.match(value, "^[%a]+$") ~= nil
end

function validator.is_numeric(value)
    if type(value) ~= "string" then
        return false
    end
    return string.match(value, "^[%d]+$") ~= nil
end

function validator.is_valid_name(value)
    if type(value) ~= "string" then
        return false
    end
    -- 允许字母、数字、中文字符、下划线，不允许特殊字符
    return string.match(value, "^[%w%_\228-\233]+$") ~= nil
end

function validator.is_date(value)
    if type(value) ~= "string" then
        return false
    end
    -- 检查YYYY-MM-DD格式
    local y, m, d = string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not (y and m and d) then
        return false
    end
    
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m < 1 or m > 12 then
        return false
    end
    
    local days_in_month = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    -- 处理闰年
    if m == 2 and (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) then
        days_in_month[2] = 29
    end
    
    return d >= 1 and d <= days_in_month[m]
end

function validator.is_time(value)
    if type(value) ~= "string" then
        return false
    end
    local h, m, s = string.match(value, "^(%d%d):(%d%d):(%d%d)$")
    if not (h and m and s) then
        return false
    end
    
    h, m, s = tonumber(h), tonumber(m), tonumber(s)
    return h >= 0 and h <= 23 and m >= 0 and m <= 59 and s >= 0 and s <= 59
end

function validator.is_datetime(value)
    if type(value) ~= "string" then
        return false
    end
    
    local date_part, time_part = string.match(value, "^(.+)%s(.+)$")
    if not (date_part and time_part) then
        return false
    end
    
    return validator.is_date(date_part) and validator.is_time(time_part)
end

-- 自定义验证规则
local custom_rules = {}

function validator.register_rule(name, func)
    if type(name) ~= "string" or type(func) ~= "function" then
        return false, "无效的规则名称或函数"
    end
    
    custom_rules[name] = func
    return true
end

function validator.validate(value, rule_name, ...)
    if custom_rules[rule_name] then
        return custom_rules[rule_name](value, ...)
    elseif validator[rule_name] then
        return validator[rule_name](value, ...)
    else
        log.error("Unknown validation rule: %s", rule_name)
        return false
    end
end

-- 批量验证多个规则
function validator.validate_all(value, rules)
    if type(rules) ~= "table" then
        return false, "规则必须是一个表"
    end
    
    for _, rule in ipairs(rules) do
        local rule_name = rule[1]
        local args = {value}
        
        for i = 2, #rule do
            table.insert(args, rule[i])
        end
        
        local result = validator.validate(table.unpack(args))
        if not result then
            return false, string.format("验证失败：规则 %s", rule_name)
        end
    end
    
    return true
end

-- 验证表单数据
function validator.validate_form(form, schema)
    if type(form) ~= "table" or type(schema) ~= "table" then
        return false, "表单和模式必须是表"
    end
    
    local errors = {}
    
    for field, field_rules in pairs(schema) do
        -- 检查必填字段
        if field_rules.required and (form[field] == nil or validator.is_empty(form[field])) then
            errors[field] = field_rules.message or "此字段为必填项"
            goto continue
        end
        
        -- 跳过非必填且为空的字段
        if not field_rules.required and (form[field] == nil or validator.is_empty(form[field])) then
            goto continue
        end
        
        -- 验证每个规则
        if field_rules.rules then
            for _, rule in ipairs(field_rules.rules) do
                local rule_name = rule[1]
                local args = {form[field]}
                
                for i = 2, #rule do
                    table.insert(args, rule[i])
                end
                
                local result = validator.validate(table.unpack(args))
                if not result then
                    errors[field] = rule.message or string.format("无效的%s", field)
                    break
                end
            end
        end
        
        ::continue::
    end
    
    if next(errors) then
        return false, errors
    end
    
    return true
end

return validator 