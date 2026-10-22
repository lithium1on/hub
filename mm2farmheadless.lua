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
local HttpService = game:GetService("HttpService")

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
            ResetOnBagFull = ResetSetting(AF.ResetOnBagFull),
            ReturnToSpawn = Bool(AF.ReturnToSpawn, true),
            AllowedCoinTypes = AF.AllowedCoinTypes,
            Method = {
                Type = Pick(M.Type, { "Tween", "Teleportation" }, "Tween"),
                TweenSpeed = Num(M.TweenSpeed, 25, 0.01),
                Delay = Num(M.Delay, 0, 0),
                BodyPart = Pick(M.BodyPart, { "HipHeight", "Torso", "Head" }, "HipHeight"),
                Offset = type(M.Offset) == "number" and M.Offset or 0,
                CoinTimeout = Num(M.CoinTimeout, 2, 0.1),
                SkipTime = Num(M.SkipTime, 5, 0),
                FreezeSettle = Num(M.FreezeSettle, 0.1, 0),
            },
            Lobby = {
                Enabled = Bool(L.Enabled, true),
                Depth = Num(L.Depth, 25, 0)
            },
            PreRound = {
                Enabled = Bool(P.Enabled, true),
                Depth = Num(P.Depth, 25, 0)
            }
        }
    }

    Cfg.Misc = {
        AntiAFK = Bool(Misc.AntiAFK, true),
        AutoRejoin = Bool(Misc.AutoRejoin, true),
        Rendering = Bool(Misc.Rendering, true),
        MaxFPS = Num(Misc.MaxFPS, 60, 1)
    }

    return Cfg
end

local WebhookState = {
    LastEvent = {},
    RecentSends = {},
    Queue = {},
    WorkerActive = false,
    PlayerAvatarBustUrl = nil,
    PlayerAvatarBustRetryAt = 0
}

local WebhookColors = {
    Loaded = 0x43B581,
    BagFull = 0xE5A447,
    RoundStarted = 0x5865F2,
    RoundSummary = 0x5865F2,
    Died = 0xE05252,
    Rejoin = 0x5865F2,
    Stuck = 0xE05252,
    LowEfficiency = 0xE5A447,
    SessionSummary = 0x43B581
}

local function GetWebhookConfig()
    local Settings = getgenv().Settings
    local Config = type(Settings) == "table" and Settings.Webhooks or nil
    if type(Config) ~= "table" or Config.Enabled ~= true then return nil end
    if type(Config.Url) ~= "string" or Config.Url == "" then return nil end
    if not string.match(Config.Url, "^https://discord%.com/api/webhooks/")
        and not string.match(Config.Url, "^https://discordapp%.com/api/webhooks/") then
        return nil
    end
    return Config
end

local function GetWebhookEventOptions(Config, EventName)
    local Events = Table(Config and Config.Events)
    local Value = Events[EventName]
    if type(Value) == "table" then return Value end
    return {}
end

local function IsWebhookEventEnabled(Config, EventName)
    if not Config then return false end
    local Events = Table(Config.Events)
    local Value = Events[EventName]
    if type(Value) == "boolean" then return Value end
    if type(Value) == "table" then return Value.Enabled == true end
    return false
end

local function AddField(Fields, Name, Value, Inline)
    if #Fields >= 25 or Name == nil or Value == nil then return end
    local FieldName = tostring(Name)
    local FieldValue = tostring(Value)
    if FieldName == "" or FieldValue == "" then return end
    if #FieldName > 256 then FieldName = string.sub(FieldName, 1, 253) .. "..." end
    if #FieldValue > 1024 then FieldValue = string.sub(FieldValue, 1, 1021) .. "..." end
    table.insert(Fields, {
        name = FieldName,
        value = FieldValue,
        inline = Inline == true
    })
end

local function GetIsoTimestamp()
    local Ok, Value = pcall(function()
        return DateTime.now():ToIsoDate()
    end)
    if Ok and type(Value) == "string" then return Value end
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function GetRequestStatus(Response)
    if type(Response) ~= "table" then return nil end
    return tonumber(Response.StatusCode or Response.Status or Response.status_code)
end

local function NormalizeEmbedText(Value)
    local Text = string.lower(tostring(Value or ""))
    Text = string.gsub(Text, "[%s%p]+", "")
    return Text
end

local function GetPlayerAvatarBustUrl(Config)
    local Appearance = Table(Config and Config.Appearance)
    local ConfiguredUrl = Appearance.AvatarBustUrl
    if type(ConfiguredUrl) == "string" and string.match(ConfiguredUrl, "^https://") then
        return ConfiguredUrl
    end

    if WebhookState.PlayerAvatarBustUrl then
        return WebhookState.PlayerAvatarBustUrl
    end
    if os.clock() < WebhookState.PlayerAvatarBustRetryAt then return nil end
    WebhookState.PlayerAvatarBustRetryAt = os.clock() + 60

    local ThumbnailUrl = "https://thumbnails.roblox.com/v1/users/avatar-bust?userIds="
        .. tostring(Player.UserId)
        .. "&size=150x150&format=Png&isCircular=false"
    local Ok, Response = pcall(function()
        return request({ Url = ThumbnailUrl, Method = "GET" })
    end)
    if not Ok or type(Response) ~= "table" or Response.Success == false then return nil end

    local Status = GetRequestStatus(Response)
    if Status and (Status < 200 or Status >= 300) then return nil end

    local DecodedOk, Body = pcall(function()
        return HttpService:JSONDecode(Response.Body)
    end)
    if not DecodedOk or type(Body) ~= "table" or type(Body.data) ~= "table" then return nil end

    local Entry = Body.data[1]
    local ImageUrl = type(Entry) == "table" and Entry.imageUrl or nil
    if type(ImageUrl) == "string" and string.match(ImageUrl, "^https://") then
        WebhookState.PlayerAvatarBustUrl = ImageUrl
    end
    return WebhookState.PlayerAvatarBustUrl
end

