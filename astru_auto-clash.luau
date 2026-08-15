-- [[ astru auto clash ]]

-- API
local AutoClash = {}

-- tuning
local RED_HOLD    = 0.25
local RADIUS_MULT = 1.30
local SPAM_INTERVAL = 0.05

-- estado
local S = {
    enabled      = false,
    active       = false,
    activeAt     = 0,
    lastValidAt  = 0,
    lastTargetAt = 0,
    lastTargetId = nil,
}

-- deps
local GameInfo, Utils, AutoParry

-- aliases
local function now()       return Utils.now() end
local function getLP()     return Utils.getLocalPlayer() end
local function getBall()   return Utils.getBall() end

-- setup deps
local function waitDeps()
    local t0 = os.clock()
    while not _G.AstruModules do
        if os.clock() - t0 > 5 then
            warn("[astru autoclash] _G.AstruModules indisponivel apos 5s")
            return false
        end
        task.wait(0.05)
    end

    local m = _G.AstruModules
    GameInfo, Utils, AutoParry = m.GameInfo, m.Utils, m.AutoParry

    if not (Utils and AutoParry) then
        warn("[astru autoclash] deps faltando em _G.AstruModules")
        return false
    end
    return true
end

-- toggle
local function uiEnabled()
    if _G.AstruClashOwner == "test" then
        return false
    end
    if typeof(_G.AstruAutoClash) == "boolean" then
        return _G.AstruAutoClash
    end
    local cfg = _G.AstruConfig
    return cfg and typeof(cfg.AutoClash) == "boolean" and cfg.AutoClash or false
end

-- ativacao
local function isBallTargeted(ctx)
    return ctx and ctx.targeted == true
end

local function ballInSpamRange(hr, ball, dist)
    if not (hr and ball) then return false end
    if type(dist) ~= "number" or dist <= 0 then return false end
    local ok, d = pcall(function() return (hr.Position - ball.Position).Magnitude end)
    return ok and typeof(d) == "number" and d <= dist
end

local function spamRadius(ctx)
    local r = ctx and ctx.parryRadius
    if type(r) ~= "number" or r <= 0 then return 8 end
    return r * RADIUS_MULT
end

local function nearestInRange(myHRP, dist)
    if not (myHRP and type(dist) == "number" and dist > 0) then return false end
    local lp = getLP()
    for _, p in ipairs(game:GetService("Players"):GetPlayers()) do
        if p ~= lp then
            local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                local ok, d = pcall(function() return (myHRP.Position - hrp.Position).Magnitude end)
                if ok and typeof(d) == "number" and d <= dist then
                    return true
                end
            end
        end
    end
    return false
end

-- contexto
local function getParryContext(t, hr, ball)
    local sync = AutoParry.getSync()
    local spd  = sync and sync.Speed or 0
    return {
        time        = t,
        hr          = hr,
        ball        = ball,
        targeted    = AutoParry.isTargeted(),
        parryRadius = AutoParry.computeParryRadius(spd),
        sync        = sync,
        spd         = spd,
    }
end

-- lifecycle
local function activate(t)
    S.active      = true
    S.activeAt    = t
    S.lastValidAt = t
end

local function deactivate()
    S.active      = false
    S.activeAt    = 0
    S.lastValidAt = 0
end

local function shouldActivate(t, ctx)
    if not (ctx.hr and ctx.ball) then return false end
    if not isBallTargeted(ctx) then return false end
    local r = spamRadius(ctx)
    if not ballInSpamRange(ctx.hr, ctx.ball, r) then return false end
    if not nearestInRange(ctx.hr, r) then return false end
    return true
end

local function shouldDeactivate(t, ctx)
    if not (ctx.hr and ctx.ball) then return true end
    if not isBallTargeted(ctx) then return true end
    local r = spamRadius(ctx)
    if not ballInSpamRange(ctx.hr, ctx.ball, r) then return true end
    if not nearestInRange(ctx.hr, r) then return true end
    local last = S.lastValidAt or S.activeAt or 0
    if (t - last) >= RED_HOLD then
        return true
    end
    return false
end

-- API publica
function AutoClash.evaluate(t, hr, ball, config)
    if not uiEnabled() then
        if S.enabled or S.active then
            S.enabled = false
            deactivate()
        end
        return
    end

    S.enabled = true
    local ctx = getParryContext(t, hr, ball)

    if S.active then
        local r = spamRadius(ctx)
        if isBallTargeted(ctx)
            and ballInSpamRange(ctx.hr, ctx.ball, r)
            and nearestInRange(ctx.hr, r)
        then
            S.lastValidAt = t
        end
        if shouldDeactivate(t, ctx) then
            deactivate()
        end
    elseif shouldActivate(t, ctx) then
        activate(t)
    end
end

-- callbacks
local function onTarget(targetId)
    S.lastTargetAt = now()
    S.lastTargetId = targetId
end

local function onTeleport()
    deactivate()
end

-- spam loop
local _spamConn, _lastFire = nil, 0

local function startSpamLoop()
    if _spamConn then return end
    _spamConn = game:GetService("RunService").Heartbeat:Connect(function()
        if not uiEnabled() or not S.active or not Utils or not Utils.forceParry then
            if S.active then deactivate() end
            return
        end
        local t = os.clock()
        if (t - _lastFire) < SPAM_INTERVAL then return end
        Utils.forceParry()
        _lastFire = t
    end)
end

local function stopSpamLoop()
    if _spamConn then _spamConn:Disconnect(); _spamConn = nil end
end

-- setup
local function setup()
    if not waitDeps() then return false end

    Utils.setOnClashOn(function() return S.active end)
    Utils.setOnTarget(onTarget)
    Utils.setOnTeleport(onTeleport)

    startSpamLoop()

    _G.AstruModules.AutoClash = AutoClash
    return true
end

-- API
function AutoClash.getState()
    return {
        active      = S.active,
        activeAt    = S.activeAt,
        enabled     = S.enabled,
        lastValidAt = S.lastValidAt,
    }
end

function AutoClash.reset()
    S.enabled  = false
    S.lastFire = 0
    deactivate()
end

-- bootstrap
task.spawn(setup)
