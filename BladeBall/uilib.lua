local Lib = loadstring(game:HttpGet("https://raw.githubusercontent.com/neaxusxgod-png/INS-ui/main/uilib.min.lua"))() or INSui

local Window = Lib:CreateWindow({
    title = "Blade Ball",
    subtitle = "Matcha AP",
    size = Vector2.new(680, 520),
    menuKey = "p",
    configName = "bladeball",
    configFolder = "bladeball",
    accentA = Color3.fromRGB(122, 134, 255),
    accentB = Color3.fromRGB(189, 130, 255),
    startOpen = true,
    keybindOverlay = false,
    checkboxStyle = true,
    smartFps = true,
    autoSave = true,
})

-- Services
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StatsService = game:GetService("Stats")
local VirtualInputManager = game:GetService("VirtualInputManager")

local lp = Players.LocalPlayer
local mouse = lp and lp:GetMouse()

--------------------------------------------------------------------------------
-- Config & Global State
--------------------------------------------------------------------------------
local Config = {
    AutoParry = false,
    ParryMode = "F Key", -- "F Key" or "Mouse"
    AutoClash = false,
    ClashRange = 20,
    ClashMinSpeed = 40,
    AutoAbility = false,
    DebugConsole = true, -- Logs Stage 1-5 to F9 developer console
    DebugOverlay = true, -- On-screen telemetry panel
    RangeRing = true,    -- Draws 3D floor ring for parry distance
    Trajectory = true,   -- Draws ball flight trajectory line
    BallDebug = true,    -- Ball & Player attributes debug overlay
    BallDebugConsole = false, -- Logs attribute changes to F9 console
    LogBallTarget = true,    -- Logs whether ball is flying at player to console
}

local State = {
    ball = nil,
    vel = Vector3.new(),
    spd = 0,
    pos = Vector3.new(),
    tgt = "",
    chasing = false,
    ping = 60,
    lastAb = 0,
    traj = {},
    isCurving = false,
    lastDot = 1,
    prevVel = Vector3.new(),
    parryCount = 0,
    serverParryCount = 0,
    isParrying = false,
    parriedBall = nil,
    parryTime = 0,
    targetTTI = 0.18,  -- initial 180ms timing, auto-adjusts dynamically
    parriedAt = 0,
    checkBall = nil,
    checkTime = 0,
    checkTTI = 0,
    successRate = {50, 0, 0}, -- {window, successes, total}
    errs = {},
    loop = 0,
    lastStageLogged = "",
    lastBallAttrs = "",
    lastPlayerAttrs = "",
    lastBallPath = "",
    lastPlayerPath = "",
    lastChasingState = nil,
    lastTgt = "",
}

--------------------------------------------------------------------------------
-- Stage-by-Stage Debug Logger
--------------------------------------------------------------------------------
local function logStage(stage, title, details)
    if not Config.DebugConsole then return end
    local logMsg = string.format("[AP STAGE %d - %s] %s", stage, title, details or "")
    if State.lastStageLogged ~= logMsg then
        State.lastStageLogged = logMsg
        print(logMsg)
    end
end

--------------------------------------------------------------------------------
-- Helper Math & Vector Functions
--------------------------------------------------------------------------------
local function dot(a, b) return a and b and (a.X*b.X + a.Y*b.Y + a.Z*b.Z) or 0 end
local function mag(v) return v and math.sqrt(v.X^2 + v.Y^2 + v.Z^2) or 0 end
local function norm(v)
    local m = mag(v)
    return m > 0 and Vector3.new(v.X/m, v.Y/m, v.Z/m) or Vector3.new()
end
local function dist(a, b) return a and b and mag(a - b) or 9999 end
local function sub(a, b) return a and b and (a - b) or Vector3.new() end

local function attr(c, k)
    if not c then return nil end
    local ok, v = pcall(function() return c:GetAttribute(k) end)
    return ok and v or nil
end

local function parseVector3(val)
    if not val then return nil end
    if typeof(val) == "Vector3" then
        return val
    elseif type(val) == "table" or typeof(val) == "table" or type(val) == "userdata" then
        local x = val.X or val.x or val[1]
        local y = val.Y or val.y or val[2]
        local z = val.Z or val.z or val[3]
        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
            return Vector3.new(x, y, z)
        end
    end
    return nil
end

local function parsePosition(val)
    if not val then return nil end
    if typeof(val) == "Vector3" then
        return val
    elseif typeof(val) == "CFrame" then
        return val.Position
    elseif type(val) == "table" or typeof(val) == "table" or type(val) == "userdata" then
        if val.Position then return parsePosition(val.Position) end
        if val.position then return parsePosition(val.position) end
        if val.p then return parsePosition(val.p) end
        local x = val.X or val.x or val[1]
        local y = val.Y or val.y or val[2]
        local z = val.Z or val.z or val[3]
        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
            return Vector3.new(x, y, z)
        end
    end
    return nil
end

