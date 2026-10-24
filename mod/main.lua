-- Mewboss 入口：注册 MOD、加载 BOSS 模块

local MOD_NAME = "Mewboss"
local MOD_VERSION = "1.0.0"

local mod = RegisterMod(MOD_NAME, 1)
mod.VERSION = MOD_VERSION

--- 统一的日志出口。所有输出都带 [Mewboss] 前缀
local function log(msg)
    Isaac.DebugString(("[%s] %s"):format(MOD_NAME, msg))
end

log(("loading v%s"):format(MOD_VERSION))

-- ============================================================ 加载 BOSS

local registry = require("scripts.bosses.init")
local loaded, failed = 0, 0

for _, entry in ipairs(registry) do
    local ok, bossOrErr = pcall(require, entry.file)

    if not ok then
        failed = failed + 1
        log(("FAILED to load module: %s | %s")
            :format(entry.name, tostring(bossOrErr)))
    else
        local ok2, err = pcall(function() bossOrErr:Register(mod) end)
        if not ok2 then
            failed = failed + 1
            log(("FAILED to register: %s | %s")
                :format(entry.name, tostring(err)))
        else
            loaded = loaded + 1
            log(("registered: %s"):format(entry.name))
        end
    end
end

log(("done - %d ok, %d failed"):format(loaded, failed))

if loaded == 0 and failed > 0 then
    log("WARNING: no boss registered, check the errors above")
end

-- ============================================================ 调试辅助

mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(_, isContinuing)
    log(("game started (isContinuing=%s), %d boss(es) registered")
        :format(tostring(isContinuing), loaded))
end)

return mod
