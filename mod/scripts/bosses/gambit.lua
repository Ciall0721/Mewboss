-- Gambit：六面骰驱动的形态 BOSS（506）

local ModEntity = require("scripts.shared.modentity")
local SM        = require("scripts.shared.statemachine")
local Attacks   = require("scripts.shared.attacks")
local U         = require("scripts.shared.util")
local Bgm       = require("scripts.shared.bgm")
local StoneMod  = require("scripts.entities.moonstone")

-- Gambit 与 Zodiac 使用同一首 BOSS 曲
local BGM_NAME = "Zodiac Desert Boss"

local GRID = 40

local DESTRUCTIBLE_GRID = {
    [GridEntityType.GRID_ROCK]        = true,
    [GridEntityType.GRID_ROCKB]       = true,
    [GridEntityType.GRID_ROCKT]       = true,
    [GridEntityType.GRID_ROCK_BOMB]   = true,
    [GridEntityType.GRID_ROCK_ALT]    = true,
    [GridEntityType.GRID_ROCK_SS]     = true,
    [GridEntityType.GRID_ROCK_SPIKED] = true,
    [GridEntityType.GRID_ROCK_ALT2]   = true,
    [GridEntityType.GRID_ROCK_GOLD]   = true,
    [GridEntityType.GRID_TNT]         = true,
    [GridEntityType.GRID_STATUE]      = true,
}

local Gambit = ModEntity.new("Gambit", "Gambit")
local Die    = ModEntity.new("Gambit Die", "GambitDie")
local Stone  = StoneMod.Entity

-- 发射单发弹幕的模式常量：0 = ONE_PROJECTILE
local ONE_PROJECTILE = 0

local beginAttack
local notifyDieOne
local notifyDieTwo

-- ============================================================ 参数
local P = {
    MoveSpeed        = 2.2,
    WalkShake        = 2,
    DecideMs         = 700,
    AttackCooldownMs = 5000,
    AlignTolerance   = 24,
    AlignRange       = 420,

    DiePushRadius      = 24,
    DiePushForce       = 6.0,
    DieDamping         = 0.90,
    DieMaxSpeed        = 8.0,
    DieRerollCooldown  = 1000,
    DieThrowSpeed      = 32,
    DieThrowMinRatio   = 0.25,
    DieThrowMaxRatio   = 0.60,
    DieKnockRadius     = 22,
    DieKnockForce      = 2.2,

    ThrowReleaseMs     = 1200,

    ConfusionDamage    = 10,
    LazerTimeout       = 20,
    QuakeRangeCells    = 9,
    QuakeStepMs        = 65,
    QuakeHitRadius     = 26,
    QuakeDamage        = 1.0,
    StormCount         = 5,
    StormDamage        = 1.0,
    StormHitRadius     = 34,
    StormHitDelayMs    = 500,
    WrathCount         = 30,
    WrathDamage        = 1.0,
    WrathMinRange      = 120,
    WrathMaxRange      = 520,
    StoneScale         = 1.1,
}

-- 各形态攻击动画的预期时长（毫秒），只用于结束兜底。
local ATTACK_DUR    = { 2720, 1320, 3000, 1820, 2740, 2740 }
-- 攻击效果触发时刻（毫秒）
local ATTACK_FX_MS  = { 800, 300, 800, 800, 1700, 2000 }

local FORM_ANIM = {
    "IdleConfusion", "IdlePoop", "IdleLazer",
    "IdleQuake", "IdleStorm", "IdleWrath",
}
-- 走路动画
local WALK_ANIM = {
    "WalkConfusion", "WalkPoop", "WalkLazer",
    "WalkQuake", "WalkStorm", "WalkWrath",
}
local ATTACK_ANIM = {
    "AttackConfusion", "AttackPoop", "AttackLazer",
    "AttackQuake", "AttackStorm", "AttackWrath",
}

-- ============================================================ 音效
local SND = {
    Confused = Isaac.GetSoundIdByName("Gambit Confused"),
    Reroll   = Isaac.GetSoundIdByName("Gambit Reroll"),
    Poop     = Isaac.GetSoundIdByName("Gambit Poop"),
    Jump     = Isaac.GetSoundIdByName("Gambit Jump"),
    Power    = Isaac.GetSoundIdByName("Gambit Power"),
    Dying    = Isaac.GetSoundIdByName("Gambit Dying"),
}

local playSnd      = U.playSnd
local nowMs        = U.now
local trace        = U.trace
local frame        = U.frame
local eachPlayer    = U.eachPlayer
local nearestPlayer = U.nearestPlayer
local randRange     = U.randRange

