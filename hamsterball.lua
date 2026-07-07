--[[
  example config to use below
  
  getgenv().BallConfig = {
  	MaxSpeed = 30,
  	Acceleration = 10,
  	BrakeDeceleration = 120,
  	Friction = 20,
  	JumpPower = 75,
  	BallSize = 7.5,
    Transparency = 0.85,
  	EnvironmentGravity = 196.2,
  	BrakeKey = Enum.KeyCode.R,
  	FreezeKey = Enum.KeyCode.F,
  	JumpEnabled = true,
  }
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer

local Active = false
local Frozen = false
local RootPart, Humanoid
local OriginalShape, OriginalSize, OriginalCanCollide, OriginalPlatformStand
local RaycastParams_
local LastSpeed = 0

local function SetupRaycastParams(Character)
	RaycastParams_ = RaycastParams.new()
	RaycastParams_.FilterType = Enum.RaycastFilterType.Exclude
	RaycastParams_.FilterDescendantsInstances = { Character }
end

local function IsGrounded()
	if not RootPart then return false end
	local Origin = RootPart.Position
	local Result = Workspace:Raycast(Origin, Vector3.new(0, -(getgenv().BallConfig.BallSize / 2 + 0.5), 0), RaycastParams_)
	return Result ~= nil
end

local function EnableBallMode()
	local Character = Player.Character
	if not Character then return end

	RootPart = Character:FindFirstChild("HumanoidRootPart")
	Humanoid = Character:FindFirstChild("Humanoid")
	if not RootPart or not Humanoid then return end

	if Active then return end

	OriginalShape = RootPart.Shape
	OriginalSize = RootPart.Size
	OriginalCanCollide = RootPart.CanCollide
	OriginalPlatformStand = Humanoid.PlatformStand

	RootPart.Shape = Enum.PartType.Ball
	RootPart.Size = Vector3.new(getgenv().BallConfig.BallSize, getgenv().BallConfig.BallSize, getgenv().BallConfig.BallSize)
	RootPart.Transparency = getgenv().BallConfig.Transparency
	RootPart.CanCollide = true

	Humanoid.PlatformStand = true
	Workspace.CurrentCamera.CameraSubject = RootPart

	Workspace.Gravity = getgenv().BallConfig.EnvironmentGravity

	SetupRaycastParams(Character)

	LastSpeed = 0
	Active = true
end

local function DisableBallMode()
	if not Active or not RootPart or not Humanoid then return end

	RootPart.Shape = OriginalShape or Enum.PartType.Block
	RootPart.Size = OriginalSize or Vector3.new(2, 2, 1)
	RootPart.CanCollide = OriginalCanCollide
	RootPart.RotVelocity = Vector3.new()
	RootPart.Velocity = Vector3.new()
	RootPart.Anchored = false

	Humanoid.PlatformStand = OriginalPlatformStand or false
	Workspace.CurrentCamera.CameraSubject = Humanoid

	Active = false
	Frozen = false
	LastSpeed = 0
end

local function ToggleFreeze()
	if not Active or not RootPart then return end
	Frozen = not Frozen
	RootPart.Anchored = Frozen
	if not Frozen then
		RootPart.RotVelocity = Vector3.new()
		LastSpeed = 0
	end
end

RunService.RenderStepped:Connect(function(DeltaTime)
	if not Active or not RootPart or not Humanoid or Frozen then return end

	local MoveDirection = Humanoid.MoveDirection
	local Braking = UserInputService:IsKeyDown(getgenv().BallConfig.BrakeKey)

	if Braking then
		LastSpeed = math.max(LastSpeed - getgenv().BallConfig.BrakeDeceleration * DeltaTime, 0)
	elseif MoveDirection.Magnitude > 0 then
		LastSpeed = math.min(LastSpeed + getgenv().BallConfig.Acceleration * DeltaTime, getgenv().BallConfig.MaxSpeed)
	else
		LastSpeed = math.max(LastSpeed - getgenv().BallConfig.Friction * DeltaTime, 0)
	end

	if LastSpeed > 0 and MoveDirection.Magnitude > 0 then
		local Axis = Vector3.new(MoveDirection.Z, 0, -MoveDirection.X)
		RootPart.RotVelocity = Axis.Unit * LastSpeed
	elseif LastSpeed > 0 then
		local CurrentAxis = RootPart.RotVelocity
		if CurrentAxis.Magnitude > 0 then
			RootPart.RotVelocity = CurrentAxis.Unit * LastSpeed
		end
	else
		RootPart.RotVelocity = Vector3.new()
	end
end)

UserInputService.JumpRequest:Connect(function()
	if not Active or not RootPart or not getgenv().BallConfig.JumpEnabled or Frozen then return end
	if IsGrounded() then
		RootPart.Velocity = Vector3.new(RootPart.Velocity.X, getgenv().BallConfig.JumpPower, RootPart.Velocity.Z)
	end
end)

UserInputService.InputBegan:Connect(function(Input, GameProcessed)
	if GameProcessed or not Active then return end
	if Input.KeyCode == getgenv().BallConfig.FreezeKey then
		ToggleFreeze()
	end
end)

if Player.Character then
	EnableBallMode()
end
