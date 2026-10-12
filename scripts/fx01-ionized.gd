extends Node2D
# ============================================================================
# PICO-8 "260923" (sako, daily carts) port for Godot 4
#
# What the original does:
#   48 random points are scattered on the surface of a sphere. Each point is
#   connected to its two nearest neighbours, which gives a wireframe "ball"
#   made of anti-aliased lines. The ball rotates in 3D (with perspective) and
#   bobs up and down. In the middle sits a glass "bubble" (a lens) that
#   magnifies and brightens whatever is behind it. The lines on the far side
#   of the ball are drawn BEFORE the lens, so they appear through the glass,
#   and the lines on the near side are drawn AFTER it, on top.
#   Finally, 16 random scanlines per frame are shifted 1px left or right for a
#   small CRT-style glitch. Pressing X (PICO-8's ❎) generates a new ball.
#
# Rendering approach:
#   The screen is an array of 128x128 PALETTE INDICES (not colors), exactly
#   like PICO-8's screen memory. This matters because the line renderer adds
#   brightness to existing pixel values and the lens reads pixel values back.
#   At the end of each frame the indices are converted to RGBA, uploaded to a
#   texture, and drawn scaled and centered in the viewport (nothing is drawn
#   outside the 128x128 square).
# ============================================================================

# Size of the PICO-8 screen in pixels.
const SCREEN := 128

# Original gl=30: length of the full animation cycle in seconds.
const GL := 30.0

# Original ez=96: "eye z", the focal distance used for perspective.
const EZ := 96.0

# Original r=64: radius of the wireframe sphere.
const R := 64.0

# Number of random points on the sphere.
const POINT_COUNT := 48

# Original palette: mypal={-15,1,-13,3,-5,11,-6,-9,7}, applied to screen
# indices 0..8. Negative numbers select PICO-8's "secret" colors (128..143):
# -15 -> 129, -13 -> 131, -5 -> 139, -6 -> 138, -9 -> 135.
# The result is a dark-to-bright green/yellow/white ramp.
# Indices 9..15 are not remapped by the original, so they keep their default
# PICO-8 colors (index 9 can only show up if pixel values overflow the ramp).
const PALETTE: Array[Color] = [
	Color8(17, 29, 53),      # 0 -> 129 (very dark blue, background)
	Color8(29, 43, 83),      # 1 -> 1   dark blue
	Color8(18, 83, 89),      # 2 -> 131 dark teal
	Color8(0, 135, 81),      # 3 -> 3   dark green
	Color8(0, 181, 67),      # 4 -> 139 green
	Color8(0, 228, 54),      # 5 -> 11  bright green
	Color8(168, 231, 46),    # 6 -> 138 lime
	Color8(243, 239, 125),   # 7 -> 135 pale yellow
	Color8(255, 241, 232),   # 8 -> 7   white
	Color8(255, 163, 0),     # 9  default orange (not remapped)
	Color8(255, 236, 39),    # 10 default yellow
	Color8(0, 228, 54),      # 11 default green
	Color8(41, 173, 255),    # 12 default blue
	Color8(131, 118, 156),   # 13 default lavender
	Color8(255, 119, 168),   # 14 default pink
	Color8(255, 204, 170),   # 15 default peach
]

# Original hc=#mypal+.5: the highest value a line may add up to.
# It is 9.5 so that it survives rounding; pset floors it to 9.
const HC := 9.5

# Original cm=#mypal/2: converts perspective scale (0..1) into line brightness.
const CM := 4.5

# Radius of the lens bubble in the middle (original: bubble(64,...,27)).
const BUBBLE_R := 27.0

# The 3D points on the sphere surface (original: pts).
var _pts: Array[Vector3] = []

# For each point, the indices of its two nearest neighbours
# (original: lines[i] = {j=nearest, k=second nearest}). x = j, y = k.
var _links: Array[Vector2i] = []

# The screen: one palette index (0..15) per pixel.
var _screen := PackedByteArray()

# Lookup table for the lens: sqrt(1 - p^2) for p = i/256 (original: dlu).
var _dlu := PackedFloat32Array()

var _rgba := PackedByteArray()         # converted RGBA bytes for the texture
var _pal_bytes := PackedByteArray()    # PALETTE as raw RGBA bytes
var _image: Image
var _texture: ImageTexture
var _start_ms := 0                     # start time, so t() begins at 0
var _rng := RandomNumberGenerator.new()


# ---------------------------------------------------------------------------
# PICO-8 math helpers
# ---------------------------------------------------------------------------

# PICO-8 sin() takes turns (0..1 = full circle) and is inverted: sin(0.25) = -1.
func _psin(turns: float) -> float:
	return -sin(TAU * turns)

