--[[
  Requires a configuration! Example below (everything is optional, defaults shown):

  getgenv().Settings = {
    Enabled = true,
    AutoFarm = {
      Enabled = true,
      ResetOnBagFull = true,
      AllowedCoinTypes = { "Coin", "Candy" },
      Method = {
        Type = "Tween",
        TweenSpeed = 25,
        Delay = 0,
        BodyPart = "HipHeight",
        Offset = 0,
        SilentHeight = 100,
        CoinTimeout = 2,
        SkipTime = 5,
        FreezeSettle = 0.1
      },
      Lobby = {
        Enabled = true,
        Depth = 25
      },
      PreRound = {
        Enabled = true,
        Height = 100,
        MaxWait = 20
      }
    },
    Miscellaneous = {
      AntiAFK = true,
      AutoRejoin = true,
      Rendering = true,
      MaxFPS = 60
    }
  }
]]

if getgenv().Loaded then return end
if getgenv().Settings == nil then return end
if game.PlaceId ~= 142823291 then return end
getgenv().Loaded = true

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local TeleportService = game:GetService("TeleportService")

local Player = game.Players.LocalPlayer
local Gameplay = game:GetService("ReplicatedStorage").Remotes.Gameplay

local function Bool(Value, Default)
    if type(Value) == "boolean" then return Value end
    return Default
end

local function Num(Value, Default, Min)
    if type(Value) == "number" and Value >= Min then return Value end
    return Default
end

local function Pick(Value, Options, Default)
    if type(Value) == "string" then
        local Lower = string.lower(Value)
        for _, Option in ipairs(Options) do
            if string.lower(Option) == Lower then return Option end
        end
    end
    return Default
end

local function Table(Value)
    if type(Value) == "table" then return Value end
    return {}
end

local function Resolve()
    local S = getgenv().Settings
    local Root = Bool(S.Enabled, true)
    local AF = Table(S.AutoFarm)
    local M = Table(AF.Method)
    local L = Table(AF.Lobby)
    local P = Table(AF.PreRound)
    local Misc = Table(S.Miscellaneous)

    local Cfg = {
        Enabled = Root,
        AutoFarm = {
            Enabled = Root and Bool(AF.Enabled, true),
            ResetOnBagFull = Bool(AF.ResetOnBagFull, true),
            AllowedCoinTypes = AF.AllowedCoinTypes,
            Method = {
                Type = Pick(M.Type, { "Tween", "Teleportation", "Silent" }, "Tween"),
                TweenSpeed = Num(M.TweenSpeed, 25, 0.01),
                Delay = Num(M.Delay, 0, 0),
                BodyPart = Pick(M.BodyPart, { "HipHeight", "Torso", "Head" }, "HipHeight"),
                Offset = type(M.Offset) == "number" and M.Offset or 0,
                SilentHeight = Num(M.SilentHeight, 100, 0),
                CoinTimeout = Num(M.CoinTimeout, 2, 0.1),
                SkipTime = Num(M.SkipTime, 5, 0),
                FreezeSettle = Num(M.FreezeSettle, 0.1, 0)
            },
            Lobby = {
                Enabled = Bool(L.Enabled, true),
                Depth = Num(L.Depth, 25, 0)
            },
            PreRound = {
                Enabled = Bool(P.Enabled, true),
                Height = Num(P.Height, 100, 0),
                MaxWait = Num(P.MaxWait, 20, 1)
            }
        }
    }

    if Root then
        Cfg.Misc = {
            AntiAFK = Bool(Misc.AntiAFK, true),
            AutoRejoin = Bool(Misc.AutoRejoin, true),
            Rendering = Bool(Misc.Rendering, true),
            MaxFPS = Num(Misc.MaxFPS, 60, 1)
        }
    else
        Cfg.Misc = { AntiAFK = true, AutoRejoin = true, Rendering = true, MaxFPS = 60 }
    end

    return Cfg
end