local function cellBlocked(room, idx)
    if idx < 0 then return true end
    local ge = room:GetGridEntity(idx)
    if ge and ge:GetType() == GridEntityType.GRID_PIT then
        return true
    end
    return SM.IsBlockedCell(room, idx)
end

--- 把一个位置吸附到最近的空旷格子中心
local function nearestFreePos(room, pos)
    local idx = room:GetGridIndex(pos)
    if idx < 0 then return nil end

    local gw, gh = room:GetGridWidth(), room:GetGridHeight()
    local cx, cy = idx % gw, math.floor(idx / gw)

    for r = 0, 8 do
        for dy = -r, r do
            for dx = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local gx, gy = cx + dx, cy + dy
                    if gx >= 0 and gx < gw and gy >= 0 and gy < gh then
                        local i = gy * gw + gx
                        if not cellBlocked(room, i) then
                            return room:GetGridPosition(i)
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function randomFreePos(room, insetX, insetY)
    local tl, br = room:GetTopLeftPos(), room:GetBottomRightPos()
    local w = math.max(1, math.floor(br.X - tl.X - insetX * 2))
    local h = math.max(1, math.floor(br.Y - tl.Y - insetY * 2))
    for _ = 1, 30 do
        local pos = Vector(tl.X + insetX + (Random() % w),
                           tl.Y + insetY + (Random() % h))
        local idx = room:GetGridIndex(pos)
        if idx >= 0 and not cellBlocked(room, idx) then
            return pos
        end
    end
    return Vector((tl.X + br.X) / 2, (tl.Y + br.Y) / 2)
end

-- ============================================================ 骰子工具

local KNOCK_TYPES = {
    [EntityType.ENTITY_TEAR]       = true,
    [EntityType.ENTITY_PROJECTILE] = true,
    [EntityType.ENTITY_LASER]      = true,
    [EntityType.ENTITY_KNIFE]      = true,
    [EntityType.ENTITY_BOMB]       = true,
}

local function findDie(bdata)
    if not bdata then return nil end
    local ref = bdata.DieRef
    if ref and ref:Exists()
       and bdata.DieHash
       and GetPtrHash(ref) == bdata.DieHash then
        return ref
    end

    local hash = bdata.DieHash
    if not hash then return nil end
    for _, d in ipairs(Die:GetAll()) do
        if d:Exists() and GetPtrHash(d) == hash then
            bdata.DieRef = d
            return d
        end
    end
    bdata.DieRef = nil
    return nil
end

--- 玩家幸运。幸运会影响骰子。
local function playerLuck()
    local best = 0
    eachPlayer(function(p)
        local l = p.Luck or 0
        if l > best then best = l end
    end)
    return best
end

local function pickValue()
    local luck = playerLuck()
    if luck > 0 then
        local t = math.min(luck / 25, 1)
        if (Random() % 10000) < math.floor(t * 10000) then
            return 1
        end
    end
    return randRange(1, 6)
end

--- 写点数。silent=true 用于初始生成，避免开局就触发 1 的技能。
local function setDieValue(die, value, silent)
    local d = Die:GetData(die, true)
    d.Value = value
    if value ~= 1 then d.OneTriggered = nil end
    if value ~= 2 then d.TwoTriggered = nil end
    die:GetSprite():Play("Face" .. value)
    if not silent then
        if value == 1 then
            notifyDieOne(die)
        elseif value == 2 then
            notifyDieTwo(die)
        end
    end
end

local function rerollDie(die)
    if not die or not die:Exists() then return end
    local d = Die:GetData(die, true)
    local old = d.Value
    local v = pickValue()
    trace("reroll %s->%d f=%d", tostring(old), v, frame())
    setDieValue(die, v)
    d.NextRerollAt = nowMs() + P.DieRerollCooldown
    playSnd(SND.Reroll, 0.8)
end

-- ============================================================ 石头弹后处理

local function applyFreshStones(npc, damage, scaleMin, scaleMax,
                                rangeMin, rangeMax, sizeFromRange)
    local hash = GetPtrHash(npc)
    local now = Game():GetFrameCount()

    for _, ent in ipairs(Isaac.FindByType(EntityType.ENTITY_PROJECTILE,
            Stone.Variant, -1, false, false)) do
        if ent.FrameCount == 0 and ent.SpawnerEntity
           and GetPtrHash(ent.SpawnerEntity) == hash then
            local pr = ent:ToProjectile()
            if pr then
                local speed = pr.Velocity:Length()
                if speed < 0.01 then speed = 8 end

                local range = randRange(rangeMin, rangeMax)
                pr:GetData().MewDieAt =
                    now + math.max(1, math.ceil(range / speed))

                if sizeFromRange then
                    local t = (range - rangeMin)
                              / math.max(1, rangeMax - rangeMin)
                    pr.Scale = scaleMin + (scaleMax - scaleMin) * t
                else
                    pr.Scale = scaleMin
                end

                pr.CollisionDamage = damage
                pr:GetSprite():Play("Flight", true)
            end
        end
    end
