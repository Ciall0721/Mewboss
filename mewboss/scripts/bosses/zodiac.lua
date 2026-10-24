--[[
    Zodiac

    机制:
        * 玩家与它之间没有障碍时进入蓄力：
          警戒区亮起
          朝锁定方向打出高弹速子弹。
        * 连线被挡时不蓄力，寻路追击，直到再次出现干净连线。
        * 弹药上限 6，每发扣 1；打空后 5 秒装填，期间不可移动不可攻击
        * 生命 200，碰撞伤害半颗心

]]

local ModEntity = require("scripts.shared.modentity")
local SM        = require("scripts.shared.statemachine")
local Attacks   = require("scripts.shared.attacks")
local Zone      = require("scripts.shared.zone")
local U         = require("scripts.shared.util")
local Bgm       = require("scripts.shared.bgm")

local Zodiac = ModEntity.new("Zodiac", "Zodiac")

local Bullet = ModEntity.new("Zodiac Bullet", "ZodiacBullet")

local SND = {
    Shoot      = Isaac.GetSoundIdByName("Zodiac Shoot"),
    ShootVocal = Isaac.GetSoundIdByName("Zodiac Shoot Vocal"),
    Empty      = Isaac.GetSoundIdByName("Zodiac Empty"),
    Reload     = Isaac.GetSoundIdByName("Zodiac Reload"),
    Dying      = Isaac.GetSoundIdByName("Zodiac Dying"),
    DyingVocal = Isaac.GetSoundIdByName("Zodiac Dying Vocal"),
}

local playSnd = U.playSnd

-- 预热自定义音效。
local function prewarmSounds()
    for _, id in ipairs({ SND.Shoot, SND.ShootVocal, SND.Empty, SND.Reload,
                          SND.Dying, SND.DyingVocal }) do
        playSnd(id, 0.0)
    end
end

-- 专属 BGM
local BGM_NAME = "Zodiac Desert Boss"

-- 死亡时播死亡音效、淡出 BGM、3 秒后恢复房间原曲。

local function beginDeath(data)
    if data.DeathSfx then return end
    data.DeathSfx = true

    playSnd(SND.Dying)
    playSnd(SND.DyingVocal)

    Bgm.StopEnforce()
    MusicManager():Fadeout()
    Bgm.RestoreAfterMs(3000)
end


-- ============================================================ 参数区
Zodiac.Params = {
    -- 移动 / 射击（已按需求 ×5）
    MoveSpeed    = 3.333,   -- 0.5 格/秒 ×5 = 2.5 格/秒
    BulletSpeed  = 20.0,    -- 1 秒 3 格 ×5 = 15 格/秒
    BulletDamage = 2.0,     -- 1 颗心

    AimTrackFrames = 30,    -- 动画前 30 帧（= 整段蓄力的一半）跟踪，之后锁定


    ChargeMinMs  = 1000,
    ChargeMaxMs  = 2000,
    ChargeAnimMs = 2000,    -- Attack 动画在 PlaybackSpeed=1 时的时长

    AppearFrames = 24,

    ChargeFrames = 600,
    ReloadFrames = 600,
    EmptyFrames  = 600,

    -- 弹药
    MaxAmmo      = 6,

    -- 血量低时，常态动画换成 LowHealth。
    LowHealthThreshold = 0.33,

    KeepDistance = 20,

    AvoidProbe = 48,

    -- 站在危险格（石头/尖刺/火堆）上时，每帧朝空格挪动。
    HazardEscapeMax = 1.5,

    -- 装填期间不可移动
    MoveWhileCharging = false,

    AimDirections = 12,
}

-- ============================================================ 状态
local S = {
    APPEAR = 1,
    IDLE   = 2,   -- 没有目标时的待机
    MOVE   = 3,   -- 追击
    CHARGE = 4,   -- 蓄力
    EMPTY  = 5,   -- 空枪
    RELOAD = 6,   -- 装填
}
Zodiac.States = S

function Zodiac:NewData()
    return {
        State     = S.APPEAR,
        StateTime = 0,
        Ammo      = self.Params.MaxAmmo,   -- 初始满弹
        Fired     = false, 
        ZoneHeat  = 0,                     -- 警戒线亮度：0=完全透明 1=红
        AimPos    = nil,                   -- 锁定的瞄准点
        AimDir    = nil,                   -- 锁定的方向
        ChargeSpeed = 1.0,                 -- 本次蓄力的动画播放速度
        minions   = nil,
    }
