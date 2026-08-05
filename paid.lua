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
    ParryMode = "F Key", -- "F Key", "LMB (Mouse)", "Both (F + LMB)", "All (Key + Mouse)"
    MinAuraRadius = 18,  -- Minimum aura circle radius (studs)
    AutoClash = true,    -- Automatic Clash Mode (Block spam when close)
    ClashDistance = 22,  -- Distance threshold for Clash Mode (studs)
    ClashMinSpeed = 35,  -- Min ball speed for Clash Mode (studs/s)
    AutoAbility = false,
    DebugConsole = true, -- Logs target threat & parry triggers to F9 developer console
    RangeRing = true,    -- Draws 3D floor ring for parry distance
    Trajectory = true,   -- Draws ball flight trajectory line
    UseRemote = false,   -- Disabled by default to avoid Matcha "hybrid mode" errors
}

local State = {
    auraRadius = 18,
    lastParryTime = 0,
    parryCount = 0,
    lastThreatState = nil,
    lastAbilityTime = 0,
    ping = 60,
    prevRawPos = Vector3.new(),
    rawVel = Vector3.new(),
    inClash = false,
    lastClashSpam = 0,
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
-- Anti-Cheat Ball Resolver (Physical Speed Cap & Outlier Filter)
--------------------------------------------------------------------------------
local MAX_PHYSICAL_SPEED = 550 -- Max realistic ball speed (studs/s). Anything above is anti-cheat teleport jump.

local Resolver = {
    rawPos = Vector3.new(),
    resolvedPos = Vector3.new(),
    resolvedVel = Vector3.new(),
    spd = 0,
    lastValidTime = 0,
    outlierCount = 0,
    validCount = 0,
}

function Resolver:Reset()
    self.rawPos = Vector3.new()
    self.resolvedPos = Vector3.new()
    self.resolvedVel = Vector3.new()
    self.spd = 0
    self.lastValidTime = 0
    self.outlierCount = 0
    self.validCount = 0
    State.prevRawPos = Vector3.new()
    State.rawVel = Vector3.new()
    State.inClash = false
end

function Resolver:Update(part, dt)
    if not part or not part.Parent then
        self:Reset()
        return false
    end

    local raw = part.Position
    self.rawPos = raw
    local now = tick()

    dt = math.clamp(dt, 0.001, 0.1)

    -- Calculate instantaneous raw frame velocity
    local instantSpeed = 0
    if State.prevRawPos ~= Vector3.new() then
        local delta = raw - State.prevRawPos
        instantSpeed = delta.Magnitude / dt
        if instantSpeed <= MAX_PHYSICAL_SPEED then
            State.rawVel = delta / dt
        end
    end
    State.prevRawPos = raw

    if self.validCount == 0 or self.resolvedPos == Vector3.new() then
        if instantSpeed <= MAX_PHYSICAL_SPEED then
            self.resolvedPos = raw
            self.resolvedVel = State.rawVel
            self.spd = State.rawVel.Magnitude
            self.lastValidTime = now
            self.validCount = 1
        end
        return true
    end

    -- Reject Anti-Cheat Teleport Jumps (Extreme Speeds > 550 studs/s)
    if instantSpeed > MAX_PHYSICAL_SPEED then
        self.outlierCount = self.outlierCount + 1
        self.resolvedPos = self.resolvedPos + self.resolvedVel * dt
        self.spd = self.resolvedVel.Magnitude
        return false
    end

    -- Real physical ball movement! Check instant turnaround (deflection/return hit)
    if State.rawVel.Magnitude > 10 and self.resolvedVel.Magnitude > 10 then
        local dirDot = State.rawVel.Unit:Dot(self.resolvedVel.Unit)
        if dirDot < 0.4 then
            -- Sudden turnaround hit! Snap immediately!
            self.resolvedPos = raw
            self.resolvedVel = State.rawVel
            self.spd = State.rawVel.Magnitude
            self.lastValidTime = now
            return true
        end
    end

    -- Normal physical movement: update position & velocity with fast lerp
    self.resolvedPos = self.resolvedPos:Lerp(raw, 0.75)
    self.resolvedVel = self.resolvedVel:Lerp(State.rawVel, 0.70)
    self.spd = self.resolvedVel.Magnitude
    self.lastValidTime = now
    self.validCount = self.validCount + 1

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
-- Direction Scanning (Sanitized Physics Bounds Only)
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

    if ballSpeed < 5 or ballSpeed > MAX_PHYSICAL_SPEED then
        return false, 0, distToPlayer, 999, 999
    end

    local dirToPlayer = (hrp.Position - ballPos).Unit
    local velDir = ballVel.Unit

    local dotProd = velDir:Dot(dirToPlayer)
    local perpDist = distToPlayer * math.sqrt(math.max(0, 1 - dotProd^2))
    local tti = distToPlayer / math.max(ballSpeed, 0.1)

    -- Strict Directional Threat Criteria:
    -- 1. Velocity vector points directly at local player (dotProd > 0.88)
    -- 2. Perpendicular trajectory miss distance is within hit area (< 10.0 studs)
    local isThreat = false
    if dotProd > 0.88 and perpDist < 10.0 then
        isThreat = true
    end

    return isThreat, dotProd, distToPlayer, tti, perpDist
end

--------------------------------------------------------------------------------
-- Enemy Proximity Scan (For Clash Detection)
--------------------------------------------------------------------------------
local function isEnemyNear(myHrp, range)
    local aliveFolder = Workspace:FindFirstChild("Alive")
    if not aliveFolder or not myHrp then return false end
    for _, char in ipairs(aliveFolder:GetChildren()) do
        if char.Name ~= lp.Name then
            local enemyHrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
            if enemyHrp then
                local dist = (enemyHrp.Position - myHrp.Position).Magnitude
                if dist <= range then
                    return true
                end
            end
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Physical Parry & Ability Action Execution (F Key, Mouse)
--------------------------------------------------------------------------------
local function pressFKey()
    pcall(function() setrobloxinput(true) end)

    if VirtualInputManager then
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
            task.spawn(function()
                task.wait(0.015)
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
                task.wait(0.015)
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
                task.wait(0.015)
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
                task.wait(0.015)
                if type(mouse1release) == "function" then mouse1release() end
            end)
        end)
    end
    if type(click) == "function" then pcall(click) end
