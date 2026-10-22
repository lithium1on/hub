--[[
  Requires a configuration! Example below (everything is optional, defaults shown):

  getgenv().Settings = {
    Enabled = true,
    AutoFarm = {
      Enabled = true,
      ResetOnBagFull = true,
      ReturnToSpawn = true,
      AllowedCoinTypes = { "Coin", "Candy" },
      Method = {
        Type = "Tween",
        TweenSpeed = 25,
        Delay = 0,
        BodyPart = "HipHeight",
        Offset = 0,
        CoinTimeout = 2,
        SkipTime = 5,
        FreezeSettle = 0.1,
      },
      Lobby = {
        Enabled = true,
        Depth = 25
      },
      PreRound = {
        Enabled = true,
        Depth = 25
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

if not game:IsLoaded() then game.Loaded:Wait() end

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

local function ResetSetting(Value)
    if type(Value) == "boolean" or type(Value) == "table" then return Value end
    return true
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