local function formatAttrValue(v)
    if typeof(v) == "Vector3" then
        return string.format("Vector3(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
    elseif typeof(v) == "CFrame" then
        return string.format("CFrame(%.1f, %.1f, %.1f)", v.Position.X, v.Position.Y, v.Position.Z)
    end
    local pv = parseVector3(v)
    if pv then
        return string.format("Vector3(%.1f, %.1f, %.1f)", pv.X, pv.Y, pv.Z)
    end
    local pp = parsePosition(v)
    if pp then
        return string.format("Position(%.1f, %.1f, %.1f)", pp.X, pp.Y, pp.Z)
    end
    return tostring(v)
end

--------------------------------------------------------------------------------
-- Folder & Player Scanners
--------------------------------------------------------------------------------
local function findBalls()
    local la = rawget(_G, "LuaApp")
    if not la then pcall(function() la = game:GetService("LuaApp") end) end
    if not la then la = game:FindFirstChild("LuaApp") end
    if la then
        local w = la:FindFirstChild("Workspace") or la
        local b = w:FindFirstChild("Balls")
        if b then return b end
    end
    return Workspace:FindFirstChild("Balls")
end

local function findAliveFolder()
    local la = rawget(_G, "LuaApp")
    if not la then pcall(function() la = game:GetService("LuaApp") end) end
    if not la then la = game:FindFirstChild("LuaApp") end
    if la then
        local w = la:FindFirstChild("Workspace") or la
        local alive = w:FindFirstChild("Alive")
        if alive then return alive end
    end
    return Workspace:FindFirstChild("Alive")
end

local function getLocalCharacter()
    if not lp then return nil end
    local aliveFolder = findAliveFolder()
    if aliveFolder then
        local char = aliveFolder:FindFirstChild(lp.Name)
        if char then return char end
    end
    return lp.Character
end

local function getAlivePlayer()
    return getLocalCharacter()
end

local function isReal(c)
    if not c then return false end

    -- Check realBall attribute on ball model
    local r1 = attr(c, "realBall")
    if r1 == false then return false end

    -- Check realBall attribute on Body part
    local body = c:FindFirstChild("Body") or c:FindFirstChild("body") or c:FindFirstChildWhichIsA("BasePart")
    if body then
        local r2 = attr(body, "realBall")
        if r2 == false then return false end
        if r2 == true then return true end
    end

    if r1 == true then return true end

    if c.Name == "Ball" then return true end
    return false
end

local function getBallBodyInstance()
    local ballsFolder = findBalls()
    if ballsFolder then
        local ball = ballsFolder:FindFirstChild("Ball")
        if ball then
            local body = ball:FindFirstChild("Body") or ball:FindFirstChild("body") or ball:FindFirstChildWhichIsA("BasePart")
            if body then return body, ball end
        end
        for _, c in ipairs(ballsFolder:GetChildren()) do
            local body = c:FindFirstChild("Body") or c:FindFirstChild("body") or c:FindFirstChildWhichIsA("BasePart")
            if body then return body, c end
        end
    end
    for _, c in ipairs(Workspace:GetChildren()) do
        if c.Name == "Ball" or isReal(c) then
            local body = c:FindFirstChild("Body") or c:FindFirstChild("body") or c:FindFirstChildWhichIsA("BasePart")
            if body then return body, c end
        end
    end
    return nil, nil
end

local function getBallInstance()
    local body, ball = getBallBodyInstance()
    if ball then return ball end
    local ballsFolder = findBalls()
    if ballsFolder then
        local b = ballsFolder:FindFirstChild("Ball")
        if b then return b end
        for _, c in ipairs(ballsFolder:GetChildren()) do
            if isReal(c) then return c end
        end
        local first = ballsFolder:GetChildren()[1]
        if first then return first end
    end
    for _, c in ipairs(Workspace:GetChildren()) do
        if c.Name == "Ball" or isReal(c) then return c end
    end
    return nil
end

local function bvel(obj)
    if not obj then return Vector3.new() end
    local body = obj:FindFirstChild("Body") or obj:FindFirstChild("body") or obj:FindFirstChildWhichIsA("BasePart") or obj.PrimaryPart or obj
    if body then
        local ok, v = pcall(function() return body.AssemblyLinearVelocity end)
        if ok and v and mag(v) > 0.001 then return v end
        local ok2, v2 = pcall(function() return body.Velocity end)
        if ok2 and v2 and mag(v2) > 0.001 then return v2 end
        local vAttr = attr(body, "Velocity") or attr(obj, "Velocity")
        local parsedV = parseVector3(vAttr)
        if parsedV and mag(parsedV) > 0.001 then return parsedV end
    end
    local ok, v = pcall(function() return obj.AssemblyLinearVelocity end)
    if ok and v and mag(v) > 0.001 then return v end
    local ok2, v2 = pcall(function() return obj.Velocity end)
    if ok2 and v2 and mag(v2) > 0.001 then return v2 end
    local vAttr = attr(obj, "Velocity")
    local parsedV = parseVector3(vAttr)
    if parsedV and mag(parsedV) > 0.001 then return parsedV end
    return Vector3.new()
end

local function bpos(obj)
    if not obj then return Vector3.new() end
    local body = obj:FindFirstChild("Body") or obj:FindFirstChild("body") or obj:FindFirstChildWhichIsA("BasePart") or obj.PrimaryPart or obj
    if body then
        local ok, p = pcall(function() return body.Position end)
        if ok and p then return p end
        local ok2, cf = pcall(function() return body:GetPivot() end)
        if ok2 and cf then return cf.Position end
        local pAttr = attr(body, "Position") or attr(body, "Pivot") or attr(obj, "Position") or attr(obj, "Pivot")
        local parsedP = parsePosition(pAttr)
        if parsedP then return parsedP end
    end
    local ok, p = pcall(function() return obj.Position end)
    if ok and p then return p end
    local ok2, cf = pcall(function() return obj:GetPivot() end)
    if ok2 and cf then return cf.Position end
    local pAttr = attr(obj, "Position") or attr(obj, "Pivot")
    local parsedP = parsePosition(pAttr)
    if parsedP then return parsedP end
    return Vector3.new()
end

--------------------------------------------------------------------------------
-- Target Resolution Logic (Attribute & Vector Based)
--------------------------------------------------------------------------------
local function resolveTarget(ballObj)
    if not ballObj then return "", false end

    local aliveP = getAlivePlayer()
    local myName = lp and lp.Name or ""

    local body = ballObj:FindFirstChild("Body") or ballObj:FindFirstChild("body") or ballObj:FindFirstChildWhichIsA("BasePart")

    -- 1. Check Ball or Ball.Body attributes directly (target / targetPlayer)
    local targetAttr = attr(ballObj, "target") or attr(ballObj, "Target") or attr(ballObj, "targetPlayer") or attr(ballObj, "TargetPlayer")
    if not targetAttr or targetAttr == "" then
        if body then
            targetAttr = attr(body, "target") or attr(body, "Target") or attr(body, "targetPlayer") or attr(body, "TargetPlayer")
        end
    end

    if targetAttr and targetAttr ~= "" and targetAttr ~= false then
        if typeof(targetAttr) == "Instance" then
            if targetAttr == lp or targetAttr == lp.Character or targetAttr == aliveP then
                return myName, true
            else
                return targetAttr.Name, (string.lower(targetAttr.Name) == string.lower(myName))
            end
        elseif type(targetAttr) == "string" then
            local isMe = (string.lower(targetAttr) == string.lower(myName))
            return targetAttr, isMe
        end
    end

    -- 2. Check ValueBase children inside Ball or Body
    local targetValObj = ballObj:FindFirstChild("target") or ballObj:FindFirstChild("Target") or ballObj:FindFirstChild("targetPlayer") or ballObj:FindFirstChild("TargetPlayer")
    if not targetValObj and body then
        targetValObj = body:FindFirstChild("target") or body:FindFirstChild("Target") or body:FindFirstChild("targetPlayer") or body:FindFirstChild("TargetPlayer")
    end
    if targetValObj and targetValObj:IsA("ValueBase") and targetValObj.Value then
        local val = targetValObj.Value
        if typeof(val) == "Instance" then
            local isMe = (val == lp or val == lp.Character or val == aliveP)
            return val.Name, isMe
        elseif type(val) == "string" and val ~= "" then
            local isMe = (string.lower(val) == string.lower(myName))
            return val, isMe
        end
    end

    -- 3. Check IsTarget / Target attribute on character in Alive folder
    local aliveFolder = findAliveFolder()
    if aliveFolder then
        for _, char in ipairs(aliveFolder:GetChildren()) do
            local isT = attr(char, "IsTarget") or attr(char, "isTarget")
            if isT == true then
                local charName = char.Name
                local isMe = (string.lower(charName) == string.lower(myName))
                return charName, isMe
            end
        end
    end

    -- 4. Vector Trajectory Precision Fallback (Projected trajectory towards LocalPlayer)
    if aliveP then
        local hrp = aliveP:FindFirstChild("HumanoidRootPart") or aliveP.PrimaryPart
        if hrp then
            local pos = bpos(ballObj)
            local vel = bvel(ballObj)
            local speed = mag(vel)
            local distToP = dist(pos, hrp.Position)
            if speed > 10 and distToP > 0 and distToP < 120 then
                local dirToP = norm(hrp.Position - pos)
                local velDir = norm(vel)
                local dotProd = dot(velDir, dirToP)
                local perpDist = distToP * math.sqrt(math.max(0, 1 - dotProd^2))
                -- Heading directly at player (dot > 0.92) with tight miss offset (< 12 studs)
                if dotProd > 0.92 and perpDist < 12 then
                    return (myName ~= "" and (myName .. " (Vector Threat)") or "You (Vector Threat)"), true
                end
            end
        end
    end

    return "", false
end

local function targetOf(ballObj)
    local tgtName, _ = resolveTarget(ballObj)
    return tgtName
end

--------------------------------------------------------------------------------
-- Ping Calculation & Smoothing
--------------------------------------------------------------------------------
local pingStatsItem
local function getPing()
    if not pingStatsItem then
        pcall(function()
            pingStatsItem = StatsService.Network:FindFirstChild("ServerStatsItem")
                and StatsService.Network.ServerStatsItem:FindFirstChild("Data Ping")
        end)
    end
    if pingStatsItem and type(memory_read) == "function" then
        local ok, v = pcall(function() return memory_read("double", pingStatsItem.Address + 0xC8) end)
        if ok and v and v > 0 then return v end
    end
    local ok, v = pcall(function() return StatsService.Ping end)
    return ok and v or 60
end

local pingHist = {}
local function smoothedPing()
    local raw = getPing()
    table.insert(pingHist, raw)
    if #pingHist > 50 then table.remove(pingHist, 1) end
    if #pingHist == 0 then return raw end
    local maxP, sumP = 0, 0
    for _, p in ipairs(pingHist) do maxP = math.max(maxP, p); sumP = sumP + p end
    local avgP = sumP / #pingHist
    if (maxP - avgP) > 20 then return maxP + 10 end
    return raw
end

local function getAttributesDict(inst)
    if not inst then return {} end
    local dict = {}
    local ok, raw = pcall(function() return inst:GetAttributes() end)
    if ok and type(raw) == "table" then
        for k, v in pairs(raw) do
            if type(k) == "string" then
                dict[k] = v
            elseif type(v) == "string" then
                dict[v] = attr(inst, v)
            end
        end
    end
    return dict
end

local function formatAttributes(inst)
    if not inst then return "(None)" end
    local attrs = getAttributesDict(inst)
    local parts = {}
    for k, v in pairs(attrs) do
        table.insert(parts, tostring(k) .. "=" .. formatAttrValue(v))
    end
    local body = inst:FindFirstChild("Body") or inst:FindFirstChild("body") or inst:FindFirstChildWhichIsA("BasePart")
    if body then
        local bodyAttrs = getAttributesDict(body)
        for k, v in pairs(bodyAttrs) do
            table.insert(parts, "Body." .. tostring(k) .. "=" .. formatAttrValue(v))
        end
    end
    table.sort(parts)
    if #parts == 0 then
        return "(No Attributes)"
    end
    return table.concat(parts, ", ")
end

--------------------------------------------------------------------------------
-- Parry & Ability Action Execution (F Key)
--------------------------------------------------------------------------------
local function pressFKey()
    local handled = false

    -- Method 1: Matcha / Executor native keypress(0x46)
    if type(keypress) == "function" then
        local ok = pcall(function()
            keypress(0x46)
            if type(keyrelease) == "function" then
                task.wait()
                keyrelease(0x46)
            end
            handled = true
        end)
        if ok and handled then return end
    end

    -- Method 2: VirtualInputManager SendKeyEvent F (0x46)
    if VirtualInputManager then
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
            task.wait()
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
            handled = true
        end)
        if handled then return end
    end

    -- Method 3: Mouse fallback if configured
    if Config.ParryMode == "Mouse" then
        if type(mouse1click) == "function" then
            mouse1click()
        elseif type(mouse1press) == "function" then
            mouse1press()
            task.wait()
            if type(mouse1release) == "function" then mouse1release() end
        end
    end