end

local function fireParryRemote()
    if not Config.UseRemote then return end
    pcall(function()
        local remotes = ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:FindFirstChild("remotes")
        if remotes then
            local pb = remotes:FindFirstChild("ParryButtonPress") or remotes:FindFirstChild("ParryAttempt") or remotes:FindFirstChild("Parry")
            if pb and pb:IsA("RemoteEvent") then
                pcall(function() pb:FireServer() end)
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
    else -- "All (Key + Mouse)"
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
-- Main Loop (Includes Auto Parry & Clash Mode Spam Engine)
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
    local chr = getLocalCharacter()
    local hrp = chr and (chr:FindFirstChild("HumanoidRootPart") or chr.PrimaryPart)

    ----------------------------------------------------------------------------
    -- CLASH MODE DETECTION & BLOCK SPAMMING ENGINE
    ----------------------------------------------------------------------------
    local isClashActive = false
    if Config.AutoParry and Config.AutoClash and hrp then
        local clashDistLimit = Config.ClashDistance or 22
        local clashMinSpd = Config.ClashMinSpeed or 35
        local hasEnemyNear = isEnemyNear(hrp, clashDistLimit + 10)

        -- Clash Condition:
        -- 1. Ball is within Clash Distance (<= 22 studs) AND speed >= 35 studs/s
        -- 2. AND (Ball is heading towards player OR enemy player is right next to local player)
        if distToPlayer <= clashDistLimit and Resolver.spd >= clashMinSpd and (isThreat or dotProd > 0.20 or hasEnemyNear) then
            isClashActive = true
        end
    end

    if isClashActive then
        if not State.inClash then
            State.inClash = true
            if Config.DebugConsole then
                print(string.format("[AutoParry] ⚔️ CLASH MODE ACTIVATED! (Dist: %.1f studs | Speed: %.1f studs/s) - SPAMMING BLOCK!", distToPlayer, Resolver.spd))
            end
        end

        -- Ultra-fast Clash Spamming (~40 Hz block spam)
        if now - State.lastClashSpam > 0.025 then
            State.lastClashSpam = now
            State.lastParryTime = now
            State.parryCount = State.parryCount + 1
            doParry()
        end
        return -- Skip normal single-parry logic while in Clash Mode
    else
        if State.inClash then
            State.inClash = false
            if Config.DebugConsole then
                print("[AutoParry] 🛡️ Clash Mode Deactivated")
            end
        end
    end

    ----------------------------------------------------------------------------
    -- STANDARD SINGLE-PARRY DIRECTIONAL LOGIC
    ----------------------------------------------------------------------------
    local baseAuraRadius = Config.MinAuraRadius or 18
    local pingLeadFactor = (State.ping / 1000) + 0.25
    local speedAddition = Resolver.spd * pingLeadFactor
    State.auraRadius = math.clamp(baseAuraRadius + speedAddition, baseAuraRadius, 75)

    local targetTTIThreshold = math.clamp((State.ping / 1000) + 0.20, 0.15, 0.40)

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

    local timeSinceLastParry = now - State.lastParryTime
    local distanceTrigger = (distToPlayer <= State.auraRadius) or (tti <= targetTTIThreshold)
    local shouldParry = Config.AutoParry and isThreat and distanceTrigger and timeSinceLastParry > 0.15

    if shouldParry then
        State.lastParryTime = now
        State.parryCount = State.parryCount + 1

        if Config.DebugConsole then
            print(string.format("[AutoParry] ⚡ PARRY EXECUTED (#%d)! Mode: %s | Dist: %.1f <= Aura: %.1f studs | Speed: %.1f studs/s | TTI: %.2fs", State.parryCount, Config.ParryMode, distToPlayer, State.auraRadius, Resolver.spd, tti))
        end

        doParry()

        if Config.AutoAbility and (now - State.lastAbilityTime > 1.2) then
            State.lastAbilityTime = now
            doAbility()
        end
    end
end)

