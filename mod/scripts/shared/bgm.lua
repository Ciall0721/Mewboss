-- 专属 BGM 的播放、强制保持与恢复

local U = require("scripts.shared.util")

local Bgm = {}

local restoreAt = nil
local registered = false

local enforceName = nil
local enforceUntil = 0
local enforceNextAt = 0

--- 播放专属 BOSS 曲。
function Bgm.Play(name)
    local id = Isaac.GetMusicIdByName(name)
    if id and id > 0 then
        MusicManager():Crossfade(id, 0.05)
    end
end

function Bgm.Enforce(name, ms)
    enforceName   = name
    enforceUntil  = U.now() + (ms or 8000)
    enforceNextAt = 0
    Bgm.Play(name)
end

function Bgm.StopEnforce()
    enforceName   = nil
    enforceUntil  = 0
    enforceNextAt = 0
end

--- BOSS 死亡后延时恢复房间原曲
function Bgm.RestoreAfterMs(ms)
    restoreAt = U.now() + ms
end

function Bgm.Update()
    if enforceName then
        local now = U.now()
        if now < enforceUntil then
            if now >= enforceNextAt then
                enforceNextAt = now + 500
                local id = Isaac.GetMusicIdByName(enforceName)
                if id and id > 0
                   and MusicManager():GetCurrentMusicID() ~= id then
                    Bgm.Play(enforceName)
                end
            end
        else
            enforceName = nil
        end
    end

    if not restoreAt then return end
    if U.now() < restoreAt then return end
    restoreAt = nil
    local room = Game():GetRoom()
    if room then room:PlayMusic() end
end

--- 注册延时恢复的执行点
function Bgm.Register(mod)
    if registered then return end
    registered = true
    mod:AddCallback(ModCallbacks.MC_POST_UPDATE, Bgm.Update)
end

return Bgm
