-- 门上行直连白名单：协议名 => 目标服务名（走 rpc.named_addr 解析）。
-- 默认空表：所有 C2S 仍 redirect 给 agent。
--
-- 开启某个协议前必须满足：
--   1. 目标服务能独立处理该协议，并通过门回包（gate.send_message / rpc_response）；
--   2. 该协议不再依赖 agent 维护的玩家缓存，否则 agent 侧缓存会过期。
--
-- 值也可以写成函数：["map_move"] = function(player_id) return ".shard.1001.1" end
return {
}
