local MonsterEntity = require "scene.monster_entity"
local class = require "utils.class"

local Wolf = class("Wolf", MonsterEntity)

function Wolf:ctor(id, monster_data)
    -- 设置狼的默认属性
    monster_data = monster_data or {}
    monster_data.name = monster_data.name or "野狼"
    monster_data.level = monster_data.level or 1
    monster_data.hp = monster_data.hp or 100
    monster_data.max_hp = monster_data.max_hp or 100
    monster_data.attack = monster_data.attack or 15
    monster_data.defense = monster_data.defense or 5
    monster_data.speed = monster_data.speed or 3
    monster_data.patrol_radius = monster_data.patrol_radius or 8
    monster_data.attack_radius = monster_data.attack_radius or 1.2
    monster_data.view_range = monster_data.view_range or 10
    monster_data.exp_reward = monster_data.exp_reward or 20
    
    -- 狼的技能
    monster_data.skills = {
        [1] = {
            id = 1,
            name = "撕咬",
            damage = 25,
            range = 1.2,
            cooldown = 5
        },
        [2] = {
            id = 2,
            name = "嚎叫",
            range = 5,
            cooldown = 15,
            effect = "增加周围狼群攻击力"
        }
    }
    
    Wolf.super.ctor(self, id, monster_data)
    
    -- 狼的特殊属性
    self.pack_bonus = false  -- 是否获得狼群增益
    self.howl_bonus = 1.0   -- 嚎叫增益倍率
end

-- 重写技能施放
function Wolf:cast_skill(skill, target)
    if skill.id == 1 then  -- 撕咬
        -- 造成额外伤害
        local damage = skill.damage * self.howl_bonus
        target:take_damage(damage, self)
        
        -- 广播技能效果
        self:broadcast_message("monster_skill", {
            monster_id = self.id,
            skill_id = skill.id,
            target_id = target.id,
            damage = damage
        })
        
    elseif skill.id == 2 then  -- 嚎叫
        -- 获取范围内的所有狼
        local wolves = self:get_surrounding_entities_by_type("Wolf", skill.range)
        
        -- 为所有狼增加攻击力
        for _, wolf in ipairs(wolves) do
            wolf.howl_bonus = 1.5  -- 增加50%伤害
            
            -- 广播技能效果
            self:broadcast_message("monster_skill", {
                monster_id = self.id,
                skill_id = skill.id,
                target_id = wolf.id,
                effect = "howl_bonus"
            })
            
            -- 15秒后恢复
            self.scene:add_timer(1500, function()
                if wolf and not wolf.dead then
                    wolf.howl_bonus = 1.0
                    
                    -- 广播效果结束
                    self:broadcast_message("monster_skill_end", {
                        monster_id = self.id,
                        skill_id = skill.id,
                        target_id = wolf.id
                    })
                end
            end)
        end
    end
end

-- 重写更新函数以处理狼群增益
function Wolf:update()
    Wolf.super.update(self)
    
    -- 检查附近是否有其他狼
    if not self.pack_bonus then
        local nearby_wolves = self:get_surrounding_entities_by_type("Wolf", 5)
        if #nearby_wolves >= 3 then  -- 至少3只狼形成狼群
            self.pack_bonus = true
            self.attack = self.attack * 1.2  -- 增加20%攻击力
            
            -- 广播获得增益效果
            self:broadcast_message("monster_buff", {
                monster_id = self.id,
                buff_type = "pack_bonus",
                attack = self.attack
            })
        end
    else
        -- 检查是否失去狼群增益
        local nearby_wolves = self:get_surrounding_entities_by_type("Wolf", 6)
        if #nearby_wolves < 3 then
            self.pack_bonus = false
            self.attack = self.attack / 1.2  -- 恢复原始攻击力
            
            -- 广播失去增益效果
            self:broadcast_message("monster_debuff", {
                monster_id = self.id,
                buff_type = "pack_bonus",
                attack = self.attack
            })
        end
    end
end

-- 重写死亡处理
function Wolf:on_death(killer)
    -- 调用父类的死亡处理
    Wolf.super.on_death(self, killer)
    
    -- 掉落物品
    local drops = {
        {id = "wolf_pelt", chance = 0.8},
        {id = "wolf_fang", chance = 0.4},
        {id = "wolf_meat", chance = 0.6}
    }
    
    for _, drop in ipairs(drops) do
        if math.random() < drop.chance then
            self.scene:create_item(drop.id, self.x, self.y)
        end
    end
    
    -- 通知附近的狼
    local nearby_wolves = self:get_surrounding_entities_by_type("Wolf", 8)
    for _, wolf in ipairs(nearby_wolves) do
        if wolf ~= self then
            -- 其他狼有50%概率逃跑
            if math.random() < 0.5 then
                wolf.hp = wolf.hp * 0.5  -- 减少生命值以触发逃跑行为
            end
        end
    end
end

-- 获取指定类型的周围实体
function Wolf:get_surrounding_entities_by_type(type_name, range)
    local result = {}
    local surrounding = self:get_surrounding_entities()
    
    for _, entity in pairs(surrounding) do
        if entity.type == type_name then
            local dx = entity.x - self.x
            local dy = entity.y - self.y
            local distance = math.sqrt(dx * dx + dy * dy)
            
            if distance <= range then
                table.insert(result, entity)
            end
        end
    end
    
    return result
end

return Wolf 