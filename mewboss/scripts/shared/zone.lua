-- 预警光束绘制（复用原版牵引光束美术）

local Zone = {}
Zone.__index = Zone

local TEX_W, TEX_H = 32, 64
local BAND_PX      = 21
local GRID_PX      = 40

-- 颜色随充能由冷渐变到红
local COLD_TINT = { 1.00, 1.00, 1.00 }
local HOT_TINT  = { 1.80, 0.28, 0.24 }
local ALPHA_MAX = 0.75

local function lerp(a, b, t)
    return a + (b - a) * t
end

local VANILLA_TRACTOR_BEAM = "gfx/007.007_tractorbeam laser.anm2"

function Zone.new(anm2path)
    local self = setmetatable({}, Zone)

    self.sprite = Sprite()
    self.sprite:Load(anm2path or VANILLA_TRACTOR_BEAM, true)
    self.sprite:Play("RedLaser")

    -- 缓冲，避免每帧新建 Vector
    self._zero = Vector.Zero
    return self
end

function Zone:HeatColor(heat, alphaScale)
    heat = math.max(0, math.min(1, heat or 0))
    return Color(
        lerp(COLD_TINT[1], HOT_TINT[1], heat),
        lerp(COLD_TINT[2], HOT_TINT[2], heat),
        lerp(COLD_TINT[3], HOT_TINT[3], heat),
        heat * ALPHA_MAX * (alphaScale or 1))
end

local function rayLength(room, origin, dir, maxLen)
    local lo, hi = 0.0, maxLen
    for _ = 1, 7 do
        local mid = (lo + hi) * 0.5
        local probe = origin + dir * mid
        if room:CheckLine(origin, probe, 0, 0, false, false) then
            lo = mid
        else
            hi = mid
        end
    end
    return lo
end

function Zone:DrawAimed(room, centerPos, targetPos, heat, step, maxDistance,
                        alphaScale)
    heat = heat or 0

    if heat <= 0.005 then return end

    local spr = self.sprite
    if not spr or not spr:IsLoaded() then return end

    local o = Isaac.WorldToScreen(Vector(0, 0))
    local unit = (Isaac.WorldToScreen(Vector(GRID_PX, 0)) - o).X
    if unit <= 0 then return end

    step = step or 45
    local ang  = (targetPos - centerPos):GetAngleDegrees()
    local snap
    if step > 0 then
        snap = math.floor((ang + step / 2) / step) * step % 360
    else
        snap = ang
    end
    local dir  = Vector.FromAngle(snap)

    local maxLen = maxDistance
                   or GRID_PX * (room:GetGridWidth() + room:GetGridHeight())
    local len = rayLength(room, centerPos, dir, maxLen)
    if len <= GRID_PX then return end

    -- 单位统一
    local screenPerWorld = unit / GRID_PX

    spr.Scale    = Vector(unit / BAND_PX, (len * screenPerWorld) / TEX_H)
    spr.Rotation = snap - 90
    spr.Color    = self:HeatColor(heat, alphaScale)
    spr:Render(Isaac.WorldToScreen(centerPos) + Game().ScreenShakeOffset,
               self._zero, self._zero)
end

-- 扇形警戒区
function Zone:DrawFan(room, centerPos, targetPos, heat, arcDeg, beams,
                      maxDistance, alphaScale)
    if (heat or 0) <= 0.005 then return end

    beams   = math.max(2, beams or 21)
    arcDeg  = arcDeg or 30
    local base = (targetPos - centerPos):GetAngleDegrees()
    local step = arcDeg / (beams - 1)

    for i = 0, beams - 1 do
        local a = base - arcDeg / 2 + step * i
        local dir = Vector.FromAngle(a)
        self:DrawAimed(room, centerPos, centerPos + dir * 400,
                       heat, 1, maxDistance, alphaScale or 0.07)
    end
end

return Zone
