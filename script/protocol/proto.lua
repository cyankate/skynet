
local sprotoparser = nil
local builder = nil
if SKYNET_LUA_ROOT then
    sprotoparser = require "Skynet/lualib/sprotoparser"
    builder = require "Skynet/script/protocol/proto_builder"
else
    sprotoparser = require "sprotoparser"
    builder = require "protocol.proto_builder"
end


local proto = {}

-- 示例协议
--[[
.Person {
    name 0 : string          -- 字符串
    id 1 : integer          -- 整数
    height 2 : integer(2)   -- 定点数（精度1/100）
    weight 3 : double       -- 浮点数
    active 4 : boolean      -- 布尔值
    data 5 : binary         -- 二进制数据
    phone 6 : *PhoneNumber  -- 数组
    address 7 : Address     -- 用户自定义类型
}
]]

-- ========== C2S 协议定义 ==========
local c2s_builder = builder.new()
    :package({
        type = "integer",
        session = "integer",
    })
    
    
    :protocol("login", 3, {
        request = {
            account_id = "string",
        },
        response = {
            success = "boolean",
            player_id = "integer",
            player_name = "string",
        }
    })
    
    -- 聊天相关类型定义
    :type("channel_info", {
        id = "string",
        name = "string",
        member_count = "integer",
        create_time = "integer",
    })
    
    :type("chat_message", {
        type = "string",
        channel_id = "integer",
        channel_name = "string",
        sender_id = "integer",
        sender_name = "string",
        content = "string",
        timestamp = "integer",
    })

    :protocol("send_channel_message", 7, {
        request = {
            channel_id = "integer",
            content = "string",
        }
    })
    
    :protocol("send_private_message", 8, {
        request = {
            to_player_id = "integer",
            content = "string",
        }
    })
    
    :protocol("get_channel_list", 9, {
        request = {}
    })
    
    :protocol("get_channel_history", 12, {
        request = {
            channel_id = "integer",
            count = "integer",
        }
    })
    
    :protocol("get_private_history", 13, {
        request = {
            player_id = "integer",
            count = "integer",
        }
    })
    
    -- 好友系统
    :type("friend_info", {
        player_id = "integer",
        name = "string",
    })
    
    :type("apply_info", {
        player_id = "integer",
        name = "string",
        apply_time = "integer",
        message = "string",
    })
    
    :protocol("add_friend", 10001, {
        request = {
            target_id = "integer",
            message = "string",
        }
    })
    
    :protocol("delete_friend", 10002, {
        request = {
            target_id = "integer",
        }
    })
    
    :protocol("agree_apply", 10003, {
        request = {
            player_id = "integer",
        }
    })
    
    :protocol("reject_apply", 10004, {
        request = {
            player_id = "integer",
        }
    })
    
    :protocol("get_friend_list", 10005, {
        request = {}
    })
    
    :protocol("get_apply_list", 10006, {
        request = {}
    })
    
    :protocol("add_blacklist", 10007, {
        request = {
            target_id = "integer",
        }
    })
    
    :protocol("remove_blacklist", 10008, {
        request = {
            target_id = "integer",
        }
    })
    
    :protocol("get_black_list", 10009, {
        request = {}
    })
    
    -- 副本协议 (500-519)
    :protocol("instance_enter", 502, {
        request = {
            inst_id = "string",
        }
    })

    :protocol("instance_exit", 503, {
        request = {
            inst_id = "string",
        }
    })

    :protocol("instance_quit", 504, {
        request = {
            inst_id = "string",
        }
    })

    :protocol("instance_ready", 505, {
        request = {
            inst_id = "string",
        }
    })

    :protocol("instance_match_cancel", 507, {
        request = {}
    })

    :protocol("instance_mode_event", 508, {
        request = {
            inst_id = "string",
            event_type = "string",
            event_value = "integer",
            target_id = "integer",
        }
    })

    :protocol("instance_match_confirm", 509, {
        request = {
            accept = "boolean",         -- true确认，false拒绝
        }
    })

    :protocol("instance_play_start", 522, {
        request = {
            type_name = "string",       -- 统一玩法入口（单人/多人）
        }
    })

    :protocol("talent_activate", 541, {
        request = {
            talent_id = "integer",
        }
    })

    :protocol("barrier_enter", 655, {
        request = {
            barrier_id = "integer",
        }
    })

    :protocol("barrier_settle", 656, {
        request = {
            inst_id = "string",
            success = "boolean",
            stars = "integer",
            progress = "integer",
        }
    })

    :protocol("barrier_claim_chest", 657, {
        request = {
            barrier_id = "integer",
            chest_index = "integer",
        }
    })

    :protocol("rogue_pick_open", 662, {
        request = {
            inst_id = "string",
        }
    })

    :protocol("rogue_pick_refresh", 663, {
        request = {
            inst_id = "string",
        }
    })

    :protocol("rogue_pick_select", 664, {
        request = {
            inst_id = "string",
            choice_index = "integer",
        }
    })

    :protocol("task_accept", 670, {
        request = {
            task_id = "integer",
        }
    })

    :protocol("task_reward", 671, {
        request = {
            task_id = "integer",
        }
    })
    
    -- 邮件系统
    :type("item_info", {
        item_id = "integer",
        count = "integer",
    })
    
    :protocol("get_mail_list", 380, {
        request = {
            page = "integer",
            page_size = "integer",
        }
    })
    
    :protocol("get_mail_detail", 381, {
        request = {
            mail_id = "string",
        }
    })
    
    :protocol("claim_items", 382, {
        request = {
            mail_id = "string",
        }
    })
    
    :protocol("delete_mail", 383, {
        request = {
            mail_id = "string",
        }
    })
    
    :protocol("send_player_mail", 384, {
        request = {
            receiver_id = "integer",
            title = "string",
            content = "string",
            items = "*item_info",
        }
    })
    
    :protocol("mark_mail_read", 385, {
        request = {
            mail_id = "string",
        }
    })