local function QueueWebhookRequest(RequestData)
    table.insert(WebhookState.Queue, RequestData)
    if WebhookState.WorkerActive then return end
    WebhookState.WorkerActive = true
    task.spawn(function()
        while true do
            if #WebhookState.Queue == 0 then
                WebhookState.WorkerActive = false
                if #WebhookState.Queue == 0 then break end
                WebhookState.WorkerActive = true
            end
            local Item = table.remove(WebhookState.Queue, 1)
            if not Item then continue end
            local MaxPerMinute = Item.MaxMessagesPerMinute
            if MaxPerMinute > 0 then
                while true do
                    local Now = os.clock()
                    local Kept = {}
                    for _, SentAt in ipairs(WebhookState.RecentSends) do
                        if Now - SentAt < 60 then table.insert(Kept, SentAt) end
                    end
                    WebhookState.RecentSends = Kept
                    if #WebhookState.RecentSends < MaxPerMinute then break end
                    local WaitFor = math.max(0.1, 60 - (Now - WebhookState.RecentSends[1]))
                    task.wait(WaitFor)
                end
            end

            local Attempts = 0
            local MaxRetries = Item.RetryCount
            local Delivered = false
            repeat
                Attempts += 1
                table.insert(WebhookState.RecentSends, os.clock())
                local Ok, Response = pcall(function()
                    return request({
                        Url = Item.Url,
                        Method = "POST",
                        Headers = { ["Content-Type"] = "application/json" },
                        Body = HttpService:JSONEncode(Item.Payload)
                    })
                end)
                local Status = Ok and GetRequestStatus(Response) or nil
                Delivered = Ok
                    and type(Response) == "table"
                    and Response.Success ~= false
                    and Status ~= nil
                    and Status >= 200
                    and Status < 300
                if not Delivered and Attempts <= MaxRetries then
                    task.wait(Item.RetryDelay)
                end
            until Delivered or Attempts > MaxRetries
        end
    end)
end

local function SendWebhook(EventName, Title, Description, Fields, OverrideColor, BypassCooldown)
    local Config = GetWebhookConfig()
    if not Config or not IsWebhookEventEnabled(Config, EventName) then return false end

    local Delivery = Table(Config.Delivery)
    local EventCooldowns = Table(Delivery.EventCooldowns)
    local Cooldown = EventCooldowns[EventName]
    if type(Cooldown) ~= "number" then
        Cooldown = Num(Delivery.Cooldown, Num(Config.Cooldown, 5, 0), 0)
    else
        Cooldown = math.max(0, Cooldown)
    end
    local Now = os.clock()
    local LastSent = WebhookState.LastEvent[EventName]
    if not BypassCooldown and LastSent and Now - LastSent < Cooldown then return false end

    local Appearance = Table(Config.Appearance)
    local EmbedFields = {}
    for _, Field in ipairs(Fields or {}) do
        AddField(EmbedFields, Field.name, Field.value, Field.inline)
    end
    if Appearance.IncludePlayerName ~= false then AddField(EmbedFields, "Player", Player.Name, true) end
    if Appearance.IncludePlaceId ~= false then AddField(EmbedFields, "Place ID", game.PlaceId, true) end
    if Appearance.IncludeJobId == true and game.JobId ~= "" then AddField(EmbedFields, "Job ID", game.JobId, false) end

    local Color = tonumber(OverrideColor) or tonumber(Table(Appearance.Colors)[EventName]) or WebhookColors[EventName] or 0x5865F2
    local EmbedTitle = tostring(Title or EventName)
    local EmbedDescription = tostring(Description or "")
    local Embed = {
        title = EmbedTitle,
        color = Color,
        fields = EmbedFields
    }
    if EmbedDescription ~= "" and NormalizeEmbedText(EmbedDescription) ~= NormalizeEmbedText(EmbedTitle) then
        Embed.description = EmbedDescription
    end
    if Appearance.IncludeAvatarBust ~= false then
        local AvatarBustUrl = GetPlayerAvatarBustUrl(Config)
        if type(AvatarBustUrl) == "string" and string.match(AvatarBustUrl, "^https://") then
            Embed.thumbnail = { url = AvatarBustUrl }
        end
    end
    if Appearance.Timestamp ~= false then Embed.timestamp = GetIsoTimestamp() end
    local Footer = Appearance.Footer
    if Footer == nil then Footer = "MM2 AutoFarm" end
    if type(Footer) == "string" and Footer ~= "" then Embed.footer = { text = string.sub(Footer, 1, 2048) } end

    local Payload = {
        username = type(Config.Username) == "string" and Config.Username ~= "" and Config.Username or "MM2 Farm",
        embeds = { Embed },
        allowed_mentions = { parse = {}, users = {}, roles = {} }
    }
    local CustomWebhookAvatarUrl = Config.AvatarUrl
    if type(CustomWebhookAvatarUrl) == "string" and string.match(CustomWebhookAvatarUrl, "^https://") then
        Payload.avatar_url = CustomWebhookAvatarUrl
    end

    local Mentions = Table(Config.Mentions)
    local MentionEvents = Table(Mentions.Events)
    local UserId = type(Config.PingUserId) == "string" and Config.PingUserId or tostring(Config.PingUserId or "")
    if Mentions.Enabled == true and MentionEvents[EventName] == true and string.match(UserId, "^%d+$") then
        Payload.content = "<@" .. UserId .. ">"
        Payload.allowed_mentions.users = { UserId }
    end

    local MaxMessagesPerMinute = Num(Delivery.MaxMessagesPerMinute, 8, 0)
    local RetryCount = math.floor(Num(Delivery.RetryCount, 1, 0))
    local RetryDelay = Num(Delivery.RetryDelay, 2, 0)
    WebhookState.LastEvent[EventName] = Now
    QueueWebhookRequest({
        Url = Config.Url,
        Payload = Payload,
        MaxMessagesPerMinute = MaxMessagesPerMinute,
        RetryCount = RetryCount,
        RetryDelay = RetryDelay
    })
    return true
end

local function NewStats()
    return { Total = 0, ByType = {} }
end

local function AddStat(Stats, CoinType)
    if type(Stats) ~= "table" then return end
    local TypeName = type(CoinType) == "string" and CoinType or "Unknown"
    Stats.Total = (Stats.Total or 0) + 1
    Stats.ByType = Table(Stats.ByType)
    Stats.ByType[TypeName] = (Stats.ByType[TypeName] or 0) + 1
end

