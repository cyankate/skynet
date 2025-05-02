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

]]

return proto