# PICO-8 cos() takes turns (0..1 = full circle).
func _pcos(turns: float) -> float:
	return cos(TAU * turns)

# PICO-8 sgn(): returns 1 for zero (Godot's sign() returns 0).
func _psgn(v: float) -> float:
	return 1.0 if v >= 0.0 else -1.0

# Rotates the 2D vector (dx, dy) by 'a' turns (original rot()).
func _rot(dx: float, dy: float, a: float) -> Vector2:
	var ca := _pcos(a)
	var sa := _psin(a)
	return Vector2(dx * ca - dy * sa, dx * sa + dy * ca)


func _ready() -> void:
	_start_ms = Time.get_ticks_msec()
	_rng.randomize()

	# Screen indices and the RGBA buffer used to upload them.
	_screen.resize(SCREEN * SCREEN)
	_rgba.resize(SCREEN * SCREEN * 4)

	# Convert PALETTE to raw bytes once, for fast per-pixel conversion.
	_pal_bytes.resize(PALETTE.size() * 4)
	for i in PALETTE.size():
		_pal_bytes[i * 4 + 0] = PALETTE[i].r8
		_pal_bytes[i * 4 + 1] = PALETTE[i].g8
		_pal_bytes[i * 4 + 2] = PALETTE[i].b8
		_pal_bytes[i * 4 + 3] = 255

	# Lens lookup table (original: dlu[i] = sqrt(1 - (i/256)^2), i = 0..256).
	_dlu.resize(257)
	for i in 257:
		var p := i / 256.0
		_dlu[i] = sqrt(maxf(1.0 - p * p, 0.0))

	_image = Image.create(SCREEN, SCREEN, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)

	# Nearest filtering keeps pixels sharp when scaled up.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	_gen()


# Original btnp(❎): PICO-8's ❎ button is the X or V key.
# Handled as a one-shot key press (key repeat ignored, like btnp).
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_X or event.keycode == KEY_V:
			_gen()


# ---------------------------------------------------------------------------
# Generation (original gen())
# ---------------------------------------------------------------------------
func _gen() -> void:
	_pts.clear()
	_links.clear()

	# --- Random points on the sphere surface ---
	# Pick random points in the cube [-1, 1)^3 until one lands inside the unit
	# sphere (rejection sampling gives a uniform distribution), then push it
	# out to the sphere surface of radius R by normalizing.
	for i in POINT_COUNT:
		var v := Vector3.ZERO
		var d := 0.0
		while true:
			v = Vector3(
				_rng.randf_range(-1.0, 1.0),
				_rng.randf_range(-1.0, 1.0),
				_rng.randf_range(-1.0, 1.0))
			# The original d3d() is just the 3D vector length.
			d = v.length()
			if d < 1.0 and d > 0.0001:
				break
		_pts.append(v / d * R)

	# --- Connect each point to its two nearest neighbours ---
	for i in _pts.size():
		var p1 := _pts[i]
		var md1 := INF   # smallest distance found so far
		var md2 := INF   # second smallest distance found so far
		var k := -1      # index of the nearest point
		var l := -1      # index of the second nearest point
		for j in _pts.size():
			if i == j:
				continue
			var d := (p1 - _pts[j]).length()
			if d < md1:
				# New nearest: the old nearest becomes the second nearest.
				md2 = md1
				md1 = d
				l = k
				k = j
			elif d < md2:
				# New second nearest.
				md2 = d
				l = j
		_links.append(Vector2i(k, l))


# ---------------------------------------------------------------------------
# Screen access (pset / pget / sget equivalents)
# ---------------------------------------------------------------------------

# pget(): returns the palette index at (x, y); 0 outside the screen.
func _pget(x: float, y: float) -> int:
	var px := int(floorf(x))
	var py := int(floorf(y))
	if px < 0 or px >= SCREEN or py < 0 or py >= SCREEN:
		return 0
	return _screen[py * SCREEN + px]


# pset(): sets one pixel. Coordinates and the (possibly fractional) color are
# floored; anything outside the screen is ignored (clipping).
func _pset(x: float, y: float, color: float) -> void:
	var px := int(floorf(x))
	var py := int(floorf(y))
	if px < 0 or px >= SCREEN or py < 0 or py >= SCREEN:
		return
	_screen[py * SCREEN + px] = int(floorf(color)) & 15


