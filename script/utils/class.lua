function class(classname, super)
    local cls = {}
    cls.__cname = classname
    cls.__index = cls

    -- 如果有父类，设置继承
    if super then
        setmetatable(cls, { __index = super })
        cls.super = super
    end

    -- 创建实例的方法
    function cls.new(...)
        local instance = setmetatable({}, cls)
        if instance.ctor then
            instance:ctor(...)
        end
        return instance
    end

    return cls
end

return class