end

-- ============================================================ 骰子实体

local function dieInit(_, npc)
    local d = Die:GetData(npc, true)
    -- 只和网格碰撞；与玩家/怪物的接触全部交给 Lua。
    npc.EntityCollisionClass = EntityCollisionClass.ENTCOLL_NONE
    -- Cube Baby 同款：ground 网格碰撞（会被石头 / 便便挡住）
    npc.GridCollisionClass = EntityGridCollisionClass.GRIDCOLL_GROUND
    npc:SetSize(10.08, Vector(1, 1), 12)
    npc.CollisionDamage = 0
    npc.HitPoints = 1000
    npc.Velocity = Vector.Zero
    d.Value = pickValue()
    npc:GetSprite():Play("Face" .. d.Value)
end

local function dieTakeDamage()
    return false
end

local function dieRemove(_, ent)
    if ent.Type ~= Die.Type then return end
    Die:ClearData(ent)
end

local function dieUpdate(_, npc)
    local d = Die:GetData(npc, true)
    local spr = npc:GetSprite()

    npc.GridCollisionClass = EntityGridCollisionClass.GRIDCOLL_GROUND

    if not d.Value then
        d.Value = pickValue()
        spr:Play("Face" .. d.Value)
    end

    -- ---------- 被投掷：直线飞向目标点，落地当帧通知本体 ----------
    if d.FlyTo then
        local room = Game():GetRoom()
        local delta = d.FlyTo - npc.Position
        local dist = delta:Length()
        local arrived = dist <= P.DieThrowSpeed
        local nextPos = arrived and d.FlyTo
                        or (npc.Position
                            + delta:Normalized() * P.DieThrowSpeed)

        local blocked = false
        local ni = room:GetGridIndex(nextPos)
        if ni >= 0 and cellBlocked(room, ni) then
            blocked = true
        end

        if arrived or blocked then
            if not blocked then npc.Position = nextPos end
            d.FlyTo = nil
            npc.Velocity = Vector.Zero
            trace("land v=%d f=%d", d.Value, frame())

            if d.Value == 1 then
                notifyDieOne(npc)
            elseif d.Value == 2 then
                notifyDieTwo(npc)
            end
        else
            npc.Position = nextPos
        end
        return
    end

    if d.Hidden then return end

    -- ---------- Cube Baby 式滑行 ----------
    local room = Game():GetRoom()
    local tl, br = room:GetTopLeftPos(), room:GetBottomRightPos()

    local hitPlayer = false
    eachPlayer(function(p)
        local delta = npc.Position - p.Position
        local dist = delta:Length()
        if dist < P.DiePushRadius and dist > 0.01 then
            hitPlayer = true
            local closeness = 1 - dist / P.DiePushRadius
            npc:AddVelocity(delta:Normalized() * P.DiePushForce * closeness)
        end
    end)

    for _, ent in ipairs(Isaac.GetRoomEntities()) do
        if KNOCK_TYPES[ent.Type] then
            local delta = npc.Position - ent.Position
            local dist = delta:Length()
            if dist < P.DieKnockRadius and dist > 0.01 then
                local closeness = 1 - dist / P.DieKnockRadius
                npc:AddVelocity(delta:Normalized()
                                * P.DieKnockForce * closeness)
            end
        end
    end

    npc.Velocity = npc.Velocity * P.DieDamping
    local v = npc.Velocity
    if v:Length() > P.DieMaxSpeed then
        npc.Velocity = v:Normalized() * P.DieMaxSpeed
    end

    -- ---------- 重投：碰到玩家 / 墙 / 障碍（边沿触发） ----------
    local wallMargin = (npc.Size or 7) + 2
    local nearWall = (npc.Position.X - tl.X <= wallMargin)
                  or (br.X - npc.Position.X <= wallMargin)
                  or (npc.Position.Y - tl.Y <= wallMargin)
                  or (br.Y - npc.Position.Y <= wallMargin)
    local touchedWorld = nearWall or npc:CollidesWithGrid()

    -- 边沿检测每帧更新；冷却只决定是否重投
    local fresh = (hitPlayer and not d.PlayerHit)
               or (touchedWorld and not d.WallHit)
    d.PlayerHit = hitPlayer
    d.WallHit   = touchedWorld

    if fresh and nowMs() >= (d.NextRerollAt or 0) then
        rerollDie(npc)
    end

