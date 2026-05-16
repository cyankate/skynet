-- 物品模块单元测试（不依赖 skynet 服务启动）
-- 在项目根目录执行: lua script/test/item_mgr_test.lua
package.path = "lualib/?.lua;script/?.lua;script/utils/?.lua;" .. (package.path or "")

local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
if home ~= "" then
    local ver = _VERSION:match("%d+%.%d+") or "5.4"
    local ext = package.config:sub(1, 1) == "\\" and "dll" or "so"
    package.cpath = string.format("%s/.luarocks/lib/lua/%s/?.%s;", home, ver, ext) .. (package.cpath or "")
end

package.loaded["skynet"] = {
    localname = function() return nil end,
    send = function() end,
    call = function() return false end,
}
package.loaded["log"] = {
    info = function() end,
    debug = function() end,
    warning = function() end,
    error = function() end,
}
package.loaded["protocol_handler"] = {
    send_to_player = function() end,
}

require "utils.class"
local CtnBag = require "ctn.ctn_bag"
local item_mgr = require "system.item_mgr"

local passed = 0
local failed = 0

local function assert_true(cond, msg)
    if not cond then
        error(msg or "assert_true failed", 2)
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected=%s actual=%s", msg or "assert_eq", tostring(b), tostring(a)), 2)
    end
end

