-- 公共工具函数

local U = {}

--- 真实毫秒
function U.now()
    return Isaac.GetTime()
end

--- 引擎帧数
function U.frame()
    return Game():GetFrameCount()
end

--- 遍历全部在场玩家
function U.eachPlayer(fn)
    for i = 0, Game():GetNumPlayers() - 1 do
        local p = Game():GetPlayer(i)
        if p and p:Exists() then fn(p) end
    end
end

--- 离 pos 最近的玩家
function U.nearestPlayer(pos)
    local best, bestD = nil, math.huge
    U.eachPlayer(function(p)
        local d = pos:Distance(p.Position)
        if d < bestD then best, bestD = p, d end
    end)
    return best
end

--- [lo, hi] 闭区间随机整数
function U.randRange(lo, hi)
    return lo + (Random() % (hi - lo + 1))
end

--- 播放自定义音效
function U.playSnd(id, volume)
    if id and id > 0 then
        SFXManager():Play(id, volume or 1.0, 0, false, 1.0)
    end
end

-- 调试追踪开关
local TRACE = false

function U.trace(fmt, ...)
    if TRACE then
        Isaac.DebugString("[DBG] " .. string.format(fmt, ...))
    end
end

return U