proto.c2s = sprotoparser.parse(c2s_builder:to_string())

-- 注册 C2S 协议 schema（用于验证）
c2s_builder:register_schema("c2s")

-- ========== S2C 协议定义 ==========
local s2c_builder = builder.new()
    :package({
        type = "integer",
        session = "integer",
    })
    
    :protocol("heartbeat", 1, {})
    
    :protocol("error", 3, {
        request = {
            code = "integer",
            message = "string",
        }
    })
    
    :protocol("login_response", 4, {
        request = {
            success = "boolean",
            player_id = "integer",
            player_name = "string",
        }
    })
    
    :type("chat_message", {
        type = "string",
        channel_id = "integer",
        channel_name = "string",
        sender_id = "integer",
        sender_name = "string",
        content = "string",
        timestamp = "integer",
    })
    
    :type("channel_info", {
        id = "string",
        name = "string",
        member_count = "integer",
        create_time = "integer",
    })
    
    :protocol("chat_message", 5, {
        request = "chat_message"  -- 引用类型
    })
    
    :protocol("channel_list", 6, {
        request = {
            channels = "*channel_info",
        }
    })
    
    :protocol("channel_history", 7, {
        request = {
            channel_id = "integer",
            messages = "*chat_message",
        }
    })
    
    :protocol("private_history", 8, {
        request = {
            player_id = "integer",
            messages = "*chat_message",
        }
    })
    
    :protocol("kicked_out", 9, {
        request = {
            reason = "string",
            message = "string",
        }
    })
    
    :protocol("player_data", 10, {
        request = {
            player_id = "integer",
            player_name = "string",
        }
    })
    
    :protocol("login_failed", 11, {
        request = {
            reason = "string",
        }
    })
    
    -- 好友系统响应
    :type("friend_info", {
        player_id = "integer",
        name = "string",
    })
    
    :type("apply_info", {
        player_id = "integer",
        name = "string",
        apply_time = "integer",
        message = "string",
    })
    
    :type("black_list_info", {
        player_id = "integer",
        name = "string",
        time = "integer",
    })
    
    :protocol("add_friend_response", 201, {
        request = {
            result = "integer",
            message = "string",
        }
    })
    
    :protocol("delete_friend_response", 202, {
        request = {
            result = "integer",
            message = "string",
        }
    })
    
    :protocol("agree_apply_response", 203, {
        request = {
            result = "integer",
            message = "string",
            friend_info = "friend_info",
        }
    })
    
    :protocol("reject_apply_response", 204, {
        request = {
            result = "integer",
            message = "string",
        }
    })
    
    :protocol("get_friend_list_response", 205, {
        request = {
            result = "integer",
            friend_list = "*friend_info",
        }
    })
    
    :protocol("get_apply_list_response", 206, {
        request = {
            result = "integer",
            apply_list = "*apply_info",
        }
    })
    
    :protocol("add_blacklist_response", 207, {
        request = {
            result = "integer",
            message = "string",
        }
    })
    
    :protocol("remove_blacklist_response", 208, {
        request = {
            result = "integer",
            message = "string",
        }
    })
    
    :protocol("get_black_list_response", 209, {
        request = {
            result = "integer",
            black_list = "*black_list_info",
        }
    })
    
    :protocol("friend_apply_notify", 211, {
        request = {
            player_id = "integer",
            message = "string",
        }
    })
    
    :protocol("friend_agree_notify", 212, {
        request = {
            friend_info = "friend_info",
        }
    })
    
    :protocol("friend_delete_notify", 213, {
        request = {
            player_id = "integer",
        }
    })
    
    -- 副本响应协议
    :protocol("instance_enter_response", 512, {
        request = {
            result = "integer",
            message = "string",
            inst_id = "string",
            scene_id = "integer",
        }
    })

    :protocol("instance_exit_response", 513, {
        request = {
            result = "integer",
            message = "string",
            inst_id = "string",
        }
    })

    :protocol("instance_quit_response", 514, {
        request = {
            result = "integer",
            message = "string",
            inst_id = "string",
        }
    })

    :protocol("instance_ready_response", 515, {
        request = {
            result = "integer",
            message = "string",
            inst_id = "string",
        }
    })

    :protocol("instance_mode_event_response", 516, {
        request = {
            result = "integer",
            message = "string",
            inst_id = "string",
            event_type = "string",
        }
    })

    :type("instance_match_member_confirm_info", {
        player_id = "integer",
        confirmed = "boolean",
    })

    :protocol("instance_match_success_notify", 519, {
        request = {
            type_name = "string",
            inst_id = "string",
            team_size = "integer",
        }
    })

    :protocol("instance_match_confirm_notify", 520, {
        request = {
            type_name = "string",
            match_id = "string",
            members = "*instance_match_member_confirm_info",
            confirm_deadline = "integer",
        }
    })

    :protocol("instance_play_start_response", 523, {
        request = {
            result = "integer",
            message = "string",
            mode = "string",            -- direct/match
            matched = "boolean",
            pending_confirm = "boolean",
            inst_id = "string",
            scene_id = "integer",
        }
    })
    

    :protocol("instance_play_data_notify", 524, {
        request = {
            inst_id = "string",
            inst_no = "integer",
            status = "integer",
            create_time = "integer",
            start_time = "integer",
            end_time = "integer",
            duration = "integer",
            progress = "integer",
            complete_success = "boolean",
            fail_reason = "string",
            extra = "string",
        }
    })

    :protocol("instance_match_tip_notify", 525, {
        request = {
            type_name = "string",
            message = "string",
        }
    })

    :protocol("instance_match_queue_notify", 526, {
        request = {
            type_name = "string",
            queue_size = "integer",
            team_size = "integer",
        }
    })

    :protocol("instance_result_notify", 527, {
        request = {
            inst_id = "string",
            success = "boolean",
            end_type = "integer",
            end_reason = "integer",
            duration = "integer",
            data = "binary",
        }
    })

    :type("item_info", {
        item_id = "integer",
        count = "integer",
    })

    :type("item_change_info", {
        item_id = "integer",
        delta = "integer",
        count = "integer",
    })

    :protocol("bag_item_list_notify", 653, {
        request = {
            items = "*item_info",
        }
    })

    :protocol("item_update_notify", 651, {
        request = {
            reason = "string",
            changes = "*item_change_info",
        }
    })

    :protocol("show_item_tips", 652, {
        request = {
            tips = "integer", 
            items = "*item_info",
        }
    })

    :protocol("head_upgrade_notify", 654, {
        request = {
            level = "integer",
            exp = "integer",
        }
    })
    
    -- 邮件系统
    :type("mail_info", {
        mail_id = "string",
        title = "string",
        content = "string",
        sender_id = "integer",
        mail_type = "integer",      -- 邮件类型:1=系统邮件,2=玩家邮件,3=公会邮件,4=系统奖励邮件,5=全局邮件
        create_time = "integer",
        expire_time = "integer",
        status = "integer",         -- 邮件状态:0=未读,1=已读
        items_status = "integer",   -- 附件状态:0=未领取,1=已领取
        items = "*item_info",
    })
    
    :protocol("mail_list_response", 330, {
        request = {
            result = "integer",
            mails = "*mail_info",
            unread_count = "integer",
            has_more = "boolean",
            total_count = "integer",
        }
    })
    
    :protocol("mail_detail_response", 331, {
        request = {
            result = "integer",
            mail = "mail_info",
        }
    })
    
    :protocol("claim_items_response", 332, {
        request = {
            result = "integer",
            message = "string",
        }
    })
    
    :protocol("delete_mail_response", 333, {
        request = {
            result = "integer",
            message = "string",
        }
    })
    
    :protocol("send_mail_response", 334, {
        request = {
            result = "integer",
            message = "string",
            mail_id = "string",
        }
    })
    
    :protocol("mark_mail_read_response", 335, {
        request = {
            result = "integer",
            message = "string",
        }
    })
    
    :protocol("new_mail_notify", 336, {
        request = {
            mail = "mail_info",
        }
    })
    
    :protocol("mail_expired_notify", 337, {
        request = {
            mail_ids = "*string",
        }
    })

    :protocol("system_notify", 338, {
        request = {
            message = "string",
        }
    })

    :protocol("talent_info_notify", 542, {
        request = {
            talents = "*integer",
        }
    })

    :protocol("talent_activate_response", 543, {
        request = {
            result = "integer",
            message = "string",
            talent_id = "integer",
            level = "integer",
        }
    })

    :type("barrier_info", {
        barrier_id = "integer",
        name = "string",
        unlocked = "boolean",
        passed = "boolean",
        best_stars = "integer",
        claimed_chests = "*integer",
    })

    :protocol("barrier_enter_response", 658, {
        request = {
            result = "integer",
            message = "string",
            barrier_id = "integer",
            inst_id = "string",
            scene_id = "integer",
            stamina = "integer",
        }
    })

    :protocol("barrier_settle_response", 659, {
        request = {
            result = "integer",
            message = "string",
            barrier_id = "integer",
            success = "boolean",
            stars = "integer",
            progress = "integer",
            best_stars = "integer",
            first_pass = "boolean",
        }
    })

    :protocol("barrier_claim_chest_response", 660, {
        request = {
            result = "integer",
            message = "string",
            barrier_id = "integer",
            chest_index = "integer",
        }
    })

    :protocol("barrier_info_notify", 661, {
        request = {
            stamina = "integer",
            barriers = "*barrier_info",
        }
    })

    :type("rogue_option", {
        ability_id = "integer",
        name = "string",
        icon = "string",
        quality = "integer",
        type = "string",
        effect_id = "integer",
        weapon_id = "integer",
    })

    :type("rogue_picked_entry", {
        ability_id = "integer",
        count = "integer",
    })

    :type("rogue_pending_pick", {
        pick_index = "integer",
        options = "*rogue_option",
    })

    :type("rogue_sync", {
        refresh_id = "integer",
        energy_tier = "integer",
        pick_times = "integer",
        max_picks = "integer",
        energy_needs = "*integer",
        owned_weapon_ids = "*integer",
        picked = "*rogue_picked_entry",
        pending = "rogue_pending_pick",
    })

    :protocol("rogue_pick_notify", 665, {
        request = {
            inst_id = "string",
            pick_index = "integer",
            options = "*rogue_option",
        }
    })

    :protocol("rogue_pick_open_response", 666, {
        request = {
            result = "integer",
            message = "string",
            inst_id = "string",
            pick_index = "integer",
        }
    })

    :protocol("rogue_pick_refresh_response", 667, {
        request = {
            result = "integer",
            message = "string",
            inst_id = "string",
            pick_index = "integer",
        }
    })

    :protocol("rogue_pick_select_response", 668, {
        request = {
            result = "integer",
            message = "string",
            inst_id = "string",
            ability_id = "integer",
            effect_id = "integer",
            pick_times = "integer",
        }
    })

    :protocol("rogue_state_notify", 669, {
        request = {
            inst_id = "string",
            pick_times = "integer",
            picked = "*rogue_picked_entry",
            sync = "rogue_sync",
        }
    })

    :type("task_progress_entry", {
        id = "string",
        value = "integer",
    })

    :type("task_info", {
        task_id = "integer",
        state = "integer",
        accept_time = "integer",
        complete_time = "integer",
        progress = "*task_progress_entry",
    })

    :protocol("task_accept_response", 670, {
        request = {
            result = "integer",
            message = "string",
            task_id = "integer",
            task = "task_info",
        }
    })

    :protocol("task_reward_response", 671, {
        request = {
            result = "integer",
            message = "string",
            task_id = "integer",
        }
    })

    :protocol("task_info_notify", 672, {
        request = {
            tasks = "*task_info",
        }
    })

    :protocol("task_update_notify", 673, {
        request = {
            task = "task_info",
        }
    })

proto.s2c = sprotoparser.parse(s2c_builder:to_string())

-- 注册 S2C 协议 schema（用于验证）
s2c_builder:register_schema("s2c")

return proto
