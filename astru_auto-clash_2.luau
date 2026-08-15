-- [[ astru auto clash 2 ]]

-- API
local AutoClash2 = {}

-- tuning
local RED_HOLD    = 0.25
local SPAM_INTERVAL = 0.05

-- auto-ativacao por "target return"
local TARGET_RETURN_MAX_LO = 0.180      -- janela folgada (vs 0.110 do original)
local TARGET_RETURN_MIN_HI = 0.110      -- (vs 0.060 do original)
local TARGET_RETURN_SPD_LO = 60
local TARGET_RETURN_SPD_HI = 200

-- desativacao mais dificil
local DEACT_RADIUS_MULT = 1.15          -- +15% no raio de parry pra desativar

-- estado
local S = {
    enabled      = false,
    active       = false,
    activeAt     = 0,
    lastValidAt  = 0,
    lastTargetAt = 0,
    lastTargetId = nil,
    wasMeTarget  = false,
    lostMeAt     = 0,
}

-- deps
local GameInfo, Utils, AutoParry

-- aliases
local function now()       return Utils.now() end
local function getLP()     return Utils.getLocalPlayer() end
local function getBall()   return Utils.getBall() end
local function getConfig() return _G.AstruConfig or {} end

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
    if _G.AstruClashOwner ~= "test" then
        return false
    end
    if typeof(_G.AstruAutoClash2) == "boolean" then
        return _G.AstruAutoClash2
    end
    local cfg = _G.AstruConfig
    return cfg and typeof(cfg.AutoClash2) == "boolean" and cfg.AutoClash2 or false
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

local function deactivationRadius(ctx)
    -- +15% sobre o raio base: mais dificil de desativar
    local r = ctx and ctx.parryRadius
    if type(r) ~= "number" or r <= 0 then return 8 end
    return r * DEACT_RADIUS_MULT
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

-- target return window (mesma logica do autoclash, porem afrouxada)
local function getTargetReturnWindow(speed)
    if speed >= TARGET_RETURN_SPD_HI then
        return TARGET_RETURN_MIN_HI
    end
    if speed <= TARGET_RETURN_SPD_LO then
        return TARGET_RETURN_MAX_LO
    end
    local alpha = (speed - TARGET_RETURN_SPD_LO) / (TARGET_RETURN_SPD_HI - TARGET_RETURN_SPD_LO)
    return TARGET_RETURN_MAX_LO + (TARGET_RETURN_MIN_HI - TARGET_RETURN_MAX_LO) * alpha
end

local function getBallSpeed(ball)
    if not ball or not ball.Parent then return 0 end
    local ok, v = pcall(function() return ball.AssemblyLinearVelocity end)
    if not ok or typeof(v) ~= "Vector3" then return 0 end
    return v.Magnitude
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

-- (ativacao agora eh 100% via onTarget -> target return. sem shouldActivate.)

local function shouldDeactivate(t, ctx)
    if not (ctx.hr and ctx.ball) then return true end
    if not isBallTargeted(ctx) then return true end
    local r = deactivationRadius(ctx)            -- raio +15% aqui
    if not ballInSpamRange(ctx.hr, ctx.ball, r) then return true end
    if not nearestInRange(ctx.hr, r) then return true end
    local last = S.lastValidAt or S.activeAt or 0
    if (t - last) >= RED_HOLD then
        return true
    end
    return false
end

-- API publica
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
        local r = deactivationRadius(ctx)        -- refresh lastValidAt com raio +15%
        if isBallTargeted(ctx)
            and ballInSpamRange(ctx.hr, ctx.ball, r)
            and nearestInRange(ctx.hr, r)
        then
            S.lastValidAt = t
        end
        if shouldDeactivate(t, ctx) then
            deactivate()
        end
    end
    -- enquanto inativo, NAO ativa aqui. soh o onTarget pode ativar.
end

-- callbacks
local function onTarget(targetId)
    local t = now()
    S.lastTargetAt = t
    S.lastTargetId = targetId

    -- auto-ativacao por target return (espelha a logica do autoclash.luau)
    if type(targetId) ~= "number" then return end
    local lp = getLP()
    if not lp then return end
    local userId = lp.UserId
    local isMe  = targetId == userId
    local wasMe = S.wasMeTarget

    if wasMe and not isMe then
        -- deixei de ser target
        S.wasMeTarget = true
        S.lostMeAt    = t
        return
    end

    if not isMe or wasMe or not S.wasMeTarget then
        return
    end

    -- voltei a ser target dentro da janela -> ativa
    local ball   = getBall()
    local speed  = getBallSpeed(ball)
    local window = getTargetReturnWindow(speed)
    local elapsed = t - (S.lostMeAt or 0)
    if elapsed <= window then
        activate(t)
    end
    S.wasMeTarget = false
    S.lostMeAt    = 0
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

    Utils.addOnClashOn(function() return S.active end)
    Utils.addOnTarget(onTarget)
    Utils.addOnTeleport(onTeleport)

    startSpamLoop()

    _G.AstruModules.AutoClash2 = AutoClash2
    return true
end

-- API
function AutoClash2.getState()
    return {
        active      = S.active,
        activeAt    = S.activeAt,
        enabled     = S.enabled,
        lastValidAt = S.lastValidAt,
    }
end

function AutoClash2.reset()
    S.enabled  = false
    S.lastFire = 0
    S.wasMeTarget = false
    S.lostMeAt    = 0
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

AutoClash2.enable = AutoClash2.activate
AutoClash2.disable = AutoClash2.deactivate

function AutoClash2.setEnabled(value)
    return value and AutoClash2.activate() or AutoClash2.deactivate()
end

function AutoClash2.isEnabled()
    return _G.AstruAutoClash2 == true and getConfig().AutoClash2 == true
end

-- bootstrap
task.spawn(setup)
