-- Man in the Moon：减伤光环 BOSS（502）与 Moon Hand（503）

local ModEntity = require("scripts.shared.modentity")
local SM        = require("scripts.shared.statemachine")
local Attacks   = require("scripts.shared.attacks")
local U         = require("scripts.shared.util")
local Bgm       = require("scripts.shared.bgm")
local StoneMod  = require("scripts.entities.moonstone")

local GRID = 40

-- ============================================================ 参数
local P = {
    -- 减伤光环
    AuraFlat        = 10,
    AuraMinFraction = 0.30,

    -- 光环被打断后的硬直时长
    AuraRestoreMs = 12000,

    -- 周期推挤：把「除自己外的所有单位」推向房间右侧
    ShoveDistance = 0.5,

    PushSpeed = 2.5,

    SkillPeriodMinSec = 5,
    SkillPeriodMaxSec = 8,
    SkillFirstDelayMs = 3000,

    SkillLockMs = 3000,

    -- 开局保护：生成后的前 3 秒本体与 hand 都不能使用技能
    StartupNoSkillMs = 3000,

    -- 预警窗口
    ShoveWarnMs = 2000,
    FanWarnMs   = 2000,

    AuraPushDistance = 120,

    BehindPushDistance = 150,

    -- 两种子弹技能共用同一种石头子弹：每发 10% 概率替换成石头蜘蛛
    SpiderShotCount    = 3,
    SpiderShotSpread   = 14,
    SpiderShotSpeed    = 10.0,
    SpiderShotDamage   = 2.0,
    SpiderChance       = 0.10,
    SpiderSubtypes     = 4,
    -- 场上（普通蜘蛛 + 石头蜘蛛）最多 3 只；达到上限后技能不再生成蜘蛛
    SpiderCap          = 3,

    -- ±20°，10 发；射程/尺寸随机，10% 替换为石头蜘蛛
    FanSkillCount     = 10,
    FanSkillArc       = 40,
    FanSkillRangeMin  = 1 / 6,
    FanSkillRangeMax  = 2 / 3,
    FanSkillScaleBase = 1.2,
    FanSkillScaleMin  = 0.5,
    FanSkillScaleMax  = 1.5,

    HandCount = 2,

    -- 怪物形态
    HandHP            = 20,
    HandChaseSpeed    = 2.08,
    HandContactDamage = 1,

    HandPushRadius  = 40,
    HandPushForce   = 6.0,
    HandKnockRadius = 22,
    HandKnockForce  = 2.2,
    HandDamping     = 0.82,
    -- 石头形态
    HandStoneDamping = 0.75,
    HandStoneMaxSpeed = 6.0,
    HandMaxSpeed      = 6.0,

    DashChargeMs   = 1000,
    DashSpeed      = 14,
    DashFrames     = 12,
    DashCooldownMs = 5000,
    DashWarnLength = 0.25,
    DashDamage     = 20,

    -- 复活的保护与冷却
    ReviveImmuneMs   = 1000,
    ReviveCooldownMs = 3000,

    StoneBlockDamage = 10,

    ReviveBurstRadius = 96,
    ReviveBurstSpeed  = 10,
    ReviveBurstFrames = 2,

    HandUnstick = 10,
}

-- ============================================================ 状态
local S = { APPEAR = 1, IDLE = 2, AURA_BREAK = 3 }

local HF = { MONSTER = 1, STONE = 2 }

local toMonster, toStone

local H = { APPEAR = 1, ACTIVE = 2, STONE = 3 }

-- ============================================================ 实体句柄
local Moon = ModEntity.new("Man in the Moon", "MoonBoss")
local Hand = ModEntity.new("Moon Hand", "MoonHand")
local Stone = StoneMod.Entity

-- ============================================================ 音效
local SND = {
    DashStart = Isaac.GetSoundIdByName("Moon Hand Dash"),
    Uncrack   = Isaac.GetSoundIdByName("Moon Aura Uncrack"),
    Fire      = Isaac.GetSoundIdByName("Moon Fire"),
}

local playSnd = U.playSnd

local Zone = require("scripts.shared.zone")
local zoneRenderer = nil
local function getZone()
    if not zoneRenderer then zoneRenderer = Zone.new() end
    return zoneRenderer
end

-- ============================================================ 时间
local nowMs = U.now

-- ============================================================ 技能错开
local function skillLocked(data)
    return nowMs() < (data.SkillLockUntil or 0)
        or nowMs() < (data.StartupUntil or 0)
        or Game():GetFrameCount() == (data.LastCastFrame or -1)
end

local function lockSkills(data)
    data.SkillLockUntil = nowMs() + P.SkillLockMs
    data.LastCastFrame = Game():GetFrameCount()
end

local function warnHeat(timer, window)
    timer = timer or 0
    if timer <= 0 or timer > window then return 0 end
    return 1 - timer / window
end

-- 技能随机池：两种子弹 3:3，推力 1
local SKILL_POOL = {
    "fan3", "fan3", "fan3",
    "fan10", "fan10", "fan10",
    "shove",
}

-- 扇形弹幕技能的弹数：3/4/5/6/7，权重 2/4/4/2/1
local FAN3_COUNT_POOL = {
    3, 3,
    4, 4, 4, 4,
    5, 5, 5, 5,
    6, 6,
    7,
}