local function GetMetricCount(Stats, Metric)
    if type(Stats) ~= "table" then return 0 end
    local Lower = string.lower(tostring(Metric or "Total"))
    if Lower == "total" or Lower == "items" or Lower == "all" then return Stats.Total or 0 end
    local Count = 0
    for Name, Amount in pairs(Table(Stats.ByType)) do
        local TypeName = string.lower(tostring(Name))
        if Lower == "candies" or Lower == "candy" then
            if string.find(TypeName, "cand") then Count += Amount end
        elseif Lower == "coins" or Lower == "coin" then
            if string.find(TypeName, "coin") then Count += Amount end
        else
            if TypeName == Lower then Count += Amount end
        end
    end
    return Count
end

local function FormatStatsBreakdown(Stats)
    local Entries = {}
    for Name, Amount in pairs(Table(Stats and Stats.ByType)) do
        table.insert(Entries, { Name = tostring(Name), Amount = tonumber(Amount) or 0 })
    end
    table.sort(Entries, function(A, B) return string.lower(A.Name) < string.lower(B.Name) end)
    local Lines = {}
    for _, Entry in ipairs(Entries) do
        table.insert(Lines, Entry.Name .. ": " .. tostring(Entry.Amount))
    end
    return #Lines > 0 and table.concat(Lines, "\n") or "None"
end

local function FormatDuration(Seconds)
    local Total = math.max(0, math.floor(tonumber(Seconds) or 0))
    local Hours = math.floor(Total / 3600)
    local Minutes = math.floor((Total % 3600) / 60)
    local Remainder = Total % 60
    if Hours > 0 then return string.format("%02d:%02d:%02d", Hours, Minutes, Remainder) end
    return string.format("%02d:%02d", Minutes, Remainder)
end

local function FormatCoinTypes(Value)
    if Value == nil then return "nil" end
    if type(Value) ~= "table" then return string.format("%q", tostring(Value)) end
    local Values = {}
    for Key, Entry in pairs(Value) do
        if type(Key) == "number" and type(Entry) == "string" then
            table.insert(Values, string.format("%q", Entry))
        elseif type(Key) == "string" and Entry == true then
            table.insert(Values, "[" .. string.format("%q", Key) .. "] = true")
        end
    end
    table.sort(Values)
    return "{ " .. table.concat(Values, ", ") .. " }"
end

local function FormatResetSetting(Value)
    if type(Value) ~= "table" then return tostring(Value) end
    local Values = {}
    for Key, Entry in pairs(Value) do
        if type(Key) == "number" and type(Entry) == "string" then
            table.insert(Values, string.format("%q", Entry))
        elseif type(Key) == "string" and type(Entry) == "boolean" then
            table.insert(Values, "[" .. string.format("%q", Key) .. "] = " .. tostring(Entry))
        end
    end
    table.sort(Values)
    return "{ " .. table.concat(Values, ", ") .. " }"
end

local function ResetAllowedForRole(Value, Role)
    if type(Value) == "boolean" then return Value end
    if type(Value) ~= "table" then return true end
    if type(Role) ~= "string" then return false end
    local Lower = string.lower(Role)
    for Key, Entry in pairs(Value) do
        if type(Key) == "number" then
            if type(Entry) == "string" and string.lower(Entry) == Lower then return true end
        elseif type(Key) == "string" and Entry == true and string.lower(Key) == Lower then
            return true
        end
    end
    return false
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
        local WebhookConfig = GetWebhookConfig()
        local RejoinOptions = GetWebhookEventOptions(WebhookConfig, "Rejoin")
        if WebhookConfig and IsWebhookEventEnabled(WebhookConfig, "Rejoin") then
            local ShouldNotify = RejoinOptions.NotifyOnError ~= false or RejoinOptions.NotifyOnAttempt ~= false
            if ShouldNotify then
                SendWebhook("Rejoin", "Rejoin Attempt", "Roblox error detected; rejoin requested.", {
                    { name = "Error", value = string.sub(tostring(ErrorMessage), 1, 900), inline = false },
                    { name = "Action", value = "Teleport requested", inline = true },
                    { name = "Place ID", value = tostring(game.PlaceId), inline = true }
                })
            end
            if RejoinOptions.NotifyOnNextLoad == true then
                getgenv().__AutoFarmPendingRejoin = true
            end
        end
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
    Self.HoldCF = nil
    Self.Elevated = false
    Self.GravForce = nil
    Self.CoinChange = 0
    Self.PreRound = false
    Self.SpawnPos = nil
    Self.SessionStartedAt = os.clock()
    Self.RoundStartedAt = nil
    Self.FirstCoinHopPending = false
    Self.RoundNumber = 0
    Self.CompletedRounds = 0
    Self.RoundReported = true
    Self.RoundStats = NewStats()
    Self.SessionStats = NewStats()
    Self.LastCollectionAt = os.clock()
    Self.StuckFailedChecks = 0
    Self.StuckAlerted = false
    Self.PendingDeathRespawn = false
    Self.LowEfficiencyStreak = 0
    Self.LowEfficiencyHistory = {}
    Self.LowEfficiencyAlerted = false
    Self.LowEfficiencyAlertCount = 0
    Self.Watched = setmetatable({}, { __mode = "k" })
    Self.Skip = setmetatable({}, { __mode = "k" })
    return Self
end