local function IsCoinTypeAllowed(Allowed, CoinType)
    if type(CoinType) ~= "string" then return false end
    if type(Allowed) ~= "table" or next(Allowed) == nil then return true end
    if Allowed[CoinType] == true then return true end
    for _, Value in ipairs(Allowed) do
        if Value == CoinType then return true end
    end
    return false
end

if Resolve().Misc.AntiAFK then
    if getconnections then
        for _, Connection in pairs(getconnections(Player.Idled)) do
            if Connection["Disable"] then Connection["Disable"](Connection)
            elseif Connection["Disconnect"] then Connection["Disconnect"](Connection) end
        end
    else
        Player.Idled:Connect(function()
            game:GetService("VirtualUser"):CaptureController()
            game:GetService("VirtualUser"):ClickButton2(Vector2.new())
        end)
    end
end

GuiService.ErrorMessageChanged:Connect(function(ErrorMessage)
    if Resolve().Misc.AutoRejoin and ErrorMessage and ErrorMessage ~= "" then
        task.wait()
        TeleportService:Teleport(game.PlaceId, Player)
    end
end)

local AutoFarm = {}
AutoFarm.__index = AutoFarm

function AutoFarm.New(Player)
    local Self = setmetatable({}, AutoFarm)
    Self.Player = Player
    Self.BagFull = false
    Self.RoundActive = false
    Self.CurrentTween = nil
    Self.Respawning = false
    Self.Connections = {}
    Self.DiedThisRound = false
    Self.Anchored = false
    Self.Frozen = false
    Self.Parked = false
    Self.ParkedChar = nil
    Self.PreRoundMap = nil
    Self.PreRoundSince = 0
    Self.CoinChange = 0
    Self.Watched = setmetatable({}, { __mode = "k" })
    Self.Skip = setmetatable({}, { __mode = "k" })
    Self.TopCache = setmetatable({}, { __mode = "k" })
    return Self
end

local function GetCharacter(Self) return Self.Player.Character end
local function GetHRP(Self)
    local Char = GetCharacter(Self)
    return Char and Char:FindFirstChild("HumanoidRootPart")
end
local function GetHumanoid(Self)
    local Char = GetCharacter(Self)
    return Char and Char:FindFirstChildWhichIsA("Humanoid")
end

function AutoFarm:AddConnection(Conn)
    table.insert(self.Connections, Conn)
end

function AutoFarm:CancelTween()
    if self.CurrentTween then
        self.CurrentTween:Cancel()
        self.CurrentTween = nil
    end
end

function AutoFarm:CanFarm(Cfg)
    return Cfg.AutoFarm.Enabled
        and self.RoundActive
        and not self.BagFull
        and not self.Respawning
        and not self.DiedThisRound
end

function AutoFarm:WaitingForRound(Cfg)
    return Cfg.AutoFarm.Enabled
        and not self.Respawning
        and (not self.RoundActive or self.DiedThisRound)
end

local function UprightRotation(HRP)
    local Look = HRP.CFrame.LookVector
    local Flat = Vector3.new(Look.X, 0, Look.Z)
    if Flat.Magnitude < 0.01 then Flat = Vector3.new(0, 0, -1) end
    return CFrame.lookAt(Vector3.zero, Flat.Unit)
end

local function FindMap(Part)
    local Cur = Part
    while Cur and Cur.Parent ~= workspace do Cur = Cur.Parent end
    if Cur and Cur.Name ~= "Lobby" and (Cur:FindFirstChild("CoinContainer") or Cur:FindFirstChild("Spawns")) then
        return Cur
    end
    return nil
end

function AutoFarm:Anchor()
    local HRP = GetHRP(self)
    if HRP then
        HRP.AssemblyLinearVelocity = Vector3.zero
        HRP.AssemblyAngularVelocity = Vector3.zero
        HRP.Anchored = true
        self.Anchored = true
    end
end

function AutoFarm:Unanchor()
    local HRP = GetHRP(self)
    if HRP then HRP.Anchored = false end
    self.Anchored = false
end

