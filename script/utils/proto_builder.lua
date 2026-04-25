-- 服务端包装层：在共享 builder 基础上扩展 datacenter 同步与跨服务查询。
local proto_builder = require "protocol.proto_builder"

local datacenter_available = false
local datacenter = nil
local schema_cache = {}
pcall(function()
    datacenter = require "skynet.datacenter"
    datacenter_available = true
end)

local function extract_validation_schema(fields, types)
    if not fields then
        return nil
    end

    if type(fields) == "string" then
        if types and types[fields] then
            return extract_validation_schema(types[fields], types)
        end
        return nil
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

local raw_register_schema = proto_builder.register_schema
function proto_builder:register_schema(direction)
    local ret = raw_register_schema(self, direction)
    for protocol_name, protocol_def in pairs(self.protocols or {}) do
        schema_cache[protocol_name] = {
            direction = direction,
            request = extract_validation_schema(protocol_def.request, self.types),
            response = extract_validation_schema(protocol_def.response, self.types),
        }
    end
    return ret
end

local function get_schema(protocol_name)
    local schema = schema_cache[protocol_name]
    if schema then
        return schema
    end

    if datacenter_available then
        schema = datacenter.get("proto_schemas", protocol_name)
        if schema then
            schema_cache[protocol_name] = schema
            return schema
        end
    end

    return nil
end

function proto_builder.save_schemas_to_datacenter()
    if not datacenter_available then
        return false
    end

    local count = 0
    for protocol_name, schema_data in pairs(schema_cache) do
        datacenter.set("proto_schemas", protocol_name, schema_data)
        count = count + 1
    end
    return count > 0, count
end

function proto_builder.clear_schemas()
    schema_cache = {}
end

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

return proto_builder

