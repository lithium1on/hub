local getRawMetatable = getrawmetatable or (debug and debug.getmetatable)
local setReadOnly = setreadonly or function() end
local newcclosure = newcclosure or function(f) return f end
local hookfunction = hookfunction or function(f, newf) return newf end
local getnamecallmethod = getnamecallmethod or function() return nil end

if not getRawMetatable then return end

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then return end

local registry = getreg and getreg() or {}

for _, v in pairs(registry) do
    if type(v) == "function" then
        local info = debug.getinfo(v)
        if info and info.name and info.name:lower() == "kick" then
            pcall(function()
                hookfunction(v, function(...) return nil end)
            end)
        end
    end
end

local meta = getRawMetatable(game)
if not meta then return end

_G.__antikick = _G.__antikick or {
    oldNamecall = meta.__namecall,
    oldIndex = meta.__index,
    oldNewIndex = meta.__newindex
}

for _, kickMethod in pairs({ LocalPlayer.Kick, LocalPlayer.kick }) do
    if type(kickMethod) == "function" then
        pcall(function()
            hookfunction(kickMethod, newcclosure(function(...) end))
        end)
    end
end

setReadOnly(meta, false)

meta.__namecall = newcclosure(function(self, ...)
    local method = getnamecallmethod()
    if self == LocalPlayer and method and tostring(method):lower() == "kick" then
        return nil
    end
    return _G.__antikick.oldNamecall(self, ...)
end)

meta.__index = newcclosure(function(self, key)
    if self == LocalPlayer then
        local lowered = tostring(key):lower()
        if lowered:find("kick") or lowered:find("destroy") or lowered:find("break") then
            return function() end
        end
    end
    return _G.__antikick.oldIndex(self, key)
end)

meta.__newindex = newcclosure(function(self, key, value)
    if self == LocalPlayer then
        local lowered = tostring(key):lower()
        if lowered:find("kick") or lowered:find("destroy") then
            return
        end
    end
    return _G.__antikick.oldNewIndex(self, key, value)
end)

setReadOnly(meta, true)

-- pff ts pmo worst bypass but its okayy