end

-- ============================================================ 攻击效果

--- 混乱：随后对自己造成 10 点伤害
local function fxConfusion(npc)
    playSnd(SND.Confused)
    npc:TakeDamage(P.ConfusionDamage, 0, EntityRef(npc), 0)
end

--- 大便：在身后生成一个网格便便
local function fxPoop(npc)
    playSnd(SND.Poop)
    local target = nearestPlayer(npc.Position)
    local dir = target and (target.Position - npc.Position):Normalized()
                or Vector(1, 0)
    local room = Game():GetRoom()
    local side = Vector(-dir.Y, dir.X)
    local candidates = {
        npc.Position - dir * 50,
        npc.Position - dir * 50 + side * 30,
        npc.Position - dir * 50 - side * 30,
    }
    for _, pos in ipairs(candidates) do
        local idx = room:GetGridIndex(pos)
        if idx >= 0 and not cellBlocked(room, idx) then
            Isaac.GridSpawn(GridEntityType.GRID_POOP, 0,
                            room:GetGridPosition(idx), false)
            return
        end
    end
end

--- 激光：朝玩家的水平 / 竖直方向发射
local function fxLazer(npc)
    local p = nearestPlayer(npc.Position)
    local ang
    if p then
        local dx = p.Position.X - npc.Position.X
        local dy = p.Position.Y - npc.Position.Y
        if math.abs(dx) >= math.abs(dy) then
            ang = (dx >= 0) and 0 or 180
        else
            ang = (dy >= 0) and 90 or 270
        end
    else
        ang = ((Random() % 2) == 0) and 0 or 90
    end
    EntityLaser.ShootAngle(LaserVariant.THICK_RED, npc.Position, ang,
                           P.LazerTimeout, Vector.Zero, npc)
end

--- 裂地波：参考 804.0.0（地震石像头）——同时向四个对角线方向炸开地面。
local function fxQuake(npc, data)
    local room = Game():GetRoom()
    local gw, gh = room:GetGridWidth(), room:GetGridHeight()
    local idx = room:GetGridIndex(npc.Position)
    if idx < 0 then return end
    local gx, gy = idx % gw, math.floor(idx / gw)

    local now = nowMs()
    data.QuakeCells = data.QuakeCells or {}

    local center = room:GetGridPosition(idx)
    table.insert(data.QuakeCells, {
        x = center.X, y = center.Y, cell = idx, at = now,
    })

    for _, d in ipairs({ {1, 1}, {1, -1}, {-1, 1}, {-1, -1} }) do
        for step = 1, P.QuakeRangeCells - 1 do
            local cx, cy = gx + d[1] * step, gy + d[2] * step
            if cx < 0 or cx >= gw or cy < 0 or cy >= gh then break end
            local cell = cy * gw + cx
            local pos = room:GetGridPosition(cell)
            table.insert(data.QuakeCells, {
                x = pos.X, y = pos.Y, cell = cell,
                at = now + step * P.QuakeStepMs,
            })
        end
    end

    SFXManager():Play(SoundEffect.SOUND_ROCK_CRUMBLE, 0.7, 0, false, 1.0)
end

--- 风暴：5 道原版圣光
local function fxStorm(npc, data)
    local room = Game():GetRoom()
    local tl, br = room:GetTopLeftPos(), room:GetBottomRightPos()
    local w = math.max(1, math.floor(br.X - tl.X - 120))
    local h = math.max(1, math.floor(br.Y - tl.Y - 120))

    data.LightStrikes = data.LightStrikes or {}
    for _ = 1, P.StormCount do
        local x = tl.X + 60 + (Random() % w)
        local y = tl.Y + 60 + (Random() % h)
        Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.CRACK_THE_SKY, 0,
                    Vector(x, y), Vector.Zero, npc)
        table.insert(data.LightStrikes, {
            x = x, y = y,
            at = nowMs() + P.StormHitDelayMs,
        })
    end
end

--- 愤怒：全屏 30 发随机角度/射程/尺寸的石头弹
local function fxWrath(npc)
    local params = Attacks.Params({
        variant       = Stone.Variant,
        scale         = P.StoneScale,
        fallingSpeed  = 2,
        fallingAccel  = -0.08,
        gridCollision = false,
    })
    local speed = 8
    for _ = 1, P.WrathCount do
        local dir = Vector.FromAngle(Random() % 360)
        npc:FireProjectiles(npc.Position, dir * speed,
                            ONE_PROJECTILE, params)
    end
    applyFreshStones(npc, P.WrathDamage, 0.6, 1.8,
                     P.WrathMinRange, P.WrathMaxRange, true)
