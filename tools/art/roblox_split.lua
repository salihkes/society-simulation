-- Roblox Studio command bar: select one or more models, run this.
-- Each model is split into Name_1, Name_2, ... with at most LIMIT parts each,
-- placed next to the original. The original is removed once it is empty.
local LIMIT = 20000

for _, model in ipairs(game:GetService("Selection"):Get()) do
	-- Top-level parts only: a part's child parts travel with it and count toward its chunk.
	local parts = {}
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			local owner = p:FindFirstAncestorWhichIsA("BasePart")
			if not (owner and owner:IsDescendantOf(model)) then
				table.insert(parts, p)
			end
		end
	end

	local index, count, chunk = 0, LIMIT, nil
	for _, p in ipairs(parts) do
		local weight = 1
		for _, d in ipairs(p:GetDescendants()) do
			if d:IsA("BasePart") then weight += 1 end
		end
		if count + weight > LIMIT then
			index += 1
			chunk = Instance.new("Model")
			chunk.Name = model.Name .. "_" .. index
			chunk.Parent = model.Parent
			count = 0
		end
		p.Parent = chunk
		count += weight
	end

	if #model:GetDescendants() == 0 then model:Destroy() end
	print(model.Name .. ": " .. #parts .. " parts -> " .. index .. " models")
end