# ---------------------------------------------------------------------------
# Anti-aliased additive line (original aaline())
# ---------------------------------------------------------------------------
# For every step along the major axis, the line covers two neighbouring pixels
# across the minor axis. Each pixel gets brightness proportional to how much
# of it the line covers. The brightness is ADDED to what is already on the
# screen (capped at HC), so crossing lines glow brighter.
#   c : peak brightness of the line (in palette steps)
func _aaline(x1: float, y1: float, x2: float, y2: float, c: float) -> void:
	var dx := x2 - x1
	var dy := y2 - y1
	if dx == 0.0 and dy == 0.0:
		return   # zero-length line: nothing to draw

	if absf(dx) > absf(dy):
		# --- Mostly horizontal: step along x, one pixel column at a time ---
		var step := _psgn(dx)
		# Start at the center of the pixel that contains x1.
		var x := floorf(x1) + 0.5
		while (x <= x2) if step > 0.0 else (x >= x2):
			# Exact y of the line at this x.
			var y := y1 + dy * (x - x1) / dx
			# The line is 1px thick: it overlaps the pixel above and below
			# this y. ya/yb are the two rows; their fractional parts give
			# the coverage of each.
			var ya := y - 0.5
			var yb := y + 0.5
			var ca := floorf(c * (1.0 - fposmod(ya, 1.0)) + 0.5)
			var cb := floorf(c * fposmod(yb, 1.0) + 0.5)
			_pset(x, ya, minf(_pget(x, ya) + ca, HC))
			_pset(x, yb, minf(_pget(x, yb) + cb, HC))
			x += step
	else:
		# --- Mostly vertical: step along y, one pixel row at a time ---
		var step := _psgn(dy)
		var y := floorf(y1) + 0.5
		while (y <= y2) if step > 0.0 else (y >= y2):
			var x := x1 + dx * (y - y1) / dy
			var xa := x - 0.5
			var xb := x + 0.5
			var ca := floorf(c * (1.0 - fposmod(xa, 1.0)) + 0.5)
			var cb := floorf(c * fposmod(xb, 1.0) + 0.5)
			_pset(xa, y, minf(_pget(xa, y) + ca, HC))
			_pset(xb, y, minf(_pget(xb, y) + cb, HC))
			y += step


# ---------------------------------------------------------------------------
# Lens (original bubble())
# ---------------------------------------------------------------------------
# A round "glass ball" that magnifies the screen behind it. Each pixel inside
# the circle samples the screen at a point pulled toward the center (a fish-eye
# / sphere projection) and is brightened, with a little random per-row noise.
func _bubble(cx: float, cy: float, rad: float) -> void:
	# The original copies the affected screen region to a spare buffer
	# (sspr into 0x8000) and reads from that copy while drawing to the screen,
	# so the lens never samples pixels it has already changed.
	# A snapshot of the whole screen is equivalent.
	var snap := _screen.duplicate()

	var rr := rad - 0.5
	var rsqr := rad * rad

	# First and last scanline centers touched by the circle.
	var ys := floorf(cy - rr) + 0.5
	var ye := minf(floorf(cy + rr), 127.0) + 0.5

	var y := ys
	while y <= ye:
		var dy := y - cy

		# Half-width of the circle on this scanline.
		var xr := sqrt(maxf(rsqr - dy * dy, 0.0)) - 0.5
		var xs := floorf(cx - xr) + 0.5
		var xe := minf(floorf(cx + xr), 127.0) + 0.5

		# Brightening divisor, randomized slightly per scanline. This gives
		# the lens a subtle shimmering noise.
		var div := 1.625 + _rng.randf() * 0.25

		var x := xs
		while x <= xe:
			var dx := x - cx

			# Normalized distance from the lens center: 0 (middle) .. 1 (edge).
			var ds := sqrt(dx * dx + dy * dy) / rad

			# Sphere height at this distance: sqrt(1 - ds^2), from the table.
			var s := _dlu[clampi(int(floorf(ds * 256.0 + 0.5)), 0, 256)]

			# Source position: pulled toward the center by factor s, which
			# makes the content look magnified and curved.
			var sx := int(floorf(cx + dx * s))
			var sy := int(floorf(cy + dy * s))
			var c := 0
			if sx >= 0 and sx < SCREEN and sy >= 0 and sy < SCREEN:
				c = snap[sy * SCREEN + sx]

			# New value: move the old value toward HC (brighter), more so in
			# the middle where (s + ds) is largest. Floored by pset.
			_pset(x, y, HC + (c - HC) * (s + ds) / div)
			x += 1.0
		y += 1.0


# ---------------------------------------------------------------------------
# Glitch (the final sspr loop of the original)
# ---------------------------------------------------------------------------
# Copies a 96px wide piece of a random scanline from x=16 to x=15 or x=17,
# which shifts it one pixel sideways. Done for 16 random rows per frame.
func _glitch() -> void:
	for i in 16:
		var y := int(floorf(16.0 + _rng.randf() * 96.0))
		var dst_x := 15 if _rng.randi() % 2 == 0 else 17

		# Read the source run first, then write it (the two ranges overlap).
		var row := PackedByteArray()
		row.resize(96)
		for k in 96:
			row[k] = _screen[y * SCREEN + 16 + k]
		for k in 96:
			_screen[y * SCREEN + dst_x + k] = row[k]