end

local function doParry()
    logStage(4, "EXECUTION", string.format("Action: Key F Pressed | Mode: %s | Ball Speed: %.1f", Config.ParryMode, State.spd))
    pressFKey()
end

local function doAbility()
    local r = ReplicatedStorage:FindFirstChild("Remotes")
    local ar = r and r:FindFirstChild("AbilityButtonPress")
    if ar then
        pcall(function() ar:FireServer() end)
        logStage(4, "ABILITY", "Auto Ability Triggered!")
    end
end

--------------------------------------------------------------------------------
-- Tabs & UI Layout (INS-ui)
--------------------------------------------------------------------------------
local Main = Window:Tab("Auto Parry", "swords")
local VisTab = Window:Tab("Visuals & Debug", "eye")

local ParrySection = Main:Section("Parry Core", "Left", "Automatic ball deflection with F key")
local ClashSection = Main:Section("Clash & Ability", "Right", "High-speed clash mode & abilities")

ParrySection:Toggle("Auto Parry (Key F)", Config.AutoParry, function(v)
    Config.AutoParry = v
    if v then
        logStage(1, "SYSTEM", "Auto Parry Activated (Key F Mode)")
    else
        logStage(1, "SYSTEM", "Auto Parry Deactivated")
    end
end)

ParrySection:Dropdown("Parry Input Mode", {"F Key", "Mouse"}, Config.ParryMode, function(v)
    Config.ParryMode = v
end)

