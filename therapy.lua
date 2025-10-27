local p=game:GetService("Players").LocalPlayer
local s=game:GetService("StarterGui")
local t=game:GetService("TeleportService")
local h=game:GetService("HttpService")
local pid=game.PlaceId
local jid=game.JobId

if queue_on_teleport then
    queue_on_teleport('loadstring(game:HttpGet("https://raw.githubusercontent.com/lithium1on/hub/refs/heads/main/therapy.lua"))()')
end

local total=0
local trig={}

for _,i in ipairs(workspace:GetDescendants()) do
    if i.Name:lower():find("coino") then
        local parent=i.Parent
        if parent and not trig[parent] then
            trig[parent]=true
            local c={}
            for _,v in ipairs(parent:GetChildren()) do
                if v.Name:lower():find("coino") then
                    table.insert(c,v)
                end
            end
            local n=#c
            if n==1 then total+=3
            elseif n==3 then total+=8
            elseif n==2 then p:Kick("debug: found 2 coinos") return end
            for _,v in ipairs(parent:GetDescendants()) do
                if v:IsA("ClickDetector") then fireclickdetector(v) end
            end
        end
    end
end

if total>0 then
    s:SetCore("SendNotification", {
        Title="[lithium's hub]",
        Text="got you "..total.." cois!!\nthank me later :3",
        Duration=3
    })
end

local success, body=pcall(function()
    return h:JSONDecode(game:HttpGet("https://games.roblox.com/v1/games/"..pid.."/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"))
end)

local servers={}
if success and body and body.data then
    for _,v in ipairs(body.data) do
        if type(v)=="table" and tonumber(v.playing) and tonumber(v.maxPlayers) and v.playing<v.maxPlayers and v.id~=jid then
            table.insert(servers,1,v.id)
        end
    end
end

if #servers>0 then
    task.wait(1) -- aka pls wait cuz server can't save shit
    t:TeleportToPlaceInstance(pid,servers[math.random(1,#servers)],p)
else
    s:SetCore("SendNotification",{
        Title="[lithium's hub]",
        Text="couldn't find a server :(",
        Duration=3
    })
end