local function pickFan3Count()
    return FAN3_COUNT_POOL[(Random() % #FAN3_COUNT_POOL) + 1]
end

--- 本周期的间隔：随机 5~8 秒。
local function randomPeriodMs()
    local lo, hi = P.SkillPeriodMinSec, P.SkillPeriodMaxSec
    return (lo + Random() % (hi - lo + 1)) * 1000
end

local function scheduleNextSkill(data, atMs)
    data.NextSkillAt = atMs
    data.NextSkill = SKILL_POOL[(Random() % #SKILL_POOL) + 1]
    data.NextFan3Count = (data.NextSkill == "fan3") and pickFan3Count() or nil
end

local function inShoveWarn(bdata)
    if not bdata or not bdata.AuraActive or bdata.State == S.APPEAR then
        return false
    end
    if bdata.NextSkill ~= "shove" then return false end
    local remain = (bdata.NextSkillAt or 0) - nowMs()
    return remain > 0 and remain <= P.ShoveWarnMs
end

local BGM_NAME = "Man in the Moon"

local eachPlayer    = U.eachPlayer
local nearestPlayer = U.nearestPlayer

-- ============================================================ 障碍物破坏
local DESTRUCTIBLE_GRID = StoneMod.DESTRUCTIBLE_GRID

local function destroyObstaclesNear(room, pos, radius)
    local idx = room:GetGridIndex(pos)
    if idx < 0 then return 0 end

    local gw, gh = room:GetGridWidth(), room:GetGridHeight()
    local cx, cy = idx % gw, math.floor(idx / gw)
    local span  = math.max(1, math.ceil(radius / GRID))
    local reach = radius + GRID * 0.5
    local n = 0

    for dy = -span, span do
        for dx = -span, span do
            local x, y = cx + dx, cy + dy
            if x >= 0 and x < gw and y >= 0 and y < gh then
                local cell = y * gw + x
                local ge = room:GetGridEntity(cell)
                local deadPoop = ge
                    and ge:GetType() == GridEntityType.GRID_POOP
                    and (ge.State or 0) >= 1000
                if ge and not deadPoop and DESTRUCTIBLE_GRID[ge:GetType()]
                   and pos:Distance(room:GetGridPosition(cell)) <= reach then
                    ge:Destroy(false)
                    n = n + 1
                end
            end
        end
    end
    return n
end

local RIGHT = Vector(1, 0)

local function beginPush(data, distance, speed)
    speed = speed or P.PushSpeed
    data.PushSpeed      = speed
    data.PushFramesLeft = math.max(1, math.floor(distance / speed))
    data.PushUntil      = Game():GetFrameCount() + data.PushFramesLeft
end

local function applyOutward(ent, center, radius, speed)
    local d = ent.Position - center
    local dist = d:Length()
    if dist > 0.01 and dist < radius then
        local k = 1 - dist / radius
        ent:AddVelocity(d:Normalized() * speed * k)
    end
end

local function startBurst(bdata, pos)
    bdata.Bursts = bdata.Bursts or {}
    table.insert(bdata.Bursts, {
        x = pos.X, y = pos.Y,
        radius = P.ReviveBurstRadius,
        speed  = P.ReviveBurstSpeed,
        untilFrame = Game():GetFrameCount() + P.ReviveBurstFrames,
    })
end

local function eachBurst(bdata, fn)
    local list = bdata.Bursts
    if not list then return end
    local frame = Game():GetFrameCount()
    for i = #list, 1, -1 do
        if frame < list[i].untilFrame then
            fn(list[i])
        else
            table.remove(list, i)
        end
    end
    if #list == 0 then bdata.Bursts = nil end
end

local function reviveHand(h, hd, bdata)
    if not hd or hd.Form ~= HF.STONE or hd.Dying then return false end

    local now = nowMs()
    if bdata then
        local gate = math.max(bdata.NextReviveAt or 0,
                              hd.ReviveCooldownUntil or 0)
        if now < gate then
            bdata.PendingReviveAt = math.max(bdata.PendingReviveAt or 0, gate)
            return false
        end
    elseif now < (hd.ReviveCooldownUntil or 0) then
        return false
    end

    local boss = nil
    for _, b in ipairs(Moon:GetAll()) do
        if b:Exists() then boss = b; break end
    end
    if boss then
        local room = Game():GetRoom()
        local gw, gh = room:GetGridWidth(), room:GetGridHeight()
        local rHand = h.Size or 14
        local R  = gw * GRID / 8
        local yR = (gh * GRID / 3) / (gw * GRID / 4)
        local rx = R + rHand + 40
        local ry = R * yR + rHand + 40

        local d = h.Position - boss.Position
        local k = math.sqrt((d.X / rx) ^ 2 + (d.Y / ry) ^ 2)
        if k < 1 then
            if k < 0.001 then
                h.Position = boss.Position + RIGHT * rx * 1.1
            else
                h.Position = boss.Position + d * (1.1 / k)
            end
        end
    end

    toMonster(h, hd)
    if bdata then
        bdata.NextReviveAt = nowMs() + P.ReviveCooldownMs
        startBurst(bdata, h.Position)
    end
    return true
end

--- 先被击杀的优先复活
local function oldestStoneHand()
    local best, bestAt = nil, math.huge
    for _, h in ipairs(Hand:GetAll()) do
        if h:Exists() then
            local hd = Hand:GetData(h, false)
            if hd and hd.Form == HF.STONE and not hd.Dying then
                local at = hd.StoneAt or 0
                if at < bestAt then
                    best, bestAt = h, at
                end
            end
        end
    end
    return best
end

local function onPlayerUpdate(_, p)
    for _, boss in ipairs(Moon:GetAll()) do
        local bdata = Moon:GetData(boss, false)
        if bdata then
            local now = Game():GetFrameCount()
            if bdata.PushUntil and now < bdata.PushUntil then
                local cap   = math.max(0, (p.MoveSpeed or 1) * 4 * 0.9)
                local speed = math.min(bdata.PushSpeed or 0, cap)
                p:AddVelocity(RIGHT * speed)
            end

            eachBurst(bdata, function(b)
                applyOutward(p, Vector(b.x, b.y), b.radius, b.speed)
            end)
        end
    end
end

-- 把除本体外的所有单位朝房间右侧推。

local SHOVE_SKIP = {
    [EntityType.ENTITY_PLAYER]     = true,
    [EntityType.ENTITY_TEAR]       = true,
    [EntityType.ENTITY_PROJECTILE] = true,
    [EntityType.ENTITY_EFFECT]     = true,
    [EntityType.ENTITY_PICKUP]     = true,
    [EntityType.ENTITY_TEXT]       = true,
}

local function pushOtherNPCs(speed)
    local v = RIGHT * speed
    for _, ent in ipairs(Isaac.GetRoomEntities()) do
        if ent.Type ~= Moon.Type and not SHOVE_SKIP[ent.Type] then
            local push = true
            if ent.Type == Hand.Type then
                local hd = Hand:GetData(ent, false)
                push = hd ~= nil
                   and hd.Form == HF.STONE
                   and not hd.Dying
                   and not (hd.PushImmuneUntil and nowMs() < hd.PushImmuneUntil)
            end
            if push then
                ent:AddVelocity(v)
            end
        end
    end
end

-- ============================================================ 本体：状态

local function setState(npc, data, state)
    SM.SetState(npc, data, state)

    local spr = npc:GetSprite()
    if state == S.APPEAR then
        spr:Play("Idle", true)
    elseif state == S.IDLE then
        spr:Play("Idle")
    elseif state == S.AURA_BREAK then
        spr:Play("Break", true)
    end
end

local function applyBodySize(npc, room)
    local roomW = room:GetGridWidth() * GRID
    local roomH = room:GetGridHeight() * GRID
    local bodyW, bodyH = roomW / 4, roomH / 3

    npc:SetSize(bodyW / 2, Vector(1, bodyH / bodyW), 12)

    return bodyW, bodyH
end

-- 本体死亡时，随从各自播一遍 Death 动画再移除
local function killHands(data)
    if data.HandsDying then return end
    data.HandsDying = true
    for _, m in ipairs(data.minions or {}) do
        if m and m.Exists and m:Exists() then
            local hd = Hand:GetData(m, false)
            if hd then
                hd.Dying = true
                m.CollisionDamage = 0
                m.Velocity = Vector.Zero
                m:GetSprite():Play("Death", true)
            else
                m:Remove()
            end
        end
    end
end

-- ============================================================ 本体：回调

local function onInit(_, npc)
    local data = Moon:GetData(npc, true)
    local room = Game():GetRoom()

    data.AuraActive = true

    local roomW = room:GetGridWidth() * GRID
    local bodyW  = applyBodySize(npc, room)
    local center = room:GetCenterPos()

    -- 生成在房间最左侧
    npc.Position = Vector(center.X - roomW / 2 + bodyW / 2, center.Y)
    npc.Velocity = Vector.Zero

    eachPlayer(function(p)
        p.Position = Vector(center.X + roomW / 2 - bodyW, center.Y)
        p.Velocity = Vector.Zero
    end)

    -- 召唤 Moon Hand：上下分列在房间右侧
    data.minions = {}
    for i = 1, P.HandCount do
        local side = (i == 1) and -1 or 1
        local spawnPos = Vector(
            center.X + roomW * 0.18,
            center.Y + side * room:GetGridHeight() * GRID * 0.22
        )
        local h = Isaac.Spawn(Hand.Type, Hand.Variant, 0, spawnPos,
                              Vector.Zero, npc)
        if h then
            table.insert(data.minions, h:ToNPC() or h)
        end
    end

    setState(npc, data, S.APPEAR)

    data.NeedActivation = true

    Bgm.Enforce(BGM_NAME, 8000)
    SFXManager():Play(SoundEffect.SOUND_BOSS_LITE_ROAR, 1.0, 0, false, 1.0)
    playSnd(SND.DashStart, 0.0)
    playSnd(SND.Uncrack, 0.0)
    playSnd(SND.Fire, 0.0)
end

local function onTakeDamage(_, npc, amount, flags, source, countdown)
    local data = Moon:GetData(npc, false)
    if not data or not data.AuraActive then return end
    if data.Applying then return end

    local reduced = math.max(amount - P.AuraFlat, amount * P.AuraMinFraction)
    if reduced >= amount - 0.0001 then return end

    data.Applying = true
    npc:TakeDamage(reduced, flags, source, countdown)
    data.Applying = false
    return false
end

-- ============================================================ 三个技能

--- 场上存活的普通蜘蛛 + 石头蜘蛛数量。
local function liveSpiderCount()
    local n = 0
    local function add(t)
        for _, e in ipairs(Isaac.FindByType(t, -1, -1, false, false)) do
            if e:Exists() and not e:IsDead() then n = n + 1 end
        end
    end
    add(EntityType.ENTITY_SPIDER)
    add(EntityType.ENTITY_ROCK_SPIDER)
    return n
end

local function castFan3(npc, count)
    local target = nearestPlayer(npc.Position)
    if not target then return end

    count = count or P.SpiderShotCount
    local base = (target.Position - npc.Position):GetAngleDegrees()
    local half = (count - 1) / 2
    local spidersLeft = math.max(0, P.SpiderCap - liveSpiderCount())

    for i = 0, count - 1 do
        local ang = base + (i - half) * P.SpiderShotSpread
        local dir = Vector.FromAngle(ang)

        if spidersLeft > 0 and (Random() % 1000) < P.SpiderChance * 1000 then
            spidersLeft = spidersLeft - 1
            -- 替换成石头蜘蛛：和子弹一样朝该方向射出去
            Isaac.Spawn(EntityType.ENTITY_ROCK_SPIDER, 0,
                        Random() % P.SpiderSubtypes,
                        npc.Position + dir * 30,
                        dir * P.SpiderShotSpeed, npc)
        else
            local params = Attacks.Params({
                variant      = Stone.Variant,
                scale        = 1.2,
                fallingSpeed = 2,
                fallingAccel = -0.08,
            })
            Attacks.StraightShot(npc,
                npc.Position + dir * 200,
                P.SpiderShotSpeed, params, P.SpiderShotDamage)
        end
    end

    for _, ent in ipairs(Isaac.FindByType(EntityType.ENTITY_PROJECTILE,
            Stone.Variant, -1, false, false)) do
        if ent.FrameCount == 0 then
            local pr = ent:ToProjectile()
            if pr then
                pr.CollisionDamage = P.SpiderShotDamage
                pr:GetSprite():Play("Flight", true)
            end
        end
    end

    playSnd(SND.Fire)
end

local function castFan10(npc)
    local target = nearestPlayer(npc.Position)
    if not target then return end

    local room    = Game():GetRoom()
    local roomLen = room:GetGridWidth() * GRID

    local n, arc, half = P.FanSkillCount, P.FanSkillArc,
                          (P.FanSkillCount - 1) / 2
    local base = (target.Position - npc.Position):GetAngleDegrees()
    local step = arc / (n - 1)

    local spidersLeft = math.max(0, P.SpiderCap - liveSpiderCount())
    local bullets, spiders, bulletAngles = 0, {}, {}
    for i = 0, n - 1 do
        if spidersLeft > 0
           and (Random() % 1000) < P.SpiderChance * 1000 then
            spiders[#spiders + 1] = i
            spidersLeft = spidersLeft - 1
        else
            bullets = bullets + 1
            bulletAngles[#bulletAngles + 1] = base + (i - half) * step
        end
    end

    if bullets > 0 then
        local params = Attacks.Params({
            variant      = Stone.Variant,
            scale        = P.FanSkillScaleBase,
            fallingSpeed = 2,
            fallingAccel = -0.08,
            height       = 3,
        })
        Attacks.FanAtTarget(npc, bullets, target.Position, 0,
                            params, P.SpiderShotDamage)
    end

    for _, i in ipairs(spiders) do
        local dir = Vector.FromAngle(base + (i - half) * step)
        Isaac.Spawn(EntityType.ENTITY_ROCK_SPIDER, 0,
                    Random() % P.SpiderSubtypes,
                    npc.Position + dir * 30,
                    dir * P.SpiderShotSpeed, npc)
    end

    local npcHash = GetPtrHash(npc)
    local fresh = {}
    for _, ent in ipairs(Isaac.FindByType(EntityType.ENTITY_PROJECTILE,
            Stone.Variant, -1, false, false)) do
        if ent.FrameCount == 0 and ent.SpawnerEntity
           and GetPtrHash(ent.SpawnerEntity) == npcHash then
            local pr = ent:ToProjectile()
            if pr then fresh[#fresh + 1] = pr end
        end
    end

    local function relAngle(v)
        return (v:GetAngleDegrees() - base + 180) % 360 - 180
    end
    table.sort(fresh, function(a, b)
        return relAngle(a.Velocity) < relAngle(b.Velocity)
    end)

    local now = Game():GetFrameCount()
    for k, pr in ipairs(fresh) do
        local ang = bulletAngles[k]
                   or (base + (k - 1 - (bullets - 1) / 2) * step)
        local speed = pr.Velocity:Length()
        if speed < 0.01 then speed = P.SpiderShotSpeed end
        pr.Velocity = Vector.FromAngle(ang) * speed

        local range = roomLen * (P.FanSkillRangeMin
            + (P.FanSkillRangeMax - P.FanSkillRangeMin)
              * (Random() / 4294967296))
        pr:GetData().MewDieAt = now + math.max(1, math.ceil(range / speed))

        local kk = P.FanSkillScaleMin
            + (P.FanSkillScaleMax - P.FanSkillScaleMin)
              * (Random() / 4294967296)
        pr.Scale = P.FanSkillScaleBase * kk
        pr.CollisionDamage = P.SpiderShotDamage
        pr:GetSprite():Play("Flight", true)
    end

    playSnd(SND.Fire)
end

--- 秒杀场上所有普通蜘蛛与石头蜘蛛。
local function killAllSpiders(npc)
    local ref = EntityRef(npc)
    local function killType(t)
        for _, e in ipairs(Isaac.FindByType(t, -1, -1, false, false)) do
            if e:Exists() and not e:IsDead() then
                e:Kill(ref)
            end
        end
    end
    killType(EntityType.ENTITY_SPIDER)
    killType(EntityType.ENTITY_ROCK_SPIDER)
end

--- 周期推挤：把除自己外的单位推向房间右侧 + 秒杀蜘蛛 + 屏幕抖动
local function castShove(npc, data, room)
    beginPush(data, room:GetGridWidth() * GRID * P.ShoveDistance,
              P.PushSpeed * 4)
    killAllSpiders(npc)
    SFXManager():Play(SoundEffect.SOUND_BOSS2INTRO_PIPES_TURNON)
    Game():ShakeScreen(30)
end

local function onUpdate(_, npc)
    local data = Moon:GetData(npc, true)
    local spr  = npc:GetSprite()
    local room = Game():GetRoom()

    -- 死亡瞬间：让随从播死亡动画，本体停止一切行为。
    if npc.HitPoints <= 0 then
        data.PushFramesLeft  = 0
        data.PushUntil       = 0
        data.Bursts          = nil
        data.PendingReviveAt = nil
        data.ReviveAllPending = nil
        killHands(data)
        if not data.MusicFaded then
            data.MusicFaded = true
            Bgm.StopEnforce()
            MusicManager():Fadeout()
            Bgm.RestoreAfterMs(3000)
        end
        return
    end

    if data.NeedActivation then
        data.NeedActivation = nil
        data.AppearUntil  = nowMs() + 700
        data.StartupUntil = nowMs() + P.StartupNoSkillMs
        scheduleNextSkill(data, nowMs() + P.SkillFirstDelayMs)
    end

    npc.Velocity = Vector.Zero

    data.SizeCheckTimer = (data.SizeCheckTimer or 0) + 1
    if data.SizeCheckTimer % 30 == 0 then
        applyBodySize(npc, room)
    end

    -- ---------- 出现 ----------
    if data.State == S.APPEAR then
        if nowMs() >= (data.AppearUntil or 0) then
            setState(npc, data, S.IDLE)
        end
        return
    end

    -- ---------- 推力 ----------
    if (data.PushFramesLeft or 0) > 0 then
        data.PushFramesLeft = data.PushFramesLeft - 1
        pushOtherNPCs(data.PushSpeed or 0)
    end

    eachBurst(data, function(burst)
        local center = Vector(burst.x, burst.y)
        for _, ent in ipairs(Isaac.GetRoomEntities()) do
            if ent.Type ~= Moon.Type and ent.Type ~= Hand.Type
               and not SHOVE_SKIP[ent.Type] then
                applyOutward(ent, center, burst.radius, burst.speed)
            end
        end
    end)

    -- ---------- 延迟复活 ----------
    if data.PendingReviveAt and nowMs() >= data.PendingReviveAt then
        data.PendingReviveAt = nil
        local h = oldestStoneHand()
        if h then
            reviveHand(h, Hand:GetData(h, false), data)
        end
    end

    if data.ReviveAllPending and (data.PendingReviveAt or 0) <= nowMs() then
        if oldestStoneHand() then
            data.PendingReviveAt = math.max(data.PendingReviveAt or 0,
                                            data.NextReviveAt or 0)
        else
            data.ReviveAllPending = nil
        end
    end

    -- ---------- 光环被打断 ----------
    if not data.AuraActive then
        if data.State == S.AURA_BREAK and not data.MouthLoop
           and spr:IsFinished("Break") then
            data.MouthLoop = true
            spr:Play("OpenMouth")
        end

        if nowMs() >= (data.AuraRestoreAt or 0) then
            data.AuraActive = true
            data.Recovering = true
            -- 护盾恢复后 3 秒内不使用任何技能
            data.SkillLockUntil = nowMs() + P.SkillLockMs
            SM.SetState(npc, data, S.IDLE)
            spr:Play("Recover", true)
            SFXManager():Play(SoundEffect.SOUND_BOSS2_DIVE, 1.0, 0, false, 1.0)
            scheduleNextSkill(data, nowMs() + P.SkillFirstDelayMs)

            -- 光环恢复 -> 石头形态的随从重新活化回怪物形态
            data.ReviveAllPending = true
            local first = oldestStoneHand()
            if first then
                reviveHand(first, Hand:GetData(first, false), data)
            end
        end
        return
    end

    if data.Recovering then
        if spr:IsFinished("Recover") then
            data.Recovering = false
            spr:Play("Idle")
        end
    end

    -- ---------- 技能排程：5n+3 秒随机施放一个 ----------
    if not skillLocked(data) and nowMs() >= (data.NextSkillAt or 0) then
        local skill = data.NextSkill or "fan3"
        if skill == "fan3" then
            castFan3(npc, data.NextFan3Count)
        elseif skill == "fan10" then
            castFan10(npc)
        else
            castShove(npc, data, room)
        end

        -- 下一次：本次施放时刻 + rand(5..8) 秒
        scheduleNextSkill(data, (data.NextSkillAt or nowMs()) + randomPeriodMs())
        lockSkills(data)
    end

    -- ---------- 角色绕到本体左侧 -> 立刻击退 ----------
    if (data.PushFramesLeft or 0) <= 0 then
        local intruder = false
        eachPlayer(function(p)
            if not intruder and p.Position.X < npc.Position.X then
                intruder = true
            end
        end)

        if intruder then
            beginPush(data, P.BehindPushDistance, P.PushSpeed)
            -- 打断蓄力中的技能 + 重置周期
            scheduleNextSkill(data, nowMs() + P.SkillFirstDelayMs)
            SFXManager():Play(SoundEffect.SOUND_BOSS2INTRO_ERRORBUZZ)
        end
    end
end

local function onDeath(_, npc)
    local data = Moon:GetData(npc, false)
    if data then killHands(data) end
end

local function onRemove(_, ent)
    if ent.Type ~= Moon.Type then return end
    local data = Moon:GetData(ent, false)
    if data and not data.HandsDying then Attacks.ClearMinions(data) end
    Moon:ClearData(ent)
end

-- ============================================================ 随从：Moon Hand

--- 怪物形态：满血、有接触伤害、会追击。
toMonster = function(npc, data)
    data.Form = HF.MONSTER
    data.StoneAt = nil
    npc.MaxHitPoints    = P.HandHP
    npc.HitPoints       = P.HandHP
    npc.CollisionDamage = P.HandContactDamage

    -- 激活：眼睛亮起（Charge 动画）+ dashstart 音效。
    data.State = H.APPEAR
    data.Charging  = nil
    data.DashUntil = nil
    data.AppearUntil = nowMs() + P.ReviveImmuneMs
    npc:GetSprite():Play("Charge", true)
    playSnd(SND.DashStart)

    -- 复活后 1 秒内位置固定、不被推动（自缚）
    data.PushImmuneUntil = nowMs() + P.ReviveImmuneMs
    -- 复活冷却：3 秒内不能再被复活
    data.ReviveCooldownUntil = nowMs() + P.ReviveCooldownMs
end

--- 石头形态：无敌、无接触伤害、可被推挤。
toStone = function(npc, data)
    data.Form = HF.STONE
    data.StoneAt = nowMs()
    data.State = H.STONE
    data.Charging  = nil
    data.DashUntil = nil
    npc.PositionOffset = Vector.Zero
    npc.HitPoints       = 1
    npc.MaxHitPoints    = math.max(npc.MaxHitPoints, 1)
    npc.CollisionDamage = 0
    npc.Velocity        = Vector.Zero
    npc:GetSprite():Play("Idle", true)

    SFXManager():Play(SoundEffect.SOUND_ROCK_CRUMBLE, 1.0, 0, false, 1.0)

    pcall(function()
    local selfHash = GetPtrHash(npc)
    local boss = nil
    for _, b in ipairs(Moon:GetAll()) do
        if b:Exists() then boss = b; break end
    end
    local bdata = boss and Moon:GetData(boss, false) or nil

    for _, h in ipairs(Hand:GetAll()) do
        if h:Exists() and GetPtrHash(h) ~= selfHash then
            local hd = Hand:GetData(h, false)
            if hd and hd.Form == HF.STONE and not hd.Dying then
                reviveHand(h, hd, bdata)
                break
            end
        end
    end
    end)
end

local function handTakeDamage(_, npc, amount)
    local data = Hand:GetData(npc, false) or Hand:GetData(npc, true)
    if data.Form == nil then data.Form = HF.MONSTER end

    if data.Form == HF.STONE then
        return false  -- 石头形态：完全免疫
    end

    if npc.HitPoints - amount <= 0 then
        toStone(npc, data)
        return false
    end
end

local function handInit(_, npc)
    local data = Hand:GetData(npc, true)
    toMonster(npc, data)  -- 出生是怪物形态
    data.ReviveCooldownUntil = 0
end

--- 打断本体的光环。
local function breakAura(boss, bdata, hand)
    bdata.AuraActive     = false
    bdata.AuraRestoreAt  = nowMs() + P.AuraRestoreMs

    local spr = boss:GetSprite()
    spr:Play("Break", true)
    bdata.MouthLoop = false
    bdata.Recovering = false
    bdata.State = S.AURA_BREAK

    -- 击退：一次较短的推力。与周期推挤走完全相同的机制
    beginPush(bdata, P.AuraPushDistance)

    hand.Position = hand.Position + RIGHT * P.HandUnstick

    playSnd(SND.Uncrack)
end

-- 随从动画状态
local function handUpdate(_, npc)
    local data = Hand:GetData(npc, true)
    local spr  = npc:GetSprite()

    -- 本体死亡后：播完 Death 动画再自己移除
    if data.Dying then
        npc.Velocity = Vector.Zero
        if spr:IsFinished("Death") then npc:Remove() end
        return
    end

    if npc.HitPoints <= 0 then
        npc.HitPoints = 1
        toStone(npc, data)
    end

    -- 本体打出的石头子弹会被 hand 阻挡
    do
        local rHand = npc.Size or 14
        for _, ent in ipairs(Isaac.FindByType(EntityType.ENTITY_PROJECTILE,
                Stone.Variant, -1, false, false)) do
            local proj = ent:ToProjectile()
            if proj and not proj:GetData().ShatterAt then
                local r = rHand + (proj.Size or 7) + 4
                if npc.Position:Distance(proj.Position) <= r then
                    npc:TakeDamage(P.StoneBlockDamage, 0, EntityRef(proj), 0)
                    StoneMod.Shatter(proj)
                end
            end
        end
    end

    if data.Form  == nil then data.Form  = HF.MONSTER end
    if data.State == nil then data.State = H.APPEAR end

    -- ---------- 激活 / 自缚（1 秒） ----------
    if data.State == H.APPEAR and data.Form == HF.MONSTER then
        npc.Velocity = Vector.Zero
        if spr:IsFinished("Charge") or nowMs() >= (data.AppearUntil or 0) then
            data.State = H.ACTIVE
            spr:Play("IdleBack")
        end
        return
    end

    local now    = nowMs()
    local immune = data.PushImmuneUntil and now < data.PushImmuneUntil

    local warnHold = false
    for _, b in ipairs(Moon:GetAll()) do
        local bd = Moon:GetData(b, false)
        if bd and inShoveWarn(bd) then warnHold = true; break end
    end
    if warnHold then
        data.Charging  = nil
        data.DashUntil = nil
        npc.PositionOffset = Vector.Zero
    end

    -- ---------- 冲刺 ----------
    local dashing = data.DashUntil and Game():GetFrameCount() < data.DashUntil

    if data.Charging then
        npc.Velocity = Vector.Zero

        -- 蓄力抖动
        npc.PositionOffset = Vector((Random() % 7) - 3,
                                    (Random() % 7) - 3)

        if now >= (data.ChargeUntil or 0) then
            data.Charging     = false
            data.DashUntil    = Game():GetFrameCount() + P.DashFrames
            data.DashHitDone  = false
            data.DashHits     = nil
            npc.Velocity      = (data.DashDir or RIGHT) * P.DashSpeed
            npc.PositionOffset = Vector.Zero
            dashing = true
        end
    end

    -- 冲刺期间
    if dashing then
        npc.Velocity = (data.DashDir or RIGHT) * P.DashSpeed

        -- 冲刺碾压路径上的障碍物
        local room = Game():GetRoom()
        local r = (npc.Size or 14) + 12
        destroyObstaclesNear(room, npc.Position, r)
        if data.DashDir then
            destroyObstaclesNear(room, npc.Position + data.DashDir * r, r)
        end

        -- 冲刺撞击敌方单位
        data.DashHits = data.DashHits or {}
        local rHand = npc.Size or 14
        local ref = EntityRef(npc)
        for _, ent in ipairs(Isaac.GetRoomEntities()) do
            if ent ~= npc
               and ent.Type ~= Hand.Type
               and ent.Type ~= Moon.Type
               and ent:Exists() and not ent:IsDead()
               and ent:IsActiveEnemy(false) then
                local key = GetPtrHash(ent)
                if not data.DashHits[key]
                   and npc.Position:Distance(ent.Position)
                       <= rHand + (ent.Size or 10) then
                    data.DashHits[key] = true
                    ent:TakeDamage(P.DashDamage, 0, ref, 0)
                end
            end
        end
    end

    -- ---------- 冲刺触发：存活形态、与玩家同一行、共享冷却结束 ----------
    if not dashing and not data.Charging
       and data.Form == HF.MONSTER and not immune and not warnHold then
        local room = Game():GetRoom()
        local gw = room:GetGridWidth()
        local hi = room:GetGridIndex(npc.Position)

        local bdata = nil
        for _, b in ipairs(Moon:GetAll()) do
            bdata = Moon:GetData(b, false)
            if bdata then break end
        end

        if hi >= 0 and bdata
           and now >= (bdata.StartupUntil or 0)
           and now >= (bdata.DashCooldownUntil or 0) then
            local row = math.floor(hi / gw)
            local target = nil
            eachPlayer(function(pl)
                if target then return end
                local pi = room:GetGridIndex(pl.Position)
                if pi >= 0 and math.floor(pi / gw) == row then
                    target = pl
                end
            end)

            if target then
                local dir = target.Position - npc.Position
                if dir:Length() > 1 then
                    data.DashDir     = dir:Normalized()
                    data.Charging    = true
                    data.ChargeUntil = now + P.DashChargeMs

                    bdata.DashCooldownUntil = now + P.DashCooldownMs
                end
            end
        end
    end

    -- ---------- 常规移动 ----------
    if not dashing and not data.Charging then

    -- ---------- 被玩家推挤 ----------
    if not immune then eachPlayer(function(p)
        local d = npc.Position - p.Position
        local dist = d:Length()
        if dist < P.HandPushRadius and dist > 0.01 then
            local closeness = 1 - dist / P.HandPushRadius
            npc:AddVelocity(d:Normalized() * P.HandPushForce * closeness)
        end
    end) end

    -- ---------- 被子弹击退 ----------
    if not immune then
    for _, ent in ipairs(Isaac.FindByType(EntityType.ENTITY_PROJECTILE, -1, -1, false, false)) do
        local d = npc.Position - ent.Position
        local dist = d:Length()
        if dist < P.HandKnockRadius and dist > 0.01 then
            local closeness = 1 - dist / P.HandKnockRadius
            npc:AddVelocity(d:Normalized() * P.HandKnockForce * closeness)
        end
    end
    end

    local damp = (data.Form == HF.STONE) and P.HandStoneDamping or P.HandDamping
    npc.Velocity = npc.Velocity * damp
    do
        local cap = (data.Form == HF.STONE) and P.HandStoneMaxSpeed
                    or P.HandMaxSpeed
        local v = npc.Velocity
        if v:Length() > cap then
            npc.Velocity = v:Normalized() * cap
        end
    end

    -- ---------- 怪物形态：追踪角色 ----------
    local bossPushing = false
    for _, boss in ipairs(Moon:GetAll()) do
        local bd = Moon:GetData(boss, false)
        if bd and (bd.PushFramesLeft or 0) > 0 then
            bossPushing = true
            break
        end
    end

    if data.Form == HF.MONSTER and not bossPushing and not immune
       and not warnHold then
        local best, bestD = nil, math.huge
        eachPlayer(function(p)
            local d = npc.Position:Distance(p.Position)
            if d < bestD then best, bestD = p, d end
        end)

        if best then
            local to = best.Position - npc.Position
            if to:Length() > 1 then
                npc.Velocity = npc.Velocity * 0.6
                             + to:Normalized() * P.HandChaseSpeed * 0.4
            end
        end
    end

    end

    -- 免疫期间：位置完全固定
    if immune then
        npc.Velocity = Vector.Zero
    end

    -- ---------- 夹在房间范围内 ----------
    do
        local room = Game():GetRoom()
        local tl, br = room:GetTopLeftPos(), room:GetBottomRightPos()
        -- 只在边界看起来合理时才夹，避免拿到异常值时把随从甩到角落
        if br.X > tl.X and br.Y > tl.Y then
            local r = npc.Size or 14
            npc.Position = Vector(
                math.max(tl.X + r, math.min(br.X - r, npc.Position.X)),
                math.max(tl.Y + r, math.min(br.Y - r, npc.Position.Y))
            )
        end
    end

    -- 动画：石头形态播 Idle；怪物形态播 IdleBack
    if data.Form == HF.STONE then
        if data.State ~= H.STONE then
            data.State = H.STONE
            spr:Play("Idle")
        end
    else
        if data.State ~= H.ACTIVE then
            data.State = H.ACTIVE
            spr:Play("IdleBack")
        end
    end

    -- ---------- 碰到本体 -> 打断光环 ----------
    do
        local room = Game():GetRoom()
        local gw, gh = room:GetGridWidth(), room:GetGridHeight()
        local R  = gw * GRID / 8
        local yR = (gh * GRID / 3) / (gw * GRID / 4)
        local rHand = npc.Size or 14

        -- 容差 +16：引擎的实体碰撞会在接触瞬间把手弹开
        local rx = R + rHand + 16
        local ry = R * yR + rHand + 16

        for _, boss in ipairs(Moon:GetAll()) do
            local bdata = Moon:GetData(boss, false)
            if bdata then
                local dx = npc.Position.X - boss.Position.X
                local dy = npc.Position.Y - boss.Position.Y
                if (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry) <= 1.0 then
                    -- 任何形态的手撞上本体都会破盾（护盾存在时）
                    if bdata.AuraActive then
                        breakAura(boss, bdata, npc)
                    end

                    if dashing and not data.DashHitDone then
                        data.DashHitDone = true
                        boss:TakeDamage(P.DashDamage, 0, EntityRef(npc), 0)
                    end
                    break
                end
            end
        end
    end
end

local function handRemove(_, ent)
    if ent.Type ~= Hand.Type then return end
    Hand:ClearData(ent)
end

local function onHandKilled(_, ent)
    if ent.Type ~= Hand.Type then return end
    local data = Hand:GetData(ent, false)
    if not data or data.Dying then return end

    local boss = nil
    for _, b in ipairs(Moon:GetAll()) do
        if b:Exists() then boss = b; break end
    end
    if not boss then return end

    local pos = ent.Position
    local h = Isaac.Spawn(Hand.Type, Hand.Variant, 0, pos, Vector.Zero, nil)
    ent:Remove()

    local npc = h and h:ToNPC()
    if not npc then return end

    local nd = Hand:GetData(npc, true)
    nd.Form = HF.STONE
    nd.State = H.STONE
    nd.StoneAt = nowMs()
    npc.HitPoints = 1
    npc.MaxHitPoints = math.max(npc.MaxHitPoints, 1)
    npc.CollisionDamage = 0
    npc.Velocity = Vector.Zero
    npc:GetSprite():Play("Idle", true)

    local bdata = Moon:GetData(boss, false)
    if bdata and bdata.minions then
        table.insert(bdata.minions, npc)
    end
    SFXManager():Play(SoundEffect.SOUND_ROCK_CRUMBLE, 1.0, 0, false, 1.0)
end

-- 蓄力中的手：一层逐渐变亮的红色描边。
local function onHandRender(_, npc, offset)
    if npc.Type ~= Hand.Type then return end
    local data = Hand:GetData(npc, false)
    if not data or not data.Charging then return end

    local room = Game():GetRoom()
    if not room then return end

    local nowMsV = nowMs()
    local left = (data.ChargeUntil or nowMsV) - nowMsV
    local progress = 1 - left / P.DashChargeMs
    progress = math.max(0, math.min(1, progress))

    local pos = Isaac.WorldToScreen(npc.Position + npc.PositionOffset)
                + offset
                - room:GetRenderScrollOffset()
                - Game().ScreenShakeOffset

    local spr = npc:GetSprite()

    local s = spr.Scale
    local baseScale = Vector(s.X, s.Y)
    local c = spr.Color
    local baseColor = c and Color(c.R, c.G, c.B, c.A, c.RO, c.GO, c.BO)
                         or Color(1, 1, 1, 1)

    local out = baseScale * 1.05
    spr.Scale = Vector(out.X, out.Y)
    local gb = 1 - 0.82 * progress
    spr.Color = Color(1, gb, gb, 0.08 + 0.18 * progress)
    for i = 0, 7 do
        local a = i * math.pi / 4
        spr:Render(pos + Vector(math.cos(a), math.sin(a)) * 1,
                   Vector.Zero, Vector.Zero)
    end

    spr.Scale = baseScale
    spr.Color = baseColor
    spr:Render(pos, Vector.Zero, Vector.Zero)
end

-- 本体护盾：周围一圈白色轮廓。
local function onMoonRender(_, npc, offset)
    local data = Moon:GetData(npc, false)
    if not data or not data.AuraActive then return end

    local room = Game():GetRoom()
    if not room then return end

    local pos = Isaac.WorldToScreen(npc.Position + npc.PositionOffset)
                + offset
                - room:GetRenderScrollOffset()
                - Game().ScreenShakeOffset

    local spr = npc:GetSprite()
    local s = spr.Scale
    local baseScale = Vector(s.X, s.Y)
    local c = spr.Color
    local baseColor = c and Color(c.R, c.G, c.B, c.A, c.RO, c.GO, c.BO)
                         or Color(1, 1, 1, 1)

    local layers = {
        { scale = 1.012, off = 2, alpha = 0.10 },
        { scale = 1.006, off = 1, alpha = 0.16 },
    }
    for _, layer in ipairs(layers) do
        spr.Scale = Vector(baseScale.X * layer.scale,
                           baseScale.Y * layer.scale)
        spr.Color = Color(0, 0, 0, layer.alpha, 1, 1, 1)
        for i = 0, 7 do
            local a = i * math.pi / 4
            spr:Render(pos + Vector(math.cos(a), math.sin(a)) * layer.off,
                       Vector.Zero, Vector.Zero)
        end
    end

    spr.Scale = baseScale
    spr.Color = baseColor
    spr:Render(pos, Vector.Zero, Vector.Zero)
end

-- ============================================================ 预警区渲染

local function onPostRender()
    local room = Game():GetRoom()
    if not room then return end
    local zone = getZone()

    for _, boss in ipairs(Moon:GetAll()) do
        if boss:Exists() and not boss:IsDead() then
            local bdata = Moon:GetData(boss, false)

            if bdata and bdata.AuraActive and bdata.State ~= S.APPEAR then
                local remain = (bdata.NextSkillAt or 0) - nowMs()
                local skill  = bdata.NextSkill
                local warnMs = (skill == "shove") and P.ShoveWarnMs
                               or P.FanWarnMs
                local heat   = warnHeat(remain, warnMs)

                if skill == "shove" and heat > 0 then
                    -- ---------- 推力预警：从上到下 10 条水平警戒线 ----------
                    local tl, br = room:GetTopLeftPos(), room:GetBottomRightPos()
                    if br.X > tl.X and br.Y > tl.Y then
                        local x0 = tl.X + GRID * 0.5
                        local x1 = br.X - GRID * 0.5
                        local y0 = tl.Y + GRID * 0.5
                        local y1 = br.Y - GRID * 0.5
                        for i = 0, 9 do
                            local y = y0 + (y1 - y0) * i / 9
                            zone:DrawAimed(room,
                                Vector(x0, y),
                                Vector(x1, y),
                                heat, 45)
                        end
                    end

                elseif skill == "fan3" and heat > 0 then
                    -- ---------- 每个弹道一条线 ----------
                    local target = nearestPlayer(boss.Position)
                    if target then
                        local count = bdata.NextFan3Count or P.SpiderShotCount
                        local base = (target.Position
                                      - boss.Position):GetAngleDegrees()
                        local half = (count - 1) / 2
                        for i = 0, count - 1 do
                            local ang = base
                                      + (i - half) * P.SpiderShotSpread
                            local dir = Vector.FromAngle(ang)
                            zone:DrawAimed(room, boss.Position,
                                boss.Position + dir * 400,
                                heat, 1)
                        end
                    end

                elseif skill == "fan10" and heat > 0 then
                    -- ---------- 半透明红色扇形区域 ----------
                    local target = nearestPlayer(boss.Position)
                    if target then
                        zone:DrawFan(room, boss.Position, target.Position,
                                     0.50 + 0.50 * heat,
                                     P.FanSkillArc, 21, nil, 0.22)
                    end
                end
            end
        end
    end

    -- ---------- 手冲刺预警：从手沿蓄力方向，1/4 房间长 ----------
    local roomW = room:GetGridWidth() * GRID
    local now = nowMs()
    for _, h in ipairs(Hand:GetAll()) do
        if h:Exists() then
            local hd = Hand:GetData(h, false)
            if hd and hd.Charging and hd.DashDir then
                local progress = 1 - ((hd.ChargeUntil or now) - now)
                                 / P.DashChargeMs
                progress = math.max(0, math.min(1, progress))
                zone:DrawAimed(room, h.Position,
                    h.Position + hd.DashDir * 200,
                    progress, 1, roomW * P.DashWarnLength)
            end
        end
    end
end

-- ============================================================ 注册

function Moon:Register(mod)
    Attacks.EnableInfiniteRange(mod, Moon.Type)

    mod:AddCallback(ModCallbacks.MC_POST_PLAYER_UPDATE, onPlayerUpdate)
    Bgm.Register(mod)
    mod:AddCallback(ModCallbacks.MC_POST_RENDER, onPostRender)
    StoneMod.EnableObstacleDestruction(Moon.Type)
    StoneMod.Register(mod)

    Moon:AddNpcCallback(mod, ModCallbacks.MC_POST_NPC_INIT,  onInit)
    Moon:AddNpcCallback(mod, ModCallbacks.MC_NPC_UPDATE,     onUpdate)
    Moon:AddNpcCallback(mod, ModCallbacks.MC_POST_NPC_DEATH, onDeath)
    Moon:AddNpcCallback(mod, ModCallbacks.MC_POST_NPC_RENDER, onMoonRender)
    Moon:AddNpcCallback(mod, ModCallbacks.MC_ENTITY_TAKE_DMG, onTakeDamage)
    mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, onRemove)

    Hand:AddNpcCallback(mod, ModCallbacks.MC_POST_NPC_INIT, handInit)
    Hand:AddNpcCallback(mod, ModCallbacks.MC_NPC_UPDATE,    handUpdate)
    Hand:AddNpcCallback(mod, ModCallbacks.MC_ENTITY_TAKE_DMG, handTakeDamage)
    Hand:AddNpcCallback(mod, ModCallbacks.MC_POST_NPC_RENDER, onHandRender)
    Hand:AddNpcCallback(mod, ModCallbacks.MC_POST_ENTITY_KILL, onHandKilled)
    mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, handRemove)
end

return Moon
