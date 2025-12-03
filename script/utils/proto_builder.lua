--[[
协议构建工具：将 Lua 表结构转换为 sproto 文本格式

字段格式: "type" 或 "type -- comment"
tag 自动从 0 开始递增生成
]]

local proto_builder = {}

-- 全局 schema 注册表（用于验证）
-- schemas[protocol_name] = {direction = "c2s"|"s2c", request = {...}, response = {...}}
local schemas = {}

-- 尝试加载 datacenter（可能在某些环境中不可用）
local datacenter_available = false
local datacenter = nil
pcall(function()
    datacenter = require "skynet.datacenter"
    datacenter_available = true
end)

-- 解析字段: "type" 或 "type -- comment"
local function parse_field(field_name, field_def, tag)
    local field_type, comment
    
    if type(field_def) ~= "string" then
        error(string.format("Invalid field definition for '%s': expected string, got %s", 
            field_name, type(field_def)))
    end
    
    local type_part, comment_part = field_def:match("^(.+)%s*%-%-%s*(.+)$")
    if type_part then
        field_type = type_part:match("^%s*(.-)%s*$")
        comment = comment_part:match("^%s*(.-)%s*$")
    else
        field_type = field_def:match("^%s*(.-)%s*$")
    end
    
    if not field_type or field_type == "" then
        error(string.format("Invalid field format for '%s': %s. Expected 'type' or 'type -- comment'", 
            field_name, field_def))
    end
    
    return {
        name = field_name,
        tag = tag,
        type = field_type,
        comment = comment,
    }
end

function proto_builder.new()
    local self = {
        types = {},
        protocols = {},
        package_fields = nil,
    }
    return setmetatable(self, {__index = proto_builder})
end

function proto_builder:package(fields)
    local parsed_fields = {}
    local field_names = {}
    
    for field_name in pairs(fields) do
        table.insert(field_names, field_name)
    end
    table.sort(field_names)
    
    for idx, field_name in ipairs(field_names) do
        table.insert(parsed_fields, parse_field(field_name, fields[field_name], idx - 1))
    end
    
    self.package_fields = parsed_fields
    return self
end

-- fields: {name = "type", name2 = "type -- comment"}
function proto_builder:type(name, fields)
    local parsed_fields = {}
    local field_names = {}
    
    for field_name in pairs(fields) do
        table.insert(field_names, field_name)
    end
    table.sort(field_names)
    
    for idx, field_name in ipairs(field_names) do
        table.insert(parsed_fields, parse_field(field_name, fields[field_name], idx - 1))
    end
    
    self.types[name] = parsed_fields
    return self
end

-- fields: 字符串（引用类型）或表（内联定义）
local function parse_protocol_fields(fields)
    if not fields then
        return nil
    end
    
    if type(fields) == "string" then
        return fields
    elseif type(fields) == "table" then
        local parsed_fields = {}
        local field_names = {}
        
        for field_name in pairs(fields) do
            table.insert(field_names, field_name)
        end
        table.sort(field_names)
        
        for idx, field_name in ipairs(field_names) do
            table.insert(parsed_fields, parse_field(field_name, fields[field_name], idx - 1))
        end
        
        return parsed_fields
    else
        return fields
    end
end

-- def: {request = {...}, response = {...}} 或 {request = "TypeName"}
function proto_builder:protocol(name, tag, def)
    self.protocols[name] = {
        tag = tag,
        request = parse_protocol_fields(def.request),
        response = parse_protocol_fields(def.response),
    }
    return self
end

-- 从字段定义中提取验证 schema
local function extract_validation_schema(fields)
    if not fields then
        return nil
    end
    
    if type(fields) == "string" then
        return {_ref_type = fields}
    end
    
    if type(fields) ~= "table" or #fields == 0 then
        return {}
    end
    
    local schema = {}
    for _, field in ipairs(fields) do
        if field.name and field.type then
            schema[field.name] = {
                type = field.type,
                required = true,
                tag = field.tag,
                comment = field.comment,
            }
        end
    end
    
    return schema
end

-- 注册协议 schema（用于验证）
-- direction: "c2s" 或 "s2c"
function proto_builder:register_schema(direction)
    for protocol_name, protocol_def in pairs(self.protocols) do
        local schema_data = {
            direction = direction,
            request = extract_validation_schema(protocol_def.request),
            response = extract_validation_schema(protocol_def.response),
        }
        schemas[protocol_name] = schema_data
    end
    return self
end

function proto_builder.save_schemas_to_datacenter()
    if not datacenter_available then
        return false
    end
    
    local count = 0
    for protocol_name, schema_data in pairs(schemas) do
        datacenter.set("proto_schemas", protocol_name, schema_data)
        count = count + 1
    end
    
    return count > 0, count
end

local function fields_to_text(fields, indent)
    indent = indent or ""
    local lines = {}
    for _, field in ipairs(fields) do
        local line = indent .. field.name .. " " .. field.tag .. " : " .. field.type
        if field.comment then
            line = line .. "  # " .. field.comment
        end
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end

