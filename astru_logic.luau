-- [[ astru logic ]]

-- metadata
local SCRIPT_NAME    = "astruk hub"
local SCRIPT_VERSION = "4"
local SCRIPT_AUTHOR  = "ppzudo"

-- config inicial
local Players       = game:GetService("Players")
local RunService    = game:GetService("RunService")
local Replicated    = game:GetService("ReplicatedStorage")
local Stats         = game:GetService("Stats")
local UIS           = game:GetService("UserInputService")
local TweenService  = game:GetService("TweenService")
local CoreGui       = game:GetService("CoreGui")
local Workspace     = game:GetService("Workspace")

local lp  = Players.LocalPlayer
local ws  = workspace
local now = os.clock
local V3  = Vector3.zero

-- prebuffer
local C = {
    LEAD_REACT_T    = 0.040,
    PB_BASE_MS      = 85,
    PB_JITTER_MULT  = 1.4,
    PB_DRIFT_FLOOR  = 20,
    PB_DRIFT_MULT   = 0.6,
    PB_FPS_FACTOR   = 0.020,
    PB_CAP_MS       = 200,
    PB_FLOOR_MS     = 35,
}

-- parry
local P = {
    FIRE_LOCK                  = 0.080,
    MIN_SPD                    = 3,
    DEFLECT_R                  = 8,
    RAD_FLOOR                  = 14,
    PB_WEIGHT                  = 1.0,
    RES_BASE                   = 0,
    RES_PER_PARRY              = 0.6,
    RES_CAP                    = 6.0,
    RES_HOLD_T                 = 1.2,
    RES_DECAY_T                = 4.0,
    RES_HITBOX_OWN_WINDOW      = 0.5,
    RES_HITBOX_PROX            = 12,
}

-- constantes
local PING_EMA             = 0.5
local PING_MAX             = 0.150
local PING_SAMPLE          = 2.5
local TELEPORT_LOCK        = 0.20
local BALL_CACHE_TTL       = 0.5
local PING_BOOT_FALLBACK   = 0.060
local SPAM_CPF             = 16
local SPAM_CPS             = 16
local SPAM_FPS_EMA         = 0.08

-- meta global
_G.AstruMeta = {
    name    = SCRIPT_NAME,
    version = SCRIPT_VERSION,
    author  = SCRIPT_AUTHOR,
}

-- config
_G.AstruConfig = _G.AstruConfig or {
    AutoParry        = true,
    AutoClash        = true,
    AutoClash2       = false,
    CPF              = SPAM_CPF,
    CPS              = SPAM_CPS,
    SpamRateMode     = "CPF",
    CustomCPF        = false,
    Keybind          = Enum.KeyCode.V,
    SpamKeybind      = Enum.KeyCode.X,
    SpamMode         = "Toggle",
    ClashBallVisible = false,
    BtnX             = nil,
    BtnY             = nil,
    ClashBallX       = 14,
    ClashBallY       = nil,
    MiniX            = nil,
    MiniY            = nil,
    PanelX           = nil,
    PanelY           = nil,
}

-- normalizacao
local function normalizeSpamConfig()
    local cfg = _G.AstruConfig
    if type(cfg) ~= "table" then
        cfg = {}
        _G.AstruConfig = cfg
    end

    if type(cfg.CPF) ~= "number" or cfg.CPF <= 0 then
        cfg.CPF = SPAM_CPF
    end
    if type(cfg.CPS) ~= "number" or cfg.CPS <= 0 then
        cfg.CPS = cfg.CPF or SPAM_CPS
    end
    if cfg.SpamRateMode ~= "CPS" and cfg.SpamRateMode ~= "CPF" then
        cfg.SpamRateMode = "CPF"
    end

    return cfg
end

normalizeSpamConfig()

-- state
local State = { active = true, conns = {} }
local S = {
    lastTarget        = -999,
    lastFireAt        = 0,
    smoothPing        = 0.05,
    pingTimer         = 0,
    teleportLockUntil = 0,
    frameDeltaEMA     = 1/60,
    frameDeltaVar     = 0,
    dtSamples         = {},
    dtIdx             = 0,
    dtLast            = 0,
    jitterEMA         = 0,
}

local Sync = {
    Speed     = 0,
    RealPos   = V3,
    Target    = -999,
    lastSyncAt = 0,
}

local AP = { fired = false, firedAt = 0 }

