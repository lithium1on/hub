--[[
  Requires a configuration, example below:

  getgenv().Settings = {
    Enabled = true,
    ResetOnBagFull = true,
    Speed = 25,
    AntiAFK = true,
    AutoRejoin = true
  }
]]

if getgenv().Loaded then return end
if game.PlaceId ~= 142823291 then return end
getgenv().Loaded = true

game:GetService('StarterGui'):SetCore("SendNotification", {
	Title = "[lithium's hub]",
	Text = "thanks for using my script!",
	Duration = 3
})

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
        local NewChar = Self.Player.CharacterAdded:Wait()
        if NewChar then Self.Respawning = false end
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
    local Gameplay = game:GetService("ReplicatedStorage").Remotes.Gameplay
    AutoFarm.AddConnection(Self, Gameplay.CoinCollected.OnClientEvent:Connect(function(CoinType, Current, Capacity)
        if CoinType == "Coin" and type(Capacity) == "number" then
            Self.BagCap = Capacity
            Self.IsElite = Capacity > 40
        end
    end))
end

function AutoFarm.DetectBagFull(Self)
    local Gameplay = game:GetService("ReplicatedStorage").Remotes.Gameplay
    AutoFarm.AddConnection(Self, Gameplay.CoinCollected.OnClientEvent:Connect(function(CoinType, Current, Capacity)
        if not Self.RoundActive or Self.BagFull or Self.Respawning or Self.DiedThisRound then return end
        if CoinType == "Coin" and type(Current) == "number" and type(Capacity) == "number" then
            if Current >= Capacity then
                Self.BagFull = true
                if getgenv().Settings.ResetOnBagFull then
                    AutoFarm.Reset(Self)
                end
            end
        end
    end))
end

function AutoFarm.DetectRounds(Self)
    local Gameplay = game:GetService("ReplicatedStorage").Remotes.Gameplay
    AutoFarm.AddConnection(Self, Gameplay.RoundStart.OnClientEvent:Connect(function()
        Self.RoundActive = true
        Self.BagFull = false
        Self.Respawning = false
        Self.DiedThisRound = false
    end))
    AutoFarm.AddConnection(Self, Gameplay.RoundEndFade.OnClientEvent:Connect(function()
        AutoFarm.CancelTween(Self)
        Self.RoundActive = false
        Self.BagFull = false
    end))
    AutoFarm.AddConnection(Self, Gameplay.CoinsStarted.OnClientEvent:Connect(function()
        Self.RoundActive = true
    end))
end

function AutoFarm.GetNearestCoin(Self)
    local HRP = GetHRP(Self)
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

function AutoFarm.TweenTo(Self, Position, Distance)
    local HRP = GetHRP(Self)
    local Hum = GetHumanoid(Self)
    if not HRP or not Hum then return end
    AutoFarm.CancelTween(Self)
    local TargetCFrame = CFrame.new(Position.Position.X, Position.Position.Y + Hum.HipHeight, Position.Position.Z)
    local Time = Distance / getgenv().Settings.Speed
    local Tween = game:GetService("TweenService"):Create(HRP, TweenInfo.new(Time, Enum.EasingStyle.Linear), {CFrame = TargetCFrame})
    Self.CurrentTween = Tween
    Tween:Play()
    return Tween
end

function AutoFarm.StartFarmingLoop(Self)
    task.spawn(function()
        while true do
            task.wait(0.1)
            if not Self.RoundActive then
                for _, Obj in pairs(workspace:GetChildren()) do
                    if Obj:FindFirstChild("CoinContainer") then
                        Self.RoundActive = true
                        break
                    end
                end
            end
            local S = getgenv().Settings
            if not S.Enabled or not Self.RoundActive or Self.BagFull or Self.Respawning or Self.DiedThisRound then
                continue
            end
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

if getgenv().Settings.AutoRejoin then
    local GuiService = game:GetService("GuiService")
    local Players = game:GetService("Players")
    local TeleportService = game:GetService("TeleportService")
    local LocalPlayer = Players.LocalPlayer
    local function OnErrorMessageChanged(ErrorMessage)
        if ErrorMessage and ErrorMessage ~= "" then
            if LocalPlayer then
                task.wait()
                TeleportService:Teleport(game.PlaceId, LocalPlayer)
            end
        end
    end
    GuiService.ErrorMessageChanged:Connect(OnErrorMessageChanged)
end

if getconnections and getgenv().Settings.AntiAFK then
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

local Farm = AutoFarm.New(Player)
getgenv()._Farm = Farm
Farm:HookDeath()
Farm:DetectElite()
Farm:DetectBagFull()
Farm:DetectRounds()
Farm:StartFarmingLoop()
