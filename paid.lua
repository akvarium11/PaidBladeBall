local Lib = pcall(function()
    return loadstring(game:HttpGet("https://raw.githubusercontent.com/neaxusxgod-png/INS-ui/main/uilib.min.lua"))()
end)
if type(Lib) == "boolean" or not Lib then Lib = rawget(_G, "INSui") end

-- Services
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StatsService = game:GetService("Stats")
local VirtualInputManager = game:GetService("VirtualInputManager")

local lp = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Config & Global State
--------------------------------------------------------------------------------
local Config = {
    AutoParry = false,
    ParryMode = "F Key", -- "F Key", "LMB (Mouse)", "Both (F + LMB)", "All (Key + Mouse + Remote)"
    MinAuraRadius = 18,  -- Minimum aura circle radius (studs)
    AutoAbility = false,
    DebugConsole = true, -- Logs target threat & parry triggers to F9 developer console
    RangeRing = true,    -- Draws 3D floor ring for parry distance
    Trajectory = true,   -- Draws ball flight trajectory line
}

local State = {
    auraRadius = 18,
    lastParryTime = 0,
    parryCount = 0,
    lastThreatState = nil,
    lastAbilityTime = 0,
    ping = 60,
}

--------------------------------------------------------------------------------
-- Ping & Math Helpers
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

local function getLocalCharacter()
    if not lp then return nil end
    local aliveFolder = Workspace:FindFirstChild("Alive")
    if aliveFolder then
        local char = aliveFolder:FindFirstChild(lp.Name)
        if char then return char end
    end
    return lp.Character
end

local function CustomW2S(pos)
    if not pos then return Vector2.new(0, 0), false end
    local camera = Workspace.CurrentCamera
    if camera then
        local ok, sp, inViewport = pcall(function() return camera:WorldToViewportPoint(pos) end)
        if ok and sp then
            return Vector2.new(sp.X, sp.Y), inViewport and (sp.Z > 0)
        end
    end
    return Vector2.new(0, 0), false
end

--------------------------------------------------------------------------------
-- Anti-Cheat Ball Resolver (Low-Latency Responsive Trajectory Tracker)
--------------------------------------------------------------------------------
local Resolver = {
    rawPos = Vector3.new(),
    resolvedPos = Vector3.new(),
    resolvedVel = Vector3.new(),
    spd = 0,
    lastValidTime = 0,
    outlierCount = 0,
    validCount = 0,
    samples = {},
}

function Resolver:Reset()
    self.rawPos = Vector3.new()
    self.resolvedPos = Vector3.new()
    self.resolvedVel = Vector3.new()
    self.spd = 0
    self.lastValidTime = 0
    self.outlierCount = 0
    self.validCount = 0
    self.samples = {}
end