local RES = {
    stack            = 0,
    lastFireBallRef  = nil,
    lastFireBallAt   = 0,
    lastHitboxAt     = 0,
    lastStackAt      = 0,
}

-- ball cache
local _ball, _ballAt = nil, 0

-- heartbeat
local _currentHB = nil

-- callbacks
local _onClashOnCb  = nil
local _onTargetCb   = nil
local _onTeleportCb = nil

-- warnings
local function astruWarn(tag, msg)
    warn(("[%s] %s: %s"):format(SCRIPT_NAME, tag, tostring(msg)))
end

-- logs
local function astruLog(msg)
    print(("[%s v%s] %s"):format(SCRIPT_NAME, SCRIPT_VERSION, msg))
end

-- remote
local parryR, parryMode, parryInit = nil, "buffer", false
local _hooked = false
local _oldNamecall, _oldIndex

-- buffers
local _buf1, _buf2
local function _initBufs()
    if type(buffer) ~= "table" then return end
    if type(buffer.fromstring) == "function" then
        _buf1 = buffer.fromstring("\1")
        _buf2 = buffer.fromstring("\2")
    elseif type(buffer.create) == "function" and type(buffer.writeu8) == "function" then
        _buf1 = buffer.create(1); buffer.writeu8(_buf1, 0, 1)
        _buf2 = buffer.create(1); buffer.writeu8(_buf2, 0, 2)
    end
end
_initBufs()

local function makeBuf(flag)
    return flag == 2 and _buf2 or _buf1
end

local function _resolveRemoteProactive()
    if parryR and parryR.Parent and parryR:IsA("RemoteEvent") then
        return parryR, parryMode
    end

    local Remotes = Replicated:FindFirstChild("Remotes")
    if Remotes then
        local r = Remotes:FindFirstChild("pr_" .. tostring(lp.UserId))
        if r and r:IsA("RemoteEvent") then
            parryR, parryMode = r, "buffer"
            return parryR, parryMode
        end
    end

    local TSFolder = Replicated:FindFirstChild("TS")
    if TSFolder then
        local gen = TSFolder:FindFirstChild("GeneratedNetworkRemotes")
        if gen then
            local r = gen:FindFirstChild("RE_1")
            if r and r:IsA("RemoteEvent") then
                parryR, parryMode = r, "event"
                return parryR, parryMode
            end
        end
    end

    if Remotes then
        for _, name in ipairs({ "did", "RE_Deflect", "Deflect" }) do
            local r = Remotes:FindFirstChild(name)
            if r and r:IsA("RemoteEvent") then
                parryR, parryMode = r, (r.Name == "RE_1") and "event" or "buffer"
                return parryR, parryMode
            end
        end
    end

    return nil, nil
end

local function _captureRemote(remote, mode)
    if not (remote and typeof(remote) == "Instance" and remote:IsA("RemoteEvent")) then return end
    if remote.Parent == nil then return end
    if parryR ~= nil then return end
    parryR    = remote
    parryMode = mode or (remote.Name == "RE_1" and "event" or "buffer")
    parryInit = false
end

local function _setupRemoteHook()
    if _hooked then return end
    if type(hookmetamethod) ~= "function" then return end

    local ok = pcall(function()
        _oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            local args   = { ... }
            if not checkcaller()
                and (method == "FireServer" or method == "fireServer")
            then
                local a1 = args[1]
                local isPayload = false
                if a1 ~= nil then
                    if typeof(a1) == "buffer" then
                        isPayload = true
                    elseif typeof(a1) == "string"
                        and (string.find(a1, "\x01") or string.find(a1, "\x02"))
                    then
                        isPayload = true
                    end
                end
                if isPayload or self.Name == "RemoteEvent" then
                    _captureRemote(self, "buffer")
                end
            end
            return _oldNamecall(self, ...)
        end)

        _oldIndex = hookmetamethod(game, "__index", function(self, key)
            if not checkcaller()
                and (key == "FireServer" or key == "fireServer")
                and typeof(self) == "Instance"
                and self:IsA("RemoteEvent")
            then
                if self.Name == "RemoteEvent"
                    or (self.Parent and string.find(self.Parent.Name, "Remote"))
                then
                    task.spawn(function() _captureRemote(self, "buffer") end)
                end
            end
            return _oldIndex(self, key)
        end)
    end)

    if ok then _hooked = true end
end
_setupRemoteHook()

