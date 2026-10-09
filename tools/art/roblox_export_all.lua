-- Roblox Studio command bar: exports every workspace model named Export_* to OBJ,
-- one save dialog per model, in name order. Type the printed name into each dialog.
-- Run roblox_glass.lua and roblox_split.lua first.
local Selection = game:GetService("Selection")

local models = {}
for _, m in ipairs(workspace:GetChildren()) do
	if m:IsA("Model") and m.Name:sub(1, 7) == "Export_" then
		table.insert(models, m)
	end
end
table.sort(models, function(a, b) return a.Name < b.Name end)

local before = Selection:Get()
for i, m in ipairs(models) do
	print(("Export %d/%d: %s"):format(i, #models, m.Name))
	Selection:Set({ m })
	local ok, err = pcall(function() PluginManager():ExportSelection(m.Name) end)
	if not ok then warn(m.Name .. ": " .. tostring(err)) end
end
Selection:Set(before)
print("Export: done")