function Resolver:Update(part, dt)
    if not part or not part.Parent then
        self:Reset()
        return false
    end

    local raw = part.Position
    self.rawPos = raw
    local now = tick()

    if self.validCount == 0 or self.resolvedPos == Vector3.new() then
        self.resolvedPos = raw
        self.resolvedVel = Vector3.new()
        self.spd = 0
        self.lastValidTime = now
        self.validCount = 1
        return true
    end

    dt = math.clamp(dt, 0.001, 0.1)

    -- Expected position based on current resolved velocity vector
    local predictedPos = self.resolvedPos + self.resolvedVel * dt
    local posErr = (raw - predictedPos).Magnitude
    local rawSpeed = (raw - self.resolvedPos).Magnitude / dt

    -- Filter Criteria:
    -- 1. Error from predicted physical trajectory is reasonable (< 45 studs)
    -- OR 2. Raw movement speed between ticks is within realistic speed (< 450 studs/s)
    local isValid = (posErr < 45) or (rawSpeed < 450)

    if not isValid then
        self.outlierCount = self.outlierCount + 1
        table.insert(self.samples, raw)
        if #self.samples > 4 then table.remove(self.samples, 1) end

        -- If raw positions consistently cluster over multiple updates, re-anchor trajectory immediately
        if #self.samples >= 2 then
            local p1 = self.samples[#self.samples]
            local p2 = self.samples[#self.samples - 1]
            local clusterSpeed = (p1 - p2).Magnitude / dt
            if clusterSpeed < 450 then
                isValid = true
                self.resolvedPos = p1
                self.resolvedVel = (p1 - p2) / dt
                self.samples = {}
            end
        end
    else
        self.samples = {}
    end

    if isValid then
        -- Accept sample with fast 0.70 LERP for minimal tracking lag
        local calcVel = (raw - self.resolvedPos) / dt
        self.resolvedPos = self.resolvedPos:Lerp(raw, 0.70)
        self.resolvedVel = self.resolvedVel:Lerp(calcVel, 0.65)
        self.spd = self.resolvedVel.Magnitude
        self.lastValidTime = now
        self.validCount = self.validCount + 1
    else
        -- Reject fake teleport jump from anti-cheat
        -- Advance predicted position along current trajectory
        self.resolvedPos = self.resolvedPos + self.resolvedVel * dt
        self.spd = self.resolvedVel.Magnitude
    end

    return true
end

--------------------------------------------------------------------------------
-- Ball Instance Binding (game.Workspace.Part)
--------------------------------------------------------------------------------
local function getBallPart()
    local part = Workspace:FindFirstChild("Part")
    if part and part:IsA("BasePart") then
        return part
    end
    for _, obj in ipairs(Workspace:GetChildren()) do
        if obj.Name == "Part" and obj:IsA("BasePart") then
            return obj
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Strict Directional Threat Scanning (Prevents false triggers when standing near)
--------------------------------------------------------------------------------
local function scanBallDirection()
    local chr = getLocalCharacter()
    if not chr then return false, 0, 999, 999, 999 end
    local hrp = chr:FindFirstChild("HumanoidRootPart") or chr.PrimaryPart
    if not hrp then return false, 0, 999, 999, 999 end

    local ballPos = Resolver.resolvedPos
    local ballVel = Resolver.resolvedVel
    local ballSpeed = Resolver.spd

    local distToPlayer = (hrp.Position - ballPos).Magnitude

    -- Require ball to be moving at physical flying speed (> 6 studs/s)
    if ballSpeed < 6 then
        return false, 0, distToPlayer, 999, 999
    end

    local dirToPlayer = (hrp.Position - ballPos).Unit
    local velDir = ballVel.Unit

    local dotProd = velDir:Dot(dirToPlayer)
    local perpDist = distToPlayer * math.sqrt(math.max(0, 1 - dotProd^2))
    local tti = distToPlayer / math.max(ballSpeed, 0.1)

    -- STRICT Directional Threat Criteria:
    -- 1. Velocity vector MUST point directly at local player (dotProd > 0.88)
    -- 2. Perpendicular trajectory miss distance MUST be tight (< 6.5 studs)
    -- (This prevents false triggers when player is standing near the ball or when ball flies past)
    local isThreat = false
    if dotProd > 0.88 and perpDist < 6.5 then
        isThreat = true
    end

    return isThreat, dotProd, distToPlayer, tti, perpDist
end

--------------------------------------------------------------------------------
-- Parry & Ability Action Execution (F Key, Mouse, Remote)
--------------------------------------------------------------------------------
local function pressFKey()
    pcall(function() setrobloxinput(true) end)

    if VirtualInputManager then
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
            task.spawn(function()
                task.wait(0.02)
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
            end)
        end)
    end

    if type(keyclick) == "function" then
        pcall(function() keyclick(0x46) end)
    elseif type(keypress) == "function" then
        pcall(function()
            keypress(0x46)
            task.spawn(function()
                task.wait(0.02)
                if type(keyrelease) == "function" then keyrelease(0x46) end
            end)
        end)
    end
end

local function pressLMB()
    pcall(function() setrobloxinput(true) end)

    if VirtualInputManager then
        pcall(function()
            local vp = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(500, 500)
            VirtualInputManager:SendMouseButtonEvent(vp.X / 2, vp.Y / 2, 0, true, game, 1)
            task.spawn(function()
                task.wait(0.02)
                VirtualInputManager:SendMouseButtonEvent(vp.X / 2, vp.Y / 2, 0, false, game, 1)
            end)
        end)
    end

    if type(mouse1click) == "function" then
        pcall(mouse1click)
    elseif type(mouse1press) == "function" then
        pcall(function()
            mouse1press()
            task.spawn(function()
                task.wait(0.02)
                if type(mouse1release) == "function" then mouse1release() end
            end)
        end)
    end
    if type(click) == "function" then pcall(click) end
end

local function fireParryRemote()
    pcall(function()
        local remotes = ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:FindFirstChild("remotes")
        if remotes then
            local pb = remotes:FindFirstChild("ParryButtonPress") or remotes:FindFirstChild("ParryAttempt") or remotes:FindFirstChild("Parry")
            if pb and pb:IsA("RemoteEvent") then
                pcall(function() pb:FireServer() end)
                return
            end
        end
        for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
            if obj:IsA("RemoteEvent") and (obj.Name:find("Parry") or obj.Name:find("parry")) then
                pcall(function() obj:FireServer() end)
                return
            end
        end
    end)
end

local function doParry()
    local mode = Config.ParryMode
    if mode == "F Key" then
        pressFKey()
        fireParryRemote()
    elseif mode == "LMB (Mouse)" or mode == "Mouse" then
        pressLMB()
        fireParryRemote()
    elseif mode == "Both (F + LMB)" then
        pressFKey()
        pressLMB()
        fireParryRemote()
    else -- "All (Key + Mouse + Remote)"
        pressFKey()
        pressLMB()
        fireParryRemote()
    end
end

local function doAbility()
    pcall(function()
        local r = ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:FindFirstChild("remotes")
        local ar = r and (r:FindFirstChild("AbilityButtonPress") or r:FindFirstChild("Ability"))
        if ar and ar:IsA("RemoteEvent") then
            pcall(function() ar:FireServer() end)
            if Config.DebugConsole then
                print("[AutoParry] ⚡ Auto Ability Triggered!")
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Main Loop (Heartbeat Thread with Latency Lead Compensation)
--------------------------------------------------------------------------------
local lastTime = tick()

RunService.Heartbeat:Connect(function()
    local now = tick()
    local dt = now - lastTime
    lastTime = now

    State.ping = getPing()

    local part = getBallPart()
    if not part then
        Resolver:Reset()
        if Config.DebugConsole and State.lastThreatState ~= nil and State.lastThreatState ~= false then
            State.lastThreatState = false
            print("[AutoParry] ⚪ Ball (game.Workspace.Part) not found / inactive")
        end
        return
    end

    Resolver:Update(part, dt)

    local isThreat, dotProd, distToPlayer, tti, perpDist = scanBallDirection()

    -- Dynamic Aura Radius with Ping & Velocity Lead Time Compensation:
    -- Higher speed & higher ping -> expand trigger radius significantly early!
    local baseAuraRadius = Config.MinAuraRadius or 18
    local pingLeadFactor = (State.ping / 1000) + 0.35 -- seconds of lead time
    local speedAddition = Resolver.spd * pingLeadFactor
    State.auraRadius = math.clamp(baseAuraRadius + speedAddition, baseAuraRadius, 150)

    -- Dynamic TTI Threshold for Early Parry
    -- Trigger parry when TTI is less than network ping + reaction window (e.g. ~0.22s - 0.40s)
    local targetTTIThreshold = math.clamp((State.ping / 1000) + 0.22, 0.15, 0.45)

    -- Console Logger for Target Threat Status
    if Config.DebugConsole then
        if isThreat ~= State.lastThreatState then
            State.lastThreatState = isThreat
            if isThreat then
                print(string.format("[AutoParry] 🎯 BALL IS FLYING AT YOU! Speed: %.1f studs/s | Dist: %.1f studs | TTI: %.2fs | Dot: %.2f | PerpDist: %.1f studs", Resolver.spd, distToPlayer, tti, dotProd, perpDist))
            else
                print(string.format("[AutoParry] 🟢 Ball vector safe / turned away | Speed: %.1f studs/s | Dist: %.1f studs | Dot: %.2f", Resolver.spd, distToPlayer, dotProd))
            end
        end
    end

    -- Check Parry Condition:
    -- 1. Threat is confirmed via strict direction scan (dot > 0.88, perpDist < 6.5)
    -- 2. AND (Distance is inside auraRadius OR TTI <= targetTTIThreshold)
    -- 3. AND Cooldown > 0.25s since last parry
    local timeSinceLastParry = now - State.lastParryTime
    local insideAura = (distToPlayer <= State.auraRadius) or (tti <= targetTTIThreshold)
    local shouldParry = Config.AutoParry and isThreat and insideAura and timeSinceLastParry > 0.25

    if shouldParry then
        State.lastParryTime = now
        State.parryCount = State.parryCount + 1

        if Config.DebugConsole then
            print(string.format("[AutoParry] ⚡ PARRY EXECUTED (#%d)! Mode: %s | Dist: %.1f <= Aura: %.1f studs | Speed: %.1f studs/s | TTI: %.2fs (Thresh: %.2fs)", State.parryCount, Config.ParryMode, distToPlayer, State.auraRadius, Resolver.spd, tti, targetTTIThreshold))
        end

        doParry()

        if Config.AutoAbility and (now - State.lastAbilityTime > 1.2) then
            State.lastAbilityTime = now
            doAbility()
        end
    end
end)

--------------------------------------------------------------------------------
-- 3D Rendering (Drawing API: White Aura Circle & Trajectory Line)
--------------------------------------------------------------------------------
task.spawn(function()
    local have_draw = type(Drawing) == "table"
    if not have_draw then return end

    local SEGMENTS = 24
    local circleOffsets = {}
    for i = 1, SEGMENTS do
        local angle = (i - 1) / SEGMENTS * math.pi * 2
        circleOffsets[i] = { cos = math.cos(angle), sin = math.sin(angle) }
    end

    local ringLines = {}
    for i = 1, SEGMENTS do
        local l = Drawing.new("Line")
        if l then l.Visible = false; l.Thickness = 2; l.Transparency = 1 end
        ringLines[i] = l
    end

    local dotObj = {}

    while true do
        task.wait(0.016) -- ~60 FPS update rate for 3D Ring
        pcall(function()
            -- Render White Aura Circle (3D Ring)
            if Config.RangeRing then
                local chr = getLocalCharacter()
                local hrp = chr and (chr:FindFirstChild("HumanoidRootPart") or chr.PrimaryPart)
                if hrp then
                    local currentAuraRadius = State.auraRadius or 18
                    local ppos = hrp.Position
                    local py = ppos.Y - 3
                    local screenPoints = {}

                    for i = 1, SEGMENTS do
                        local off = circleOffsets[i]
                        local p = Vector3.new(ppos.X + off.cos * currentAuraRadius, py, ppos.Z + off.sin * currentAuraRadius)
                        local sv, on = CustomW2S(p)
                        screenPoints[i] = { pos = sv, visible = on }
                    end

                    for i = 1, SEGMENTS do
                        local nxt = (i % SEGMENTS) + 1
                        local p1 = screenPoints[i]
                        local p2 = screenPoints[nxt]
                        local line = ringLines[i]

                        if line and p1.visible and p2.visible then
                            line.From = p1.pos
                            line.To = p2.pos
                            line.Color = Color3.fromRGB(255, 255, 255)
                            line.Thickness = 2
                            line.Transparency = 1
                            line.Visible = true
                        elseif line then
                            line.Visible = false
                        end
                    end
                else
                    for i = 1, SEGMENTS do if ringLines[i] then ringLines[i].Visible = false end end
                end
            else
                for i = 1, SEGMENTS do if ringLines[i] then ringLines[i].Visible = false end end
            end

            -- Render Resolved Trajectory Line
            for _, l in pairs(dotObj) do if l then l.Visible = false end end
            if Config.Trajectory and Resolver.spd > 1 and Resolver.resolvedPos ~= Vector3.new() then
                local prev
                local velDir = Resolver.resolvedVel.Unit
                for i = 0, 5 do
                    local p = Resolver.resolvedPos + velDir * Resolver.spd * (i * 0.35)
                    local sv, on = CustomW2S(p)
                    if on then
                        if prev then
                            if not dotObj[i] then dotObj[i] = Drawing.new("Line") end
                            if dotObj[i] then
                                dotObj[i].Visible = true
                                dotObj[i].From = prev
                                dotObj[i].To = sv
                                dotObj[i].Color = Color3.fromRGB(255, 255, 0)
                                dotObj[i].Thickness = 3
                                dotObj[i].Transparency = 1
                            end
                        end
                        prev = sv
                    end
                end
            end
        end)
    end
end)

--------------------------------------------------------------------------------
-- UI Menu Construction
--------------------------------------------------------------------------------
if Lib and Lib.CreateWindow then
    local Window = Lib:CreateWindow({
        title = "Blade Ball - AntiCheat Resolver",
        subtitle = "Matcha AP",
        size = Vector2.new(600, 440),
        menuKey = "p",
        configName = "bladeball_resolver",
        configFolder = "bladeball",
        accentA = Color3.fromRGB(122, 134, 255),
        accentB = Color3.fromRGB(189, 130, 255),
        startOpen = true,
        keybindOverlay = false,
        checkboxStyle = true,
        smartFps = true,
        autoSave = true,
    })

    local Main = Window:Tab("Auto Parry", "swords")
    local VisTab = Window:Tab("Visuals & Debug", "eye")

    local ParrySection = Main:Section("Parry Core", "Left", "Automatic deflection via direction scanning")
    local SettingsSection = Main:Section("Settings", "Right", "Parry behavior & abilities")

    ParrySection:Toggle("Auto Parry", Config.AutoParry, function(v)
        Config.AutoParry = v
        if v then
            print("[AutoParry] Auto Parry Activated")
        else
            print("[AutoParry] Auto Parry Deactivated")
        end
    end)

    ParrySection:Dropdown("Parry Input Mode", {"F Key", "LMB (Mouse)", "Both (F + LMB)", "All (Key + Mouse + Remote)"}, Config.ParryMode, function(v)
        Config.ParryMode = v
    end)

    ParrySection:Slider("Min Aura Radius", 10, 40, Config.MinAuraRadius, function(v)
        Config.MinAuraRadius = v
    end)

    SettingsSection:Toggle("Auto Ability", Config.AutoAbility, function(v)
        Config.AutoAbility = v
    end)

    local RenderSection = VisTab:Section("Render Settings", "Left", "3D distance ring & trajectory line")
    local DebugSection = VisTab:Section("Console Logging", "Right", "Developer console logs (F9)")

    RenderSection:Toggle("White Aura Circle (3D Ring)", Config.RangeRing, function(v)
        Config.RangeRing = v
    end)

    RenderSection:Toggle("Ball Flight Trajectory", Config.Trajectory, function(v)
        Config.Trajectory = v
    end)

    DebugSection:Toggle("Console Logs (F9 Output)", Config.DebugConsole, function(v)
        Config.DebugConsole = v
    end)

    DebugSection:Button("Reset Ball Resolver", function()
        Resolver:Reset()
        print("[AutoParry] Ball Resolver State Reset")
    end)
end

print("=== Blade Ball Auto Parry (Optimized Latency & Strict Direction) Loaded ===")
