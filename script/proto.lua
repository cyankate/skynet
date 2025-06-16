local sprotoparser = require "sprotoparser"

local proto = {}

proto.c2s = sprotoparser.parse [[
.package {
	type 0 : integer
	session 1 : integer
}


get 1 {
	request {
		what 0 : string
	}
}

set 2 {
	request {
		what 0 : string
		value 1 : string
	}
}

login 3 {
	request {
		account_id 0 : string
	}
}

signin 4 {
	request {
		idx 0 : integer
	}
}

add_item 5 {
	request {
		item_id 0 : integer
		count 1 : integer
	}
}

change_name 6 {
	request {
		name 0 : string
	}
}

send_channel_message 7 {
	request {
		channel_id 0 : integer
		content 1 : string
	}
}

send_private_message 8 {
	request {
		to_player_id 0 : integer
		content 1 : string
	}
}

.channel_info {
	id 0 : string
	name 1 : string
	member_count 2 : integer
	create_time 3 : integer
}

get_channel_list 9 {
	request {
	}	
}

.chat_message {
	type 0 : string
	channel_id 1 : integer	
	channel_name 2 : string
	sender_id 3 : integer
	sender_name 4 : string	
	content 5 : string
	timestamp 6 : integer
}

get_channel_history 12 {
	request {
		channel_id 0 : integer
		count 1 : integer
	}
}

get_private_history 13 {
	request {
		player_id 0 : integer
		count 1 : integer
	}
}

add_score 14 {
	request {
		score 0 : integer
	}
}

.friend_info {
	player_id 0 : integer
	name 1 : string
}

.apply_info {
	player_id 0 : integer
	name 1 : string
	apply_time 2 : integer
	message 3 : string
}

add_friend 10001 {
	request {
		target_id 0 : integer
		message 1 : string
	}
}

delete_friend 10002 {
	request {
		target_id 0 : integer
	}
}

agree_apply 10003 {
	request {
		player_id 0 : integer
	}
}

reject_apply 10004 {
	request {
		player_id 0 : integer
	}
}

get_friend_list 10005 {
	request {
	}
}

get_apply_list 10006 {
	request {
	}
}

add_blacklist 10007 {
	request {
		target_id 0 : integer
	}
}

remove_blacklist 10008 {
	request {
		target_id 0 : integer
	}
}

get_black_list 10009 {
	request {
	}
}

# 斗地主协议 (300-349)
landlord_create_room 300 {
	request {
	}
}

landlord_join_room 301 {
	request {
		room_id 0 : integer
	}
}

landlord_leave_room 302 {
	request {
	}
}

landlord_ready 303 {
	request {
	}
}

landlord_play_cards 304 {
	request {
		cards 0 : *string
	}
}

landlord_quick_match 305 {
	request {
	}
}

landlord_cancel_match 306 {
	request {
	}
}

# 麻将协议 (350-399)
mahjong_create_room 350 {
	request {
		mode 0 : integer      # 游戏模式
		base_score 1 : integer  # 底分
	}
}

mahjong_join_room 351 {
	request {
		room_id 0 : integer
	}
}

mahjong_leave_room 352 {
	request {
		room_id 0 : integer
	}
}

mahjong_ready 353 {
	request {
		room_id 0 : integer
	}
}

mahjong_play_tile 354 {
	request {
		room_id 0 : integer
		tile_type 1 : integer
		tile_value 2 : integer
	}
}

mahjong_chi_tile 355 {
	request {
		room_id 0 : integer
		tiles 1 : *integer 
	}
}

mahjong_peng_tile 356 {
	request {
		room_id 0 : integer
	}
}

mahjong_gang_tile 357 {
	request {
		room_id 0 : integer
		tile_type 1 : integer
		tile_value 2 : integer
	}
}

mahjong_hu_tile 358 {
	request {
		room_id 0 : integer
	}
}

mahjong_quick_match 359 {
	request {
		mode 0 : integer      # 游戏模式
		base_score 1 : integer  # 底分
	}
}

mahjong_cancel_match 360 {
	request {
	}
}


get_mail_list 380 {
	request {
		page 0 : integer
		page_size 1 : integer
	}
}

get_mail_detail 381 {
	request {
		mail_id 0 : string
	}
}

claim_items 382 {
	request {
		mail_id 0 : string
	}
}

delete_mail 383 {
	request {
		mail_id 0 : string
	}
}

.item_info {
    item_id 0 : integer
    count 1 : integer
}

send_player_mail 384 {
	request {
		receiver_id 0 : integer
		title 1 : string
		content 2 : string
		items 3 : *item_info  
	}
}

mark_mail_read 385 {
	request {
		mail_id 0 : string
	}
}
]]

