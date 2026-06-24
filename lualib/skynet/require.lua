-- skynet module two-step initialize . When you require a skynet module :
-- 1. Run module main function as official lua module behavior.
-- 2. Run the functions register by skynet.init() during the step 1,
--      unless calling `require` in main thread .
-- If you call `require` in main thread ( service main function ), the functions
-- registered by skynet.init() do not execute immediately, they will be executed
-- by skynet.start() before start function.

local M = {}

local mainthread, ismain = coroutine.running()
assert(ismain, "skynet.require must initialize in main thread")

local context = {
	[mainthread] = {},
}

do
	local native_require = _G.require
	local loaded = package.loaded
	local loading = {}

	local function is_resolved(m)
		return m ~= nil
	end

	-- 循环依赖：返回代理，在模块加载完成后再解析字段（运行时访问）
	local function create_proxy(name)
		return setmetatable({}, {
			__index = function(_, k)
				local m = loaded[name]
				if type(m) == "table" then
					return m[k]
				end
				if loading[name] then
					error(string.format(
						"module '%s' circular require: '%s' not ready yet",
						name, tostring(k)
					))
				end
				error(string.format("module '%s' not found", name))
			end,
		})
	end

	local function finish_module(name, modfunc, filename, init_list)
		local m = modfunc(name, filename)

		if init_list then
			for _, f in ipairs(init_list) do
				f()
			end
		end

		if m == nil then
			m = true
		end

		loaded[name] = m
		return m
	end

	function M.require(name)
		local m = loaded[name]
		if is_resolved(m) then
			return m
		end

		local co, main = coroutine.running()

		local loading_queue = loading[name]
		if loading_queue then
			-- 同一协程/主线程内的循环 require：返回代理，避免 stack overflow
			if main or loading_queue.co == co then
				return create_proxy(name)
			end
			-- 不同协程并发加载同一模块：等待先完成的协程
			local skynet = require "skynet"
			loading_queue[#loading_queue + 1] = co
			skynet.wait(co)
			m = loaded[name]
			if not is_resolved(m) then
				error(string.format("require %s failed", name))
			end
			return m
		end

		local filename = package.searchpath(name, package.path)
		if not filename then
			return native_require(name)
		end

		local modfunc = loadfile(filename)
		if not modfunc then
			return native_require(name)
		end

		loading_queue = { co = co }
		loading[name] = loading_queue

		local init_list
		local old_init_list
		if not main then
			old_init_list = context[co]
			init_list = {}
			context[co] = init_list
		end

		local ok, err = xpcall(function()
			finish_module(name, modfunc, filename, init_list)
		end, debug.traceback)

		if not main then
			context[co] = old_init_list
		end

		local waiting = #loading_queue
		if waiting > 0 then
			local skynet = require "skynet"
			for i = 1, waiting do
				skynet.wakeup(loading_queue[i])
			end
		end
		loading[name] = nil

		if not ok then
			loaded[name] = nil
			error(err)
		end

		return loaded[name]
	end
end

function M.init_all()
	for _, f in ipairs(context[mainthread]) do
		f()
	end
	context[mainthread] = nil
end

function M.init(f)
	assert(type(f) == "function")
	local co = coroutine.running()
	table.insert(context[co], f)
end

return M
