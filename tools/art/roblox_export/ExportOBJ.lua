-- Export_ to OBJ: every instance named Export_… becomes its own OBJ.
-- Installed by tools/art/roblox_export.sh, which also runs the little server
-- this plugin hands the text to (plugins cannot write files themselves).
--
-- Geometry is rebuilt from each part, in studs, relative to the model's
-- pivot: Block, Wedge, CornerWedge, Cylinder, Ball, MeshPart (read through
-- EditableMesh) and SpecialMesh (FileMesh / Brick / Sphere / Wedge).
-- Unions and anything unreadable are skipped and listed in the report.

local HttpService = game:GetService("HttpService")
local AssetService = game:GetService("AssetService")

local PREFIX = "Export_"
local URL = "http://127.0.0.1:34900"
local SKIP_INVISIBLE = true   -- parts with Transparency 1 (collision boxes)
local WORLD_SPACE = false     -- true: keep world positions instead of centring on the pivot
local SEGMENTS = 24           -- cylinder / ball roundness
local CHUNK = 400000          -- characters per POST

local toolbar = plugin:CreateToolbar("OBJ Export")
local button = toolbar:CreateButton("Export_ to OBJ", "Write every " .. PREFIX .. "… model as its own OBJ", "")
button.ClickableWhenViewportHidden = true

local function post(path, name, body)
	local q = name and ("?name=" .. HttpService:UrlEncode(name)) or ""
	HttpService:PostAsync(URL .. path .. q, body or "", Enum.HttpContentType.TextPlain)
end

-- ── primitive shapes, in part space, faces wound counter-clockwise ──────

local function block(s)
	local x, y, z = s.X / 2, s.Y / 2, s.Z / 2
	return {
		Vector3.new(-x, -y, -z), Vector3.new(x, -y, -z), Vector3.new(x, y, -z), Vector3.new(-x, y, -z),
		Vector3.new(-x, -y, z), Vector3.new(x, -y, z), Vector3.new(x, y, z), Vector3.new(-x, y, z),
	}, { { 1, 4, 3, 2 }, { 5, 6, 7, 8 }, { 1, 5, 8, 4 }, { 2, 3, 7, 6 }, { 1, 2, 6, 5 }, { 4, 8, 7, 3 } }
end

-- high edge at the back (+Z), slope facing front (-Z) and up
local function wedge(s)
	local x, y, z = s.X / 2, s.Y / 2, s.Z / 2
	return {
		Vector3.new(-x, -y, -z), Vector3.new(x, -y, -z), Vector3.new(x, -y, z), Vector3.new(-x, -y, z),
		Vector3.new(x, y, z), Vector3.new(-x, y, z),
	}, { { 1, 2, 3, 4 }, { 4, 3, 5, 6 }, { 1, 6, 5, 2 }, { 1, 4, 6 }, { 2, 5, 3 } }
end

-- peak above the +X / -Z corner
local function cornerWedge(s)
	local x, y, z = s.X / 2, s.Y / 2, s.Z / 2
	return {
		Vector3.new(-x, -y, -z), Vector3.new(x, -y, -z), Vector3.new(x, -y, z), Vector3.new(-x, -y, z),
		Vector3.new(x, y, -z),
	}, { { 1, 2, 3, 4 }, { 2, 5, 3 }, { 1, 5, 2 }, { 1, 4, 5 }, { 4, 3, 5 } }
end