proto.s2c = sprotoparser.parse [[
.package {
	type 0 : integer
	session 1 : integer
}

heartbeat 1 {}

error 3 {
	request {
		code 0 : integer
		message 1 : string
	}
}

login_response 4 {
	request {
		success 0 : boolean
		player_id 1 : integer
		player_name 2 : string
	}
}

chat_message 5 {
	request {
		type 0 : string
		channel_id 1 : integer	
		channel_name 2 : string
		sender_id 3 : integer
		sender_name 4 : string	
		content 5 : string
		timestamp 6 : integer
	}
}

channel_list 6 {
	request {
		channels 0 : *channel_info
	}
}

channel_history 7 {
	request {
		channel_id 0 : integer
		messages 1 : *chat_message
	}
}

private_history 8 {
	request {
		player_id 0 : integer
		messages 1 : *chat_message
	}
}

.channel_info {
	id 0 : string
	name 1 : string
	member_count 2 : integer
	create_time 3 : integer
}

.chat_message {
	type 0 : string
	channel_id 1 : integer	
	channel_name 2 : string
	sender_id 3 : integer
	sender_name 4 : string	
	content 5 : string
	timestamp 6 : integer
}

kicked_out 9 {
	request {
		reason 0 : string
		message 1 : string
	}
}

player_data 10 {
	request {
		player_id 0 : integer
		player_name 1 : string
	}
}

login_failed 11 {
	request {
		reason 0 : string
	}
}

.friend_info {
	player_id 0 : integer
	name 1 : string
}

.apply_info {
	player_id 0 : integer
	name 1 : string
	apply_time 2 : integer
	message 3 : string
}

add_friend_response 201 {
	request {
		result 0 : integer
		message 1 : string
	}
}

delete_friend_response 202 {
	request {
		result 0 : integer
		message 1 : string
	}
}

agree_apply_response 203 {
	request {
		result 0 : integer
		message 1 : string
		friend_info 2 : friend_info
	}
}

reject_apply_response 204 {
	request {
		result 0 : integer
		message 1 : string
	}
}

get_friend_list_response 205 {
	request {
		result 0 : integer
		friend_list 1 : *friend_info
	}
}

get_apply_list_response 206 {
	request {
		result 0 : integer
		apply_list 1 : *apply_info
	}
}

add_blacklist_response 207 {
	request {
		result 0 : integer
		message 1 : string
	}
}

remove_blacklist_response 208 {
	request {
		result 0 : integer
		message 1 : string
	}
}

.black_list_info {
	player_id 0 : integer
	name 1 : string
	time 2 : integer
}

get_black_list_response 209 {
	request {
		result 0 : integer
		black_list 1 : *black_list_info
	}
}

friend_apply_notify 211 {
	request {
		player_id 0 : integer
		message 1 : string
	}
}

friend_agree_notify 212 {
	request {
		friend_info 0 : friend_info
	}
}

friend_delete_notify 213 {
	request {
		player_id 0 : integer
	}
}

# 房间信息结构
.room_info {
    room_id 0 : integer
    creator_id 1 : integer
    game_type 2 : integer  # 1:斗地主 2:麻将
    player_count 3 : integer
    status 4 : integer     # 0:等待开始 1:游戏中
    players 5 : *player_info
}

.player_info {
    player_id 0 : integer
    ready 1 : boolean
    seat 2 : integer
    cards_count 3 : integer
}

# 斗地主协议
landlord_game_start_notify 307 {
    request {
        room_id 0 : integer
        players 1 : *player_info
        cards 2 : *string      # 自己的手牌
        landlord_id 3 : integer  # 地主ID
        bottom_cards 4 : *string  # 地主牌
        current_player 5 : integer # 当前出牌玩家
    }
}

landlord_play_cards_notify 308 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        cards 2 : *string
        next_player_id 3 : integer
    }
}

