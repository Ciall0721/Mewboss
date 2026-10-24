-- BOSS 池：StageAPI 注册；无 StageAPI 时运行时替换

local ModEntity = require("scripts.shared.modentity")

-- 楼层分组
local BASEMENT_STAGES = {
    [LevelStage.STAGE1_1] = true,
    [LevelStage.STAGE1_2] = true,
}
local MINES_STAGES = {
    [LevelStage.STAGE2_1] = true,
    [LevelStage.STAGE2_2] = true,
}
local BASEMENT_TYPES = {
    [StageType.STAGETYPE_ORIGINAL]   = true,
    [StageType.STAGETYPE_WOTL]       = true,
    [StageType.STAGETYPE_AFTERBIRTH] = true,
}
local MINES_TYPES = {
    [StageType.STAGETYPE_REPENTANCE]   = true,
    [StageType.STAGETYPE_REPENTANCE_B] = true,
}
local POOL_GROUPS = {
    basement = { stages = { LevelStage.STAGE1_1, LevelStage.STAGE1_2 },
                 types  = BASEMENT_TYPES },
    mines    = { stages = { LevelStage.STAGE2_1, LevelStage.STAGE2_2 },
                 types  = MINES_TYPES },
}

local C = {
    -- 兜底模式（无 StageAPI）下每个 BOSS 房替换的概率
    Chance = 0.5,

    -- 兜底模式允许的楼层（LevelStage）
    Stages = {
        [LevelStage.STAGE1_1] = true,
        [LevelStage.STAGE1_2] = true,
        [LevelStage.STAGE2_1] = true,
        [LevelStage.STAGE2_2] = true,
    },

    -- 兜底模式的可选 BOSS、权重、出现楼层与楼层类型
    Bosses = {
        { name = "Zodiac",          weight = 1,
          stages = BASEMENT_STAGES, types = BASEMENT_TYPES },
        { name = "Man in the Moon", weight = 1,
          stages = MINES_STAGES,    types = MINES_TYPES },
        { name = "Gambit",          weight = 1,
          stages = BASEMENT_STAGES, types = BASEMENT_TYPES },
    },
}

-- StageAPI 用的 BOSS 定义（id 是存档 / 池子里的键，必须唯一）
local BOSS_DEFS = {
    { id = "Mewgenics Zodiac", type = 501, variant = 0, pool = "basement",
      portrait = "gfx/ui/boss/portrait_501.0_zodiac.png",
      bossname = "gfx/ui/boss/bossname_501.0_zodiac.png" },
    { id = "Mewgenics Moon",   type = 502, variant = 0, pool = "mines",
      portrait = "gfx/ui/boss/portrait_502.0_maninthemoon.png",
      bossname = "gfx/ui/boss/bossname_502.0_maninthemoon.png" },
    { id = "Mewgenics Gambit", type = 506, variant = 0, pool = "basement",
      portrait = "gfx/ui/boss/portrait_506.0_gambit.png",
      bossname = "gfx/ui/boss/bossname_506.0_gambit.png" },
}

local stageAPIConfigured = false
local stageAPIFailed = false

-- ============================================================ StageAPI

local function doConfigureStageAPI()
    -- 单实体 BOSS 房布局
    for _, d in ipairs(BOSS_DEFS) do
        StageAPI.AddBossData(d.id, {
            Name     = d.id,
            Entity   = { Type = d.type, Variant = d.variant, SubType = 0 },
            -- BOSS 战前介绍页（versusscreen 的 BossPortrait / BossName 图层）
            Portrait = d.portrait,
            BossName = d.bossname,
            Rooms    = StageAPI.CreateSingleEntityRoomList(
                           d.type, d.variant, 0,
                           d.id .. " Rooms", RoomType.ROOM_BOSS,
                           d.id .. " Room"),
        })
    end

    -- 按楼层分组追加到各楼层池
    for poolName, group in pairs(POOL_GROUPS) do
        for _, stage in ipairs(group.stages) do
            for _, stype in ipairs(StageAPI.StageTypes or {}) do
                if group.types[stype] then
                    local info = StageAPI.GetBaseFloorInfo(stage, stype)
                    if info and info.Bosses then
                        local pool = info.Bosses.Pool or info.Bosses
                        for _, d in ipairs(BOSS_DEFS) do
                            if d.pool == poolName then
                                info.HasCustomBosses = true
                                table.insert(pool,
                                    { BossID = d.id, Weight = 1 })
                            end
                        end
                    end
                end
            end
        end
    end