end

-- ============================================================ 预警区渲染
-- 用原版牵引光束美术
local zoneRenderer = nil
local function getZone()
    if not zoneRenderer then
        zoneRenderer = Zone.new()
    end
    return zoneRenderer
end

-- ============================================================ 工具
local function idleAnim(npc, data)
    local maxHp = data.maxHp or npc.MaxHitPoints
    if maxHp and maxHp > 0
       and npc.HitPoints / maxHp <= Zodiac.Params.LowHealthThreshold then
        return "LowHealth"
    end
    return "Idle"
end

-- 状态 -> 动画
local function setState(npc, data, state)
    SM.SetState(npc, data, state)

    local spr = npc:GetSprite()
    if state == S.APPEAR then
        spr:Play(idleAnim(npc, data), true)
    elseif state == S.IDLE then
        spr:Play(idleAnim(npc, data))
    elseif state == S.MOVE then
        spr:Play("Walk")
    elseif state == S.CHARGE then
        spr:Play("Attack", true)
    elseif state == S.EMPTY then
        spr:Play("AttackEmpty", true)
        playSnd(SND.Empty)
    elseif state == S.RELOAD then
        spr:Play("Reload", true)
    end

    if state == S.MOVE then
        spr.PlaybackSpeed = 1.5
    elseif state == S.CHARGE then
        spr.PlaybackSpeed = data.ChargeSpeed or 1.0
    else
        spr.PlaybackSpeed = 1.0
    end
end

local function safeTarget(ent)
    local npc = ent:ToNPC()
    if not npc then return nil end

    local t = npc:GetPlayerTarget()
    if t and t.Exists and t:Exists() then
        return t
    end
    return nil
end

-- 蓄力判定：方向不限
local function aimDir(delta)
    if delta:Length() < 40 then return nil end
    return delta:Normalized()
end

local function getAlignment(room, npc, target)
    local delta = target.Position - npc.Position
    local dist = delta:Length()

    local dir = aimDir(delta)
    if not dir then return nil end

    if not SM.HasClearLine(room, npc.Position, npc.Position + dir * dist) then
        return nil
    end

    return { dir = dir, dist = dist }
end

-- ============================================================ 危险格判定
local function isHazardCell(room, idx, fireCells)
    if idx < 0 then return false end
    if SM.IsBlockedCell(room, idx) then return true end
    return fireCells ~= nil and fireCells[idx] == true
end

-- ============================================================ 射击

local function tryFire(npc, data, room)
    local target = safeTarget(npc)
    if not target then return false end

    if not data.AimPos then
        data.AimDir = data.AimDir or Vector(1, 0)
        data.AimPos = npc.Position + data.AimDir * 2000
    end

    local params = Attacks.Params({
        variant      = Bullet.Variant,
        scale        = 1.5,
        spread       = 0,
        fallingSpeed = 0,
        fallingAccel = 0,
    })

    Attacks.StraightShot(npc, data.AimPos,
                         Zodiac.Params.BulletSpeed, params,
                         Zodiac.Params.BulletDamage)

    playSnd(SND.Shoot)
    return true
end

-- ============================================================ 回调

local function onInit(_, npc)
    local data = Zodiac:GetData(npc, true)
    data.Ammo  = Zodiac.Params.MaxAmmo
    data.maxHp = npc.MaxHitPoints        -- 低血量动画切换

    npc:SetSize(13.2, Vector(1, 1), 12)

    setState(npc, data, S.APPEAR)

    Bgm.Enforce(BGM_NAME, 8000)
    prewarmSounds()
end

