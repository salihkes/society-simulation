extends RefCounted
## Snow depth and track simulation with its network packet format, apart from rendering.

## Track record: x, y, z, yaw, width, length, cut, snowfall at creation, time, kind (0 foot, 1 tyre).
const STRIDE := 10
const MAX_TRACKS := 32768
const MAX_AGE := 900.0
const MAX_DEPTH := 0.30

var depth := 0.0
var snowfall := 0.0
var elapsed := 0.0
var max_depth := 0.18
## Metres per real minute.
var accumulation := 0.006
var melt := 0.002
var command := ""
var epoch := ""
var last := 0
var first := 1
var records: Array[PackedFloat32Array] = []
var _sent := 0
var revision := 0


## Applies limits and rates; a new command id with a depth resets the cover.
func configure(config: Dictionary) -> void:
	max_depth = clampf(float(config.get("max_depth", max_depth)), 0.0, MAX_DEPTH)
	accumulation = clampf(float(config.get("rate", accumulation)), 0.0, 0.10)
	melt = clampf(float(config.get("melt", melt)), 0.0, 0.10)
	var id := str(config.get("command", ""))
	if id != "" and id != command:
		command = id
		if config.has("depth"):
			set_depth(float(config.depth))


## Resets the cover to value metres: a new epoch with no tracks.
func set_depth(value: float) -> void:
	depth = clampf(value, 0.0, MAX_DEPTH)
	max_depth = maxf(max_depth, depth)
	epoch = "%s-%s" % [Time.get_unix_time_from_system(), Time.get_ticks_usec()]
	records.clear()
	last = 0
	first = 1
	_sent = 0
	snowfall = 0.0
	revision += 1


## Accumulates or melts over delta seconds and drops expired tracks.
func advance(delta: float, snowing: bool) -> void:
	if epoch == "":
		set_depth(depth)
	elapsed += maxf(delta, 0.0)
	if snowing:
		var added := maxf(delta, 0.0) * accumulation / 60.0
		# Snowfall keeps burying tracks after depth reaches its cap.
		snowfall += added
		if depth < max_depth:
			depth = minf(max_depth, depth + added)
	else:
		depth = maxf(0.0, depth - maxf(delta, 0.0) * melt / 60.0)
	_prune()


## Drops tracks over MAX_TRACKS, older than MAX_AGE, buried by later snowfall, or with no snow.
func _prune() -> void:
	while not records.is_empty():
		var r := records[0]
		if records.size() <= MAX_TRACKS and elapsed - r[8] < MAX_AGE and snowfall - r[7] < r[6] and depth > 0.0001:
			break
		records.pop_front()
		first += 1
		revision += 1


## Does nothing without snow.
func stamp(position: Vector3, yaw: float, width: float, length: float, tire := false) -> void:
	if depth <= 0.001:
		return
	# A full-depth cut would expose the ground's differing render and collision surfaces.
	var cut := minf(depth * (0.72 if tire else 0.60), 0.16 if tire else 0.12)
	records.append(PackedFloat32Array([position.x, position.y, position.z, yaw,
		clampf(width, 0.05, 1.0), clampf(length, 0.08, 3.0), cut, snowfall, elapsed, 1.0 if tire else 0.0]))
	last += 1
	revision += 1
	_prune()


## The state with every record (full) or the records not yet sent.
func packet(full := false) -> Dictionary:
	var start := first if full else maxi(first, _sent + 1)
	var values := PackedFloat32Array()
	for i in range(maxi(0, start - first), records.size()):
		values.append_array(records[i])
	if not full:
		_sent = last
	return {"epoch": epoch, "first": first, "last": last, "start": start, "full": full,
		"data": Marshalls.raw_to_base64(values.to_byte_array()) if not values.is_empty() else "", "depth": depth,
		"fall": snowfall, "time": elapsed, "max": max_depth, "rate": accumulation,
		"melt": melt, "command": command}


## Adopts a valid packet, false if invalid, out of order or stale; full or new-epoch replaces all.
func apply_packet(data: Dictionary) -> bool:
	if not valid_packet(data):
		return false
	var incoming_epoch := str(data.epoch)
	var full := bool(data.get("full", false))
	var start := int(data.start)
	var end := int(data.last)
	var begin := int(data.first)
	if not full and incoming_epoch == epoch and start > last + 1:
		# The reliable stream is contiguous; wait for the missing records.
		return false
	if not full and incoming_epoch != epoch and start != begin:
		return false
	if incoming_epoch == epoch and (end < last or float(data.time) < elapsed - 0.001):
		return false
	var values := Marshalls.base64_to_raw(str(data.data)).to_float32_array() if str(data.data) != "" else PackedFloat32Array()
	if full or incoming_epoch != epoch:
		records.clear()
		first = start
		last = start - 1
		epoch = incoming_epoch
		revision += 1
	for n in values.size() / STRIDE:
		var id := start + n
		if id <= last:
			continue
		records.append(values.slice(n * STRIDE, (n + 1) * STRIDE))
		last = id
		revision += 1
	while first < begin and not records.is_empty():
		records.pop_front()
		first += 1
		revision += 1
	first = begin
	last = end
	depth = float(data.depth)
	snowfall = float(data.fall)
	elapsed = float(data.time)
	max_depth = float(data.get("max", 0.18))
	accumulation = float(data.get("rate", 0.006))
	melt = float(data.get("melt", 0.002))
	command = str(data.get("command", ""))
	# If this peer becomes the authority it sends only newer records.
	_sent = last
	return true


## Every key, finite in-range values, consistent ids and exactly the data the id range needs.
static func valid_packet(data: Dictionary) -> bool:
	for key in ["epoch", "first", "last", "start", "data", "depth", "fall", "time"]:
		if not data.has(key):
			return false
	for key in ["depth", "fall", "time", "max", "rate", "melt"]:
		if not is_finite(float(data.get(key, 0.0))):
			return false
	if float(data.depth) < 0.0 or float(data.depth) > MAX_DEPTH or float(data.fall) < 0.0 or float(data.time) < 0.0:
		return false
	var first_id := int(data.first)
	var last_id := int(data.last)
	var start_id := int(data.start)
	if first_id < 1 or last_id < first_id - 1 or start_id < first_id or start_id > last_id + 1 or last_id - first_id + 1 > MAX_TRACKS:
		return false
	if str(data.data).length() > MAX_TRACKS * STRIDE * 4 * 2:
		return false
	var raw := Marshalls.base64_to_raw(str(data.data)) if str(data.data) != "" else PackedByteArray()
	if raw.size() != (last_id - start_id + 1) * STRIDE * 4:
		return false
	for value in raw.to_float32_array():
		if not is_finite(value):
			return false
	return not bool(data.get("full", false)) or start_id == first_id