-- axis along `axis` ("X" for Part cylinders, "Y" for SpecialMesh cylinders)
local function cylinder(s, axis)
	local len, r, n = s.X, math.min(s.Y, s.Z) / 2, SEGMENTS
	if axis == "Y" then len, r = s.Y, math.min(s.X, s.Z) / 2 end
	local v, f = {}, {}
	for i = 0, n - 1 do
		local a = 2 * math.pi * i / n
		local c, sn = r * math.cos(a), r * math.sin(a)
		if axis == "Y" then
			v[#v + 1] = Vector3.new(sn, -len / 2, c)
			v[#v + 1] = Vector3.new(sn, len / 2, c)
		else
			v[#v + 1] = Vector3.new(-len / 2, c, sn)
			v[#v + 1] = Vector3.new(len / 2, c, sn)
		end
	end
	local lo, hi = {}, {}
	for i = 0, n - 1 do
		local j = (i + 1) % n
		f[#f + 1] = { 2 * i + 1, 2 * j + 1, 2 * j + 2, 2 * i + 2 }
		hi[#hi + 1] = 2 * i + 2
		lo[#lo + 1] = 2 * (n - 1 - i) + 1
	end
	f[#f + 1] = hi
	f[#f + 1] = lo
	return v, f
end

local function ball(s)
	local rx, ry, rz = s.X / 2, s.Y / 2, s.Z / 2
	local rings, segs = SEGMENTS // 2, SEGMENTS
	local v, f = { Vector3.new(0, ry, 0) }, {}
	for j = 1, rings - 1 do
		local t = math.pi * j / rings
		for i = 0, segs - 1 do
			local p = 2 * math.pi * i / segs
			v[#v + 1] = Vector3.new(rx * math.sin(t) * math.cos(p), ry * math.cos(t), rz * math.sin(t) * math.sin(p))
		end
	end
	v[#v + 1] = Vector3.new(0, -ry, 0)
	local bottom = #v
	local function at(j, i) return 2 + (j - 1) * segs + (i % segs) end
	for i = 0, segs - 1 do
		f[#f + 1] = { 1, at(1, i + 1), at(1, i) }
		f[#f + 1] = { bottom, at(rings - 1, i), at(rings - 1, i + 1) }
		for j = 1, rings - 2 do
			f[#f + 1] = { at(j, i), at(j, i + 1), at(j + 1, i + 1), at(j + 1, i) }
		end
	end
	-- wind every face outward (the ball is convex and centred)
	for _, face in f do
		local a, b, c = v[face[1]], v[face[2]], v[face[3]]
		if (b - a):Cross(c - a):Dot(a + b + c) < 0 then
			local r = {}
			for k = #face, 1, -1 do r[#r + 1] = face[k] end
			table.clear(face)
			for _, idx in r do face[#face + 1] = idx end
		end
	end
	return v, f
end

-- ── meshes, read once per id ────────────────────────────────────────────

local meshCache = {}
local function readMesh(id)
	if meshCache[id] ~= nil then return meshCache[id] end
	local ok, em = pcall(function() return AssetService:CreateEditableMeshAsync(Content.fromUri(id)) end)
	if not ok then ok, em = pcall(function() return AssetService:CreateEditableMeshAsync(id) end) end
	if not ok or not em then
		meshCache[id] = false
		return false, tostring(em)
	end
	local verts, index, faces = {}, {}, {}
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, vid in em:GetVertices() do
		local p = em:GetPosition(vid)
		verts[#verts + 1] = p
		index[vid] = #verts
		lo, hi = lo:Min(p), hi:Max(p)
	end
	for _, fid in em:GetFaces() do
		local face = {}
		for _, vid in em:GetFaceVertices(fid) do face[#face + 1] = index[vid] end
		faces[#faces + 1] = face
	end
	em:Destroy()
	local mesh = { verts = verts, faces = faces, center = (lo + hi) / 2, size = hi - lo }
	meshCache[id] = mesh
	return mesh
end

-- a mesh stretched to fill `size`, centred, the way MeshParts are shown
local function fitted(mesh, size)
	local function k(a, b) return b > 1e-6 and a / b or 1 end
	local scale = Vector3.new(k(size.X, mesh.size.X), k(size.Y, mesh.size.Y), k(size.Z, mesh.size.Z))
	local v = {}
	for i, p in mesh.verts do v[i] = (p - mesh.center) * scale end
	return v, mesh.faces
end

-- ── one part → vertices + faces in part space, or nil + why ─────────────

local function shapeOf(part)
	local special = part:FindFirstChildWhichIsA("SpecialMesh")
	if special then
		local t, s = special.MeshType, part.Size * special.Scale
		local v, f
		if t == Enum.MeshType.FileMesh then
			local mesh, err = readMesh(special.MeshId)
			if not mesh then return nil, "SpecialMesh " .. special.MeshId .. " unreadable (" .. (err or "cached failure") .. ")" end
			v, f = {}, mesh.faces
			for i, p in mesh.verts do v[i] = p * special.Scale end
		elseif t == Enum.MeshType.Brick then v, f = block(s)
		elseif t == Enum.MeshType.Sphere then v, f = ball(s)
		elseif t == Enum.MeshType.Wedge then v, f = wedge(s)
		elseif t == Enum.MeshType.Cylinder then v, f = cylinder(s, "Y")
		else return nil, "SpecialMesh type " .. t.Name end
		if special.Offset ~= Vector3.zero then
			for i, p in v do v[i] = p + special.Offset end
		end
		return v, f
	end
	if part:IsA("MeshPart") then
		local mesh, err = readMesh(part.MeshId)
		if not mesh then return nil, "MeshPart " .. part.MeshId .. " unreadable (" .. (err or "cached failure") .. ")" end
		return fitted(mesh, part.Size)
	end
	if part:IsA("PartOperation") then return nil, "union (" .. part.ClassName .. ")" end
	if part:IsA("WedgePart") then return wedge(part.Size) end
	if part:IsA("CornerWedgePart") then return cornerWedge(part.Size) end
	if part:IsA("Part") then
		local shape = part.Shape.Name
		if shape == "Block" then return block(part.Size) end
		if shape == "Wedge" then return wedge(part.Size) end
		if shape == "CornerWedge" then return cornerWedge(part.Size) end
		if shape == "Cylinder" then return cylinder(part.Size, "X") end
		if shape == "Ball" then return ball(part.Size) end
		return nil, "Part shape " .. shape
	end
	return nil, part.ClassName
end

-- ── one Export_ instance → one OBJ ──────────────────────────────────────

local function hex(c)
	return string.format("%02X%02X%02X", math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255))
end

local function exportOne(root, fileName, skipped)
	local origin = CFrame.new()
	if not WORLD_SPACE and (root:IsA("Model") or root:IsA("BasePart")) then origin = root:GetPivot() end
	local parts = root:IsA("BasePart") and { root } or {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then parts[#parts + 1] = d end
	end

	post("/open", fileName)
	local buf, len, nverts, written, materials, mtl = {}, 0, 0, 0, {}, {}
	local function flush()
		if len > 0 then post("/obj", fileName, table.concat(buf)) end
		table.clear(buf)
		len = 0
	end
	local function add(s)
		buf[#buf + 1] = s
		len += #s
		if len >= CHUNK then flush() end
	end

	for n, part in parts do
		if SKIP_INVISIBLE and part.Transparency >= 1 then continue end
		local v, f = shapeOf(part)
		if not v then
			skipped[#skipped + 1] = fileName .. " / " .. part:GetFullName():sub(#root:GetFullName() + 2) .. ": " .. f
			continue
		end
		local mat = part.Material.Name .. "_" .. hex(part.Color)
		if not materials[mat] then
			materials[mat] = true
			local c = part.Color
			mtl[#mtl + 1] = string.format("newmtl %s\nKd %.4f %.4f %.4f\nd %.3f\n\n", mat, c.R, c.G, c.B, 1 - part.Transparency)
		end
		local rel = origin:Inverse() * part.CFrame
		add(string.format("o %s_%d\nusemtl %s\n", (part.Name:gsub("%s", "_")), n, mat))
		for _, p in v do
			local w = rel * p
			add(string.format("v %.5f %.5f %.5f\n", w.X, w.Y, w.Z))
		end
		for _, face in f do
			local idx = {}
			for k, i in face do idx[k] = tostring(i + nverts) end
			add("f " .. table.concat(idx, " ") .. "\n")
		end
		nverts += #v
		written += 1
		if n % 200 == 0 then task.wait() end
	end
	flush()
	post("/mtl", fileName, table.concat(mtl))
	local summary = string.format("%d parts, %d vertices", written, nverts)
	post("/done", fileName, summary)
	return summary
end

local running = false
button.Click:Connect(function()
	if running then return end
	running = true
	button:SetActive(true)
	local ok, err = pcall(function()
		local alive = pcall(function() HttpService:GetAsync(URL .. "/ping") end)
		if not alive then
			error("the export server is not running: drag tools/art/roblox_export.sh into a terminal first")
		end
		local roots, used, skipped = {}, {}, {}
		for _, d in workspace:GetDescendants() do
			if d.Name:sub(1, #PREFIX) == PREFIX then roots[#roots + 1] = d end
		end
		if #roots == 0 then error("nothing in Workspace is named " .. PREFIX .. "…") end
		for _, root in roots do
			local fileName = root.Name
			used[fileName] = (used[fileName] or 0) + 1
			if used[fileName] > 1 then fileName ..= "_" .. used[fileName] end
			print("[Export_ to OBJ] " .. fileName .. ": " .. exportOne(root, fileName, skipped))
		end
		local report = string.format("[Export_ to OBJ] %d models written, %d parts skipped", #roots, #skipped)
		for _, line in skipped do report ..= "\n  skipped " .. line end
		post("/log", nil, report)
		if #skipped > 0 then warn(report) else print(report) end
	end)
	if not ok then warn("[Export_ to OBJ] " .. tostring(err)) end
	button:SetActive(false)
	running = false
end)