-- API global
_G.AstruState  = State
_G.AstruManual = false
_G.AstruAutoClash2 = _G.AstruConfig.AutoClash2 == true
_G.AstruClashOwner = _G.AstruClashOwner

_G.AstruStop = function()
    State.active = false
    for i = #State.conns, 1, -1 do
        pcall(State.conns[i].Disconnect, State.conns[i])
        State.conns[i] = nil
    end
    if _currentHB then pcall(_currentHB.Disconnect, _currentHB); _currentHB = nil end
    _G.AstruManual = false
    _G.AstruAutoClash2 = false
    _G.AstruClashOwner = nil
    if _G.__astruMiniGui and _G.__astruMiniGui.Destroy then
        pcall(_G.__astruMiniGui.Destroy)
    end
    astruLog("stop()")
end

-- conexoes
local function track(c)
    if c and c.Disconnect then
        State.conns[#State.conns + 1] = c
    end
    return c
end

-- reset
local function resetAllState()
    S.lastTarget, S.lastFireAt, S.teleportLockUntil = -999, 0, 0
    Sync.Speed, Sync.RealPos = 0, V3
    Sync.Target, Sync.lastSyncAt = -999, 0
    AP.fired, AP.firedAt = false, 0

    S.frameDeltaEMA = 1/60
    S.frameDeltaVar  = 0
    S.dtIdx = 0
    for i = 1, #S.dtSamples do S.dtSamples[i] = nil end
    S.jitterEMA = 0

    RES.stack, RES.lastFireBallRef, RES.lastFireBallAt = 0, nil, 0
    RES.lastHitboxAt, RES.lastStackAt = 0, 0

    _ball, _ballAt = nil, 0
end

-- ping
local function pingOneWay()
    local p = S.smoothPing
    if not p or p <= 0 then p = PING_BOOT_FALLBACK end
    return math.clamp(p * 0.5, 0, PING_MAX)
end

local function samplePing()
    local ok, p = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000 end)
    if ok and type(p) == "number" and p > 0 and p < 0.5 then
        S.smoothPing = S.smoothPing * (1 - PING_EMA) + p * PING_EMA
    end
end

local function leadCompensation(spd)
    if not spd or spd < 1 then return 0 end
    return spd * (pingOneWay() + C.LEAD_REACT_T)
end

-- prebuffer
local _pbCache = { ms = -1, ping = -1, jitter = -1, var = -1 }

local function preBufferMs()
    local p        = pingOneWay() * 1000
    local jitter   = S.jitterEMA
    local variance = S.frameDeltaVar
    if math.abs(p - _pbCache.ping) < 1
        and math.abs(jitter - _pbCache.jitter) < 0.5
        and math.abs(variance - _pbCache.var) < 1e-7
        and _pbCache.ms > 0
    then
        return _pbCache.ms
    end

    local pb = C.PB_BASE_MS + jitter * C.PB_JITTER_MULT
    local driftMs = math.max(variance * 1000 * 100, C.PB_DRIFT_FLOOR)
    pb = pb + driftMs * C.PB_DRIFT_MULT

    local fps = 60
    if S.frameDeltaEMA > 0 then fps = 1 / S.frameDeltaEMA end
    if fps < 60 then
        pb = pb + (60 - fps) * C.PB_FPS_FACTOR * 1000
    end

    pb = math.clamp(pb * P.PB_WEIGHT, C.PB_FLOOR_MS, C.PB_CAP_MS)
    _pbCache.ms, _pbCache.ping, _pbCache.jitter, _pbCache.var = pb, p, jitter, variance
    return pb
end

local function preBufferStuds(spd)
    if not spd or spd < 1 then return 0 end
    return spd * preBufferMs() / 1000
end

-- frame jitter
local function sampleFrameDelta(dt)
    if dt <= 0 then return end

    S.frameDeltaEMA = S.frameDeltaEMA * 0.9 + dt * 0.1
    S.dtIdx = (S.dtIdx % 60) + 1
    S.dtSamples[S.dtIdx] = dt

    if S.dtLast > 0 then
        local devMs = math.abs(dt - S.dtLast) * 1000
        S.jitterEMA = S.jitterEMA * 0.85 + devMs * 0.15
    end
    S.dtLast = dt

    local acc, cnt = 0, 0
    for i = 1, 60 do
        local v = S.dtSamples[i]
        if v then acc, cnt = acc + (v - S.frameDeltaEMA) ^ 2, cnt + 1 end
    end
    if cnt > 0 then S.frameDeltaVar = S.frameDeltaVar * 0.9 + (acc / cnt) * 0.1 end