local function onUpdate(_, npc)
    local data = Zodiac:GetData(npc, true)
    local spr  = npc:GetSprite()
    local room = Game():GetRoom()
    local P    = Zodiac.Params

    -- 死亡：死亡音效
    if npc.HitPoints <= 0 then
        beginDeath(data)
        return
    end

    local simSpeed = 1
    if npc:HasEntityFlags(EntityFlag.FLAG_SLOW) then
        simSpeed = 0.5
    end
    SM.Tick(data, simSpeed)


    -- ---------- 不站在危险格上 ----------
    local fireCells = {}
    for _, ent in ipairs(Isaac.GetRoomEntities()) do
        if ent.Type == EntityType.ENTITY_FIREPLACE then
            local i = room:GetGridIndex(ent.Position)
            if i >= 0 then fireCells[i] = true end
        end
    end

    do
        local myIdx = room:GetGridIndex(npc.Position)
        if isHazardCell(room, myIdx, fireCells) then
            -- 已经站在危险格上：朝最近的安全格挪一步
            local gw, gh = room:GetGridWidth(), room:GetGridHeight()
            local cx, cy = myIdx % gw, math.floor(myIdx / gw)
            local bestPos, bestD = nil, math.huge

            for dy = -1, 1 do
                for dx = -1, 1 do
                    if dx ~= 0 or dy ~= 0 then
                        local nx, ny = cx + dx, cy + dy
                        if nx >= 0 and nx < gw and ny >= 0 and ny < gh then
                            local ni = ny * gw + nx
                            if not isHazardCell(room, ni, fireCells) then
                                local p = room:GetGridPosition(ni)
                                local d = npc.Position:Distance(p)
                                if d < bestD then bestPos, bestD = p, d end
                            end
                        end
                    end
                end
            end

            if bestPos then
                local to = bestPos - npc.Position
                local dist = to:Length()
                if dist > 0.5 then
                    local step = math.min(dist, P.HazardEscapeMax)
                    npc.Position = npc.Position + to:Normalized() * step
                end
            end
        end
    end

    -- ---------- 预警区充能程度 ----------
    do
        if data.State == S.CHARGE then
            data.ZoneHeat = math.max(0, math.min(1, (spr:GetFrame() + 1) / 60))
        else
            data.ZoneHeat = math.max(0, data.ZoneHeat - 0.025 * simSpeed)
        end
    end


    -- ---------- 枪口/身体朝向 ----------
    do
        local aimX
        if data.State == S.CHARGE and data.AimDir then
            aimX = data.AimDir.X
        else
            local aim = safeTarget(npc)
            if aim then aimX = aim.Position.X - npc.Position.X end
        end
        if aimX and math.abs(aimX) > 0.01 then
            npc.FlipX = aimX < 0
        end
    end

    -- ---------- 出现 ----------
    if data.State == S.APPEAR then
        if SM.Elapsed(data, P.AppearFrames) then
            setState(npc, data, S.MOVE)
        end
        return
    end

    -- ---------- 空枪：子弹打光后先播一次「没子弹了」 ----------
    if data.State == S.EMPTY then
        npc.Velocity = Vector.Zero
        if spr:IsFinished("AttackEmpty") or SM.Elapsed(data, P.EmptyFrames) then
            setState(npc, data, S.RELOAD)
            playSnd(SND.Reload)
        end
        return
    end

    -- ---------- 装填：定住，什么都不做 ----------
    if data.State == S.RELOAD then
        npc.Velocity = Vector.Zero
        if spr:IsFinished("Reload") or SM.Elapsed(data, P.ReloadFrames) then
            data.Ammo = P.MaxAmmo                     -- 补满
            setState(npc, data, S.MOVE)
            -- 弹匣卡到位：用老虎机的「停轮」声
            SFXManager():Play(SoundEffect.SOUND_ULTRA_GREED_SLOT_STOP, 1.0, 0, false, 1.0)
        end
        return
    end

    -- ---------- 蓄力 ----------
    if data.State == S.CHARGE then
        if not P.MoveWhileCharging then
            npc.Velocity = Vector.Zero
        end

        if spr:GetFrame() < P.AimTrackFrames then
            local t = safeTarget(npc)
            if t then
                local dir = aimDir(t.Position - npc.Position)
                if dir then
                    data.AimDir = dir
                    data.AimPos = npc.Position + dir * 2000
                end
            end
        end

        if not data.ChargeSfx then
            data.ChargeSfx = true
            playSnd(SND.ShootVocal)
        end

        if not data.Fired and spr:IsEventTriggered("Shoot") then
            data.Fired = true
            if tryFire(npc, data, room) then
                data.Ammo = data.Ammo - 1
            end

        end

        if SM.Elapsed(data, P.ChargeFrames + 2) or spr:IsFinished("Attack") then
            if data.Ammo <= 0 then
                setState(npc, data, S.EMPTY)
            else
                setState(npc, data, S.MOVE)
            end
        end
        return
    end

    -- ---------- 追击 / 决定要不要蓄力 ----------
    local target = safeTarget(npc)
    if not target then
        npc.Velocity = Vector.Zero
        if data.State ~= S.IDLE then setState(npc, data, S.IDLE) end
        return
    end

    if data.Ammo <= 0 then
        setState(npc, data, S.EMPTY)
        return
    end

    -- 同轴且连线干净 -> 蓄力。

    local align = getAlignment(room, npc, target)
    if align then
        data.Fired     = false
        data.ChargeSfx = false
        data.AimDir    = align.dir
        data.AimPos    = npc.Position + align.dir * 2000

        data.ChargeSpeed = P.ChargeAnimMs
                         / U.randRange(P.ChargeMinMs, P.ChargeMaxMs)
        setState(npc, data, S.CHARGE)
        return
    end

    -- 否则追击。

    local toTarget = target.Position - npc.Position
    if toTarget:Length() > P.KeepDistance then

        data.PathTimer = (data.PathTimer or 0) - 1
        local needRepath = (data.PathTimer <= 0)
            or (not data.Waypoint)
            or npc.Position:Distance(data.Waypoint) < 16

        if needRepath then
            data.PathTimer = 10

            local extra = {}
            for _, ent in ipairs(Isaac.GetRoomEntities()) do
                if ent.Type == EntityType.ENTITY_FIREPLACE then
                    local idx = room:GetGridIndex(ent.Position)
                    if idx >= 0 then extra[idx] = true end
                end
            end

            data.Waypoint = SM.NextWaypoint(room, npc.Position, target.Position, extra)
        end

        local desired
        if data.Waypoint then
            local toWp = data.Waypoint - npc.Position
            desired = (toWp:Length() > 2) and toWp:Normalized() or toTarget:Normalized()
        else
            desired = SM.Steer(room, npc.Position, toTarget:Normalized(), P.AvoidProbe)
        end

        npc.Velocity = SM.MoveVelocity(npc, desired, P.MoveSpeed, 0.3)

        -- 下一步会踩进危险格就不走
        local nextIdx = room:GetGridIndex(npc.Position + npc.Velocity)
        if isHazardCell(room, nextIdx, fireCells) then
            npc.Velocity = Vector.Zero
        end
    else
        npc.Velocity = npc.Velocity * 0.85
    end

    if data.State ~= S.MOVE then
        setState(npc, data, S.MOVE)
    end
