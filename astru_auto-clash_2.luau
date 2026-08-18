-- [[ astru auto clash 2 ]]

-- tuning
local RED_HOLD = 0.220
local SPAM_INTERVAL = 0.05

local TARGET_RETURN_MAX_LO = 0.210
local TARGET_RETURN_MIN_HI = 0.120
local TARGET_RETURN_SPD_LO = 60
local TARGET_RETURN_SPD_HI = 200

local PHYS_SPD_REF = 120
local PHYS_DOT_EMA = 0.25
local PHYS_THRESH = 0.14
local PHYS_RAD_SLACK = 1.22
local ACT_RADIUS_MULT = 1.27
local DEACT_RADIUS_MULT = 1.08

-- state
local S = {
    enabled = false,
    active = false,
    activeAt = 0,
    lastValidAt = 0,
    lastTargetAt = 0,
    lastTargetId = nil,
    wasMeTarget = false,
    lostMeAt = 0,
    physDotEma = 0,
}

-- dependencies
local GameInfo, Utils, AutoParry
local _spamConn, _lastFire = nil, 0

local AutoClash2 = {}

-- helpers
local function now()
    return Utils.now()
end

local function getLP()
    return Utils.getLocalPlayer()
end

local function getBall()
    return Utils.getBall()
end

local function getConfig()
    return _G.AstruConfig or {}
end

local function waitDeps()
    local started = os.clock()

    while not _G.AstruModules do
        if os.clock() - started > 5 then
            warn("[astru autoclash] _G.AstruModules indisponivel apos 5s")
            return false
        end

        task.wait(0.05)
    end

    local modules = _G.AstruModules
    GameInfo = modules.GameInfo
    Utils = modules.Utils
    AutoParry = modules.AutoParry

    if not (Utils and AutoParry) then
        warn("[astru autoclash] deps faltando em _G.AstruModules")
        return false
    end

    return true
end

local function uiEnabled()
    if _G.AstruClashOwner ~= "test" then
        return false
    end

    if typeof(_G.AstruAutoClash2) == "boolean" then
        return _G.AstruAutoClash2
    end

    local config = _G.AstruConfig
    return config
        and typeof(config.AutoClash2) == "boolean"
        and config.AutoClash2
        or false
end

local function isBallTargeted(ctx)
    return ctx and ctx.targeted == true
end

local function ballInRange(hr, ball, distance)
    if not (hr and ball) then
        return false
    end

    if type(distance) ~= "number" or distance <= 0 then
        return false
    end

    local ok, currentDistance = pcall(function()
        return (hr.Position - ball.Position).Magnitude
    end)

    return ok and typeof(currentDistance) == "number" and currentDistance <= distance
end

local function getDeactivationRadius(ctx)
    local radius = ctx and ctx.parryRadius

    if type(radius) ~= "number" or radius <= 0 then
        return 8
    end

    return radius * DEACT_RADIUS_MULT
end

local function getActivationRadius(ctx)
    local radius = ctx and ctx.parryRadius

    if type(radius) ~= "number" or radius <= 0 then
        return 8
    end

    return radius * ACT_RADIUS_MULT
end

local function nearestInRange(myHRP, distance)
    if not (myHRP and type(distance) == "number" and distance > 0) then
        return false
    end

    local localPlayer = getLP()

    for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
        if player ~= localPlayer then
            local character = player.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")

            if hrp then
                local ok, currentDistance = pcall(function()
                    return (myHRP.Position - hrp.Position).Magnitude
                end)

                if ok and typeof(currentDistance) == "number" and currentDistance <= distance then
                    return true
                end
            end
        end
    end

    return false
end

-- context
local function getParryContext(t, hr, ball)
    local sync = AutoParry.getSync()
    local speed = sync and sync.Speed or 0

    return {
        time = t,
        hr = hr,
        ball = ball,
        targeted = AutoParry.isTargeted(),
        parryRadius = AutoParry.computeParryRadius(speed),
        sync = sync,
        spd = speed,
    }
end

local function getTargetReturnWindow(speed)
    if speed >= TARGET_RETURN_SPD_HI then
        return TARGET_RETURN_MIN_HI
    end

    if speed <= TARGET_RETURN_SPD_LO then
        return TARGET_RETURN_MAX_LO
    end

    local alpha = (speed - TARGET_RETURN_SPD_LO)
        / (TARGET_RETURN_SPD_HI - TARGET_RETURN_SPD_LO)

    return TARGET_RETURN_MAX_LO
        + (TARGET_RETURN_MIN_HI - TARGET_RETURN_MAX_LO) * alpha
end

local function getBallSpeed(ball)
    if not ball or not ball.Parent then
        return 0
    end

    local ok, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if not ok or typeof(velocity) ~= "Vector3" then
        return 0
    end

    return velocity.Magnitude
end

local function tickPhysical(ctx)
    local hr = ctx and ctx.hr
    local ball = ctx and ctx.ball

    if not (hr and hr.Parent and ball and ball.Parent) then
        S.physDotEma = 0
        return false
    end

    local ok, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if not ok or typeof(velocity) ~= "Vector3" then
        S.physDotEma = 0
        return false
    end

    local speed = velocity.Magnitude

    if speed <= 1 then
        S.physDotEma = 0
        return false
    end

    local offset = hr.Position - ball.Position
    local distance = offset.Magnitude

    if distance < 0.001 then
        S.physDotEma = 0
        return false
    end

    local radius = getActivationRadius(ctx)
    local dot = velocity:Dot(offset.Unit)

    if distance <= radius * PHYS_RAD_SLACK then
        S.physDotEma = S.physDotEma * (1 - PHYS_DOT_EMA) + dot * PHYS_DOT_EMA
    else
        S.physDotEma = 0
    end

    return distance <= radius and S.physDotEma > PHYS_THRESH