end

--- 注册 BossData 并把 BOSS 加进对应楼层的池。
local function configureStageAPI()
    if stageAPIConfigured then return true end
    if stageAPIFailed then return false end
    if not StageAPI or not StageAPI.AddBossData
       or not StageAPI.CreateSingleEntityRoomList
       or not StageAPI.GetBaseFloorInfo then
        return false
    end

    local ok, err = pcall(doConfigureStageAPI)
    if not ok then
        stageAPIFailed = true
        Isaac.DebugString("[Mewboss] StageAPI config failed: "
            .. tostring(err))
        return false
    end

    stageAPIConfigured = true
    if StageAPI.LogMinor then
        StageAPI.LogMinor(
            "Mewgenics: bosses added to basement / mines boss pools")
    end
    Isaac.DebugString("[Mewboss] StageAPI: bosses added to boss pools")
    return true
end

-- ============================================================ 兜底：运行时替换

local function resolve()
    for _, b in ipairs(C.Bosses) do
        if not b.Handle then
            b.Handle = ModEntity.new(b.name, b.name)
        end
    end
end

local function pickBoss()
    -- 按当前楼层 + 楼层类型过滤
    local level = Game():GetLevel()
    local stage = level:GetStage()
    local stype = level:GetStageType()
    local candidates, total = {}, 0
    for _, b in ipairs(C.Bosses) do
        if (not b.stages or b.stages[stage])
           and (not b.types or b.types[stype]) then
            candidates[#candidates + 1] = b
            total = total + b.weight
        end
    end
    if total <= 0 or #candidates == 0 then return nil end

    local roll = (Random() % 10000) / 10000 * total
    local acc = 0
    for _, b in ipairs(candidates) do
        acc = acc + b.weight
        if roll < acc then return b end
    end
    return candidates[#candidates]
end

local function modBossPresent()
    for _, b in ipairs(C.Bosses) do
        if b.Handle and #b.Handle:GetAll() > 0 then return true end
    end
    return false
end

local function onNewRoom()
    -- 有 StageAPI 就交给它处理（BOSS 在房间生成阶段就已经选好）
    if configureStageAPI() then return end

    local room = Game():GetRoom()
    if not room or room:GetType() ~= RoomType.ROOM_BOSS then return end
    if room:IsClear() then return end

    local stage = Game():GetLevel():GetStage()
    if not C.Stages[stage] then return end
    if modBossPresent() then return end

    local vanilla, pos = {}, nil
    for _, ent in ipairs(Isaac.GetRoomEntities()) do
        local npc = ent:ToNPC()
        if npc and npc:IsBoss() then
            table.insert(vanilla, npc)
            pos = pos or npc.Position
        end
    end
    if not pos or #vanilla == 0 then return end

    if (Random() % 10000) >= math.floor(C.Chance * 10000) then return end

    local pick = pickBoss()
    if not pick or not pick.Handle then return end

    local boss = Isaac.Spawn(pick.Handle.Type, pick.Handle.Variant, 0,
                             pos, Vector.Zero, nil)
    if not boss then return end
    for _, npc in ipairs(vanilla) do
        if npc:Exists() then npc:Remove() end
    end
end

-- ============================================================ 注册

local Pool = {}

function Pool:Register(mod)
    resolve()

    -- StageAPI 可能晚于本 MOD 加载，主菜单每帧补一次注册
    configureStageAPI()
    mod:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
        if not stageAPIConfigured and not stageAPIFailed then
            configureStageAPI()
        end
    end)

    mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, onNewRoom)
end

return Pool