func _process(_delta: float) -> void:
	# Re-render the "screen" every frame and request a redraw.
	_render()
	queue_redraw()


# ---------------------------------------------------------------------------
# Frame rendering (the main loop of the original code)
# ---------------------------------------------------------------------------
func _render() -> void:
	# Animation phase in turns (one full cycle every GL seconds).
	var t := (Time.get_ticks_msec() - _start_ms) / 1000.0
	var p := t / GL

	# cls(): clear to palette index 0.
	_screen.fill(0)

	# Vertical bobbing offsets. The lens (yo1) and the ball (yo2) bob with a
	# small phase difference, so the lens appears to lag behind the ball.
	var yo1 := _psin(p * 4.0) * 8.0
	var yo2 := _psin(p * 4.0 - 0.1) * 8.0

	# --- Rotate and project every point ---
	# Each entry: x, y = screen position, z = depth (0 = nearest, 128 = far),
	# w = perspective scale (bigger = closer).
	var ppts: Array[Vector4] = []
	for pt in _pts:
		var x := pt.x
		var y := pt.y
		var z := pt.z

		# Spin around the vertical axis (2 turns per cycle).
		var r1 := _rot(x, z, p * 2.0)
		x = r1.x
		z = r1.y

		# Tumble around the horizontal axis (1 turn per cycle).
		var r2 := _rot(y, z, p)
		y = r2.x
		z = r2.y

		# Push the ball away from the camera so z is always >= 0, then bob it.
		z += R
		y += yo2

		# Perspective: farther points (larger z) shrink toward the center.
		var s := EZ / (z + EZ)
		ppts.append(Vector4(64.0 + x * s, 64.0 + y * s, z, s))

	# --- Build the line lists ---
	# Each point has two lines (to its two nearest neighbours). A line goes in
	# the "back" list if its average depth is behind the sphere's center, and
	# in the "front" list otherwise. Entries: [x1, y1, x2, y2, brightness].
	var back: Array[PackedFloat32Array] = []
	var front: Array[PackedFloat32Array] = []

	for i in _links.size():
		var p1 := ppts[i]
		var p2 := ppts[_links[i].x]
		var p3 := ppts[_links[i].y]

		# Brightness grows with the perspective scale of both end points, so
		# nearer lines are brighter and distant ones fade out.
		var c1 := (p1.w + p2.w) * CM
		var c2 := (p1.w + p3.w) * CM

		var z1 := (p1.z + p2.z) / 2.0
		var z2 := (p1.z + p3.z) / 2.0

		var l1 := PackedFloat32Array([p1.x, p1.y, p2.x, p2.y, c1])
		var l2 := PackedFloat32Array([p1.x, p1.y, p3.x, p3.y, c2])

		if z1 > R:
			back.append(l1)
		else:
			front.append(l1)
		if z2 > R:
			back.append(l2)
		else:
			front.append(l2)

	# 1) Far-side lines first, so they appear behind the lens...
	for l in back:
		_aaline(l[0], l[1], l[2], l[3], l[4])

	# 2) ...then the lens, which distorts what has been drawn so far...
	var s_center := EZ / (R + EZ)
	_bubble(64.0, 64.0 + yo1 * s_center, BUBBLE_R)

	# 3) ...then the near-side lines on top of the lens.
	for l in front:
		_aaline(l[0], l[1], l[2], l[3], l[4])

	# 4) Final scanline glitch.
	_glitch()

	_upload()


# Converts the index screen to RGBA and uploads it to the texture.
func _upload() -> void:
	for i in SCREEN * SCREEN:
		var k: int = _screen[i] * 4
		var o := i * 4
		_rgba[o] = _pal_bytes[k]
		_rgba[o + 1] = _pal_bytes[k + 1]
		_rgba[o + 2] = _pal_bytes[k + 2]
		_rgba[o + 3] = 255
	_image.set_data(SCREEN, SCREEN, false, Image.FORMAT_RGBA8, _rgba)
	_texture.update(_image)


func _draw() -> void:
	# --- Fit the 128x128 screen into the viewport, centered ---
	var vp := get_viewport_rect().size
	var scale_f := minf(vp.x, vp.y) / float(SCREEN)             # uniform scale
	var size := Vector2(SCREEN, SCREEN) * scale_f
	var origin := (vp - size) * 0.5                             # top-left of the square

	# Black bars if the viewport isn't square.
	draw_rect(Rect2(Vector2.ZERO, vp), Color.BLACK)

	# The image itself, scaled up with nearest filtering.
	draw_texture_rect(_texture, Rect2(origin, size), false)
