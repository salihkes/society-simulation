-- Roblox Studio command bar: moves every glass part out of the Export_* models
-- into one workspace model named "Export_Glass".
-- Glass = Transparency 0.5 and Reflectance 0.5. Set BOTH = false to take either.
local BOTH = true

local function half(x) return math.abs(x - 0.5) < 0.01 end

local glass = workspace:FindFirstChild("Export_Glass") or Instance.new("Model")
glass.Name = "Export_Glass"
glass.Parent = workspace

local moved = 0
for _, m in ipairs(workspace:GetDescendants()) do
	if m:IsA("Model") and m.Name:sub(1, 7) == "Export_" and m ~= glass then
		for _, p in ipairs(m:GetDescendants()) do
			if p:IsA("BasePart") and p:IsDescendantOf(m) then
				local t, r = half(p.Transparency), half(p.Reflectance)
				if (BOTH and t and r) or (not BOTH and (t or r)) then
					p.Parent = glass
					moved += 1
				end
			end
		end
	end
end
print("Glass: moved " .. moved .. " parts")
