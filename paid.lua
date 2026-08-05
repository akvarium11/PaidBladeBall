--------------------------------------------------------------------------------
-- UI Library Loader (CatHook Method: Local Workspace + Remote GitHub Fallback)
--------------------------------------------------------------------------------
local Lib
do
    local function resolveLib(res)
        if res and type(res) == "table" and res.CreateWindow then
            return res
        end
        if type(getgenv) == "function" then
            local ok, g = pcall(getgenv)
            if ok and type(g) == "table" then
                if g.INSui and type(g.INSui) == "table" and g.INSui.CreateWindow then return g.INSui end
                if g.INSuiUI and type(g.INSuiUI) == "table" and g.INSuiUI.CreateWindow then return g.INSuiUI end
            end
        end
        if type(_G) == "table" then
            if _G.INSui and type(_G.INSui) == "table" and _G.INSui.CreateWindow then return _G.INSui end
            if _G.INSuiUI and type(_G.INSuiUI) == "table" and _G.INSuiUI.CreateWindow then return _G.INSuiUI end
        end
        if type(shared) == "table" then
            if shared.INSui and type(shared.INSui) == "table" and shared.INSui.CreateWindow then return shared.INSui end
            if shared.INSuiUI and type(shared.INSuiUI) == "table" and shared.INSuiUI.CreateWindow then return shared.INSuiUI end
        end
        return nil
    end

    local function fetchUI()
        -- 1. Try local workspace paths first
        if type(readfile) == "function" then
            local paths = {"BladeBall/uilib.lua", "workspace/BladeBall/uilib.lua", "uilib.lua", "workspace/uilib.lua"}
            for _, path in ipairs(paths) do
                local ok, content = pcall(readfile, path)
                if ok and content and type(content) == "string" and #content > 0 then
                    local func, err = loadstring(content)
                    if func then
                        local okExec, res = pcall(func)
                        if okExec then
                            local lib = resolveLib(res)
                            if lib then return lib end
                        end
                    end
                end
            end
        end

        -- 2. Try HTTP download from GitHub
        local targetUrl = "https://raw.githubusercontent.com/akvarium11/PaidBladeBall/refs/heads/master/BladeBall/uilib.lua"
        local httpSuccess, httpContent = pcall(function()
            if type(httpget) == "function" then
                return httpget(targetUrl)
            elseif game and type(game.HttpGet) == "function" then
                return game:HttpGet(targetUrl)
            end
        end)

        if httpSuccess and httpContent and type(httpContent) == "string" and #httpContent > 0 then
            local func, compileErr = loadstring(httpContent)
            if func then
                local okExec, res = pcall(func)
                if okExec then
                    local lib = resolveLib(res)
                    if lib then return lib end
                else
                    warn("[AutoParry] Failed to execute online UI Library: " .. tostring(res))
                end
            else
                warn("[AutoParry] Failed to compile online UI Library: " .. tostring(compileErr))
            end
        else
            warn("[AutoParry] Failed to download UI Library from GitHub: " .. tostring(httpContent))
        end

        -- 3. Fallback to existing global INSui if available
        return resolveLib(nil)
    end

    Lib = fetchUI()
end

-- Services
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StatsService = game:GetService("Stats")
local VirtualInputManager = game:GetService("VirtualInputManager")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Config & Global State
--------------------------------------------------------------------------------
local Config = {
    AutoParry = false,
    AutoParryKey = "X", -- Default keybind to toggle Auto Parry (e.g. "X")
    ParryMode = "F Key", -- "F Key", "LMB (Mouse)", "Both (F + LMB)", "All (Key + Mouse)"
    TargetCheck = true,  -- Strict target check (prevents false positives when ball flies near you to another player)
    MinAuraRadius = 15,  -- Base aura circle radius (studs)
    ParryLeadTime = 0.25,-- Lead time added to network ping for TTI calculation (seconds)
    AutoClash = true,    -- Automatic Clash Mode (Block spam when close)
    ClashDistance = 22,  -- Distance threshold for Clash Mode (studs)
    ClashMinSpeed = 35,  -- Min ball speed for Clash Mode (studs/s)
    AutoAbility = false,
    DebugConsole = true, -- Logs target threat & parry triggers to F9 developer console
    RangeRing = true,    -- Draws 3D floor ring for parry distance
    Trajectory = true,   -- Draws ball flight trajectory line
    KeybindHUD = true,   -- Floating Keybinds Island HUD
    UseRemote = false,   -- Disabled by default to avoid Matcha "hybrid mode" errors
}

