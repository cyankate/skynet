package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local manager = require "skynet.manager"
local log = require "log"
local score_rank = require "rank.score_rank"

local CMD = {}
local ranks = {}

function init_rank()
    local rank = score_rank.new("test")
    ranks["score"] = rank
    rank.loaded_ = true 
    -- for k = 1, 3 do 
    --     local data = {
    --         key = "name" .. k,
    --         score = math.random(1, 100),
    --     }
    --     rank:insert(data)
    --     skynet.sleep(10)
    -- end 

    local data1 = {
        key = "name1",
        score = 75,
    }
    rank:insert(data1)
    skynet.sleep(10)

    local data2 = {
        key = "name2",
        score = 63,
    }
    rank:insert(data2)
    skynet.sleep(10)

    local data3 = {
        key = "name3",
        score = 20,
    }
    rank:insert(data3)
    skynet.sleep(10)

    local data4 = {
        key = "name4",
        score = 50,
    }
    rank:insert(data4)

    local data5 = {
        key = "name5",
        score = 50,
    }
    rank:insert(data5)
    
    rank:print()

    local data = {
        key = "name4",
        score = 2,
    }
    rank:insert(data)
    rank:print()
end 

function CMD.update_rank(_data)
    log.info(string.format("Updating rank for player %s"))
    -- 这里可以添加更新排名的逻辑
    -- 例如将 rank_data 保存到数据库
    return true
end

function CMD.get_rank(player_id)
    log.info(string.format("Getting rank for player %s", player_id))
    -- 这里可以添加获取排名的逻辑
    -- 例如从数据库中查询排名数据
    local rank_data = {
        rank = 1,
        score = 1000,
    }
    return rank_data
end

function CMD.get_rank_list()
    log.info("Getting rank list")
    -- 这里可以添加获取排名列表的逻辑
    -- 例如从数据库中查询排名数据
    local rank_list = {
        { player_id = 1, score = 1000 },
        { player_id = 2, score = 900 },
        { player_id = 3, score = 800 },
    }
    return rank_list
end

function load_rank()

end 


skynet.start(function()
    log.info("Rank module started")

    skynet.register(".rank")
    
    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        else
            log.error(string.format("Unknown command %s", cmd))
        end
    end)
    init_rank()
end)