end

-- lifecycle
local function activate(t)
    S.active = true
    S.activeAt = t
    S.lastValidAt = t
end

local function deactivate()
    S.active = false
    S.activeAt = 0
    S.lastValidAt = 0
end

local function shouldDeactivate(t, ctx)
    if not (ctx.hr and ctx.ball) then
        return true
    end

    if not isBallTargeted(ctx) then
        return true
    end

    local radius = getDeactivationRadius(ctx)

    if not ballInRange(ctx.hr, ctx.ball, radius) then
        return true
    end

    if not nearestInRange(ctx.hr, radius) then
        return true
    end

    local lastValid = S.lastValidAt or S.activeAt or 0

    return (t - lastValid) >= RED_HOLD
end

-- callbacks
local function onTarget(targetId)
    local t = now()
    S.lastTargetAt = t
    S.lastTargetId = targetId
    if type(targetId) ~= "number" then
        return
    end

    local localPlayer = getLP()

    if not localPlayer then
        return
    end

    local isMe = targetId == localPlayer.UserId

    if isMe then
        local lostAt = S.lostMeAt or 0

        if lostAt > 0 then
            local character = localPlayer.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            local ball = getBall()

            if hrp and ball and ball.Parent then
                local speed = getBallSpeed(ball)
                local window = getTargetReturnWindow(speed)
                local elapsed = t - lostAt

                if elapsed <= window then
                    local okSync, sync = pcall(function()
                        return AutoParry.getSync()
                    end)

                    local syncSpeed = okSync and sync and sync.Speed or 0

                    local okRadius, parryRadius = pcall(function()
                        return AutoParry.computeParryRadius(syncSpeed)
                    end)

                    local baseRadius = okRadius
                        and type(parryRadius) == "number"
                        and parryRadius > 0
                        and parryRadius
                        or 8

                    local activationRadius = baseRadius * ACT_RADIUS_MULT

                    local okDistance, distance = pcall(function()
                        return (hrp.Position - ball.Position).Magnitude
                    end)

                    if okDistance and distance <= activationRadius then
                        activate(t)
                    end
                end
            end
        end

        S.wasMeTarget = true
        S.lostMeAt = 0
        return
    end

    if S.wasMeTarget then
        S.lostMeAt = t
    end
end

local function onTeleport()
    deactivate()
end

-- spam
local function startSpamLoop()
    if _spamConn then
        return
    end

    _spamConn = game:GetService("RunService").Heartbeat:Connect(function()
        if not uiEnabled() or not S.active or not Utils or not Utils.forceParry then
            if S.active then
                deactivate()
            end
            return
        end

        local t = os.clock()

        if t - _lastFire < SPAM_INTERVAL then
            return
        end

        Utils.forceParry()
        _lastFire = t
    end)
end

local function stopSpamLoop()
    if _spamConn then
        _spamConn:Disconnect()
        _spamConn = nil
    end
end

-- setup
local function setup()
    if not waitDeps() then
        return false
    end

    Utils.addOnClashOn(function()
        return S.active
    end)

    Utils.addOnTarget(onTarget)
    Utils.addOnTeleport(onTeleport)

    startSpamLoop()

    _G.AstruModules.AutoClash2 = AutoClash2

    return true
end

-- api
function AutoClash2.evaluate(t, hr, ball, config)
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
        local radius = getDeactivationRadius(ctx)

        if isBallTargeted(ctx)
            and ballInRange(ctx.hr, ctx.ball, radius)
            and nearestInRange(ctx.hr, radius)
        then
            S.lastValidAt = t
        end

        if shouldDeactivate(t, ctx) then
            deactivate()
        end
    elseif tickPhysical(ctx) then
        activate(t)
    end
end

function AutoClash2.getState()
    return {
        active = S.active,
        activeAt = S.activeAt,
        enabled = S.enabled,
        lastValidAt = S.lastValidAt,
    }
end

function AutoClash2.reset()
    S.enabled = false
    S.lastTargetAt = 0
    S.lastTargetId = nil
    S.wasMeTarget = false
    S.lostMeAt = 0
    S.physDotEma = 0

    _lastFire = 0

    deactivate()
end

local function setOwner(enabled)
    if enabled then
        _G.AstruClashOwner = "test"
        _G.AstruAutoClash = false

        if type(_G.AstruConfig) == "table" then
            _G.AstruConfig.AutoClash = false
        end
    elseif _G.AstruClashOwner == "test" then
        _G.AstruClashOwner = nil
    end
end

function AutoClash2.activate()
    _G.AstruAutoClash2 = true

    if type(_G.AstruConfig) == "table" then
        _G.AstruConfig.AutoClash2 = true
    end

    setOwner(true)

    return true
end

function AutoClash2.deactivate()
    _G.AstruAutoClash2 = false

    if type(_G.AstruConfig) == "table" then
        _G.AstruConfig.AutoClash2 = false
    end

    deactivate()
    setOwner(false)

    return true
end

function AutoClash2.setEnabled(value)
    return value and AutoClash2.activate() or AutoClash2.deactivate()
end

function AutoClash2.isEnabled()
    return _G.AstruAutoClash2 == true
        and getConfig().AutoClash2 == true
end

AutoClash2.enable = AutoClash2.activate
AutoClash2.disable = AutoClash2.deactivate

-- bootstrap
task.spawn(setup)