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
	response {
		channels 0 : *channel_info
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

]]

return proto
