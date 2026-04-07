--[[
  Requires a configuration, example below:
  getgenv().Settings = {
    Enabled = true,
    ResetOnBagFull = true,
    Speed = 25,
    AntiAFK = true
  }
]]

if getgenv().Loaded then return end
getgenv().Loaded = true

game:GetService("StarterGui"):SetCore("SendNotification", {
    Title = "[lithium's hub]",
    Text = "thanks for using my script!",
    Duration = 3
})

local AutoFarm = {}
AutoFarm.__index = AutoFarm

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Remotes = ReplicatedStorage.Remotes
local Gameplay = Remotes.Gameplay
local Extras = Remotes.Extras

function AutoFarm.New(Player)
    local Self = setmetatable({}, AutoFarm)
    Self.Player = Player
    Self.BagFull = false
    Self.RoundActive = false
    Self.IsElite = false
    Self.CurrentTween = nil
    Self.Respawning = false
    Self.Connections = {}
    Self.DiedThisRound = false
    Self.LiveCoins = {}
    return Self
end

local function GetCharacter(Self) return Self.Player.Character end
local function GetHRP(Self)
    local C = GetCharacter(Self)
    return C and C:FindFirstChild("HumanoidRootPart")
end
local function GetHumanoid(Self)
    local C = GetCharacter(Self)
    return C and C:FindFirstChildWhichIsA("Humanoid")
end

function AutoFarm.AddConnection(Self, Conn)
    table.insert(Self.Connections, Conn)
end

function AutoFarm.CancelTween(Self)
    if Self.CurrentTween then
        Self.CurrentTween:Cancel()
        Self.CurrentTween = nil
    end
end

function AutoFarm.Reset(Self)
    if Self.Respawning then return end
    Self.Respawning = true
    Self.BagFull = false
    Self.DiedThisRound = true
    AutoFarm.CancelTween(Self)
    local Humanoid = GetHumanoid(Self)
    if Humanoid then
        Humanoid:ChangeState(Enum.HumanoidStateType.Dead)
    else
        local Char = GetCharacter(Self)
        if Char then Char:BreakJoints() end
    end
    task.spawn(function()
        Self.Player.CharacterAdded:Wait()
        Self.Respawning = false
    end)
end

function AutoFarm.HookDeath(Self)
    local function Attach(Char)
        local Hum = Char:FindFirstChildWhichIsA("Humanoid")
        if not Hum then return end
        AutoFarm.AddConnection(Self, Hum.Died:Connect(function()
            Self.DiedThisRound = true
            Self.Respawning = true
            AutoFarm.CancelTween(Self)
        end))
    end
    if Self.Player.Character then Attach(Self.Player.Character) end
    AutoFarm.AddConnection(Self, Self.Player.CharacterAdded:Connect(function(Char)
        Self.Respawning = false
        Attach(Char)
    end))
end

function AutoFarm.DetectElite(Self)
    task.spawn(function()
        local Ok, Result = pcall(function() return Extras.AmElite:InvokeServer() end)
        if Ok then Self.IsElite = Result == true end
    end)
    AutoFarm.AddConnection(Self, Extras.LevelUp.OnClientEvent:Connect(function()
        task.spawn(function()
            local Ok, Result = pcall(function() return Extras.AmElite:InvokeServer() end)
            if Ok then Self.IsElite = Result == true end
        end)
    end))
end

function AutoFarm.DetectBagFull(Self)
    local BagNames = {"Coin", "SnowToken", "BeachBall", "Egg", "Candy"}
    local function GetContainer()
        local GUI = Self.Player.PlayerGui
        local Main = GUI and GUI:FindFirstChild("MainGUI")
        local Game = Main and Main:FindFirstChild("Game")
        local Bags = Game and Game:FindFirstChild("CoinBags")
        return Bags and Bags:FindFirstChild("Container")
    end
    AutoFarm.AddConnection(Self, Gameplay.CoinCollected.OnClientEvent:Connect(function()
        if not Self.RoundActive or Self.BagFull or Self.Respawning or Self.DiedThisRound then return end
        local Container = GetContainer()
        if not Container then return end
        for _, Name in ipairs(BagNames) do
            local Bag = Container:FindFirstChild(Name)
            if Bag then
                local Full = Bag:FindFirstChild("Full")
                if Full and Full.Visible then
                    Self.BagFull = true
                    if getgenv().Settings.ResetOnBagFull then
                        AutoFarm.Reset(Self)
                    end
                    return
                end
            end
        end
    end))
end

