while true do
	local triggered = {}
	local total = 0

	for _, inst in ipairs(workspace:GetDescendants()) do
		if inst.Name:lower():find("coino") then
			local parent = inst.Parent
			if parent and not triggered[parent] then
				triggered[parent] = true

				local coinos = {}
				for _, child in ipairs(parent:GetChildren()) do
					if child.Name:lower():find("coino") then
						table.insert(coinos, child)
					end
				end

				local count = #coinos
				if count == 1 then
					total += 3
				elseif count == 3 then
					total += 8
				elseif count == 2 then
					game.Players.LocalPlayer:Kick("found 2 cois in same path?!\ncontact @lithium.1on on discord")
					return
				end

				for _, c in ipairs(parent:GetDescendants()) do
					if c:IsA("ClickDetector") then
						fireclickdetector(c)
					end
				end
				task.wait(0.1)
			end
		end
	end

	if total > 0 then
		game:GetService('StarterGui'):SetCore("SendNotification", {
			Title = "[lithium's hub]",
			Text = "got you " .. total .. " cois!!\nthank me later :3",
			Duration = 3
		})
	end

	task.wait(2)
end