end

local FX = { fxConfusion, fxPoop, fxLazer, fxQuake, fxStorm, fxWrath }

-- ============================================================ 本体

beginAttack = function(npc, data, form)
    data.State       = "ATTACK"
    data.Initial     = false
    data.AttackForm  = form
    data.AttackStartedAt = nowMs()
    data.AttackDur    = ATTACK_DUR[form] or 3000
    data.FxAt         = nowMs() + (ATTACK_FX_MS[form] or 1000)
    data.FxPending    = true
    data.TraceAt      = nil

    -- 2~6 形态的攻击共用 5 秒冷却（1 形态不受限、也不占用冷却）
    if form >= 2 and form <= 6 then
        data.AttackReadyAt = nowMs() + P.AttackCooldownMs
    end

    local p = nearestPlayer(npc.Position)
    local spr = npc:GetSprite()
    if p then
        data.Facing = (p.Position.X >= npc.Position.X) and 1 or -1
        spr.FlipX = data.Facing < 0
    end
    spr.PlaybackSpeed = (form == 3) and 2.0 or 1.0
    spr:Play(ATTACK_ANIM[form], true)
    trace("atk form=%d f=%d", form, frame())
    if form == 6 then playSnd(SND.Power) end
end

--- 骰子点数变成 1：立刻打断本体当前动作并播放混乱攻击。
notifyDieOne = function(die)
    local d = Die:GetData(die, false)
    if not d or d.OneTriggered then return end
    d.OneTriggered = true

    trace("notify1 f=%d", frame())
    local hash = GetPtrHash(die)
    for _, b in ipairs(Gambit:GetAll()) do
        local bd = Gambit:GetData(b, false)
        if bd and bd.DieHash == hash and not bd.Dying then
            beginAttack(b, bd, 1)
            return
        end
    end
end

--- 骰子点数变成 2：立刻打断本体当前动作，原地蓄力 1 秒后放一次大便攻击。
notifyDieTwo = function(die)
    local d = Die:GetData(die, false)
    if not d or d.TwoTriggered then return end
    d.TwoTriggered = true

    trace("notify2 f=%d", frame())
    local hash = GetPtrHash(die)
    for _, b in ipairs(Gambit:GetAll()) do
        local bd = Gambit:GetData(b, false)
        if bd and bd.DieHash == hash and not bd.Dying then
            bd.State = "LAND_CHARGE"
            -- 落到 2：原地蓄力 1 秒后攻击，不等冷却
            bd.LandChargeUntil = nowMs() + 1000
            bd.ThrowDone = true
            bd.Initial = false
            b.Velocity = Vector.Zero
            b:GetSprite().PlaybackSpeed = 1.0
            b:GetSprite():Play("Idle")
            return
        end
    end
end

local function startThrow(npc, data, die)
    trace("throw f=%d", frame())
    data.State = "THROW"
    data.ThrowStartedAt = nowMs()
    data.ThrowDone = false
    data.ThrowAngle = Random() % 360
    npc:GetSprite().PlaybackSpeed = 1.0
    data.Facing = (Vector.FromAngle(data.ThrowAngle).X >= 0) and 1 or -1
    npc:GetSprite().FlipX = data.Facing < 0
    playSnd(SND.Jump)

    if die then
        local d = Die:GetData(die, true)
        data.DieHome = die.Position
        d.Hidden = true
        die.Visible = false
    end

    npc:GetSprite():Play("ThrowDie", true)
end

local function releaseDie(npc, data)
    local die = findDie(data)
    if not die then return end

    local d = Die:GetData(die, true)
    d.Hidden = false
    die.Visible = true
    die.Position = data.DieHome or npc.Position
    die.Velocity = Vector.Zero
    trace("release f=%d", frame())

    local room = Game():GetRoom()
    local tl, br = room:GetTopLeftPos(), room:GetBottomRightPos()
    local r = die.Size or 7
    local roomW = room:GetGridWidth() * GRID

    local ang  = data.ThrowAngle or (Random() % 360)
    local minD = roomW * P.DieThrowMinRatio
    local maxD = math.max(minD + 80, roomW * P.DieThrowMaxRatio)
    local dist = randRange(math.floor(minD), math.floor(maxD))

    local target = die.Position + Vector.FromAngle(ang) * dist
    target = Vector(
        math.max(tl.X + r, math.min(br.X - r, target.X)),
        math.max(tl.Y + r, math.min(br.Y - r, target.Y))
    )

    -- 落点不能落在石头 / 便便等障碍物里
    local tidx = room:GetGridIndex(target)
    if tidx >= 0 and cellBlocked(room, tidx) then
        target = nearestFreePos(room, target) or target
    end

    d.FlyTo = target