function AutoFarm.SeedCoins(Self)
    Self.LiveCoins = {}
    for _, Obj in pairs(workspace:GetChildren()) do
        local Container = Obj:FindFirstChild("CoinContainer")
        if Container then
            for _, Coin in pairs(Container:GetChildren()) do
                if Coin:GetAttribute("CoinID") == "Coin" and Coin:FindFirstChild("TouchInterest") then
                    Self.LiveCoins[Coin] = true
                end
            end
        end
    end
end

function AutoFarm.DetectRounds(Self)
    AutoFarm.AddConnection(Self, Gameplay.RoundStart.OnClientEvent:Connect(function()
        Self.RoundActive = true
        Self.BagFull = false
        Self.Respawning = false
        Self.DiedThisRound = false
        AutoFarm.SeedCoins(Self)
    end))
    AutoFarm.AddConnection(Self, Gameplay.RoundEndFade.OnClientEvent:Connect(function()
        AutoFarm.CancelTween(Self)
        Self.RoundActive = false
        Self.BagFull = false
        Self.LiveCoins = {}
    end))
end

function AutoFarm.TrackCoins(Self)
    AutoFarm.SeedCoins(Self)
    AutoFarm.AddConnection(Self, Gameplay.CoinsStarted.OnClientEvent:Connect(function()
        AutoFarm.SeedCoins(Self)
    end))
    AutoFarm.AddConnection(Self, Gameplay.CoinCollected.OnClientEvent:Connect(function()
        for Coin in pairs(Self.LiveCoins) do
            if not Coin:FindFirstChild("TouchInterest") or not Coin.Parent then
                Self.LiveCoins[Coin] = nil
            end
        end
    end))
end

function AutoFarm.GetNearestCoin(Self)
    local HRP = GetHRP(Self)
    if not HRP then return nil end
    local Closest, Dist = nil, math.huge
    for Coin in pairs(Self.LiveCoins) do
        if Coin:FindFirstChild("TouchInterest") and Coin.Parent then
            local D = (HRP.Position - Coin.Position).Magnitude
            if D < Dist then Closest, Dist = Coin, D end
        else
            Self.LiveCoins[Coin] = nil
        end
    end
    return Closest, Dist
end

function AutoFarm.TweenTo(Self, TargetCFrame, Distance)
    local HRP = GetHRP(Self)
    local Hum = GetHumanoid(Self)
    if not HRP or not Hum then return end
    AutoFarm.CancelTween(Self)
    local Goal = CFrame.new(TargetCFrame.Position.X, TargetCFrame.Position.Y + Hum.HipHeight, TargetCFrame.Position.Z)
    local Tween = TweenService:Create(HRP, TweenInfo.new(Distance / getgenv().Settings.Speed, Enum.EasingStyle.Linear), {CFrame = Goal})
    Self.CurrentTween = Tween
    Tween:Play()
    return Tween
end

function AutoFarm.StartFarmingLoop(Self)
    task.spawn(function()
        while true do
            task.wait(0.1)
            if not getgenv().Settings.Enabled or not Self.RoundActive
            or Self.BagFull or Self.Respawning or Self.DiedThisRound then continue end
            local HRP = GetHRP(Self)
            if not HRP then continue end
            local Coin, Distance = AutoFarm.GetNearestCoin(Self)
            if Coin then
                if Distance > 150 then
                    HRP.CFrame = Coin.CFrame
                else
                    local Tween = AutoFarm.TweenTo(Self, Coin.CFrame, Distance)
                    if Tween then
                        repeat task.wait()
                        until not Coin:FindFirstChild("TouchInterest")
                            or not Self.RoundActive
                            or Self.BagFull
                            or Self.Respawning
                            or Self.DiedThisRound
                        AutoFarm.CancelTween(Self)
                    end
                end
            else
                task.wait(0.3)
            end
        end
    end)
end

local Player = game.Players.LocalPlayer
if getconnections and getgenv().Settings and getgenv().Settings.AntiAFK then
    for _, C in pairs(getconnections(Player.Idled)) do
        if C.Disable then C:Disable() elseif C.Disconnect then C:Disconnect() end
    end
else
    Player.Idled:Connect(function()
        game:GetService("VirtualUser"):CaptureController()
        game:GetService("VirtualUser"):ClickButton2(Vector2.new())
    end)
end

local Farm = AutoFarm.New(Player)
Farm:HookDeath()
Farm:DetectElite()
Farm:DetectBagFull()
Farm:DetectRounds()
Farm:TrackCoins()
Farm:StartFarmingLoop()