--------------------------------------------------------------------------------
-- 3D Rendering (Drawing API: Dynamic Aura Ring & Trajectory Line)
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
            -- Render Aura Circle (3D Ring)
            if Config.RangeRing then
                local chr = getLocalCharacter()
                local hrp = chr and (chr:FindFirstChild("HumanoidRootPart") or chr.PrimaryPart)
                if hrp then
                    local currentAuraRadius = State.inClash and (Config.ClashDistance or 22) or (State.auraRadius or 18)
                    local ppos = hrp.Position
                    local py = ppos.Y - 3
                    local screenPoints = {}

                    for i = 1, SEGMENTS do
                        local off = circleOffsets[i]
                        local p = Vector3.new(ppos.X + off.cos * currentAuraRadius, py, ppos.Z + off.sin * currentAuraRadius)
                        local sv, on = CustomW2S(p)
                        screenPoints[i] = { pos = sv, visible = on }
                    end

                    -- Change ring color to Bright Red in Clash Mode, White in Normal Mode
                    local ringColor = State.inClash and Color3.fromRGB(255, 50, 50) or Color3.fromRGB(255, 255, 255)
                    local ringThickness = State.inClash and 3 or 2

                    for i = 1, SEGMENTS do
                        local nxt = (i % SEGMENTS) + 1
                        local p1 = screenPoints[i]
                        local p2 = screenPoints[nxt]
                        local line = ringLines[i]

                        if line and p1.visible and p2.visible then
                            line.From = p1.pos
                            line.To = p2.pos
                            line.Color = ringColor
                            line.Thickness = ringThickness
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
            if Config.Trajectory and Resolver.spd > 1 and Resolver.spd <= MAX_PHYSICAL_SPEED and Resolver.resolvedPos ~= Vector3.new() then
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
                                dotObj[i].Color = State.inClash and Color3.fromRGB(255, 50, 50) or Color3.fromRGB(255, 255, 0)
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
        size = Vector2.new(620, 480),
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
    local ClashSection = Main:Section("Clash Mode", "Right", "High-speed close proximity block spam")

    ParrySection:Toggle("Auto Parry", Config.AutoParry, function(v)
        Config.AutoParry = v
        if v then
            print("[AutoParry] Auto Parry Activated")
        else
            print("[AutoParry] Auto Parry Deactivated")
        end
    end)

    ParrySection:Dropdown("Parry Input Mode", {"F Key", "LMB (Mouse)", "Both (F + LMB)", "All (Key + Mouse)"}, Config.ParryMode, function(v)
        Config.ParryMode = v
    end)

    ParrySection:Slider("Min Aura Radius", 10, 40, Config.MinAuraRadius, function(v)
        Config.MinAuraRadius = v
    end)

    ClashSection:Toggle("Auto Clash Mode", Config.AutoClash, function(v)
        Config.AutoClash = v
        print("[AutoParry] Auto Clash Mode set to: " .. tostring(v))
    end)

    ClashSection:Slider("Clash Distance", 10, 40, Config.ClashDistance, function(v)
        Config.ClashDistance = v
    end)

    ClashSection:Slider("Clash Min Speed", 10, 100, Config.ClashMinSpeed, function(v)
        Config.ClashMinSpeed = v
    end)

    ClashSection:Toggle("Auto Ability", Config.AutoAbility, function(v)
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

print("=== Blade Ball Auto Parry (Auto Clash Mode + Spam Engine Included) Loaded ===")