function proto_builder:to_string()
    local lines = {}
    
    if self.package_fields then
        table.insert(lines, ".package {")
        table.insert(lines, fields_to_text(self.package_fields, "\t"))
        table.insert(lines, "}")
        table.insert(lines, "")
    end
    
    local type_names = {}
    for name in pairs(self.types) do
        table.insert(type_names, name)
    end
    table.sort(type_names)
    
    for _, name in ipairs(type_names) do
        local fields = self.types[name]
        table.insert(lines, "." .. name .. " {")
        table.insert(lines, fields_to_text(fields, "\t"))
        table.insert(lines, "}")
        table.insert(lines, "")
    end
    
    local protocol_names = {}
    for name in pairs(self.protocols) do
        table.insert(protocol_names, name)
    end
    table.sort(protocol_names, function(a, b)
        return self.protocols[a].tag < self.protocols[b].tag
    end)
    
    for _, name in ipairs(protocol_names) do
        local proto = self.protocols[name]
        table.insert(lines, name .. " " .. proto.tag .. " {")
        
        if proto.request then
            if type(proto.request) == "string" then
                table.insert(lines, "\trequest " .. proto.request)
            elseif type(proto.request) == "table" then
                if #proto.request > 0 then
                    table.insert(lines, "\trequest {")
                    table.insert(lines, fields_to_text(proto.request, "\t\t"))
                    table.insert(lines, "\t}")
                else
                    table.insert(lines, "\trequest {}")
                end
            end
        end
        
        if proto.response then
            if type(proto.response) == "string" then
                table.insert(lines, "\tresponse " .. proto.response)
            elseif type(proto.response) == "table" then
                if #proto.response > 0 then
                    table.insert(lines, "\tresponse {")
                    table.insert(lines, fields_to_text(proto.response, "\t\t"))
                    table.insert(lines, "\t}")
                else
                    table.insert(lines, "\tresponse {}")
                end
            end
        end
        
        table.insert(lines, "}")
        table.insert(lines, "")
    end
    
    return table.concat(lines, "\n")
end

-- 获取 schema（先从 datacenter 加载，如果没有再从本地查找）
local function get_schema(protocol_name)
    -- 先尝试从本地查找
    local schema = schemas[protocol_name]
    if schema then
        return schema
    end
    
    -- 如果本地没有，尝试从 datacenter 加载
    if datacenter_available then
        schema = datacenter.get("proto_schemas", protocol_name)
        if schema then
            -- 缓存到本地
            schemas[protocol_name] = schema
            return schema
        end
    end
    
    return nil
end

-- 获取发送给客户端的协议 schema（C2S 的 response 或 S2C 的 request）
function proto_builder.get_send_to_client_schema(protocol_name)
    local schema = get_schema(protocol_name)
    if not schema then
        return nil
    end
    
    if schema.direction == "c2s" then
        return schema.response
    elseif schema.direction == "s2c" then
        return schema.request
    end
    
    return nil
end

-- 获取接收客户端消息的协议 schema（C2S 的 request 或 S2C 的 response）
function proto_builder.get_receive_from_client_schema(protocol_name)
    local schema = get_schema(protocol_name)
    if not schema then
        return nil
    end
    
    if schema.direction == "c2s" then
        return schema.request
    elseif schema.direction == "s2c" then
        return schema.response
    end
    
    return nil
end

-- 验证相关函数
local function is_empty(value)
    if value == nil then
        return true
    end
    if type(value) == "string" and value == "" then
        return true
    end
    if type(value) == "table" and next(value) == nil then
        return true
    end
    return false
end

local function validate_type(value, expected_type)
    if value == nil then
        return true
    end
    
    local actual_type = type(value)
    
    if expected_type:match("^%*") then
        if actual_type ~= "table" then
            return false, string.format("期望数组类型，实际类型: %s", actual_type)
        end
        local is_array = true
        for k, _ in pairs(value) do
            if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
                is_array = false
                break
            end
        end
        if not is_array then
            return false, "数组格式不正确（应为数字索引从1开始）"
        end
        return true
    end
    
    local type_map = {
        integer = "number",
        double = "number",
        boolean = "boolean",
        string = "string",
        binary = "string",
    }
    
    local lua_type = type_map[expected_type]
    if lua_type then
        if actual_type ~= lua_type then
            return false, string.format("期望类型: %s，实际类型: %s", expected_type, actual_type)
        end
        return true
    end
    
    if actual_type == "table" then
        return true
    end
    
    return false, string.format("未知类型: %s", expected_type)
end

-- 验证协议字段
function proto_builder.validate(protocol_name, data, schema)
    if not data or type(data) ~= "table" then
        return false, "数据必须是表类型"
    end
    
    if not schema then
        return true
    end
    
    local errors = {}
    
    for field_name, field_def in pairs(schema) do
        local field_type = field_def.type or field_def
        local required = field_def.required ~= false
        
        local value = data[field_name]
        
        if required and is_empty(value) then
            table.insert(errors, string.format("字段 '%s' 不能为空", field_name))
        end
        
        if not is_empty(value) then
            local ok, err_msg = validate_type(value, field_type)
            if not ok then
                table.insert(errors, string.format("字段 '%s' %s", field_name, err_msg))
            end
        end
    end
    
    if #errors > 0 then
        return false, table.concat(errors, "; ")
    end
    
    return true
end

return proto_builder

