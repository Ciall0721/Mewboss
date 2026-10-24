-- 弹幕构造与无限射程工具

local Attacks = {}

local MODE = {
    ONE_PROJECTILE               = 0,
    TWO_PROJECTILES              = 1,
    THREE_PROJECTILES            = 2,
    THREE_PROJECTILES_SPREAD     = 3,
    FOUR_PROJECTILES             = 4,
    FIVE_PROJECTILES             = 5,
    FOUR_PROJECTILES_PLUS_PATTERN= 6,
    FOUR_PROJECTILES_X_PATTERN   = 7,
    EIGHT_PROJECTILES_STAR_PATTERN = 8,
    N_PROJECTILES_IN_CIRCLE      = 9,
}

--- 构造弹幕参数
function Attacks.Params(opts)
    opts = opts or {}
    local p = ProjectileParams()

    p.Variant     = opts.variant or ProjectileVariant.PROJECTILE_TEAR
    p.BulletFlags = opts.flags or 0
    p.Scale       = opts.scale or 1

    if opts.spread       then p.Spread = opts.spread end
    if opts.height       then p.HeightModifier = opts.height end
    if opts.fallingSpeed then p.FallingSpeedModifier = opts.fallingSpeed end
    if opts.fallingAccel then p.FallingAccelModifier = opts.fallingAccel end
    if opts.gridCollision ~= nil then
        p.GridCollision = (opts.gridCollision == true)
    end

    return p
end

-- 无限射程
local infiniteRangeSpawners = {}
local infiniteVariants = {}
local infiniteRangeRegistered = false

-- 冻结下坠
local function freezeFall(proj)
    local d = proj:GetData()
    if d.MewFixedHeight == nil then
        d.MewFixedHeight = proj.Height
    end
    proj.FallingSpeed = 0
    proj.FallingAccel = 0
    proj.Height = d.MewFixedHeight
end

function Attacks.EnableInfiniteRange(mod, entityType)
    infiniteRangeSpawners[entityType] = true

    if infiniteRangeRegistered then return end
    infiniteRangeRegistered = true

    mod:AddCallback(ModCallbacks.MC_POST_PROJECTILE_UPDATE, function(_, proj)
        if not infiniteRangeSpawners[proj.SpawnerType]
           and not infiniteVariants[proj.Variant] then
            return
        end
        freezeFall(proj)
    end)
end

function Attacks.FreezeFallIfEnabled(proj)
    if infiniteRangeSpawners[proj.SpawnerType]
       or infiniteVariants[proj.Variant] then
        freezeFall(proj)
    end
end

function Attacks.EnableInfiniteRangeVariant(variant)
    infiniteVariants[variant] = true
end

local function applyToFreshProjectiles(npc, variant, damage, scale)
    local npcHash = GetPtrHash(npc)
    for _, ent in ipairs(Isaac.FindByType(EntityType.ENTITY_PROJECTILE, variant, -1, false, false)) do
        if ent.FrameCount == 0 and ent.SpawnerEntity
           and GetPtrHash(ent.SpawnerEntity) == npcHash then
            local proj = ent:ToProjectile()
            if proj then
                if damage then proj.CollisionDamage = damage end
                if scale  then proj.Scale = scale end
                Attacks.FreezeFallIfEnabled(proj)
            end
        end
    end
end

--- 扇形弹幕
function Attacks.FanAtTarget(npc, num, targetPos, trajMod, params, damage)
    npc:FireBossProjectiles(num, targetPos, trajMod or 0, params)
    applyToFreshProjectiles(npc, params.Variant, damage)
end

-- 直线射击
function Attacks.StraightShot(npc, targetPos, speed, params, damage)
    local delta = targetPos - npc.Position
    if delta:Length() < 0.001 then return end

    local vel = delta:Normalized() * speed
    npc:FireProjectiles(npc.Position, vel, MODE.ONE_PROJECTILE, params)
    applyToFreshProjectiles(npc, params.Variant, damage)
end

--- 清掉某个 BOSS 召唤出来的全部随从
function Attacks.ClearMinions(data)
    if not data.minions then return end
    for _, m in ipairs(data.minions) do
        if m and m.Exists and m:Exists() then
            m:Remove()
        end
    end
    data.minions = nil
end

return Attacks