ClashSection:Toggle("Auto Clash", Config.AutoClash, function(v)
    Config.AutoClash = v
end)

ClashSection:Slider("Clash Distance", 5, 40, Config.ClashRange, function(v)
    Config.ClashRange = v
end)

ClashSection:Slider("Clash Min Speed", 10, 100, Config.ClashMinSpeed, function(v)
    Config.ClashMinSpeed = v
end)

ClashSection:Toggle("Auto Ability", Config.AutoAbility, function(v)
    Config.AutoAbility = v
end)

-- Visuals & Debug Section
local DebugSection = VisTab:Section("Stage Debug & HUD", "Left", "Console logs and telemetry overlay")
local VisualsSection = VisTab:Section("Render Settings", "Right", "3D distance ring and trajectory line")
local BallDebugSection = VisTab:Section("Ball & Player Debug", "Left", "Attribute inspector for LuaApp.Workspace")

DebugSection:Toggle("Stage Debug Console Logs", Config.DebugConsole, function(v)
    Config.DebugConsole = v
end)

DebugSection:Toggle("On-Screen Telemetry HUD", Config.DebugOverlay, function(v)
    Config.DebugOverlay = v
end)

VisualsSection:Toggle("3D Parry Range Ring", Config.RangeRing, function(v)
    Config.RangeRing = v
end)