local State = {
    auraRadius = 15,
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

    -- Detect sudden ball teleport / round start reset
    if self.resolvedPos ~= Vector3.new() and (raw - self.resolvedPos).Magnitude > 180 then
        self:Reset()
        self.resolvedPos = raw
        self.lastValidTime = now
        State.prevRawPos = raw
        return true
    end

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
    self.resolvedPos = self.resolvedPos:Lerp(raw, 0.80)
    self.resolvedVel = self.resolvedVel:Lerp(State.rawVel, 0.75)
    self.spd = self.resolvedVel.Magnitude
    self.lastValidTime = now
    self.validCount = self.validCount + 1

    return true
end

--------------------------------------------------------------------------------
-- Ball Instance & Target Binding
--------------------------------------------------------------------------------
local function getBallPart()
    local ballsFolder = Workspace:FindFirstChild("Balls") or Workspace:FindFirstChild("balls")
    if ballsFolder then
        for _, obj in ipairs(ballsFolder:GetChildren()) do
            if obj:IsA("BasePart") and obj:GetAttribute("realBall") ~= false then
                return obj
            end
        end
    end

    local part = Workspace:FindFirstChild("Part")
    if part and part:IsA("BasePart") and part:GetAttribute("realBall") ~= false then
        return part
    end

    for _, obj in ipairs(Workspace:GetChildren()) do
        if obj.Name == "Part" and obj:IsA("BasePart") and obj:GetAttribute("realBall") ~= false then
            return obj
        end
    end
    return nil
end

local function isBallTargetingMe(ball)
    if not ball or not lp then return false end

    -- Check attributes (string or instance)
    local targetAttr = ball:GetAttribute("target") or ball:GetAttribute("Target") or ball:GetAttribute("targeter") or ball:GetAttribute("Targeter")
    if targetAttr ~= nil then
        if type(targetAttr) == "string" and targetAttr == lp.Name then
            return true
        elseif typeof(targetAttr) == "Instance" and (targetAttr == lp or targetAttr == lp.Character) then
            return true
        else
            return false
        end
    end

    -- Check children objects (StringValue or ObjectValue)
    local targetVal = ball:FindFirstChild("target") or ball:FindFirstChild("Target") or ball:FindFirstChild("targeter")
    if targetVal then
        if targetVal:IsA("ObjectValue") and (targetVal.Value == lp or targetVal.Value == lp.Character) then
            return true
        elseif targetVal:IsA("StringValue") and targetVal.Value == lp.Name then
            return true
        else
            return false
        end
    end

    -- Target attribute not set / unknown
    return nil
end

--------------------------------------------------------------------------------
-- Direction & Threat Scanning
--------------------------------------------------------------------------------
local function scanBallDirection(ball)
    local chr = getLocalCharacter()
    if not chr or not ball then return false, 0, 999, 999, 999, "No Target/Ball" end
    local hrp = chr:FindFirstChild("HumanoidRootPart") or chr.PrimaryPart
    if not hrp then return false, 0, 999, 999, 999, "No HRP" end

    local ballPos = Resolver.resolvedPos
    local ballVel = Resolver.resolvedVel
    local ballSpeed = Resolver.spd

    local distToPlayer = (hrp.Position - ballPos).Magnitude

    if ballSpeed < 2 or ballSpeed > MAX_PHYSICAL_SPEED then
        return false, 0, distToPlayer, 999, 999, "Invalid Speed"
    end

    local dirToPlayer = (hrp.Position - ballPos).Unit
    local velDir = ballVel.Magnitude > 1 and ballVel.Unit or dirToPlayer

    local dotProd = velDir:Dot(dirToPlayer)
    local perpDist = distToPlayer * math.sqrt(math.max(0, 1 - dotProd^2))
    local tti = distToPlayer / math.max(ballSpeed, 0.1)

    -- 1. Check game target attributes (Primary Anti-False Positive mechanism)
    local targetingMe = isBallTargetingMe(ball)
    if Config.TargetCheck and targetingMe == false then
        return false, dotProd, distToPlayer, tti, perpDist, "Targeting Other Player"
    end

    if targetingMe == true then
        return true, dotProd, distToPlayer, tti, perpDist, "Targeting Me"
    end

    -- 2. Fallback Physics Check if target attribute is absent/unknown:
    -- Require strong directional alignment (dotProd > 0.75) and trajectory miss distance < 12 studs
    local isThreat = (dotProd > 0.75 and perpDist < 12.0)
    return isThreat, dotProd, distToPlayer, tti, perpDist, isThreat and "Physics Threat" or "Safe Vector"
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
            print("[AutoParry] ⚪ Ball not found / inactive")
        end
        return
    end

    Resolver:Update(part, dt)

    local isThreat, dotProd, distToPlayer, tti, perpDist, threatReason = scanBallDirection(part)
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

        -- Clash Condition (MUST be a real threat to LocalPlayer!):
        -- 1. Ball is targeting / threatening LocalPlayer
        -- 2. Ball is within Clash Distance (<= 22 studs)
        -- 3. Ball speed >= ClashMinSpeed OR enemy is close by
        if isThreat and distToPlayer <= clashDistLimit and (Resolver.spd >= clashMinSpd or hasEnemyNear) then
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
    local pingSeconds = State.ping / 1000
    local parryLead = Config.ParryLeadTime or 0.25
    local targetTTIThreshold = math.clamp(pingSeconds + parryLead, 0.10, 0.50)

    -- Dynamic Visual Aura Radius
    local baseAuraRadius = Config.MinAuraRadius or 15
    local speedAddition = Resolver.spd * (pingSeconds + 0.15)
    State.auraRadius = math.clamp(baseAuraRadius + speedAddition, baseAuraRadius, 50)

    if Config.DebugConsole then
        if isThreat ~= State.lastThreatState then
            State.lastThreatState = isThreat
            if isThreat then
                print(string.format("[AutoParry] 🎯 THREAT DETECTED (%s)! Speed: %.1f studs/s | Dist: %.1f studs | TTI: %.2fs | Dot: %.2f", threatReason, Resolver.spd, distToPlayer, tti, dotProd))
            else
                print(string.format("[AutoParry] 🟢 Vector safe / turned away (%s) | Speed: %.1f studs/s | Dist: %.1f studs | Dot: %.2f", threatReason, Resolver.spd, distToPlayer, dotProd))
            end
        end
    end

    local timeSinceLastParry = now - State.lastParryTime
    local triggerCondition = (tti <= targetTTIThreshold) or (distToPlayer <= Config.MinAuraRadius)
    local shouldParry = Config.AutoParry and isThreat and triggerCondition and (timeSinceLastParry > 0.18)

    if shouldParry then
        State.lastParryTime = now
        State.parryCount = State.parryCount + 1

        if Config.DebugConsole then
            print(string.format("[AutoParry] ⚡ PARRY EXECUTED (#%d)! Mode: %s | Dist: %.1f studs | Speed: %.1f studs/s | TTI: %.2fs (Thresh: %.2fs)", State.parryCount, Config.ParryMode, distToPlayer, Resolver.spd, tti, targetTTIThreshold))
        end

        doParry()

        if Config.AutoAbility and (now - State.lastAbilityTime > 1.2) then
            State.lastAbilityTime = now
            doAbility()
        end
    end
end)