function AutoFarm:Freeze(Hum)
    Hum.AutoRotate = false
    local Char = GetCharacter(self)
    local Animate = Char and Char:FindFirstChild("Animate")
    if Animate and Animate:IsA("LocalScript") then Animate.Disabled = true end
    local Animator = Hum:FindFirstChildOfClass("Animator")
    if Animator then
        for _, Track in ipairs(Animator:GetPlayingAnimationTracks()) do
            Track:Stop(0)
        end
    end
    self.Frozen = true
end

function AutoFarm:Unfreeze()
    self.Frozen = false
    local Hum = GetHumanoid(self)
    if Hum then Hum.AutoRotate = true end
    local Char = GetCharacter(self)
    local Animate = Char and Char:FindFirstChild("Animate")
    if Animate and Animate:IsA("LocalScript") then Animate.Disabled = false end
end

function AutoFarm:Release()
    self:CancelTween()
    self.Parked = false
    self.ParkedChar = nil
    if self.Anchored then self:Unanchor() end
    if self.Frozen then self:Unfreeze() end
end

function AutoFarm:Reset()
    if self.Respawning then return end
    self.Respawning = true
    self.BagFull = false
    self.DiedThisRound = true
    self:CancelTween()
    if self.Anchored then self:Unanchor() end
    local Hum = GetHumanoid(self)
    if Hum then
        Hum:ChangeState(Enum.HumanoidStateType.Dead)
    else
        local Char = GetCharacter(self)
        if Char then Char:BreakJoints() end
    end
    task.spawn(function()
        local NewChar = self.Player.CharacterAdded:Wait()
        if NewChar then self.Respawning = false end
    end)
end

function AutoFarm:HookDeath()
    local CRC = require(game:GetService("ReplicatedStorage").Modules.CurrentRoundClient)

    self:AddConnection(CRC.PlayerDataChanged.Event:Connect(function()
        local Data = CRC.GetLatestPlayerData()
        local MyData = Data and Data[self.Player.Name]
        if MyData and MyData.Dead == true and self.RoundActive then
            self.DiedThisRound = true
            self.Respawning = true
            self:CancelTween()
        end
    end))

    local function Attach(Char)
        local Hum = Char:FindFirstChildWhichIsA("Humanoid")
        if not Hum then return end
        self:AddConnection(Hum.Died:Connect(function()
            if self.RoundActive then
                self.DiedThisRound = true
                self.Respawning = true
                self:CancelTween()
            end
        end))
    end

    if self.Player.Character then Attach(self.Player.Character) end
    self:AddConnection(self.Player.CharacterAdded:Connect(function(Char)
        task.wait()
        self.Respawning = false
        self.PreRoundMap = nil
        Attach(Char)
    end))
end

function AutoFarm:DetectCoins()
    self:AddConnection(Gameplay.CoinCollected.OnClientEvent:Connect(function(CoinType, Current, Capacity)
        if type(CoinType) ~= "string" or type(Current) ~= "number" or type(Capacity) ~= "number" then return end
        local Cfg = Resolve()
        if not IsCoinTypeAllowed(Cfg.AutoFarm.AllowedCoinTypes, CoinType) then return end
        if not self.RoundActive or self.BagFull or self.Respawning or self.DiedThisRound then return end
        if Current >= Capacity then
            self.BagFull = true
            if Cfg.AutoFarm.ResetOnBagFull and Cfg.AutoFarm.Enabled then
                self:Reset()
            end
        end
    end))
end