end

-- ball cache
local function getBall()
    local t = now()
    if _ball and _ball.Parent and (t - _ballAt) < BALL_CACHE_TTL then return _ball end
    if ws then
        local b = ws:FindFirstChild("GameBall", true)
        if b and b.Parent then
            _ball, _ballAt = b, t
            return b
        end
    end
    _ball, _ballAt = nil, t
    return nil
end

-- remote validation
local function validRemote(r)
    return typeof(r) == "Instance" and r.Parent ~= nil and r:IsA("RemoteEvent")
end

-- fire parry
local function fireParry(flag)
    if not validRemote(parryR) then
        parryR, parryMode, parryInit = nil, "buffer", false
        return false
    end
    if parryMode == "event" then
        local ok, err = pcall(parryR.FireServer, parryR)
        if not ok then astruWarn("fireParry.event", err) end
        return ok
    end
    local p = makeBuf(flag or 1)
    if not p then return false end
    if not parryInit then
        local ip = makeBuf(2)
        if ip then
            local ok = pcall(parryR.FireServer, parryR, ip)
            parryInit = ok
        end
    end
    local ok, err = pcall(parryR.FireServer, parryR, p)
    if not ok then astruWarn("fireParry.fire", err) end
    return ok
end

-- parry completo
local function sendParry()
    if not validRemote(parryR) then
        parryR, parryMode, parryInit = nil, "buffer", false
        return false
    end
    if not fireParry(1) then
        parryR, parryMode, parryInit = nil, "buffer", false
        return false
    end

    S.lastFireAt = now()
    local b = getBall()
    if b and b.Parent then
        RES.lastFireBallRef, RES.lastFireBallAt = b, S.lastFireAt
    end

    if _onClashOnCb then
        local ok, err = pcall(_onClashOnCb)
        if not ok then astruWarn("onClashOnCb", err) end
    end

    return true
end

-- resiliencia
local function resRadiusBonus()
    return math.min(RES.stack * P.RES_PER_PARRY, P.RES_CAP)
end

-- tick da resiliencia
local function tickResilience(t)
    if RES.stack <= 0 then return end
    local since = t - RES.lastStackAt
    if since > (P.RES_HOLD_T + P.RES_DECAY_T) then
        RES.stack = 0
        return
    end
    if since > P.RES_HOLD_T then
        local frac = 1 - (since - P.RES_HOLD_T) / P.RES_DECAY_T
        if frac <= 0 then
            RES.stack = 0
        else
            local decayed = math.floor(RES.stack * frac + 0.5)
            if decayed ~= RES.stack then RES.stack = decayed end
        end
    end
end

-- spam rate
local function getSpamRateMode()
    return normalizeSpamConfig().SpamRateMode
end

local function getCPF()
    local cfg = normalizeSpamConfig()
    return cfg.CPF
end

local function getCPS()
    local cfg = normalizeSpamConfig()
    return cfg.CPS
end

-- spam engine
local _spamFps = nil
local _spamNextFireAt = nil
local _spamMode = nil
local _spamRate = nil
local _spamDispatchRate = nil
local _spamPending = 0
local _spamWorkerEpoch = 0
local _spamWorkerRunning = false

local function resetCpsSchedule()
    _spamNextFireAt = nil
    _spamMode = nil
    _spamRate = nil
end

local function enqueueSpamClicks(count)
    if type(count) ~= "number" or count <= 0 then return end
    _spamPending = _spamPending + math.floor(count)
end

local function startSpamWorker()
    if _spamWorkerRunning then return end
    _spamWorkerRunning = true
    _spamWorkerEpoch = _spamWorkerEpoch + 1
    local epoch = _spamWorkerEpoch

    task.spawn(function()
        while _spamWorkerRunning and _spamWorkerEpoch == epoch do
            if not _G.AstruManual or _spamPending <= 0 then
                task.wait()
            else
                local rate = math.max(tonumber(_spamDispatchRate) or tonumber(_spamRate) or 1, 1)
                _spamPending = _spamPending - 1
                fireParry(1)

                task.wait(1 / rate)
            end
        end
        if _spamWorkerEpoch == epoch then
            _spamWorkerRunning = false
        end
    end)
