--[[
  Requires a configuration! Example below:

  getgenv().Settings = {
    Enabled = true,
    ResetOnBagFull = true,
    Speed = 25,
    AntiAFK = true,
    AutoRejoin = true,
    Rendering = true,
    MaxFPS = 60
  }
]]

if getgenv().Loaded then return end
if getgenv().Settings == nil then return end
if game.PlaceId ~= 142823291 then return end
getgenv().Loaded = true

local Player = game.Players.LocalPlayer
local Gameplay = game:GetService("ReplicatedStorage").Remotes.Gameplay

if Settings.AntiAFK then
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

if Settings.AutoRejoin then
    local GuiService = game:GetService("GuiService")
    local TeleportService = game:GetService("TeleportService")
    GuiService.ErrorMessageChanged:Connect(function(ErrorMessage)
        if ErrorMessage and ErrorMessage ~= "" then
            task.wait()
            TeleportService:Teleport(game.PlaceId, Player)
        end
    end)
end

local AutoFarm = {}
AutoFarm.__index = AutoFarm

function AutoFarm.New(Player)
    local Self = setmetatable({}, AutoFarm)
    Self.Player = Player
    Self.BagFull = false
    Self.RoundActive = false
    Self.IsElite = false
    Self.BagCap = 40
    Self.CurrentTween = nil
    Self.Respawning = false
    Self.Connections = {}
    Self.DiedThisRound = false
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

function AutoFarm:Reset()
    if self.Respawning then return end
    self.Respawning = true
    self.BagFull = false
    self.DiedThisRound = true
    self:CancelTween()
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
        Attach(Char)
    end))
end

function AutoFarm:DetectCoins()
    self:AddConnection(Gameplay.CoinCollected.OnClientEvent:Connect(function(CoinType, Current, Capacity)
        if CoinType ~= "Coin" or type(Current) ~= "number" or type(Capacity) ~= "number" then return end
        if self.BagCap ~= Capacity then
            self.BagCap = Capacity
            self.IsElite = Capacity > 40
        end
        if not self.RoundActive or self.BagFull or self.Respawning or self.DiedThisRound then return end
        if Current >= Capacity then
            self.BagFull = true
            if Settings.ResetOnBagFull and Settings.Enabled then
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

    self:AddConnection(Gameplay.VictoryScreen.OnClientEvent:Connect(function()
        self:CancelTween()
        self.RoundActive = false
        self.BagFull = false
    end))

    self:AddConnection(CRC.PlayerDataChanged.Event:Connect(function()
        local Data = CRC.GetLatestPlayerData()
        local IsEmpty = true
        for _ in pairs(Data) do IsEmpty = false break end
        if IsEmpty then
            self:CancelTween()
            self.RoundActive = false
            self.BagFull = false
        end
    end))

    self:AddConnection(Gameplay.RoundEndFade.OnClientEvent:Connect(function()
        if self.RoundActive then
            self:CancelTween()
            self.RoundActive = false
            self.BagFull = false
        end
    end))
end

function AutoFarm:GetNearestCoin()
    local HRP = GetHRP(self)
    if not HRP then return nil end
    local Closest, Dist = nil, math.huge
    for _, Obj in pairs(workspace:GetChildren()) do
        local Container = Obj:FindFirstChild("CoinContainer")
        if Container then
            for _, Coin in pairs(Container:GetChildren()) do
                if Coin:GetAttribute("CoinID") == "Coin" and Coin:FindFirstChild("TouchInterest") then
                    local D = (HRP.Position - Coin.Position).Magnitude
                    if D < Dist then
                        Closest = Coin
                        Dist = D
                    end
                end
            end
        end
    end
    return Closest, Dist
end

function AutoFarm:TweenTo(TargetCFrame, Distance)
    local HRP = GetHRP(self)
    local Hum = GetHumanoid(self)
    if not HRP or not Hum then return end
    self:CancelTween()
    local Goal = CFrame.new(TargetCFrame.Position.X, TargetCFrame.Position.Y + Hum.HipHeight, TargetCFrame.Position.Z)
    local Tween = game:GetService("TweenService"):Create(
        HRP,
        TweenInfo.new(Distance / Settings.Speed, Enum.EasingStyle.Linear),
        { CFrame = Goal }
    )
    self.CurrentTween = Tween
    Tween:Play()
    return Tween
end

function AutoFarm:StartFarmingLoop()
    task.spawn(function()
        while true do
            task.wait()

            if Settings.Rendering ~= game:GetService("RunService"):Is3dRenderingEnabled() then
                game:GetService("RunService"):Set3dRenderingEnabled(Settings.Rendering)
            end

            if setfpscap then setfpscap(Settings.MaxFPS) end

            if not Settings.Enabled or not self.RoundActive or self.BagFull or self.Respawning or self.DiedThisRound then
                continue
            end

            local HRP = GetHRP(self)
            if not HRP then continue end

            local Coin, Distance = self:GetNearestCoin()
            if Coin then
                if Distance > 150 then
                    HRP.CFrame = Coin.CFrame
                else
                    local Tween = self:TweenTo(Coin.CFrame, Distance)
                    if Tween then
                        repeat task.wait()
                        until not Coin:FindFirstChild("TouchInterest")
                            or not self.RoundActive
                            or self.BagFull
                            or self.Respawning
                            or self.DiedThisRound
                            or not Settings.Enabled
                        self:CancelTween()
                    end
                end
            else
                task.wait(0.3)
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