function AutoFarm:DetectRounds()
    local CRC = require(game:GetService("ReplicatedStorage").Modules.CurrentRoundClient)

    local MyData = CRC.PlayerData and CRC.PlayerData[self.Player.Name]
    if MyData then
        self.RoundActive = true
        self.DiedThisRound = MyData.Dead == true
    end

    self:AddConnection(Gameplay.RoundStart.OnClientEvent:Connect(function()
        self.RoundActive = true
        self.BagFull = false
        self.Respawning = false
        self.DiedThisRound = false
    end))

    self:AddConnection(Gameplay.TeleportToPart.OnClientEvent:Connect(function(Part)
        self.Parked = false
        self.ParkedChar = nil
        if self.Anchored then self:Unanchor() end
        local Map = typeof(Part) == "Instance" and FindMap(Part) or nil
        self.PreRoundMap = Map
        self.PreRoundSince = os.clock()
    end))

    self:AddConnection(Gameplay.VictoryScreen.OnClientEvent:Connect(function()
        self:CancelTween()
        self.RoundActive = false
        self.BagFull = false
        self.PreRoundMap = nil
    end))

    self:AddConnection(CRC.PlayerDataChanged.Event:Connect(function()
        local Data = CRC.GetLatestPlayerData()
        local IsEmpty = true
        for _ in pairs(Data) do IsEmpty = false break end
        if IsEmpty then
            self:CancelTween()
            self.RoundActive = false
            self.BagFull = false
            self.PreRoundMap = nil
        end
    end))

    self:AddConnection(Gameplay.RoundEndFade.OnClientEvent:Connect(function()
        if self.RoundActive then
            self:CancelTween()
            self.RoundActive = false
            self.BagFull = false
            self.PreRoundMap = nil
        end
    end))
end

function AutoFarm:GetNearestCoin(Cfg)
    local HRP = GetHRP(self)
    if not HRP then return nil end
    local Allowed = Cfg.AutoFarm.AllowedCoinTypes
    local Now = os.clock()
    local Closest, ClosestMap, Dist = nil, nil, math.huge
    for _, Obj in pairs(workspace:GetChildren()) do
        local Container = Obj:FindFirstChild("CoinContainer")
        if Container then
            self:WatchContainer(Container)
            for _, Coin in pairs(Container:GetChildren()) do
                local SkipUntil = self.Skip[Coin]
                if (not SkipUntil or Now >= SkipUntil)
                    and IsCoinTypeAllowed(Allowed, Coin:GetAttribute("CoinID"))
                    and Coin:FindFirstChild("TouchInterest") then
                    local D = (HRP.Position - Coin.Position).Magnitude
                    if D < Dist then
                        Closest = Coin
                        ClosestMap = Obj
                        Dist = D
                    end
                end
            end
        end
    end
    return Closest, ClosestMap
end

function AutoFarm:GetBodyPart(Name)
    local Char = GetCharacter(self)
    if not Char then return nil end
    if Name == "Head" then
        return Char:FindFirstChild("Head")
    elseif Name == "Torso" then
        return Char:FindFirstChild("UpperTorso") or Char:FindFirstChild("Torso")
    end
    return nil
end

function AutoFarm:GetGoal(Coin, HRP, Hum, BodyPart, Offset)
    local Target = Coin.Position + Vector3.new(0, Offset, 0)
    local Rot = UprightRotation(HRP)
    local Part = self:GetBodyPart(BodyPart)
    if not Part then
        return CFrame.new(Target.X, Target.Y + Hum.HipHeight, Target.Z) * Rot
    end

    local PartOffset = HRP.CFrame:ToObjectSpace(Part.CFrame).Position
    return CFrame.new(Target - Rot:VectorToWorldSpace(PartOffset)) * Rot
end

function AutoFarm:TweenTo(Goal, Distance, Speed)
    local HRP = GetHRP(self)
    if not HRP then return end
    self:CancelTween()
    local Tween = TweenService:Create(
        HRP,
        TweenInfo.new(Distance / Speed, Enum.EasingStyle.Linear),
        { CFrame = Goal }
    )
    self.CurrentTween = Tween
    Tween:Play()
    return Tween
end

function AutoFarm:WatchContainer(Container)
    if self.Watched[Container] then return end
    self.Watched[Container] = true
    self:AddConnection(Container.DescendantAdded:Connect(function() self.CoinChange += 1 end))
    self:AddConnection(Container.DescendantRemoving:Connect(function() self.CoinChange += 1 end))
end

