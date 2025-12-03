
local skynet = require "skynet"
local sprotoparser = require "sprotoparser"
local sprotoloader = require "sprotoloader"
local proto = require "proto"
local proto_builder = require "utils.proto_builder"

skynet.start(function()
	sprotoloader.save(proto.c2s, 1)
	sprotoloader.save(proto.s2c, 2)
	
	-- 将所有已注册的 schema 保存到 datacenter，以便其他服务访问
	local ok, count = proto_builder.save_schemas_to_datacenter()
	if ok then
		log.info(string.format("已保存 %d 个协议 schema 到 datacenter", count))
	else
		log.warning("警告：datacenter 不可用，schema 无法跨服务共享")
	end
	
	-- don't call skynet.exit() , because sproto.core may unload and the global slot become invalid
end)