landlord_game_over_notify 309 {
    request {
        room_id 0 : integer
        winner_id 1 : integer
        players 2 : *player_info
        score 3 : integer
    }
}

# 麻将协议
mahjong_game_start_notify 361 {
    request {
        room_id 0 : integer
        players 1 : *player_info
    }
}

mahjong_draw_tile_notify 362 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        tile_type 2 : integer
        tile_value 3 : integer
        remaining_count 4 : integer
    }
}

mahjong_play_tile_notify 363 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        tile_type 2 : integer
        tile_value 3 : integer
        next_player_id 4 : integer
    }
}

mahjong_chi_tile_notify 364 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        tiles 2 : *integer
        next_player_id 3 : integer
    }
}

mahjong_peng_tile_notify 365 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        tile_type 2 : integer
        tile_value 3 : integer
        next_player_id 4 : integer
    }
}

mahjong_gang_tile_notify 366 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        tile_type 2 : integer
        tile_value 3 : integer
        next_player_id 4 : integer
    }
}

mahjong_hu_tile_notify 367 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        win_type 2 : integer 
        score 3 : integer
    }
}

mahjong_game_over_notify 368 {
    request {
        room_id 0 : integer
        winner_id 1 : integer
        players 2 : *player_info
    }
}

# 斗地主协议
landlord_join_notify 320 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        players 2 : *player_info
    }
}

landlord_leave_notify 321 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        players 2 : *player_info
    }
}

landlord_ready_notify 322 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        players 2 : *player_info
    }
}

landlord_player_offline_notify 315 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        players 2 : *player_info
    }
}

landlord_player_reconnect_notify 316 {
    request {
        room_id 0 : integer
        player_id 1 : integer
        players 2 : *player_info
    }
}

landlord_game_state_notify 317 {
    request {
        room_id 0 : integer
        status 1 : integer
        players 2 : *player_info
        cards 3 : *string          # 自己的手牌
        landlord_id 4 : integer    # 地主ID
        bottom_cards 5 : *string   # 地主牌
        current_player 6 : integer # 当前出牌玩家
        last_cards 7 : *string     # 上一次出的牌
        last_player 8 : integer    # 上一次出牌的玩家
    }
}

.mail_info {
    mail_id 0 : string
    title 1 : string
    content 2 : string
    sender_id 3 : integer
    mail_type 4 : integer      # 邮件类型:1=系统邮件,2=玩家邮件,3=公会邮件,4=系统奖励邮件,5=全局邮件
    create_time 5 : integer
    expire_time 6 : integer
    status 7 : integer         # 邮件状态:0=未读,1=已读
    items_status 8 : integer   # 附件状态:0=未领取,1=已领取
    items 9 : *item_info      # 附件
}

.item_info {
    item_id 0 : integer
    count 1 : integer
}

mail_list_response 330 {
    request {
        result 0 : integer
        mails 1 : *mail_info
        unread_count 2 : integer
        has_more 3 : boolean
        total_count 4 : integer
    }
}

mail_detail_response 331 {
    request {
        result 0 : integer
        mail 1 : mail_info
    }
}

claim_items_response 332 {
    request {
        result 0 : integer
        message 1 : string
    }
}

delete_mail_response 333 {
    request {
        result 0 : integer
        message 1 : string
    }
}

send_mail_response 334 {
    request {
        result 0 : integer
        message 1 : string
        mail_id 2 : string
    }
}

mark_mail_read_response 335 {
    request {
        result 0 : integer
        message 1 : string
    }
}

new_mail_notify 336 {
    request {
        mail 0 : mail_info
    }
}

mail_expired_notify 337 {
    request {
        mail_ids 0 : *string
    }
}
]]

return proto