end

local function stopSpamWorker()
    _spamWorkerRunning = false
    _spamPending = 0
end

local function tickSpam(dt)
    if not _G.AstruManual then
        resetCpsSchedule()
        stopSpamWorker()
        return
    end
    if type(dt) ~= "number" or dt <= 0 then return end

    local mode = getSpamRateMode()
    local rate

    if mode == "CPS" then
        rate = math.max(getCPS(), 1)
        local t = now()

        if _spamMode ~= mode or _spamRate ~= rate or _spamNextFireAt == nil then
            _spamPending = 0
            _spamMode = mode
            _spamRate = rate
            _spamDispatchRate = rate
            _spamNextFireAt = t
        end

        if t >= _spamNextFireAt then
            local clicks = math.floor((t - _spamNextFireAt) * rate) + 1
            _spamNextFireAt = _spamNextFireAt + clicks / rate
            enqueueSpamClicks(clicks)
        end
    else
        local fpsNow = 1 / dt
        _spamFps = _spamFps and (_spamFps + (fpsNow - _spamFps) * SPAM_FPS_EMA) or fpsNow

        local cpf = math.max(getCPF(), 1)
        local fps = math.max(_spamFps or fpsNow, 1)
        rate = math.max(cpf * math.max(60, fps) / fps, 1)
        if _spamMode == "CPS" then
            _spamPending = 0
        end
        resetCpsSchedule()
        _spamDispatchRate = math.max(rate * fps, 1)
        enqueueSpamClicks(math.floor(rate))
    end

    startSpamWorker()
end

-- parry
local function bindParry(ch)
    if not (ch and ch.Parent) then return end
    local hrp = ch:WaitForChild("HumanoidRootPart", 9e9)
    if not (hrp and hrp.Parent) then return end
    local dead = false

    track(ch.AncestryChanged:Connect(function(_, p)
        if not p then dead = true; resetAllState() end
    end))

    local hum = ch:FindFirstChildOfClass("Humanoid")
    if hum then track(hum.Died:Connect(resetAllState)) end

    if _currentHB then
        pcall(_currentHB.Disconnect, _currentHB)
        _currentHB = nil
    end

    _currentHB = RunService.Heartbeat:Connect(function(dt)
        if dead or not State.active then return end
        if not (ch.Parent and hrp.Parent) then dead = true; return end

        if _G.AstruAutoParry == false then return end

        tickSpam(dt)

        local t = now()
        if t < S.teleportLockUntil then return end
        if _G.AstruManual then return end

        local AC = _G.AstruModules and _G.AstruModules.AutoClash
        if AC and AC.evaluate then
            pcall(AC.evaluate, t, hrp, getBall(), _G.AstruConfig)
        end

        tickResilience(t)

        local ball = getBall()
        if not (ball and ball.Parent) then return end
        if Sync.Target ~= lp.UserId then return end

        local syncFresh = (t - Sync.lastSyncAt) < 0.3
        local bp = (syncFresh and Sync.RealPos ~= V3) and Sync.RealPos or ball.Position

        local spd
        if syncFresh and Sync.Speed > 0 then
            spd = Sync.Speed
        else
            local ok, av = pcall(function() return ball.AssemblyLinearVelocity end)
            spd = (ok and typeof(av) == "Vector3") and av.Magnitude or 0
        end
        if spd < P.MIN_SPD then return end

        local leadB = leadCompensation(spd)
        local pbStuds = preBufferStuds(spd)
        local parryRad = math.max(
            P.DEFLECT_R
            + leadB
            + pbStuds
            + resRadiusBonus(),
            P.RAD_FLOOR
        )

        local dx, dy, dz = hrp.Position.X - bp.X, hrp.Position.Y - bp.Y, hrp.Position.Z - bp.Z
        if dx*dx + dy*dy + dz*dz > parryRad * parryRad then return end

        if AP.fired then return end
        if AP.firedAt > Sync.lastSyncAt then return end
        if (t - AP.firedAt) < P.FIRE_LOCK then return end

        S.pingTimer = S.pingTimer + dt
        if S.pingTimer >= PING_SAMPLE then
            S.pingTimer = 0
            samplePing()
        end

        AP.fired, AP.firedAt, S.lastFireAt = true, t, t
        sendParry()
    end)
    track(_currentHB)
end