function AutoFarm:NotifyLoaded()
    local Config = GetWebhookConfig()
    if not Config or not IsWebhookEventEnabled(Config, "Loaded") then return end
    local Options = GetWebhookEventOptions(Config, "Loaded")
    local Fields = {}
    local Cfg = Resolve()

    if Options.IncludeConfiguration ~= false then
        AddField(Fields, "Global", "```lua\nEnabled = " .. tostring(Cfg.Enabled) .. "\n```", false)
        if Options.IncludeAutoFarmSettings ~= false then
            local AF = Cfg.AutoFarm
            local ResetValue = FormatResetSetting(AF.ResetOnBagFull)
            AddField(Fields, "AutoFarm", "```lua\nEnabled = " .. tostring(AF.Enabled)
                .. ",\nResetOnBagFull = " .. ResetValue
                .. ",\nReturnToSpawn = " .. tostring(AF.ReturnToSpawn)
                .. ",\nAllowedCoinTypes = " .. FormatCoinTypes(AF.AllowedCoinTypes) .. "\n```", false)
            AddField(Fields, "Movement", "```lua\nType = \"" .. tostring(AF.Method.Type) .. "\""
                .. ",\nTweenSpeed = " .. tostring(AF.Method.TweenSpeed)
                .. ",\nDelay = " .. tostring(AF.Method.Delay)
                .. ",\nBodyPart = \"" .. tostring(AF.Method.BodyPart) .. "\""
                .. ",\nOffset = " .. tostring(AF.Method.Offset)
                .. ",\nCoinTimeout = " .. tostring(AF.Method.CoinTimeout)
                .. ",\nSkipTime = " .. tostring(AF.Method.SkipTime)
                .. ",\nFreezeSettle = " .. tostring(AF.Method.FreezeSettle) .. "\n```", false)
            AddField(Fields, "Lobby / PreRound", "```lua\nLobby = { Enabled = " .. tostring(AF.Lobby.Enabled)
                .. ", Depth = " .. tostring(AF.Lobby.Depth) .. " }"
                .. ",\nPreRound = { Enabled = " .. tostring(AF.PreRound.Enabled)
                .. ", Depth = " .. tostring(AF.PreRound.Depth) .. " }\n```", false)
        end
        if Options.IncludeMiscSettings ~= false then
            AddField(Fields, "Miscellaneous", "```lua\nAntiAFK = " .. tostring(Cfg.Misc.AntiAFK)
                .. ",\nAutoRejoin = " .. tostring(Cfg.Misc.AutoRejoin)
                .. ",\nRendering = " .. tostring(Cfg.Misc.Rendering)
                .. ",\nMaxFPS = " .. tostring(Cfg.Misc.MaxFPS) .. "\n```", false)
        end
        local WebhookEvents = {}
        for Name, Value in pairs(Table(Config.Events)) do
            local IsEnabled = type(Value) == "boolean" and Value or (type(Value) == "table" and Value.Enabled == true)
            if IsEnabled then table.insert(WebhookEvents, tostring(Name)) end
        end
        table.sort(WebhookEvents)
        AddField(Fields, "Enabled Webhook Events", #WebhookEvents > 0 and table.concat(WebhookEvents, ", ") or "None", false)
    end

    SendWebhook("Loaded", "Script Initialized", "Script initialized! Configuration loaded below.", Fields)
end

function AutoFarm:BeginRound(Notify)
    if self.RoundActive then
        local Config = GetWebhookConfig()
        if Config and (IsWebhookEventEnabled(Config, "RoundSummary")
            or IsWebhookEventEnabled(Config, "SessionSummary")
            or IsWebhookEventEnabled(Config, "LowEfficiency")) then
            self:FinishRound()
        end
    end
    self.RoundNumber += 1
    self.RoundStartedAt = os.clock()
    self.FirstCoinHopPending = true
    self.RoundStats = NewStats()
    self.RoundActive = true
    self.RoundReported = false
    self.PreRound = false
    self.BagFull = false
    self.Respawning = false
    self.DiedThisRound = false
    self.LastCollectionAt = os.clock()
    self.StuckFailedChecks = 0
    self.StuckAlerted = false
    self.PendingDeathRespawn = false

    if Notify ~= false then
        SendWebhook("RoundStarted", "Round Started", "Round " .. tostring(self.RoundNumber) .. " started.", {
            { name = "Round", value = tostring(self.RoundNumber), inline = true },
            { name = "Farm Status", value = self:CanFarm(Resolve()) and "Ready" or "Waiting", inline = true }
        })
    end
end

function AutoFarm:EvaluateLowEfficiency(Stats)
    local Config = GetWebhookConfig()
    if not Config or not IsWebhookEventEnabled(Config, "LowEfficiency") then return end
    local Options = GetWebhookEventOptions(Config, "LowEfficiency")
    local Metric = tostring(Options.Metric or "Candies")
    local Threshold = Num(Options.ThresholdExclusive, 20, 0)
    local RequiredRounds = math.floor(Num(Options.ConsecutiveRounds, 3, 1))
    local Count = GetMetricCount(Stats, Metric)

    if Count < Threshold then
        self.LowEfficiencyStreak += 1
        table.insert(self.LowEfficiencyHistory, { Round = self.RoundNumber, Count = Count })
        while #self.LowEfficiencyHistory > RequiredRounds do table.remove(self.LowEfficiencyHistory, 1) end

        local NotifyOnce = Options.NotifyOncePerStreak ~= false
        if self.LowEfficiencyStreak >= RequiredRounds and (not self.LowEfficiencyAlerted or not NotifyOnce) then
            local Fields = {
                { name = "Metric", value = Metric, inline = true },
                { name = "Threshold", value = "< " .. tostring(Threshold), inline = true },
                { name = "Consecutive Rounds", value = tostring(self.LowEfficiencyStreak), inline = true },
                { name = "Average Per Round", value = string.format("%.2f", (function()
                    local Total = 0
                    for _, Entry in ipairs(self.LowEfficiencyHistory) do Total += Entry.Count end
                    return #self.LowEfficiencyHistory > 0 and Total / #self.LowEfficiencyHistory or 0
                end)()), inline = true }
            }
            if Options.IncludeRoundHistory ~= false then
                local History = {}
                for _, Entry in ipairs(self.LowEfficiencyHistory) do
                    table.insert(History, "Round " .. tostring(Entry.Round) .. ": " .. tostring(Entry.Count))
                end
                AddField(Fields, "Round History", table.concat(History, "\n"), false)
            end
            local Sent = SendWebhook("LowEfficiency", "Farm Efficiency Warning", "Farm is inefficient; reached low amount of " .. tostring(Count) .. " " .. string.lower(Metric) .. " collected in " .. tostring(self.LowEfficiencyStreak) .. " rounds straight.", Fields)
            if Sent then
                self.LowEfficiencyAlertCount += 1
                self.LowEfficiencyAlerted = true
            end
        end
    else
        if self.LowEfficiencyAlerted and Options.NotifyOnRecovery == true then
            SendWebhook("LowEfficiency", "Farm Efficiency Recovered", "Collection returned to the configured target.", {
                { name = "Metric", value = Metric, inline = true },
                { name = "Latest Round", value = tostring(Count), inline = true },
                { name = "Threshold", value = ">= " .. tostring(Threshold), inline = true },
                { name = "Previous Low Streak", value = tostring(self.LowEfficiencyStreak), inline = true }
            }, nil, true)
        end
        self.LowEfficiencyStreak = 0
        self.LowEfficiencyHistory = {}
        self.LowEfficiencyAlerted = false
    end
end

function AutoFarm:FinishRound()
    self.FirstCoinHopPending = false
    if not self.RoundActive or self.RoundReported then
        self.RoundActive = false
        self.PreRound = false
        self.BagFull = false
        self.StuckFailedChecks = 0
        self.StuckAlerted = false
        return
    end

    self.RoundReported = true
    local FinishedAt = os.clock()
    local Duration = self.RoundStartedAt and (FinishedAt - self.RoundStartedAt) or 0
    local Stats = self.RoundStats or NewStats()
    self.CompletedRounds += 1
    self:EvaluateLowEfficiency(Stats)

    local Config = GetWebhookConfig()
    local SummaryOptions = GetWebhookEventOptions(Config, "RoundSummary")
    local EveryRounds = math.floor(Num(SummaryOptions.EveryNRounds, 1, 1))
    local MinimumCollected = Num(SummaryOptions.OnlyIfCollectedAtLeast, 0, 0)
    if self.CompletedRounds % EveryRounds == 0 and (Stats.Total or 0) >= MinimumCollected then
        local Fields = {}
        if SummaryOptions.IncludeRoundNumber ~= false then
            AddField(Fields, "Round Number", self.RoundNumber, true)
        end
        AddField(Fields, "Items Collected", Stats.Total or 0, true)
        if SummaryOptions.IncludeDuration ~= false then
            AddField(Fields, "Round Duration", FormatDuration(Duration), true)
        end
        if SummaryOptions.IncludeCoinBreakdown ~= false then
            AddField(Fields, "Collection Breakdown", FormatStatsBreakdown(Stats), false)
            AddField(Fields, "Coins", GetMetricCount(Stats, "Coins"), true)
            AddField(Fields, "Candies", GetMetricCount(Stats, "Candies"), true)
        end
        if SummaryOptions.IncludeSessionTotals == true then
            AddField(Fields, "Session Items", self.SessionStats.Total or 0, true)
            if SummaryOptions.IncludeSessionBreakdown == true then
                AddField(Fields, "Session Breakdown", FormatStatsBreakdown(self.SessionStats), false)
            end
        end
        SendWebhook("RoundSummary", "Round Finished", nil, Fields)
    end

    local SessionOptions = GetWebhookEventOptions(Config, "SessionSummary")
    local SessionEvery = math.floor(Num(SessionOptions.EveryNRounds, 10, 1))
    if self.CompletedRounds > 0 and self.CompletedRounds % SessionEvery == 0 then
        local Fields = {}
        if SessionOptions.IncludeRoundsPlayed ~= false then
            AddField(Fields, "Rounds Played", self.CompletedRounds, true)
        end
        AddField(Fields, "Total Items", self.SessionStats.Total or 0, true)
        if SessionOptions.IncludeTotalCoins ~= false then
            AddField(Fields, "Total Coins", GetMetricCount(self.SessionStats, "Coins"), true)
        end
        if SessionOptions.IncludeTotalCandies ~= false then
            AddField(Fields, "Total Candies", GetMetricCount(self.SessionStats, "Candies"), true)
        end
        if SessionOptions.IncludeAveragePerRound ~= false then
            AddField(Fields, "Average Items / Round", string.format("%.2f", (self.SessionStats.Total or 0) / math.max(1, self.CompletedRounds)), true)
        end
        if SessionOptions.IncludeSessionDuration ~= false then
            AddField(Fields, "Session Duration", FormatDuration(os.clock() - self.SessionStartedAt), true)
        end
        if SessionOptions.IncludeLowEfficiencyWarnings ~= false then
            AddField(Fields, "Low-Efficiency Alerts", self.LowEfficiencyAlertCount or 0, true)
        end
        if SessionOptions.IncludeCollectionBreakdown ~= false then
            AddField(Fields, "Collection Breakdown", FormatStatsBreakdown(self.SessionStats), false)
        end
        SendWebhook("SessionSummary", "Session Summary", "Periodic session statistics.", Fields)
    end

    self:CancelTween()
    self.RoundActive = false
    self.PreRound = false
    self.BagFull = false
    self.StuckFailedChecks = 0
    self.StuckAlerted = false
end

function AutoFarm:NotifyBagFull(Current, Capacity, Action)
    local Config = GetWebhookConfig()
    if not Config or not IsWebhookEventEnabled(Config, "BagFull") then return end
    local Options = GetWebhookEventOptions(Config, "BagFull")
    if Action == "Character Reset" and Options.NotifyOnReset == false then return end
    if Action == "Return to Spawn" and Options.NotifyOnReturnToSpawn == false then return end

    local Fields = {
        { name = "Bag Status", value = "FULL", inline = true },
        { name = "Current / Capacity", value = tostring(Current) .. " / " .. tostring(Capacity), inline = true }
    }
    if Options.IncludeBagAction ~= false then AddField(Fields, "Action", Action, false) end
    if Options.IncludeRoundStats ~= false then
        AddField(Fields, "Round Items Collected", self.RoundStats.Total or 0, true)
        AddField(Fields, "Round Breakdown", FormatStatsBreakdown(self.RoundStats), false)
    end
    SendWebhook("BagFull", "Bag is Full", nil, Fields)
end

function AutoFarm:HandleDeath()
    if not self.RoundActive or self.DiedThisRound then return end
    self.DiedThisRound = true
    self.Respawning = true
    self.PendingDeathRespawn = true
    self:CancelTween()

    local Config = GetWebhookConfig()
    local Options = GetWebhookEventOptions(Config, "Died")
    if Options.NotifyOnDeath ~= false then
        local Fields = {
            { name = "Round Number", value = tostring(self.RoundNumber), inline = true },
            { name = "Round Items", value = tostring(self.RoundStats.Total or 0), inline = true },
            { name = "Respawn", value = "Pending", inline = true }
        }
        if Options.IncludeRoundStats ~= false then AddField(Fields, "Collection Breakdown", FormatStatsBreakdown(self.RoundStats), false) end
        SendWebhook("Died", "Player Died", "Player died during the round.", Fields)
    end
end

function AutoFarm:StartStuckMonitor()
    task.spawn(function()
        while self.Player and self.Player.Parent do
            local Config = GetWebhookConfig()
            local Options = GetWebhookEventOptions(Config, "Stuck")
            local Interval = Num(Options.CheckEverySeconds, 15, 1)
            task.wait(Interval)

            Config = GetWebhookConfig()
            if not Config or not IsWebhookEventEnabled(Config, "Stuck") then
                self.StuckFailedChecks = 0
                continue
            end
            Options = GetWebhookEventOptions(Config, "Stuck")
            local Cfg = Resolve()
            local HasActiveRound = self.RoundActive or Options.RequireActiveRound == false
            if not HasActiveRound or not Cfg.AutoFarm.Enabled or self.BagFull or self.Respawning or self.DiedThisRound then
                self.StuckFailedChecks = 0
                continue
            end

            local LastProgress = self.LastCollectionAt or self.RoundStartedAt or self.SessionStartedAt
            local NoCollectionSeconds = Num(Options.NoCollectionSeconds, 120, 1)
            if os.clock() - LastProgress >= NoCollectionSeconds then
                self.StuckFailedChecks += 1
                local RequiredChecks = math.floor(Num(Options.RequiredFailedChecks, 2, 1))
                if self.StuckFailedChecks >= RequiredChecks then
                    local NotifyOnce = Options.NotifyOnceUntilRecovery ~= false
                    if not self.StuckAlerted or not NotifyOnce then
                        local Sent = SendWebhook("Stuck", "Farm Stuck", "Farm is not collecting items.", {
                            { name = "Last Collection", value = FormatDuration(os.clock() - LastProgress) .. " ago", inline = true },
                            { name = "No-Collection Threshold", value = tostring(NoCollectionSeconds) .. "s", inline = true },
                            { name = "Failed Checks", value = tostring(self.StuckFailedChecks), inline = true },
                            { name = "Round Items", value = tostring(self.RoundStats.Total or 0), inline = true },
                            { name = "Farm Enabled", value = tostring(Cfg.AutoFarm.Enabled), inline = true },
                            { name = "Recovery", value = "Pending", inline = true }
                        })
                        if Sent then self.StuckAlerted = true end
                    end
                    if not NotifyOnce then self.StuckFailedChecks = 0 end
                end
            else
                self.StuckFailedChecks = 0
            end
        end
    end)
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
    Hum.PlatformStand = true
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

function AutoFarm:RemoveGravForce()
    if self.GravForce then
        local Att = self.GravForce.Attachment0
        self.GravForce:Destroy()
        if Att then Att:Destroy() end
        self.GravForce = nil
    end
end

function AutoFarm:Unfreeze()
    self.Frozen = false
    self:RemoveGravForce()
    local Hum = GetHumanoid(self)
    if Hum then
        Hum.PlatformStand = false
        Hum.AutoRotate = true
    end
    local Char = GetCharacter(self)
    local Animate = Char and Char:FindFirstChild("Animate")
    if Animate and Animate:IsA("LocalScript") then Animate.Disabled = false end
end

function AutoFarm:Release()
    self:CancelTween()
    self.Parked = false
    self.ParkedChar = nil
    self.HoldCF = nil
    if self.Anchored then self:Unanchor() end
    if self.Frozen then self:Unfreeze() end
end

function AutoFarm:HookPhysics()
    self:AddConnection(RunService.Stepped:Connect(function()
        if not self.Frozen then return end
        local Char = GetCharacter(self)
        if not Char then return end
        for _, Part in ipairs(Char:GetChildren()) do
            if Part:IsA("BasePart") then Part.CanCollide = false end
        end
    end))

    self:AddConnection(RunService.Heartbeat:Connect(function()
        local HRP = GetHRP(self)
        if not HRP then return end

        if self.Frozen then
            if not HRP.Anchored then
                HRP.AssemblyLinearVelocity = Vector3.zero
                HRP.AssemblyAngularVelocity = Vector3.zero
            end

            local Force = self.GravForce
            if not Force or Force.Parent ~= HRP then
                self:RemoveGravForce()
                local Att = Instance.new("Attachment")
                Att.Name = "FarmGravAtt"
                Att.Parent = HRP
                Force = Instance.new("VectorForce")
                Force.Name = "FarmGrav"
                Force.Attachment0 = Att
                Force.RelativeTo = Enum.ActuatorRelativeTo.World
                Force.ApplyAtCenterOfMass = true
                Force.Parent = HRP
                self.GravForce = Force
            end
            Force.Force = Vector3.new(0, workspace.Gravity * HRP.AssemblyMass, 0)
        elseif self.GravForce then
            self:RemoveGravForce()
        end

        if self.Parked and self.HoldCF and self.ParkedChar == GetCharacter(self) then
            if not HRP.Anchored then
                HRP.AssemblyLinearVelocity = Vector3.zero
                HRP.Anchored = true
                self.Anchored = true
            end
            if (HRP.Position - self.HoldCF.Position).Magnitude > 1 then
                HRP.CFrame = self.HoldCF
            end
        end
    end))
end

function AutoFarm:HookPreRound()
    self:AddConnection(Gameplay.TeleportToPart.OnClientEvent:Connect(function(Part)
        if typeof(Part) ~= "Instance" or not Part:IsA("BasePart") then return end
        self.SpawnPos = Part.Position
        self.PreRound = true
        self.Parked = false
        self.ParkedChar = nil
        self.HoldCF = nil
    end))
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

function AutoFarm:ReturnToSpawn(Cfg)
    if not Cfg.AutoFarm.ReturnToSpawn or not self.SpawnPos then return end
    local HRP = GetHRP(self)
    local Hum = GetHumanoid(self)
    if not HRP or not Hum then return end
    self:CancelTween()
    HRP.AssemblyLinearVelocity = Vector3.zero
    HRP.AssemblyAngularVelocity = Vector3.zero
    HRP.CFrame = CFrame.new(self.SpawnPos + Vector3.new(0, Hum.HipHeight + 3, 0)) * UprightRotation(HRP)
    self.Elevated = false
end

function AutoFarm:HookDeath()
    local CRC = require(game:GetService("ReplicatedStorage").Modules.CurrentRoundClient)

    self:AddConnection(CRC.PlayerDataChanged.Event:Connect(function()
        local Data = CRC.GetLatestPlayerData()
        local MyData = Data and Data[self.Player.Name]
        if MyData and MyData.Dead == true and self.RoundActive and not self.DiedThisRound then
            self:HandleDeath()
        end
    end))

    local function Attach(Char)
        local Hum = Char:FindFirstChildWhichIsA("Humanoid")
        if not Hum then return end
        self:AddConnection(Hum.Died:Connect(function()
            if self.RoundActive and not self.DiedThisRound then
                self:HandleDeath()
            end
        end))
    end

    if self.Player.Character then Attach(self.Player.Character) end
    self:AddConnection(self.Player.CharacterAdded:Connect(function(Char)
        task.wait()
        local WasDeathRespawn = self.PendingDeathRespawn
        self.PendingDeathRespawn = false
        self.Respawning = false
        self.Elevated = false
        self.Parked = false
        self.ParkedChar = nil
        self.HoldCF = nil
        if WasDeathRespawn then
            local Config = GetWebhookConfig()
            local Options = GetWebhookEventOptions(Config, "Died")
            if Options.NotifyOnRespawn == true then
                SendWebhook("Died", "Player Respawned", "Player respawned.", {
                    { name = "Round Number", value = tostring(self.RoundNumber), inline = true },
                    { name = "Round Status", value = self.RoundActive and "Active" or "Ended", inline = true },
                    { name = "Farm Status", value = self:CanFarm(Resolve()) and "Ready" or "Waiting", inline = true }
                }, nil, true)
            end
        end
        Attach(Char)
    end))
end

function AutoFarm:GetRole()
    local Ok, Role = pcall(function()
        local CRC = require(game:GetService("ReplicatedStorage").Modules.CurrentRoundClient)
        local Data = CRC.GetLatestPlayerData()
        local MyData = Data and Data[self.Player.Name]
        return MyData and MyData.Role
    end)
    return Ok and Role or nil
end

function AutoFarm:ShouldReset(Value)
    if type(Value) == "boolean" then return Value end
    return ResetAllowedForRole(Value, self:GetRole())
end

function AutoFarm:DetectCoins()
    self:AddConnection(Gameplay.CoinCollected.OnClientEvent:Connect(function(CoinType, Current, Capacity)
        if type(CoinType) ~= "string" or type(Current) ~= "number" or type(Capacity) ~= "number" then return end
        local Cfg = Resolve()
        if not IsCoinTypeAllowed(Cfg.AutoFarm.AllowedCoinTypes, CoinType) then return end
        if not self.RoundActive or self.BagFull or self.Respawning or self.DiedThisRound then return end

        if GetWebhookConfig() then
            AddStat(self.RoundStats, CoinType)
            AddStat(self.SessionStats, CoinType)
        end
        self.LastCollectionAt = os.clock()
        self.StuckFailedChecks = 0
        if self.StuckAlerted then
            local WebhookConfig = GetWebhookConfig()
            local StuckOptions = GetWebhookEventOptions(WebhookConfig, "Stuck")
            if StuckOptions.NotifyOnRecovery == true then
                SendWebhook("Stuck", "Farm Recovered", "Farm resumed collecting items.", {
                    { name = "Last Collected Type", value = CoinType, inline = true },
                    { name = "Round Items", value = tostring(self.RoundStats.Total or 0), inline = true },
                    { name = "Recovery", value = "Collection detected", inline = true }
                }, nil, true)
            end
            self.StuckAlerted = false
        end

        if Current >= Capacity then
            self.BagFull = true
            local ShouldReset = self:ShouldReset(Cfg.AutoFarm.ResetOnBagFull)
            local Action = "No action"
            if Cfg.AutoFarm.Enabled then
                if ShouldReset then
                    Action = "Character Reset"
                elseif Cfg.AutoFarm.ReturnToSpawn and self.SpawnPos then
                    Action = "Return to Spawn"
                elseif Cfg.AutoFarm.ReturnToSpawn then
                    Action = "Return to Spawn unavailable"
                end
            end
            self:NotifyBagFull(Current, Capacity, Action)
            if Cfg.AutoFarm.Enabled then
                if ShouldReset then
                    self:Reset()
                else
                    self:ReturnToSpawn(Cfg)
                end
            end
        end
    end))
end

function AutoFarm:DetectRounds()
    local CRC = require(game:GetService("ReplicatedStorage").Modules.CurrentRoundClient)

    local MyData = CRC.PlayerData and CRC.PlayerData[self.Player.Name]
    if MyData then
        self:BeginRound(false)
        self.DiedThisRound = MyData.Dead == true
    end

    self:AddConnection(Gameplay.RoundStart.OnClientEvent:Connect(function()
        self:BeginRound(true)
    end))

    self:AddConnection(Gameplay.VictoryScreen.OnClientEvent:Connect(function()
        self:CancelTween()
        self:FinishRound()
    end))

    self:AddConnection(CRC.PlayerDataChanged.Event:Connect(function()
        local Data = CRC.GetLatestPlayerData()
        local IsEmpty = true
        for _ in pairs(Data) do IsEmpty = false break end
        if IsEmpty then
            self:CancelTween()
            self:FinishRound()
        end
    end))

    self:AddConnection(Gameplay.RoundEndFade.OnClientEvent:Connect(function()
        if self.RoundActive then
            self:CancelTween()
            self:FinishRound()
        end
    end))
end

function AutoFarm:GetNearestCoin(Cfg)
    local HRP = GetHRP(self)
    if not HRP then return nil end
    local Allowed = Cfg.AutoFarm.AllowedCoinTypes
    local Now = os.clock()
    local Closest, Dist = nil, math.huge
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
                        Dist = D
                    end
                end
            end
        end
    end
    return Closest
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

function AutoFarm:Hop(Goal, Coin)
    for _ = 1, 2 do
        for _, Height in ipairs({ 2, 0 }) do
            local HRP = GetHRP(self)
            if not HRP or not Coin.Parent or not Coin:FindFirstChild("TouchInterest") then return end
            if not self:CanFarm(Resolve()) then return end
            HRP.CFrame = Goal + Vector3.new(0, Height, 0)
            task.wait(0.05)
        end
    end
end

function AutoFarm:WaitForFirstCoinTween(Tween, Goal, Coin, Distance, Speed, Timeout, SkipTime)
    local End = os.clock() + Distance / Speed + Timeout
    local Seen = self.CoinChange

    while os.clock() < End do
        task.wait()

        if not Coin.Parent or not Coin:FindFirstChild("TouchInterest") then
            self.FirstCoinHopPending = false
            return true
        end

        local Cfg = Resolve()
        if not self:CanFarm(Cfg) then return false end

        if Tween.PlaybackState == Enum.PlaybackState.Completed then
            self.FirstCoinHopPending = false
            self:Hop(Goal, Coin)
            return self:WaitForCoin(Coin, Timeout, SkipTime, false)
        end

        if self.CoinChange ~= Seen then
            Seen = self.CoinChange
            local HRP = GetHRP(self)
            local Best = HRP and self:GetNearestCoin(Cfg)
            if Best and Best ~= Coin
                and (HRP.Position - Best.Position).Magnitude + 1 < (HRP.Position - Coin.Position).Magnitude then
                return "retarget"
            end
        end
    end

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
    self.Elevated = true
end

function AutoFarm:GetLobbySpot(Depth)
    local Lobby = workspace:FindFirstChild("Lobby")
    if not Lobby then return nil end
    local Ok, CF, Size = pcall(function() return Lobby:GetBoundingBox() end)
    if not Ok then return nil end
    local Y = math.max(CF.Position.Y - Size.Y / 2 - Depth, workspace.FallenPartsDestroyHeight + 20)
    return Vector3.new(CF.Position.X, Y, CF.Position.Z)
end

function AutoFarm:GetSpawnSpot(Depth)
    if not self.SpawnPos then return nil end
    local Y = math.max(self.SpawnPos.Y - Depth, workspace.FallenPartsDestroyHeight + 20)
    return Vector3.new(self.SpawnPos.X, Y, self.SpawnPos.Z)
end

function AutoFarm:ParkAt(Spot, Cfg)
    local Char = GetCharacter(self)
    local HRP = GetHRP(self)
    local Hum = GetHumanoid(self)
    if not Char or not HRP or not Hum then return end

    self:CancelTween()
    self:Freeze(Hum)
    HRP.CFrame = CFrame.new(Spot) * UprightRotation(HRP)
    self.Elevated = true
    task.wait(Cfg.AutoFarm.Method.FreezeSettle)

    if self:WaitingForRound(Resolve()) and GetHRP(self) == HRP then
        self:Anchor()
        self.HoldCF = HRP.CFrame
        self.Parked = true
        self.ParkedChar = Char
    end
end

function AutoFarm:ParkUnderLobby(Cfg)
    local Char = GetCharacter(self)
    local HRP = GetHRP(self)
    if not Char or not HRP then return end
    if self.Parked and self.ParkedChar == Char and HRP.Anchored then return end
    local Spot = self:GetLobbySpot(Cfg.AutoFarm.Lobby.Depth)
    if Spot then self:ParkAt(Spot, Cfg) end
end

function AutoFarm:ParkUnderSpawn(Cfg)
    local Char = GetCharacter(self)
    local HRP = GetHRP(self)
    if not Char or not HRP then return end
    if self.Parked and self.ParkedChar == Char and HRP.Anchored then return end
    local Spot = self:GetSpawnSpot(Cfg.AutoFarm.PreRound.Depth)
    if Spot then self:ParkAt(Spot, Cfg) end
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
                    if self.PreRound and self.SpawnPos and Cfg.AutoFarm.PreRound.Enabled then
                        self:ParkUnderSpawn(Cfg)
                    elseif Cfg.AutoFarm.Lobby.Enabled then
                        self:ParkUnderLobby(Cfg)
                    else
                        self:Release()
                    end
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

            local Coin = self:GetNearestCoin(Cfg)
            if not Coin then
                self:WaitForCoinChange(0.3)
                continue
            end

            if self.Parked then
                self.Parked = false
                self.ParkedChar = nil
                self.HoldCF = nil
            end

            local Goal = self:GetGoal(Coin, HRP, Hum, Method.BodyPart, Method.Offset)
            local Result = false
            local Teleport = Method.Type ~= "Tween" or self.Elevated

            if self.Anchored then
                if Teleport then
                    HRP.CFrame = Goal
                    task.wait()
                    self:Unanchor()
                else
                    self:Unanchor()
                    task.wait()
                end
                HRP = GetHRP(self)
                Hum = GetHumanoid(self)
                if not HRP or not Hum then continue end
                Goal = self:GetGoal(Coin, HRP, Hum, Method.BodyPart, Method.Offset)
            end

            local IsFirstRoundCoin = self.FirstCoinHopPending

            if not Teleport then
                HRP.CFrame = CFrame.new(HRP.Position) * Goal.Rotation
                local Distance = (Goal.Position - HRP.Position).Magnitude
                local Tween = self:TweenTo(Goal, Distance, Method.TweenSpeed)
                if Tween then
                    if IsFirstRoundCoin then
                        Result = self:WaitForFirstCoinTween(Tween, Goal, Coin, Distance, Method.TweenSpeed, Method.CoinTimeout, Method.SkipTime)
                    else
                        Result = self:WaitForCoin(Coin, Distance / Method.TweenSpeed + Method.CoinTimeout, Method.SkipTime, true)
                    end
                    self:CancelTween()
                end
            else
                HRP.CFrame = Goal
                if Method.Type == "Tween" then self.Elevated = false end
                if IsFirstRoundCoin and self.FirstCoinHopPending then
                    self.FirstCoinHopPending = false
                    self:Hop(Goal, Coin)
                end
                Result = self:WaitForCoin(Coin, Method.CoinTimeout, Method.SkipTime, false)
            end

            if IsFirstRoundCoin and Result == true then
                self.FirstCoinHopPending = false
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
    Farm:HookPhysics()
    Farm:HookPreRound()
    Farm:HookDeath()
    Farm:DetectCoins()
    Farm:DetectRounds()
    Farm:StartFarmingLoop()
    local WebhookConfig = GetWebhookConfig()
    if WebhookConfig and IsWebhookEventEnabled(WebhookConfig, "Stuck") then
        Farm:StartStuckMonitor()
    end
    Farm:NotifyLoaded()

    local RejoinOptions = GetWebhookEventOptions(WebhookConfig, "Rejoin")
    if getgenv().__AutoFarmPendingRejoin and WebhookConfig and IsWebhookEventEnabled(WebhookConfig, "Rejoin") and RejoinOptions.NotifyOnNextLoad == true then
        getgenv().__AutoFarmPendingRejoin = nil
        SendWebhook("Rejoin", "Script Loaded After Rejoin", "Script initialized after the rejoin attempt.", {
            { name = "Status", value = "Initialized", inline = true },
            { name = "Place ID", value = tostring(game.PlaceId), inline = true }
        }, nil, true)
    end
end

AutoFarm:Load()
