local sprotoparser = require "sprotoparser"

local proto = {}

proto.c2s = sprotoparser.parse [[
.package {
	type 0 : integer
	session 1 : integer
}

handshake 1 {
	response {
		msg 0  : string
	}
}

get 2 {
	request {
		what 0 : string
	}
	response {
		result 0 : string
	}
}

set 3 {
	request {
		what 0 : string
		value 1 : string
	}
}

quit 4 {}

login 5 {
	request {
		account_id 0 : string
	}
}

signin 6 {
	request {
		idx 0 : integer
	}
}

add_item 7 {
	request {
		idx 0 : integer
	}
}

change_name 8 {
	request {
		idx 0 : integer
	}
}

send_channel_message 9 {
	request {
		channel_id 0 : string
		content 1 : string
	}
}

send_private_message 10 {
	request {
		to_player_id 0 : integer
		content 1 : string
	}
}

get_channel_list 11 {}

join_channel 12 {
	request {
		channel_id 0 : string
	}
}

leave_channel 13 {
	request {
		channel_id 0 : string
	}
}

get_channel_history 14 {
	request {
		channel_id 0 : string
		count 1 : integer
	}
}

get_private_history 15 {
	request {
		player_id 0 : integer
		count 1 : integer
	}
}

]]

proto.s2c = sprotoparser.parse [[
.package {
	type 0 : integer
	session 1 : integer
}

heartbeat 1 {}

detail 2 {
	response {
		name 0 : string
	}
}

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
		channel_id 1 : string
		from_id 2 : integer
		from_name 3 : string
		to_id 4 : integer
		to_name 5 : string
		content 6 : string
		timestamp 7 : integer
	}
}

channel_list 6 {
	request {
		channels 0 : *channel_info
	}
}

channel_history 7 {
	request {
		channel_id 0 : string
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
	channel_id 1 : string
	from_id 2 : integer
	from_name 3 : string
	to_id 4 : integer
	to_name 5 : string
	content 6 : string
	timestamp 7 : integer
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

]]

return proto