end

local function bossInit(_, npc)
    local data = Gambit:GetData(npc, true)
    data.State     = "MOVE"
    data.Initial   = true
    data.Facing    = 1
    data.AttackReadyAt = 0

    local room = Game():GetRoom()
    local diePos = randomFreePos(room, 100, 80)

    local die = Isaac.Spawn(Die.Type, Die.Variant, 0, diePos,
                            Vector.Zero, npc)
    if die then
        data.DieHash = GetPtrHash(die)
        setDieValue(die, pickValue(), true)
    end

    npc:GetSprite():Play("Idle")
    playSnd(SND.Jump, 0.6)
    -- 与 Zodiac 同一首；介绍页结束后会被房间曲顶掉，所以强制一段时间
    Bgm.Enforce(BGM_NAME, 8000)
end

local function playFormAnim(npc, value, moving)
    local spr = npc:GetSprite()
    local walk = moving and WALK_ANIM[value]
    local anim = walk or FORM_ANIM[value] or "Idle"
    if not spr:IsPlaying(anim) then
        spr.PlaybackSpeed = walk and 2.0 or 1.0
        spr:Play(anim)
    end
end

local function bossUpdate(_, npc)
    local data = Gambit:GetData(npc, true)
    local spr  = npc:GetSprite()
    local room = Game():GetRoom()

    if npc.HitPoints <= 0 then
        if not data.Dying then
            data.Dying = true
            spr:Play("Death", true)
            playSnd(SND.Dying)
            Bgm.StopEnforce()
            MusicManager():Fadeout()
            Bgm.RestoreAfterMs(3000)
            local die = findDie(data)
            if die then die:Remove() end
        end
        return
    end

    -- 只和房间墙碰撞；石头 / 便便 / 已摧毁残骸的阻挡全部由 Lua 寻路处理。
    npc.GridCollisionClass = EntityGridCollisionClass.GRIDCOLL_WALLS

    local die   = findDie(data)
    local ddata = die and Die:GetData(die, false)
    local value = ddata and ddata.Value or 0

    npc.CollisionDamage = 1
    spr.FlipX = (data.Facing or 1) < 0

    -- 走路抖动只影响渲染；非移动状态每帧归零
    npc.PositionOffset = Vector.Zero

    -- 兜底（参考 Zodiac）：本体被外力挤进障碍物格时，朝最近空格挪一小步
    local myIdx = room:GetGridIndex(npc.Position)
    if myIdx >= 0 and cellBlocked(room, myIdx) then
        local free = nearestFreePos(room, npc.Position)
        if free then
            local d = free - npc.Position
            if d:Length() > 0.01 then
                npc.Position = npc.Position
                    + d:Normalized() * math.min(P.MoveSpeed, d:Length())
            end
        end
    end

    -- 圣光延迟结算（只打玩家）
    if data.LightStrikes then
        for i = #data.LightStrikes, 1, -1 do
            local st = data.LightStrikes[i]
            if nowMs() >= st.at then
                eachPlayer(function(p)
                    if p.Position:Distance(Vector(st.x, st.y))
                       <= P.StormHitRadius then
                        p:TakeDamage(P.StormDamage, 0, EntityRef(npc), 0)
                    end
                end)
                table.remove(data.LightStrikes, i)
            end
        end
        if #data.LightStrikes == 0 then data.LightStrikes = nil end
    end

    -- 裂地波结算（804 地震石像头式：地面炸开、打碎障碍、伤害玩家）
    if data.QuakeCells then
        for i = #data.QuakeCells, 1, -1 do
            local q = data.QuakeCells[i]
            if nowMs() >= q.at then
                Isaac.Spawn(EntityType.ENTITY_EFFECT,
                            EffectVariant.ROCK_EXPLOSION, 0,
                            Vector(q.x, q.y), Vector.Zero, npc)
                eachPlayer(function(p)
                    if p.Position:Distance(Vector(q.x, q.y))
                       <= P.QuakeHitRadius then
                        p:TakeDamage(P.QuakeDamage, 0, EntityRef(npc), 0)
                    end
                end)
                local ge = room:GetGridEntity(q.cell)
                if ge and DESTRUCTIBLE_GRID[ge:GetType()] then
                    ge:Destroy(false)
                end
                table.remove(data.QuakeCells, i)
            end
        end
        if #data.QuakeCells == 0 then data.QuakeCells = nil end
    end

    -- ======================================================== MOVE
    if data.State == "MOVE" then
        local goDie = data.Initial or value < 3 or value == 0
        local target = nil
        if goDie then
            if die and ddata and not ddata.Hidden then target = die end
        else
            target = nearestPlayer(npc.Position)
        end

        if target then
            local delta = target.Position - npc.Position
            if delta:Length() > 1 then
                if delta.X ~= 0 then
                    data.Facing = (delta.X > 0) and 1 or -1
                end

                -- 每 10 帧或到达路点时重新寻路
                data.PathTimer = (data.PathTimer or 0) - 1
                local needRepath = (data.PathTimer <= 0)
                    or (not data.Waypoint)
                    or npc.Position:Distance(data.Waypoint) < 16

                if needRepath then
                    data.PathTimer = 10
                    local extra
                    local gw, gh = room:GetGridWidth(), room:GetGridHeight()
                    for i = 0, gw * gh - 1 do
                        local ge = room:GetGridEntity(i)
                        if ge and ge:GetType() == GridEntityType.GRID_PIT then
                            extra = extra or {}
                            extra[i] = true
                        end
                    end
                    data.Waypoint = SM.NextWaypoint(room, npc.Position,
                                                    target.Position, extra)
                end

                local desired
                if data.Waypoint then
                    local toWp = data.Waypoint - npc.Position
                    desired = (toWp:Length() > 2) and toWp:Normalized()
                              or delta:Normalized()
                else
                    desired = SM.Steer(room, npc.Position,
                                       delta:Normalized(), GRID * 1.2)
                end

                npc.Velocity = SM.MoveVelocity(npc, desired, P.MoveSpeed, 0.3)

                local nextIdx = room:GetGridIndex(npc.Position + npc.Velocity)
                if nextIdx >= 0 and cellBlocked(room, nextIdx) then
                    npc.Velocity = Vector.Zero
                end
            else
                npc.Velocity = Vector.Zero
                data.Waypoint = nil
            end
        else
            npc.Velocity = Vector.Zero
            data.Waypoint = nil
        end

        local wantMove = target
            and target.Position:Distance(npc.Position) > 1
        if wantMove then
            data.StuckAt = data.StuckAt or nowMs()
            if nowMs() - data.StuckAt >= 500 then
                if data.StuckPos
                   and npc.Position:Distance(data.StuckPos) < 3 then
                    local idx = room:GetGridIndex(npc.Position)
                    if idx >= 0 then
                        npc.Position = room:GetGridPosition(idx)
                    end
                    data.Waypoint = nil
                    data.PathTimer = 0
                    local ge = idx >= 0 and room:GetGridEntity(idx) or nil
                    trace("unstick boss f=%d t=%s s=%s", frame(),
                          ge and tostring(ge:GetType()) or "nil",
                          ge and tostring(ge.State) or "-")
                end
                data.StuckAt = nowMs()
                data.StuckPos = npc.Position
            end
        else
            data.StuckAt = nil
            data.StuckPos = nil
        end

        -- 移动时才播放走路动画；停下立即回到待机
        local moving = npc.Velocity:Length() > 0.01
        playFormAnim(npc, value, moving)

        if moving then
            local a = P.WalkShake
            npc.PositionOffset = Vector((Random() % (a * 2 + 1)) - a,
                                        (Random() % (a * 2 + 1)) - a)
        end

        -- 碰到骰子 -> 决策
        local touchRange = (npc.Size or 12) + (die and die.Size or 7)
        if die then
            local di = room:GetGridIndex(die.Position)
            if di >= 0 and cellBlocked(room, di) then
                touchRange = touchRange + GRID + 8
            end
        end
        if goDie and die and ddata and not ddata.Hidden
           and npc.Position:Distance(die.Position) <= touchRange then
            npc.Velocity = Vector.Zero
            data.State = "DECIDE"
            data.DecideAt = nowMs() + P.DecideMs
            data.DieHome = die.Position
            spr:Play("Idle")
            return
        end

        -- 3/4/5/6 追击玩家的主动攻击（共享 5 秒冷却）
        if not goDie and value >= 3 and value <= 6
           and nowMs() >= (data.AttackReadyAt or 0) then
            local p = nearestPlayer(npc.Position)
            if p then
                local dx = p.Position.X - npc.Position.X
                local dy = p.Position.Y - npc.Position.Y
                local dist = math.sqrt(dx * dx + dy * dy)
                local doAttack = false

                if value == 3 then
                    doAttack = dist <= P.AlignRange
                        and (math.abs(dx) <= P.AlignTolerance
                             or math.abs(dy) <= P.AlignTolerance)
                elseif value == 4 then
                    doAttack = dist <= P.AlignRange
                        and math.abs(math.abs(dx) - math.abs(dy))
                            <= P.AlignTolerance
                else
                    doAttack = true
                end

                if doAttack then
                    beginAttack(npc, data, value)
                end
            end
        end

    -- ======================================================== DECIDE
    elseif data.State == "DECIDE" then
        npc.Velocity = Vector.Zero
        if nowMs() >= (data.DecideAt or 0) then
            -- 碰到骰子后投掷
            startThrow(npc, data, die)
        end

    -- ======================================================== ATTACK
    elseif data.State == "ATTACK" then
        npc.Velocity = Vector.Zero

        if data.FxPending and nowMs() >= data.FxAt then
            data.FxPending = false
            local fn = FX[data.AttackForm]
            if fn then fn(npc, data) end
        end

        local elapsed  = nowMs() - (data.AttackStartedAt or nowMs())
        local expected = data.AttackDur or 3000
        local anim     = ATTACK_ANIM[data.AttackForm]

        if nowMs() >= (data.TraceAt or 0) then
            data.TraceAt = nowMs() + 500
            trace("atk tick form=%d t=%d spr=%d", data.AttackForm,
                  elapsed, spr:GetFrame())
        end

        local minShown = expected * 0.6
        local finished = spr:IsFinished(anim)
        if (elapsed >= minShown and finished) or elapsed >= expected * 3 then
            if data.FxPending then
                data.FxPending = false
                local fn = FX[data.AttackForm]
                if fn then fn(npc, data) end
            end
            trace("atk end form=%d f=%d", data.AttackForm, frame())
            data.State = "MOVE"
        end

    -- ======================================================== THROW
    elseif data.State == "THROW" then
        npc.Velocity = Vector.Zero

        -- 动画启动 1 秒后骰子飞出
        if not data.ThrowDone
           and nowMs() - (data.ThrowStartedAt or nowMs()) >= P.ThrowReleaseMs then
            data.ThrowDone = true
            releaseDie(npc, data)
        end

        -- 动画结束且骰子已落地才恢复行动
        local landed = not ddata or not ddata.FlyTo
        if landed and data.ThrowDone
           and (spr:IsFinished("ThrowDie")
                or nowMs() - (data.ThrowStartedAt or nowMs()) >= 12000) then
            data.Initial = false
            data.State = "MOVE"
        end

    -- ======================================================== LAND_CHARGE
    elseif data.State == "LAND_CHARGE" then
        npc.Velocity = Vector.Zero
        if nowMs() >= (data.LandChargeUntil or 0) then
            if value == 2 then
                beginAttack(npc, data, 2)
            else
                -- 蓄力期间骰子已经不是 2：取消这次 2 技能
                trace("cancel2 v=%d f=%d", value, frame())
                data.State = "MOVE"
            end
        end
    end