-- character
local function onChar(ch)
    resetAllState()
    task.defer(function() pcall(bindParry, ch) end)
end

track(lp.CharacterAdded:Connect(onChar))
if lp.Character then task.defer(function() pcall(onChar, lp.Character) end) end

-- ball sync
local Remotes = Replicated:FindFirstChild("Remotes")
local ballSync = Remotes and Remotes:FindFirstChild("BallSyncData")
if ballSync and ballSync:IsA("RemoteEvent") then
    track(ballSync.OnClientEvent:Connect(function(d)
        if typeof(d) ~= "table" then return end
        local t = now()
        if type(d.Speed) == "number" then Sync.Speed = d.Speed end
        if typeof(d.RealPosition) == "Vector3" then Sync.RealPos = d.RealPosition end
        Sync.lastSyncAt = t

        if d.Teleported == true then
            S.teleportLockUntil = t + TELEPORT_LOCK
            AP.fired = false
            if _onTeleportCb then pcall(_onTeleportCb) end
            return
        end

        local newTarget = d.TargetPlayerID
        if newTarget == S.lastTarget then Sync.Target = newTarget; return end
        S.lastTarget, Sync.Target = newTarget, newTarget
        AP.fired = false
        if _onTargetCb then pcall(_onTargetCb, newTarget) end
    end))
end

-- ball watcher
local function setBall(b)         _ball, _ballAt = b, now() end
local function clearBallRef(b)    if b == _ball then _ball, _ballAt = nil, now() end end

local gameFolder  = ws:WaitForChild("Game", 30)
local ballWatcher = gameFolder and gameFolder:FindFirstChild("Ball")
if ballWatcher then
    track(ballWatcher.ChildAdded:Connect(function(c)
        if c.Name == "GameBall" and c:IsA("BasePart") then setBall(c) end
    end))
    track(ballWatcher.ChildRemoved:Connect(clearBallRef))
    local existing = ballWatcher:FindFirstChild("GameBall")
    if existing and existing:IsA("BasePart") then setBall(existing) end
end

-- hitboxgrow
track(ws.DescendantAdded:Connect(function(d)
    if not State.active or d.Name ~= "HitboxGrow" then return end
    local t = now()
    if (t - RES.lastFireBallAt) > P.RES_HITBOX_OWN_WINDOW then return end
    if not (RES.lastFireBallRef and RES.lastFireBallRef.Parent) then return end
    if (t - RES.lastHitboxAt) < 0.4 then return end
    local dp = d.Position
    if typeof(dp) ~= "Vector3" then return end
    if (RES.lastFireBallRef.Position - dp).Magnitude > P.RES_HITBOX_PROX then return end

    RES.lastHitboxAt, RES.lastStackAt = t, t
    RES.stack = RES.stack + 1
    local maxStack = math.floor((P.RES_CAP - P.RES_BASE) / P.RES_PER_PARRY)
    if RES.stack > maxStack then RES.stack = maxStack end
end))

-- frame jitter
track(RunService.Heartbeat:Connect(function(dt)
    sampleFrameDelta(dt)
end))

-- ping
task.spawn(function()
    for _ = 1, 3 do task.defer(samplePing); task.wait(0.2) end
end)

-- API publica
local Utils = {
    now           = function() return os.clock() end,
    getLocalPlayer = function() return Players.LocalPlayer end,
    getBall        = function()
        local b = workspace:FindFirstChild("GameBall")
        return (b and b:IsA("BasePart")) and b or nil
    end,
    setOnClashOn  = function(fn) _onClashOnCb  = fn end,
    setOnTarget   = function(fn) _onTargetCb   = fn end,
    setOnTeleport = function(fn) _onTeleportCb = fn end,
    forceParry    = function() return sendParry() end,
}

local AutoParry = {
    getSync            = function() return Sync end,
    isTargeted         = function()
        return Sync.Target == (Players.LocalPlayer and Players.LocalPlayer.UserId) or false
    end,
    computeParryRadius = function(spd)
        if type(spd) ~= "number" or spd < 1 then return 6 end
        return math.clamp(6 + spd * 0.25, 6, 30)
    end,
}

local GameInfo = {
    version = SCRIPT_VERSION,
    name    = SCRIPT_NAME,
    placeId = game.PlaceId,
    jobId   = game.JobId,
}

