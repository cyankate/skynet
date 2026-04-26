local skynet = require "skynet"
require "skynet.manager"
local logger_service = require "logger.logger_service"

local CMD = {}

function CMD.logging(source, type, color, str)
	logger_service.logging(source, type, color, str)
end

function CMD.register_name(source, name)
	logger_service.register_name(source, name)
end

skynet.register_protocol {
	name = "text",
	id = skynet.PTYPE_TEXT,
	unpack = skynet.tostring,
	dispatch = function(_, source, msg)
		log.system("%s", msg)
	end
}

skynet.register_protocol {
	name = "SYSTEM",
	id = skynet.PTYPE_SYSTEM,
	unpack = function(...) return ... end,
	dispatch = function(_, source)
		-- reopen signal
		log.fatal("SIGHUP")
	end
}

skynet.start(function()
	logger_service.init()
	skynet.register(".logger")
	
    skynet.dispatch("lua", function(_, source, cmd, ...)
		local f = assert(CMD[cmd], cmd .. " not found")
		f(source, ...)
	end)
end)