function AutoFarm:WaitForCoinChange(Seconds)
    local Seen = self.CoinChange
    local End = os.clock() + Seconds
    repeat task.wait() until self.CoinChange ~= Seen or os.clock() >= End
end

function AutoFarm:WaitForCoin(Coin, Timeout, SkipTime, Retarget)
    local End = os.clock() + Timeout
    local Seen = self.CoinChange
    repeat
        task.wait()
        if not Coin.Parent or not Coin:FindFirstChild("TouchInterest") then return true end
        local Cfg = Resolve()
        if not self:CanFarm(Cfg) then return false end
        if Retarget and self.CoinChange ~= Seen then
            Seen = self.CoinChange
            local HRP = GetHRP(self)
            local Best = HRP and self:GetNearestCoin(Cfg)
            if Best and Best ~= Coin
                and (HRP.Position - Best.Position).Magnitude + 1 < (HRP.Position - Coin.Position).Magnitude then
                return "retarget"
            end
        end
    until os.clock() >= End
    self.Skip[Coin] = os.clock() + SkipTime
    return false
end

function AutoFarm:Pause(Seconds, Settle)
    task.wait(Settle)
    if not self:CanFarm(Resolve()) then return end
    self:Anchor()
    local End = os.clock() + Seconds
    while os.clock() < End do
        task.wait()
        if not self:CanFarm(Resolve()) then return end
    end
end

function AutoFarm:GetTopY(Map)
    if not Map then return nil end
    local Cached = self.TopCache[Map]
    if Cached then return Cached end
    local Ok, CF, Size = pcall(function() return Map:GetBoundingBox() end)
    if Ok then
        local Y = CF.Position.Y + Size.Y / 2
        self.TopCache[Map] = Y
        return Y
    end
    return nil
end

function AutoFarm:Hide(Map, Height)
    local HRP = GetHRP(self)
    if not HRP then return end
    local Y = (self:GetTopY(Map) or (HRP.Position.Y + 50)) + Height
    HRP.CFrame = CFrame.new(HRP.Position.X, Y, HRP.Position.Z) * HRP.CFrame.Rotation
end

function AutoFarm:GetLobbySpot(Depth)
    local Lobby = workspace:FindFirstChild("Lobby")
    if not Lobby then return nil end
    local Ok, CF, Size = pcall(function() return Lobby:GetBoundingBox() end)
    if not Ok then return nil end
    local Y = math.max(CF.Position.Y - Size.Y / 2 - Depth, workspace.FallenPartsDestroyHeight + 20)
    return Vector3.new(CF.Position.X, Y, CF.Position.Z)
end

function AutoFarm:ParkUnderLobby(Cfg)
    local Char = GetCharacter(self)
    local HRP = GetHRP(self)
    local Hum = GetHumanoid(self)
    if not Char or not HRP or not Hum then return end
    if self.Parked and self.ParkedChar == Char and HRP.Anchored then return end

    local Spot = self:GetLobbySpot(Cfg.AutoFarm.Lobby.Depth)
    if not Spot then return end

    self:CancelTween()
    if HRP.Anchored then
        self:Unanchor()
        task.wait()
    end
    self:Freeze(Hum)
    HRP.CFrame = CFrame.new(Spot) * UprightRotation(HRP)
    task.wait(Cfg.AutoFarm.Method.FreezeSettle)

    if self:WaitingForRound(Resolve()) and GetHRP(self) == HRP then
        self:Anchor()
        self.Parked = true
        self.ParkedChar = Char
    end
end

function AutoFarm:PreRoundActive(Cfg)
    if not self.PreRoundMap or not Cfg.AutoFarm.PreRound.Enabled then return false end
    if not self.PreRoundMap.Parent or os.clock() - self.PreRoundSince > Cfg.AutoFarm.PreRound.MaxWait then
        self.PreRoundMap = nil
        return false
    end
    return true
end