--------------------------------------------------------------------------------
-- Fallback Keybind Handler (When UI Library is not active)
--------------------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if not Lib and input.UserInputType == Enum.UserInputType.Keyboard then
        if input.KeyCode == Enum.KeyCode[Config.AutoParryKey] then
            Config.AutoParry = not Config.AutoParry
            if Config.AutoParry then
                print("[AutoParry] Auto Parry Activated (via Keybind)")
            else
                print("[AutoParry] Auto Parry Deactivated (via Keybind)")
            end
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
    local hudBg, hudLine, hudHeader, hudItem

    while true do
        task.wait(0.016) -- ~60 FPS update rate for 3D Ring
        pcall(function()
            -- Render Aura Circle (3D Ring)
            if Config.RangeRing then
                local chr = getLocalCharacter()
                local hrp = chr and (chr:FindFirstChild("HumanoidRootPart") or chr.PrimaryPart)
                if hrp then
                    local currentAuraRadius = State.inClash and (Config.ClashDistance or 22) or (State.auraRadius or 15)
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
            -- Render Keybind HUD Island (Fallback when Lib is not loaded)
            if Config.KeybindHUD and not Lib then
                if not hudBg then
                    hudBg = Drawing.new("Square")
                    hudBg.Filled = true
                    hudBg.Color = Color3.fromRGB(18, 18, 22)
                    hudBg.Transparency = 0.85
                    hudBg.Size = Vector2.new(175, 48)
                    hudBg.Position = Vector2.new(20, 100)

                    hudLine = Drawing.new("Line")
                    hudLine.From = Vector2.new(20, 100)
                    hudLine.To = Vector2.new(195, 100)
                    hudLine.Color = Color3.fromRGB(122, 134, 255)
                    hudLine.Thickness = 2

                    hudHeader = Drawing.new("Text")
                    hudHeader.Text = "KEYBINDS"
                    hudHeader.Size = 12
                    hudHeader.Color = Color3.fromRGB(160, 160, 185)
                    hudHeader.Position = Vector2.new(28, 105)

                    hudItem = Drawing.new("Text")
                    hudItem.Size = 14
                    hudItem.Position = Vector2.new(28, 124)
                end

                hudBg.Visible = true
                hudLine.Visible = true
                hudHeader.Visible = true
                hudItem.Visible = true

                local keyName = Config.AutoParryKey or "X"
                if Config.AutoParry then
                    hudItem.Text = string.format("Auto Parry  [%s]  ON", keyName)
                    hudItem.Color = Color3.fromRGB(0, 255, 150)
                else
                    hudItem.Text = string.format("Auto Parry  [%s]  OFF", keyName)
                    hudItem.Color = Color3.fromRGB(200, 70, 70)
                end
            else
                if hudBg then
                    hudBg.Visible = false
                    hudLine.Visible = false
                    hudHeader.Visible = false
                    hudItem.Visible = false
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
        keybindOverlay = true,
        checkboxStyle = true,
        smartFps = true,
        autoSave = true,
    })

    if Window.SetKeybindOverlay then
        Window:SetKeybindOverlay(Config.KeybindHUD ~= false)
    end

    local Main = Window:Tab("Auto Parry", "swords")
    local VisTab = Window:Tab("Visuals & Debug", "eye")

    if Window.AddSettingsTab then
        Window:AddSettingsTab()
    end

    local ParrySection = Main:Section("Parry Core", "Left", "Automatic deflection via direction scanning")
    local ClashSection = Main:Section("Clash Mode", "Right", "High-speed close proximity block spam")

    ParrySection:Toggle("Auto Parry", Config.AutoParry, function(v)
        Config.AutoParry = v
        if v then
            print("[AutoParry] Auto Parry Activated")
        else
            print("[AutoParry] Auto Parry Deactivated")
        end
    end):AddKeybind(Config.AutoParryKey, "Toggle")

    ParrySection:Toggle("Target Verification", Config.TargetCheck, function(v)
        Config.TargetCheck = v
        print("[AutoParry] Target Verification set to: " .. tostring(v))
    end)

    ParrySection:Dropdown("Parry Input Mode", {"F Key", "LMB (Mouse)", "Both (F + LMB)", "All (Key + Mouse)"}, Config.ParryMode, function(v)
        Config.ParryMode = v
    end)

    ParrySection:Slider("Min Aura Radius", 10, 40, Config.MinAuraRadius, function(v)
        Config.MinAuraRadius = v
    end)

    ParrySection:Slider("Parry Lead Time (x100s)", 10, 50, math.floor(Config.ParryLeadTime * 100), function(v)
        Config.ParryLeadTime = v / 100
    end)

    ClashSection:Toggle("Auto Clash Mode", Config.AutoClash, function(v)
        Config.AutoClash = v
        print("[AutoParry] Auto Clash Mode set to: " .. tostring(v))
    end):AddKeybind("C", "Toggle")

    ClashSection:Slider("Clash Distance", 10, 40, Config.ClashDistance, function(v)
        Config.ClashDistance = v
    end)

    ClashSection:Slider("Clash Min Speed", 10, 100, Config.ClashMinSpeed, function(v)
        Config.ClashMinSpeed = v
    end)

    ClashSection:Toggle("Auto Ability", Config.AutoAbility, function(v)
        Config.AutoAbility = v
    end):AddKeybind("V", "Toggle")

    local RenderSection = VisTab:Section("Render Settings", "Left", "3D distance ring & trajectory line")
    local DebugSection = VisTab:Section("Console Logging", "Right", "Developer console logs (F9)")

    RenderSection:Toggle("White Aura Circle (3D Ring)", Config.RangeRing, function(v)
        Config.RangeRing = v
    end)

    RenderSection:Toggle("Ball Flight Trajectory", Config.Trajectory, function(v)
        Config.Trajectory = v
    end)

    RenderSection:Toggle("Keybinds Island (HUD)", Config.KeybindHUD, function(v)
        Config.KeybindHUD = v
        if Window and type(Window.SetKeybindOverlay) == "function" then
            Window:SetKeybindOverlay(v)
        end
    end)

    DebugSection:Toggle("Console Logs (F9 Output)", Config.DebugConsole, function(v)
        Config.DebugConsole = v
    end)

    DebugSection:Button("Reset Ball Resolver", function()
        Resolver:Reset()
        print("[AutoParry] Ball Resolver State Reset")
    end)
else
    warn("[AutoParry] Could not initialize UI Library (Lib is nil). UI Menu skipped.")
end

print("=== Blade Ball Auto Parry (Target Verification + Anti-False Positive Engine) Loaded ===")