local function run_case(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print("[PASS] " .. name)
    else
        failed = failed + 1
        print("[FAIL] " .. name)
        print(err)
    end
end

local function mock_player(player_id, bag_opts)
    bag_opts = bag_opts or {}
    local player = {
        player_id_ = player_id,
        ctns_ = {},
    }
    if bag_opts.no_bag ~= true then
        local bag = CtnBag.new(player_id, "bag", "bag")
        bag.slots_ = bag_opts.slots or {}
        bag.virtual_items_ = bag_opts.virtual_items or {}
        bag.config_ = {
            max_slots = bag_opts.max_slots or 100,
            max_stack = bag_opts.max_stack or 999,
            batch_size = 50,
        }
        player.ctns_.bag = bag
    end
    function player:get_ctn(name)
        return self.ctns_[name]
    end
    return player
end

local function count_in_list(list, item_id)
    for _, row in ipairs(list or {}) do
        if row.item_id == item_id then
            return row.count
        end
    end
    return 0
end

local function total_slot_count(bag)
    local n = 0
    for _ in pairs(bag.slots_ or {}) do
        n = n + 1
    end
    return n
end

-- ========== 基础增减 ==========

run_case("add_items increases count", function()
    local p = mock_player(1)
    local ok = item_mgr.add_items(p, { [10001] = 3 }, "test_add")
    assert_true(ok)
    assert_eq(item_mgr.get_item_count(p, 10001), 3)
end)

run_case("cost_items decreases count", function()
    local p = mock_player(2)
    assert_true(item_mgr.add_items(p, { [10001] = 5 }, "test_add"))
    assert_true(item_mgr.cost_items(p, { [10001] = 2 }, "test_cost"))
    assert_eq(item_mgr.get_item_count(p, 10001), 3)
end)

run_case("cost_items fails when not enough", function()
    local p = mock_player(3)
    assert_true(item_mgr.add_items(p, { [10001] = 1 }, "test_add"))
    local ok, err = item_mgr.cost_items(p, { [10001] = 2 }, "test_cost")
    assert_true(not ok)
    assert_eq(item_mgr.get_item_count(p, 10001), 1)
    assert_true(type(err) == "string")
end)

run_case("add_items rejects unknown item", function()
    local p = mock_player(4)
    local ok, err = item_mgr.add_items(p, { [99999] = 1 }, "test_add")
    assert_true(not ok)
    assert_true(string.find(err or "", "配置") ~= nil)
end)

run_case("add_items ignores zero count", function()
    local p = mock_player(5)
    local ok = item_mgr.add_items(p, { [10001] = 0 }, "test_add")
    assert_true(ok)
    assert_eq(item_mgr.get_item_count(p, 10001), 0)
end)

run_case("cost_items rejects unknown item before deduct", function()
    local p = mock_player(51)
    assert_true(item_mgr.add_items(p, { [10001] = 3 }, "test_add"))
    local ok, err = item_mgr.cost_items(p, { [10001] = 1, [99999] = 1 }, "test_cost")
    assert_true(not ok)
    assert_eq(item_mgr.get_item_count(p, 10001), 3, "has_enough 阶段失败，不应扣减")
    assert_true(string.find(err or "", "配置") ~= nil)
end)

-- ========== 背包容量 / 堆叠 ==========

run_case("bag full when slots exhausted", function()
    local p = mock_player(6, { max_slots = 2, max_stack = 10 })
    assert_true(item_mgr.add_items(p, { [10001] = 1 }, "test_add"))
    assert_true(item_mgr.add_items(p, { [10002] = 1 }, "test_add"))
    local ok, err = item_mgr.add_items(p, { [10003] = 1 }, "test_add")
    assert_true(not ok)
    assert_true(string.find(err or "", "背包") ~= nil)
end)

run_case("stack respects max_stack", function()
    local p = mock_player(7, { max_slots = 10, max_stack = 5 })
    assert_true(item_mgr.add_items(p, { [10001] = 7 }, "test_add"))
    assert_eq(item_mgr.get_item_count(p, 10001), 7)
    assert_eq(total_slot_count(p:get_ctn("bag")), 2)
end)

run_case("add_items stacks onto existing slot", function()
    local p = mock_player(71, {
        max_slots = 10,
        max_stack = 10,
        slots = { [1] = { item_id = 10001, count = 3 } },
    })
    assert_true(item_mgr.add_items(p, { [10001] = 2 }, "test_add"))
    assert_eq(item_mgr.get_item_count(p, 10001), 5)
    assert_eq(total_slot_count(p:get_ctn("bag")), 1)
end)

run_case("cost_items deducts across multiple slots", function()
    local p = mock_player(72, {
        max_slots = 10,
        max_stack = 10,
        slots = {
            [1] = { item_id = 10001, count = 2 },
            [2] = { item_id = 10001, count = 3 },
        },
    })
    assert_true(item_mgr.cost_items(p, { [10001] = 4 }, "test_cost"))
    assert_eq(item_mgr.get_item_count(p, 10001), 1)
end)

-- ========== precheck：实体批量加，失败不落袋 ==========

run_case("precheck fails without changing empty bag", function()
    local p = mock_player(11, { max_slots = 2, max_stack = 5 })
    local ok, err = item_mgr.add_items(p, { [10001] = 6, [10002] = 6 }, "test_add")
    assert_true(not ok)
    assert_true(string.find(err or "", "背包") ~= nil)
    assert_eq(item_mgr.get_item_count(p, 10001), 0)
    assert_eq(item_mgr.get_item_count(p, 10002), 0)
    assert_eq(total_slot_count(p:get_ctn("bag")), 0)
end)

run_case("precheck fails keeps prior items unchanged", function()
    local p = mock_player(12, { max_slots = 2, max_stack = 10 })
    assert_true(item_mgr.add_items(p, { [10001] = 1 }, "test_add"))
    assert_true(item_mgr.add_items(p, { [10002] = 1 }, "test_add"))
    local ok = item_mgr.add_items(p, { [10003] = 1 }, "test_add")
    assert_true(not ok)
    assert_eq(item_mgr.get_item_count(p, 10001), 1)
    assert_eq(item_mgr.get_item_count(p, 10002), 1)
    assert_eq(item_mgr.get_item_count(p, 10003), 0)
end)

run_case("batch add multiple real items succeeds", function()
    local p = mock_player(13, { max_slots = 5, max_stack = 10 })
    assert_true(item_mgr.add_items(p, { [10001] = 3, [10002] = 4 }, "test_add"))
    assert_eq(item_mgr.get_item_count(p, 10001), 3)
    assert_eq(item_mgr.get_item_count(p, 10002), 4)
end)

run_case("can_add_items false when bag has no room", function()
    local p = mock_player(14, { max_slots = 2, max_stack = 10 })
    assert_true(item_mgr.add_items(p, { [10001] = 1 }, "test_add"))
    assert_true(item_mgr.add_items(p, { [10002] = 1 }, "test_add"))
    local ok = item_mgr.can_add_items(p, { [10003] = 1 })
    assert_true(not ok)
end)

-- ========== 无背包 ==========

run_case("add_items fails when bag missing", function()
    local p = mock_player(20, { no_bag = true })
    local ok, err = item_mgr.add_items(p, { [10001] = 1 }, "test_add")
    assert_true(not ok)
    assert_true(string.find(err or "", "背包") ~= nil)
end)

run_case("cost_items fails when bag missing", function()
    local p = mock_player(21, { no_bag = true })
    local ok, err = item_mgr.cost_items(p, { [10001] = 1 }, "test_cost")
    assert_true(not ok)
    assert_true(string.find(err or "", "背包") ~= nil)
end)

-- ========== 列表 / 虚拟道具 ==========

run_case("build_item_list aggregates by item_id", function()
    local p = mock_player(8, {
        max_slots = 10,
        max_stack = 5,
        slots = {
            [1] = { item_id = 10001, count = 2 },
            [2] = { item_id = 10001, count = 3 },
            [3] = { item_id = 10002, count = 1 },
        },
    })
    local list = item_mgr.build_item_list(p)
    assert_eq(count_in_list(list, 10001), 5)
    assert_eq(count_in_list(list, 10002), 1)
    assert_eq(#list, 2)
end)

run_case("build_item_list empty bag", function()
    local p = mock_player(81)
    assert_eq(#item_mgr.build_item_list(p), 0)
end)

run_case("build_item_list merges real and virtual", function()
    local p = mock_player(82, {
        slots = { [1] = { item_id = 10001, count = 2 } },
        virtual_items = { [100002] = 5 },
    })
    local list = item_mgr.build_item_list(p)
    assert_eq(#list, 2)
    assert_eq(count_in_list(list, 10001), 2)
    assert_eq(count_in_list(list, 100002), 5)
end)

run_case("virtual item add and cost", function()
    local p = mock_player(9)
    assert_true(item_mgr.add_items(p, { [100002] = 4 }, "test_virtual"))
    assert_eq(item_mgr.get_item_count(p, 100002), 4)
    assert_true(item_mgr.cost_items(p, { [100002] = 1 }, "test_virtual"))
    assert_eq(item_mgr.get_item_count(p, 100002), 3)
end)

run_case("cost all removes item from list", function()
    local p = mock_player(10)
    assert_true(item_mgr.add_items(p, { [10002] = 2 }, "test_add"))
    assert_true(item_mgr.cost_items(p, { [10002] = 2 }, "test_cost"))
    assert_eq(item_mgr.get_item_count(p, 10002), 0)
    assert_eq(count_in_list(item_mgr.build_item_list(p), 10002), 0)
end)

print(string.format("\nDone: %d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