local function setAutoClash2Enabled(value)
    local enabled = value == true
    _G.AstruAutoClash2 = enabled
    if type(_G.AstruConfig) == "table" then
        _G.AstruConfig.AutoClash2 = enabled
    end
    return enabled
end

local AutoClash2API = {
    activate = function()
        return setAutoClash2Enabled(true)
    end,
    deactivate = function()
        return setAutoClash2Enabled(false)
    end,
    enable = function()
        return setAutoClash2Enabled(true)
    end,
    disable = function()
        return setAutoClash2Enabled(false)
    end,
    setEnabled = function(value)
        return setAutoClash2Enabled(value)
    end,
    isEnabled = function()
        return _G.AstruAutoClash2 == true
    end,
}

_G.AstruModules = {
    GameInfo   = GameInfo,
    Utils      = Utils,
    AutoParry  = AutoParry,
    AutoClash2 = AutoClash2API,
    set        = function(self, key, value) rawset(self, key, value); _G.AstruModules[key] = value end,
}

-- carregamento UI
local function loadUI()
    -- override externo
    local src = _G.__AstruUI
    if type(src) == "string" and #src > 0 then
        local fn, err = loadstring(src)
        if fn then
            local ok, runErr = pcall(fn)
            if ok then
                astruLog("ui ok (injetada via _G.__AstruUI)")
                return true
            else
                astruWarn("ui.run", runErr)
            end
        else
            astruWarn("ui.compile", err)
        end
    end

    -- fontes remotas
    local sources = {
        "https://pastebin.com/raw/AdrM4aNm",
    }

    for i, url in ipairs(sources) do
        local ok, body = pcall(function() return game:HttpGet(url) end)
        if ok and type(body) == "string" and #body > 50 then
            local fn, err = loadstring(body)
            if fn then
                local ran, runErr = pcall(fn)
                if ran then
                    astruLog("ui ok (fonte: primaria)")
                    return true
                else
                    astruWarn("ui.run", runErr)
                end
            else
                astruWarn("ui.compile", err)
            end
        else
            astruWarn("ui.httpget", "falha ou payload invalido")
        end
    end

    astruLog("ui nao fornecida (rodando so logic)")
    return false
end

-- carregamento AutoClash
local function loadAutoClash()
    local sources = {
        "https://pastebin.com/raw/n7B2gPiF",
        "https://pastebin.com/raw/3N7PJKm2",
    }

    for i, url in ipairs(sources) do
        local ok, src = pcall(function() return game:HttpGet(url) end)
        if ok and type(src) == "string" and #src > 50 then
            local chunk, err = loadstring(src)
            if chunk then
                local ran, runErr = pcall(chunk)
                if ran then
                    local tag = (i == 1) and "primario" or "fallback"
                    astruLog(("autoclash ok (fonte: %s)"):format(tag))
                    return true
                else
                    astruWarn(("autoclash.run[%d]"):format(i), runErr)
                end
            else
                astruWarn(("autoclash.compile[%d]"):format(i), err)
            end
        else
            astruWarn(("autoclash.httpget[%d]"):format(i), "falha ou payload invalido")
        end
    end

    astruLog("autoclash nao carregou (logic segue funcionando)")
    return false
end

-- carregamento AutoClash2
local function loadAutoClash2()
    local sources = {
        "https://pastebin.com/raw/aMrhFDfe",
    }

    for i, url in ipairs(sources) do
        if type(url) == "string" and #url > 0 then
            local ok, src = pcall(function() return game:HttpGet(url) end)
            if ok and type(src) == "string" and #src > 50 then
                local chunk, err = loadstring(src)
                if chunk then
                    local ran, runErr = pcall(chunk)
                    if ran then
                        local api = _G.AstruModules and _G.AstruModules.AutoClash2
                        local sync = _G.AstruAutoClash2 and api and api.activate or api and api.deactivate
                        if type(sync) == "function" then pcall(sync) end
                        astruLog("autoclash2 ok (fonte de teste)")
                        return true
                    else
                        astruWarn("autoclash2.run", runErr)
                    end
                else
                    astruWarn("autoclash2.compile", err)
                end
            else
                astruWarn("autoclash2.httpget", "falha ou payload invalido")
            end
        end
    end

    astruLog("autoclash2 nao carregou (raw vazio ou invalido; API stub permanece ativa)")
    return false
end

-- bootstrap
loadUI()
loadAutoClash()
loadAutoClash2()

astruLog("logic pronto")