end

local function onDeath(_, npc)
    local data = Zodiac:GetData(npc, false)
    if data then Attacks.ClearMinions(data) end


end

local function onRemove(_, ent)
    if ent.Type ~= Zodiac.Type then return end
    local data = Zodiac:GetData(ent, false)
    if data then Attacks.ClearMinions(data) end
    Zodiac:ClearData(ent)
end

--- 预警区绘制。
local function onPostRender()
    local room = Game():GetRoom()
    if not room then return end

    local zone = getZone()
    for _, ent in ipairs(Zodiac:GetAll()) do
        if ent:Exists() and not ent:IsDead() then
            local data = Zodiac:GetData(ent, false)
            if data and data.State ~= S.APPEAR and (data.ZoneHeat or 0) > 0 then

                local aimPos = data.AimPos
                if not aimPos then
                    local aim = safeTarget(ent)
                    aimPos = aim and aim.Position or nil
                end
                if aimPos then
                    zone:DrawAimed(room, ent.Position, aimPos,
                                   data.ZoneHeat, 0)
                end
            end
        end
    end
end

-- ============================================================ 注册
local function orientBullet(_, proj)

    if proj.Variant ~= Bullet.Variant then return end

    local ang  = proj.Velocity:GetAngleDegrees()     -- 0=右, 90=下, 顺时针
    local step = 360 / Zodiac.Params.AimDirections   -- 30°
    local idx  = math.floor((ang + step / 2) / step) % Zodiac.Params.AimDirections
    proj:GetSprite():SetFrame("Flight", idx)
end

function Zodiac:Register(mod)

    Attacks.EnableInfiniteRange(mod, Zodiac.Type)
    Attacks.EnableInfiniteRangeVariant(Bullet.Variant)

    -- 弹丸朝向
    mod:AddCallback(ModCallbacks.MC_POST_PROJECTILE_UPDATE, orientBullet)

    -- 死亡后恢复房间原曲
    Bgm.Register(mod)

    Zodiac:AddNpcCallback(mod, ModCallbacks.MC_POST_NPC_INIT,  onInit)
    Zodiac:AddNpcCallback(mod, ModCallbacks.MC_NPC_UPDATE,     onUpdate)
    Zodiac:AddNpcCallback(mod, ModCallbacks.MC_POST_NPC_DEATH, onDeath)
    mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, onRemove)
    mod:AddCallback(ModCallbacks.MC_POST_RENDER, onPostRender)
end

return Zodiac
