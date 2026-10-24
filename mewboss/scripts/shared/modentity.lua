--[[
    ModEntity —— 自定义实体的轻量句柄
]]

local ModEntity = {}
ModEntity.__index = ModEntity

function ModEntity:NewData()
    return {
        StateTime = 0,
        Phase = 1,
    }
end

--- 创建一个实体句柄
function ModEntity.new(displayName, dataKey)
    local self = setmetatable({}, ModEntity)

    self.Name = displayName
    self.DataKey = dataKey or displayName

    self.Type = Isaac.GetEntityTypeByName(displayName)
    self.Variant = Isaac.GetEntityVariantByName(displayName)

    if not self.Type or self.Type == 0 then
        error(("[ModEntity] 实体未注册: %q —— 检查 content/entities2.xml 的 name 是否一致，"
               .. "或是否忘了重启游戏（改 XML 后 luamod 不会重新读取）"):format(displayName))
    end

    return self
end

--- 取本实体的每实例数据表
function ModEntity:GetData(ent, init)
    local store = ent:GetData()
    local key = self.DataKey

    if store[key] == nil and init then
        store[key] = self:NewData()
    end
    return store[key]
end

--- 删除本实体的数据
function ModEntity:ClearData(ent)
    ent:GetData()[self.DataKey] = nil
end

--- 注册一个带本实体类型过滤的回调。
function ModEntity:AddNpcCallback(mod, callbackId, fn)
    mod:AddCallback(callbackId, fn, self.Type)
end

--- 把本实体的所有实例收集成列表
function ModEntity:GetAll()
    return Isaac.FindByType(self.Type, self.Variant, -1, false, false)
end

return ModEntity
