local class = require "utils.class"

---@class MinHeap
---@field items table 堆数组
---@field compare_fn function 比较函数
---@field item_positions table 元素位置映射表
local MinHeap = class("MinHeap")

---创建最小堆实例
---@param compare_fn function 比较函数，默认为小于比较
function MinHeap:ctor(compare_fn)
    self.items = {}
    self.compare_fn = compare_fn or function(a, b) return a < b end
    self.item_positions = {}  -- 用于快速定位元素位置
end

---获取堆大小
---@return number 堆中元素数量
function MinHeap:size()
    return #self.items
end

---检查堆是否为空
---@return boolean 是否为空
function MinHeap:empty()
    return self:size() == 0
end

---添加元素到堆中
---@param item table 要添加的元素，必须包含id字段
function MinHeap:push(item)
    if not item.id then
        error("Item must have an id field")
    end
    table.insert(self.items, item)
    self.item_positions[item.id] = #self.items
    self:sift_up(#self.items)
end

---从堆顶移除并返回最小元素
---@return table|nil 堆顶元素，如果堆为空则返回nil
function MinHeap:pop()
    if self:empty() then return nil end
    
    local result = self.items[1]
    self.item_positions[result.id] = nil
    
    -- 将最后一个元素移到根节点
    self.items[1] = self.items[#self.items]
    if not self:empty() then
        self.item_positions[self.items[1].id] = 1
    end
    table.remove(self.items)
    
    if #self.items > 1 then
        self:sift_down(1)
    end
    
    return result
end

---更新指定ID元素的优先级
---@param id any 元素ID
---@param new_score number 新的优先级分数
function MinHeap:update_key(id, new_score)
    local pos = self.item_positions[id]
    if not pos then return end
    
    local old_score = self.items[pos].f_score
    self.items[pos].f_score = new_score
    
    if new_score < old_score then
        self:sift_up(pos)
    else
        self:sift_down(pos)
    end
end

---向上调整堆
---@param pos number 开始调整的位置
function MinHeap:sift_up(pos)
    local parent = math.floor(pos / 2)
    while parent > 0 and self.compare_fn(self.items[pos], self.items[parent]) do
        -- 交换元素
        self.items[pos], self.items[parent] = self.items[parent], self.items[pos]
        self.item_positions[self.items[pos].id] = pos
        self.item_positions[self.items[parent].id] = parent
        pos = parent
        parent = math.floor(pos / 2)
    end
end

---向下调整堆
---@param pos number 开始调整的位置
function MinHeap:sift_down(pos)
    local size = #self.items
    while true do
        local smallest = pos
        local left = 2 * pos
        local right = 2 * pos + 1
        
        if left <= size and self.compare_fn(self.items[left], self.items[smallest]) then
            smallest = left
        end
        if right <= size and self.compare_fn(self.items[right], self.items[smallest]) then
            smallest = right
        end
        
        if smallest == pos then break end
        
        -- 交换元素
        self.items[pos], self.items[smallest] = self.items[smallest], self.items[pos]
        self.item_positions[self.items[pos].id] = pos
        self.item_positions[self.items[smallest].id] = smallest
        pos = smallest
    end
end

---获取堆顶元素但不移除
---@return table|nil 堆顶元素，如果堆为空则返回nil
function MinHeap:peek()
    if self:empty() then return nil end
    return self.items[1]
end

---检查堆的有效性
---@return boolean 堆是否有效
function MinHeap:is_valid()
    for i = 1, math.floor(#self.items / 2) do
        local left = 2 * i
        local right = 2 * i + 1
        
        if left <= #self.items and self.compare_fn(self.items[left], self.items[i]) then
            return false
        end
        if right <= #self.items and self.compare_fn(self.items[right], self.items[i]) then
            return false
        end
    end
    return true
end

---清空堆
function MinHeap:clear()
    self.items = {}
    self.item_positions = {}
end

return MinHeap 