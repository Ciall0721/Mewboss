-- BOSS 状态机与网格寻路工具

local SM = {}

--- 切换状态，并清零子状态与状态计时。
function SM.SetState(npc, data, state)
    npc.I1 = state
    npc.I2 = 0
    data.State = state
    data.StateTime = 0
end

--- 每帧推进状态计时
function SM.Tick(data, simSpeed)
    data.StateTime = (data.StateTime or 0) + (simSpeed or 1)
end

--- 当前状态已持续帧数是否达到 n
function SM.Elapsed(data, n)
    return (data.StateTime or 0) >= n
end

function SM.MoveVelocity(npc, targetVec, speed, inertia)
    inertia = inertia or 0.3
    return npc.Velocity * inertia + targetVec:Resized(speed) * (1 - inertia)
end

-- ============================================================ 避障

local OBSTACLE = {
    [GridEntityType.GRID_ROCK]        = true,
    [GridEntityType.GRID_ROCKB]       = true,
    [GridEntityType.GRID_ROCKT]       = true,
    [GridEntityType.GRID_ROCK_BOMB]   = true,
    [GridEntityType.GRID_ROCK_ALT]    = true,
    [GridEntityType.GRID_ROCK_SS]     = true,
    [GridEntityType.GRID_ROCK_SPIKED] = true,
    [GridEntityType.GRID_ROCK_ALT2]   = true,
    [GridEntityType.GRID_ROCK_GOLD]   = true,

    [GridEntityType.GRID_SPIKES]       = true,
    [GridEntityType.GRID_SPIKES_ONOFF] = true,

    [GridEntityType.GRID_FIREPLACE]    = true,
    [GridEntityType.GRID_POOP]         = true,
    [GridEntityType.GRID_TNT]          = true,
    [GridEntityType.GRID_STATUE]       = true,
    [GridEntityType.GRID_WALL]         = true,

    [GridEntityType.GRID_PIT]          = true,
}

--- 两点之间有没有通透的视线
function SM.HasClearLine(room, from, to)
    if not room:CheckLine(from, to, 0, 0, false, false) then
        return false
    end

    local delta = to - from
    local dist  = delta:Length()
    if dist < 1 then return true end

    local steps = math.max(1, math.floor(dist / 20))
    for i = 1, steps do
        local idx = room:GetGridIndex(from + delta * (i / steps))
        if SM.IsBlockedCell(room, idx) then
            return false
        end
    end

    return true
end

--- 这个格子是不是障碍物。
function SM.IsBlockedCell(room, idx)
    if idx < 0 then return true end

    local ge = room:GetGridEntity(idx)
    if not ge then return false end

    local t = ge:GetType()
    if t == GridEntityType.GRID_NULL then return false end
    -- 便便 State >= 1000 表示已摧毁，残骸不挡路
    if t == GridEntityType.GRID_POOP and (ge.State or 0) >= 1000 then
        return false
    end
    return OBSTACLE[t] == true
end

local STEER_ANGLES = { 0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150 }

local PROBE_FRACS = { 0.5, 1.0, 1.6 }

function SM.Steer(room, fromPos, desired, probeDist)
    for _, deg in ipairs(STEER_ANGLES) do
        local d = desired:Rotated(deg)
        local free = true

        for _, frac in ipairs(PROBE_FRACS) do
            local idx = room:GetGridIndex(fromPos + d:Resized(probeDist * frac))
            if SM.IsBlockedCell(room, idx) then
                free = false
                break
            end
        end

        if free then return d end
    end

    return desired
end

-- ============================================================ 网格寻路

local DIRS8 = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}

function SM.NextWaypoint(room, fromPos, toPos, extraBlocked)
    local function blocked(idx)
        return (extraBlocked ~= nil and extraBlocked[idx] == true)
            or SM.IsBlockedCell(room, idx)
    end

    local gw, gh = room:GetGridWidth(), room:GetGridHeight()
    local startIdx = room:GetGridIndex(fromPos)
    local goalIdx  = room:GetGridIndex(toPos)

    if startIdx < 0 or goalIdx < 0 then return nil end
    if startIdx == goalIdx then return toPos end

    if blocked(goalIdx) then
        local gx, gy = goalIdx % gw, math.floor(goalIdx / gw)
        local fixed = nil
        for _, d in ipairs(DIRS8) do
            local nx, ny = gx + d[1], gy + d[2]
            if nx >= 0 and nx < gw and ny >= 0 and ny < gh then
                local ni = ny * gw + nx
                if not blocked(ni) then fixed = ni; break end
            end
        end
        if not fixed then return nil end
        goalIdx = fixed
    end

    local prev  = { [startIdx] = -1 }
    local queue = { startIdx }
    local head  = 1
    local found = false

    while head <= #queue do
        local cur = queue[head]; head = head + 1
        if cur == goalIdx then found = true; break end

        local cx, cy = cur % gw, math.floor(cur / gw)

        for _, d in ipairs(DIRS8) do
            local nx, ny = cx + d[1], cy + d[2]
            if nx >= 0 and nx < gw and ny >= 0 and ny < gh then
                local ni = ny * gw + nx
                if prev[ni] == nil and not blocked(ni) then
                    -- 斜走禁止切角：两个正交邻格都得通
                    local ok = true
                    if d[1] ~= 0 and d[2] ~= 0 then
                        if blocked(cy * gw + nx) or blocked(ny * gw + cx) then
                            ok = false
                        end
                    end
                    if ok then
                        prev[ni] = cur
                        queue[#queue + 1] = ni
                    end
                end
            end
        end
    end

    if not found then return nil end

    -- ---- 回溯到起点的下一步 ----
    local node = goalIdx
    while node ~= startIdx do
        local p = prev[node]
        if p == nil or p == -1 then return nil end
        if p == startIdx then
            return room:GetGridPosition(node)
        end
        node = p
    end

    return toPos
end

return SM