end

local function bossDeath(_, npc)
    local data = Gambit:GetData(npc, false)
    if data then
        local die = findDie(data)
        if die then die:Remove() end
    end
end

--- 本体不受自己生成的圣光/激光伤害。
local function bossTakeDamage(_, npc, amount, flags, source, countdown)
    local src = source and source.Entity
    if src then
        local t = src.Type
        if (t == EntityType.ENTITY_EFFECT or t == EntityType.ENTITY_LASER)
           and src.SpawnerEntity
           and GetPtrHash(src.SpawnerEntity) == GetPtrHash(npc) then
            return false
        end
    end
end

local function bossRemove(_, ent)
    if ent.Type ~= Gambit.Type then return end
    Gambit:ClearData(ent)
end

-- ============================================================ 注册

function Gambit:Register(mod)
    StoneMod.Register(mod)
    Bgm.Register(mod)

    Gambit:AddNpcCallback(mod, ModCallbacks.MC_POST_NPC_INIT, bossInit)
    Gambit:AddNpcCallback(mod, ModCallbacks.MC_NPC_UPDATE, bossUpdate)
    Gambit:AddNpcCallback(mod, ModCallbacks.MC_POST_NPC_DEATH, bossDeath)
    Gambit:AddNpcCallback(mod, ModCallbacks.MC_ENTITY_TAKE_DMG, bossTakeDamage)
    mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, bossRemove)

    Die:AddNpcCallback(mod, ModCallbacks.MC_POST_NPC_INIT, dieInit)
    Die:AddNpcCallback(mod, ModCallbacks.MC_NPC_UPDATE, dieUpdate)
    Die:AddNpcCallback(mod, ModCallbacks.MC_ENTITY_TAKE_DMG, dieTakeDamage)
    mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, dieRemove)
end

return Gambit