VisualsSection:Toggle("Ball Flight Trajectory", Config.Trajectory, function(v)
    Config.Trajectory = v
end)

BallDebugSection:Toggle("Ball & Player Debug HUD", Config.BallDebug, function(v)
    Config.BallDebug = v
end)

BallDebugSection:Toggle("Print Attributes to Console", Config.BallDebugConsole, function(v)
    Config.BallDebugConsole = v
end)

BallDebugSection:Toggle("Log Ball Target to Console", Config.LogBallTarget, function(v)
    Config.LogBallTarget = v
end)

--------------------------------------------------------------------------------
-- Main Heartbeat Loop (Stages 1 - 5 Logic)
--------------------------------------------------------------------------------
local ballContainer, lastScan = nil, 0

RunService.Heartbeat:Connect(function()
    local ok, err = pcall(function()
        local now = tick()
        State.loop = State.loop + 1

        ------------------------------------------------------------------------
        -- BALL & PLAYER DEBUG ATTRIBUTES TRACKING
        ------------------------------------------------------------------------
        local currentBall = getBallInstance()
        local currentAlivePlayer = getAlivePlayer()

        local bPath = currentBall and currentBall:GetFullName() or "None"
        local bAttrsStr = formatAttributes(currentBall)

        local pPath = currentAlivePlayer and currentAlivePlayer:GetFullName() or "None"
        local pAttrsStr = formatAttributes(currentAlivePlayer)

        if Config.BallDebugConsole then
            if bAttrsStr ~= State.lastBallAttrs or bPath ~= State.lastBallPath then
                print(string.format("[BALL DEBUG] %s Attributes: %s", bPath, bAttrsStr))
            end
            if pAttrsStr ~= State.lastPlayerAttrs or pPath ~= State.lastPlayerPath then
                print(string.format("[PLAYER DEBUG] %s Attributes: %s", pPath, pAttrsStr))
            end
        end

        State.lastBallAttrs = bAttrsStr
        State.lastBallPath = bPath
        State.lastPlayerAttrs = pAttrsStr
        State.lastPlayerPath = pPath

        State.ping = smoothedPing()

        ------------------------------------------------------------------------
        -- STAGE 5: POST-PARRY FEEDBACK & AUTO-TUNING
        ------------------------------------------------------------------------
        if State.checkBall and now > State.checkTime then
            if State.checkBall.Parent then
                local cv = bvel(State.checkBall)
                local cp = bpos(State.checkBall)
                local chr2 = getLocalCharacter()
                if chr2 and cv.Magnitude > 1 then
                    local hrp2 = chr2:FindFirstChild("HumanoidRootPart") or chr2.PrimaryPart
                    if hrp2 then
                        local toP = norm(hrp2.Position - cp)
                        local toward = dot(norm(cv), toP) > 0
                        if toward then
                            -- Failed deflection / parried too late -> increase target TTI (parry earlier next time)
                            State.targetTTI = math.min(State.targetTTI + 0.008, 0.5)
                            State.successRate[3] = State.successRate[3] + 1
                            logStage(5, "AUTO-TUNE", string.format("Outcome: FAIL (Ball still flying at player) | Adjust TTI -> %.3fs", State.targetTTI))
                        else
                            -- Successful deflection -> slightly tighten target TTI
                            State.targetTTI = math.max(State.targetTTI - 0.004, 0.05)
                            State.successRate[2] = State.successRate[2] + 1
                            State.successRate[3] = State.successRate[3] + 1
                            logStage(5, "AUTO-TUNE", string.format("Outcome: SUCCESS (Ball deflected!) | Adjust TTI -> %.3fs", State.targetTTI))
                        end
                    end
                end
            end
            State.checkBall = nil
        end

        ------------------------------------------------------------------------
        -- STAGE 1: SCAN & FIND REAL BALL
        ------------------------------------------------------------------------
        if not ballContainer or not ballContainer.Parent or now - lastScan > 0.5 then
            ballContainer = findBalls()
            lastScan = now
        end
        local bc = ballContainer

        local ballObj = nil
        if bc then
            for _, c in ipairs(bc:GetChildren()) do
                if isReal(c) then ballObj = c; break end
            end
        end
        if not ballObj then
            for _, c in ipairs(Workspace:GetChildren()) do
                if isReal(c) then ballObj = c; break end
            end
        end

        State.ball = ballObj
        if not ballObj or not ballObj.Parent or not isReal(ballObj) then
            State.vel = Vector3.new(); State.spd = 0; State.chasing = false
            State.traj = {}; State.parryCount = 0
            if (Config.LogBallTarget or Config.DebugConsole) and State.lastChasingState ~= nil and State.lastChasingState ~= false then
                State.lastChasingState = false
                print("[BALL TARGET] ⚪ Ball inactive / not found")
            end
            return
        end

        State.pos = bpos(ballObj)
        State.vel = bvel(ballObj)
        State.spd = mag(State.vel)

        local tgtName, isTgtMe = resolveTarget(ballObj)
        State.tgt = tgtName
        State.chasing = isTgtMe

        -- Server Parry Verification from Player Attributes
        local aliveP = getAlivePlayer()
        if aliveP then
            local spc = attr(aliveP, "ServerParryCount")
            if type(spc) == "number" and spc > (State.serverParryCount or 0) then
                State.serverParryCount = spc
                logStage(5, "SERVER PARRY CONFIRMED", string.format("ServerParryCount updated to %d!", spc))
            end
            local isP = attr(aliveP, "Parrying")
            if isP ~= nil then
                State.isParrying = (isP == true)
            end
        end

        ------------------------------------------------------------------------
        -- STAGE 2: METRICS & TRAJECTORY COMPUTATION
        ------------------------------------------------------------------------
        if not State.traj[ballObj] then
            State.traj[ballObj] = { samples = {}, isCurve = false, lastDot = 1 }
        end
        local td = State.traj[ballObj]
        table.insert(td.samples, { vel = State.vel })
        if #td.samples > 25 then table.remove(td.samples, 1) end

        -- Curve Angle Detection
        if #td.samples >= 3 then
            local angleSum = 0
            for i = 2, #td.samples do
                local pv = td.samples[i-1].vel; local cv = td.samples[i].vel
                local pm2 = mag(pv); local cm2 = mag(cv)
                if pm2 > 0 and cm2 > 0 then
                    local dval = math.max(-1, math.min(1, dot(norm(pv), norm(cv))))
                    local ang = math.deg(math.acos(dval))
                    if ang > 4 then angleSum = angleSum + ang/4 end
                end
            end
            td.isCurve = angleSum > 6
        end
        State.isCurving = td.isCurve

        local chr = getLocalCharacter()
        local hrp = chr and (chr:FindFirstChild("HumanoidRootPart") or chr.PrimaryPart)
        local hrpPos = hrp and hrp.Position or (State.pos + Vector3.new(0,0,10))

        local d = dist(State.pos, hrpPos)
        local tti = State.spd > 0.5 and (d / State.spd) or 99
        local parryDist = State.spd * (State.targetTTI + (State.ping / 800)) + 2
        if td.isCurve then parryDist = parryDist * 1.1 end
        parryDist = math.clamp(parryDist, 6, 32)

        local dirToPlayer = norm(hrpPos - State.pos)
        local velDir = norm(State.vel)
        local dotProd = dot(velDir, dirToPlayer)
        local toward = dotProd > 0
        local perpDist = d * math.sqrt(math.max(0, 1 - dotProd^2))

        ------------------------------------------------------------------------
        -- BALL TARGET & DIRECTION CONSOLE LOGGER
        ------------------------------------------------------------------------
        local isFlyingAtPlayer = false
        if State.spd > 1 and hrp then
            if State.chasing then
                -- Explicit target: ball is designated for LocalPlayer and moving generally towards player or close
                isFlyingAtPlayer = (dotProd > 0.15 or d < 20)
            else
                -- Not explicit target: ball vector must be flying directly at LocalPlayer
                isFlyingAtPlayer = ((dotProd > 0.90 and perpDist < 12) or (d < 12 and dotProd > 0.5)) and State.spd > 5
            end
        end

        if Config.LogBallTarget or Config.DebugConsole then
            if State.lastChasingState ~= isFlyingAtPlayer or State.tgt ~= State.lastTgt then
                State.lastChasingState = isFlyingAtPlayer
                State.lastTgt = State.tgt
                if isFlyingAtPlayer then
                    print(string.format("[BALL TARGET] 🎯 BALL IS FLYING AT YOU! | Target: %s | Speed: %.1f studs/s | Distance: %.1f studs | TTI: %.2fs | PerpDist: %.1f studs", State.tgt ~= "" and State.tgt or (lp and lp.Name or "You"), State.spd, d, tti, perpDist))
                elseif State.chasing then
                    print(string.format("[BALL TARGET] ⚠️ You are target, but vector angled away | Target: %s | Speed: %.1f studs/s | Distance: %.1f studs | Dot: %.2f", State.tgt ~= "" and State.tgt or (lp and lp.Name or "You"), State.spd, d, dotProd))
                elseif State.tgt ~= "" then
                    print(string.format("[BALL TARGET] 🟢 Ball flying at another player | Current Target: %s | Speed: %.1f studs/s | Distance to you: %.1f studs", State.tgt, State.spd, d))
                else
                    print(string.format("[BALL TARGET] ⚪ Ball moving, no target | Speed: %.1f studs/s | Distance to you: %.1f studs", State.spd, d))
                end
            end
        end

        ------------------------------------------------------------------------
        -- STAGE 3: PARRY & CLASH DECISION CHECK
        ------------------------------------------------------------------------
        local alreadyParried = State.parriedBall == ballObj and (now - State.parryTime) < 0.5

        local shouldParry = Config.AutoParry and chr and State.spd >= 10 and not alreadyParried and isFlyingAtPlayer
        if shouldParry then
            if hrp and d > 0 and d <= parryDist then
                logStage(3, "DECISION -> PARRY TRIGGERED!", string.format("Dist: %.1f <= ParryDist: %.1f | Speed: %.1f | TTI: %.2fs | Ping: %dms | Dot: %.2f", d, parryDist, State.spd, tti, State.ping, dotProd))

                doParry()

                State.parriedBall = ballObj
                State.parryTime = now
                State.parriedAt = tti
                State.parryCount = State.parryCount + 1
                State.checkBall = ballObj
                State.checkTime = now + 0.25

                if Config.AutoAbility and (now - State.lastAb > 1.2) then
                    doAbility()
                    State.lastAb = now
                end
            end
        end

        -- Auto Clash Logic
        if Config.AutoClash and chr and State.spd >= Config.ClashMinSpeed and not (State.parriedBall == ballObj and (now - State.parryTime) < 0.15) then
            if hrp and toward and d > 0 and d <= Config.ClashRange then
                logStage(3, "DECISION -> CLASH PARRY!", string.format("Clash Range: %.1f | Speed: %.1f", d, State.spd))

                doParry()

                State.parriedBall = ballObj
                State.parryTime = now
                State.parryCount = State.parryCount + 1
                State.checkBall = ballObj
                State.checkTime = now + 0.25
            end
        end

        State.prevVel = State.vel
    end)
    if not ok then
        local m = tostring(err):sub(1, 80)
        table.insert(State.errs, 1, m)
        if #State.errs > 5 then table.remove(State.errs) end
    end
end)

