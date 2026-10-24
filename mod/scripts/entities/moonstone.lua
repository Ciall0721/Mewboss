-- 石头弹：共用弹丸与障碍物破坏

local ModEntity = require("scripts.shared.modentity")
local Attacks   = require("scripts.shared.attacks")

local GRID = 40

local Stone = ModEntity.new("Moon Stone", "MoonStone")

local P = {
    ShatterFrames   = 2,
    ShatterVariants = 8,
}

-- 可被石头子弹打碎的网格障碍
local DESTRUCTIBLE_GRID = {
    [GridEntityType.GRID_POOP]         = true,
    [GridEntityType.GRID_ROCK]         = true,
    [GridEntityType.GRID_ROCK_ALT]     = true,
    [GridEntityType.GRID_ROCK_ALT2]    = true,
    [GridEntityType.GRID_ROCK_BOMB]    = true,
    [GridEntityType.GRID_ROCK_GOLD]    = true,
    [GridEntityType.GRID_ROCK_SPIKED]  = true,
    [GridEntityType.GRID_ROCK_SS]      = true,
    [GridEntityType.GRID_ROCKT]        = true,
    [GridEntityType.GRID_TNT]          = true,
}

local destroyOwners = {}
local registered = false

local function shatter(proj)
    local d = proj:GetData()
    if d.ShatterAt then return end
    d.ShatterAt = Game():GetFrameCount() + P.ShatterFrames
    proj.Velocity = Vector.Zero
    proj.CollisionDamage = 0

    local spr = proj:GetSprite()
    local variant = Random() % P.ShatterVariants
    spr:Play("Broken" .. variant, true)
end

local function destroyOneObstacleNear(room, pos, radius)
    local idx = room:GetGridIndex(pos)
    if idx < 0 then return false end

    local gw, gh = room:GetGridWidth(), room:GetGridHeight()
    local cx, cy = idx % gw, math.floor(idx / gw)
    local span  = math.max(1, math.ceil(radius / GRID))
    local reach = radius + GRID * 0.5

    for dy = -span, span do
        for dx = -span, span do
            local x, y = cx + dx, cy + dy
            if x >= 0 and x < gw and y >= 0 and y < gh then
                local cell = y * gw + x
                local ge = room:GetGridEntity(cell)
                -- 已摧毁的便便残骸（PoopState 1000）不算障碍
                local deadPoop = ge
                    and ge:GetType() == GridEntityType.GRID_POOP
                    and (ge.State or 0) >= 1000
                if ge and not deadPoop and DESTRUCTIBLE_GRID[ge:GetType()]
                   and pos:Distance(room:GetGridPosition(cell)) <= reach then
                    ge:Destroy(false)
                    return true
                end
            end
        end
    end
    return false
end

local function keepStoneAnim(_, proj)
    if proj.Variant ~= Stone.Variant then return end
    local d = proj:GetData()

    if d.ShatterAt then
        proj.Velocity = Vector.Zero
        if Game():GetFrameCount() >= d.ShatterAt then
            proj:Remove()
        end
        return
    end

    if d.MewDieAt and Game():GetFrameCount() >= d.MewDieAt then
        shatter(proj)
        return
    end

    local owner = proj.SpawnerEntity
    if owner and destroyOwners[owner.Type] then
        local room = Game():GetRoom()
        local r = (proj.Size or 7) + 4
        if destroyOneObstacleNear(room, proj.Position, r)
           or destroyOneObstacleNear(room,
                                     proj.Position + proj.Velocity * 1.5, r) then
            shatter(proj)
            return
        end
    end

    local spr = proj:GetSprite()
    if not spr:IsPlaying("Flight") then
        spr:Play("Flight", true)
    end
end

local M = {
    Entity               = Stone,
    Variant              = Stone.Variant,
    DESTRUCTIBLE_GRID    = DESTRUCTIBLE_GRID,
    Shatter              = shatter,
    DestroyOneObstacleNear = destroyOneObstacleNear,
}

function M.EnableObstacleDestruction(entityType)
    destroyOwners[entityType] = true
end

function M.Register(mod)
    if registered then return end
    registered = true

    Attacks.EnableInfiniteRangeVariant(Stone.Variant)
    mod:AddCallback(ModCallbacks.MC_POST_PROJECTILE_UPDATE, keepStoneAnim)
end

return M