function AutoFarm:ParkOnMap(Cfg)
    local Map = self.PreRoundMap
    if not Map or not Map.Parent then
        self.PreRoundMap = nil
        return
    end
    local Char = GetCharacter(self)
    local HRP = GetHRP(self)
    local Hum = GetHumanoid(self)
    if not Char or not HRP or not Hum then return end
    if self.Parked and self.ParkedChar == Char and HRP.Anchored then return end

    self:CancelTween()
    if HRP.Anchored then
        self:Unanchor()
        task.wait()
    end
    self:Freeze(Hum)

    local Settle = Cfg.AutoFarm.Method.FreezeSettle
    task.wait(Settle)
    if self.PreRoundMap ~= Map or GetHRP(self) ~= HRP then return end
    self:Hide(Map, Cfg.AutoFarm.PreRound.Height)
    task.wait(Settle)

    local Now = Resolve()
    if self.PreRoundMap == Map and GetHRP(self) == HRP
        and (self:WaitingForRound(Now) or not self:GetNearestCoin(Now)) then
        self:Anchor()
        self.Parked = true
        self.ParkedChar = Char
    end
end

function AutoFarm:StartFarmingLoop()
    task.spawn(function()
        while true do
            task.wait()

            local Cfg = Resolve()
            RunService:Set3dRenderingEnabled(Cfg.Misc.Rendering)
            if setfpscap then setfpscap(Cfg.Misc.MaxFPS) end

            if not self:CanFarm(Cfg) then
                if self:WaitingForRound(Cfg) then
                    if self:PreRoundActive(Cfg) then
                        self:ParkOnMap(Cfg)
                    elseif Cfg.AutoFarm.Lobby.Enabled then
                        self:ParkUnderLobby(Cfg)
                    else
                        self:Release()
                    end
                elseif Cfg.AutoFarm.Enabled and self.RoundActive and self.BagFull
                    and not self.Respawning and not self.DiedThisRound then
                    if not self.Anchored then self:Anchor() end
                else
                    self:Release()
                end
                continue
            end

            local HRP = GetHRP(self)
            local Hum = GetHumanoid(self)
            if not HRP or not Hum then continue end

            local Method = Cfg.AutoFarm.Method
            self:Freeze(Hum)

            local Coin, Map = self:GetNearestCoin(Cfg)
            if not Coin then
                if self:PreRoundActive(Cfg) then
                    self:ParkOnMap(Cfg)
                end
                self:WaitForCoinChange(0.3)
                continue
            end

            self.PreRoundMap = nil
            if self.Parked then
                self.Parked = false
                self.ParkedChar = nil
            end

            if self.Anchored then
                self:Unanchor()
                task.wait()
                HRP = GetHRP(self)
                Hum = GetHumanoid(self)
                if not HRP or not Hum then continue end
            end

            local Goal = self:GetGoal(Coin, HRP, Hum, Method.BodyPart, Method.Offset)
            local Result = false

            if Method.Type == "Tween" then
                HRP.CFrame = CFrame.new(HRP.Position) * Goal.Rotation
                local Distance = (Goal.Position - HRP.Position).Magnitude
                local Tween = self:TweenTo(Goal, Distance, Method.TweenSpeed)
                if Tween then
                    Result = self:WaitForCoin(Coin, Distance / Method.TweenSpeed + Method.CoinTimeout, Method.SkipTime, true)
                    self:CancelTween()
                end
            else
                HRP.CFrame = Goal
                Result = self:WaitForCoin(Coin, Method.CoinTimeout, Method.SkipTime, false)
                if Method.Type == "Silent" and Result ~= "retarget" then
                    self:Hide(Map, Method.SilentHeight)
                end
            end

            if Result == true and Method.Delay > 0 then
                self:Pause(Method.Delay, Method.FreezeSettle)
            end
        end
    end)
end

function AutoFarm:Load()
    local Farm = AutoFarm.New(Player)
    getgenv()._Farm = Farm
    Farm:HookDeath()
    Farm:DetectCoins()
    Farm:DetectRounds()
    Farm:StartFarmingLoop()
end

AutoFarm:Load()