--------------------------------------------------------------------------------
-- Rendering & On-Screen Debug HUD (Drawing API)
--------------------------------------------------------------------------------
task.spawn(function()
    local have_draw = type(Drawing) == "table"
    if not have_draw then return end

    local ogLines, dotObj, ringLines = {}, {}, {}
    for i = 1, 16 do
        local l = Drawing.new("Line")
        if l then l.Visible = false; l.Thickness = 3; l.Transparency = 0 end
        ringLines[i] = l
    end

    local cursorTxt = Drawing.new("Text")
    if cursorTxt then cursorTxt.Font = Drawing.Fonts.UI; cursorTxt.Size = 14; cursorTxt.Outline = true; cursorTxt.Center = true; cursorTxt.Visible = false end

    for i = 1, 36 do
        local t = Drawing.new("Text")
        if t then t.Font = Drawing.Fonts.UI; t.Size = 12; t.Outline = true; t.Visible = false end
        ogLines[i] = t
    end

    local bg = Drawing.new("Square"); local bdr = Drawing.new("Square")
    if bg then bg.Thickness = 0; bg.Visible = false end
    if bdr then bdr.Filled = false; bdr.Thickness = 1; bdr.Color = Color3.fromRGB(60,60,60); bdr.Visible = false end

    local dbgDrag = { active = false, offX = 0, offY = 0, posX = 15, posY = 15 }
    local prevClick = false

    while true do
        task.wait(0.03)
        local ok, err = pcall(function()
            local mx, my
            pcall(function() mx = mouse.X; my = mouse.Y end)
            local _, clicked = pcall(ismouse1pressed)

            -- Handle Dragging Telemetry HUD
            if clicked and not prevClick and mx and my then
                if bg and bg.Visible and mx >= dbgDrag.posX and mx <= dbgDrag.posX + 380 and my >= dbgDrag.posY and my <= dbgDrag.posY + 20 then
                    dbgDrag.active = true
                    dbgDrag.offX = mx - dbgDrag.posX
                    dbgDrag.offY = my - dbgDrag.posY
                end
            end
            if dbgDrag.active and clicked and mx and my then
                dbgDrag.posX = mx - dbgDrag.offX
                dbgDrag.posY = my - dbgDrag.offY
            end
            if not clicked then dbgDrag.active = false end
            prevClick = clicked

            local dOn = Config.DebugOverlay or Config.BallDebug
            if bg then bg.Visible = dOn end
            if bdr then bdr.Visible = dOn end
            for i = 1, 36 do if ogLines[i] then ogLines[i].Visible = false end end

            if dOn then
                local hudH = Config.BallDebug and 480 or 340
                if bg then bg.Color = Color3.fromRGB(10,10,10); bg.Transparency = 0.15; bg.Size = Vector2.new(380, hudH); bg.Position = Vector2.new(dbgDrag.posX, dbgDrag.posY) end
                if bdr then bdr.Position = Vector2.new(dbgDrag.posX, dbgDrag.posY); bdr.Size = Vector2.new(380, hudH) end

                local chr = getLocalCharacter()
                local hrp = chr and (chr:FindFirstChild("HumanoidRootPart") or chr.PrimaryPart)
                local d = hrp and State.ball and dist(State.pos, hrp.Position) or 0
                local pdist = State.spd > 0.5 and math.clamp(State.spd * (State.targetTTI + (State.ping / 800)) + 2 * (State.isCurving and 1.1 or 1.0), 6, 32) or 0
                local tti = State.spd > 0.5 and d / State.spd or 0
                local sr = State.successRate[3] > 0 and math.floor(State.successRate[2]/State.successRate[3]*100) or 0

                local lines = {
                    "=== Blade Ball Auto Parry (Key F) ===", "",
                    "Ball Detected:", tostring(State.ball ~= nil),
                    "Speed:", math.floor(State.spd) .. " studs/s",
                    "Target:", State.tgt, "Chasing You:", tostring(State.chasing),
                    "Ping:", State.ping .. " ms",
                    "Distance:", string.format("%.1f studs", d),
                    "Time-To-Impact:", string.format("%.2fs", tti),
                    "Target TTI:", string.format("%.3fs", State.targetTTI),
                    "Parry Range:", string.format("%.1f studs", pdist),
                    "Curving Ball:", tostring(State.isCurving),
                    "Parries Executed:", State.parryCount,
                    "Server Parry Count:", State.serverParryCount or 0,
                    "Success Rate:", sr .. "%",
                    "Dedup Cooldown:", (State.parriedBall == State.ball and (tick() - State.parryTime < 0.5)) and "ACTIVE" or "READY",
                    "Clash Mode:", Config.AutoClash and "ON" or "OFF",
                    "Last Status:", #State.errs > 0 and State.errs[1] or "OK",
                }

                if Config.BallDebug then
                    table.insert(lines, "--- BALL & PLAYER DEBUG ---")
                    table.insert(lines, "")
                    table.insert(lines, "Player Path:")
                    table.insert(lines, State.lastPlayerPath ~= "" and State.lastPlayerPath or "None")
                    table.insert(lines, "Player Attrs:")
                    table.insert(lines, State.lastPlayerAttrs ~= "" and State.lastPlayerAttrs:sub(1, 60) or "(None)")
                    table.insert(lines, "Ball Path:")
                    table.insert(lines, State.lastBallPath ~= "" and State.lastBallPath or "None")
                    table.insert(lines, "Ball Attrs:")
                    table.insert(lines, State.lastBallAttrs ~= "" and State.lastBallAttrs:sub(1, 60) or "(None)")
                end

                for i = 1, #lines, 2 do
                    local t = ogLines[(i+1)//2]
                    if t then
                        t.Visible = true
                        t.Text = lines[i] .. " " .. tostring(lines[i+1] or "")
                        t.Position = Vector2.new(dbgDrag.posX + 8, dbgDrag.posY + 6 + ((i-1)//2)*18)
                        t.Color = i == 1 and Color3.fromRGB(122,134,255)
                            or (tostring(lines[i]):sub(1,3) == "---" and Color3.fromRGB(255,189,122) or Color3.fromRGB(200,230,255))
                    end
                end
            end

            -- 3D Range Ring Rendering
            local calcParryDist = 12
            if State.ball and State.spd > 0.5 then
                calcParryDist = math.clamp(State.spd * (State.targetTTI + (State.ping / 800)) + 2 * (State.isCurving and 1.1 or 1.0), 6, 32)
            end
            for i = 1, 16 do if ringLines[i] then ringLines[i].Visible = false end end

            local chr = getLocalCharacter()
            if Config.RangeRing and chr and State.ball and calcParryDist > 3 then
                local hrp = chr:FindFirstChild("HumanoidRootPart") or chr.PrimaryPart
                if hrp then
                    local ppos = hrp.Position; local seg = 16
                    for i = 1, seg do
                        local a1, a2 = (i-1)/seg*math.pi*2, i/seg*math.pi*2
                        local py = ppos.Y - 2
                        local p1 = Vector3.new(ppos.X + math.cos(a1)*calcParryDist, py, ppos.Z + math.sin(a1)*calcParryDist)
                        local p2 = Vector3.new(ppos.X + math.cos(a2)*calcParryDist, py, ppos.Z + math.sin(a2)*calcParryDist)
                        local ok1, s1, v1 = pcall(WorldToScreen, p1)
                        local ok2, s2, v2 = pcall(WorldToScreen, p2)
                        if ok1 and ok2 and v1 and v2 and ringLines[i] then
                            ringLines[i].Visible = true
                            ringLines[i].From = s1; ringLines[i].To = s2
                            ringLines[i].Color = State.chasing and Color3.fromRGB(100,255,100) or Color3.fromRGB(255,200,100)
                            ringLines[i].Transparency = 0
                        end
                    end
                end
            end

            -- Ball Trajectory Line Rendering
            for _, l in pairs(dotObj) do if l then l.Visible = false end end
            if Config.Trajectory and State.ball and State.spd > 0.5 then
                local prev
                for i = 0, 5 do
                    local p = State.pos + norm(State.vel) * State.spd * (i * 0.35)
                    local okW, sv, on = pcall(WorldToScreen, p)
                    if okW and on then
                        if prev then
                            if not dotObj[i] then dotObj[i] = Drawing.new("Line") end
                            if dotObj[i] then
                                dotObj[i].Visible = true
                                dotObj[i].From = prev; dotObj[i].To = sv
                                dotObj[i].Color = Color3.fromRGB(255, 255, 0)
                                dotObj[i].Thickness = 3
                                dotObj[i].Transparency = 0
                            end
                        end
                        prev = sv
                    end
                end
            end
        end)
    end
end)

print("=== Blade Ball Auto Parry (INS-ui + Stage Debug) Loaded ===")
