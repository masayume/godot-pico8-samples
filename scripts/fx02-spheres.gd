extends Node2D
# ============================================================================
# PICO-8 "260922" (sako, daily carts) port for Godot 4
#
# What the original does:
#   A smooth green -> white -> blue -> navy gradient fills the screen. It is
#   made of big concentric circles drawn with 2-color dither patterns, so the
#   shades blend without banding. Six glass "bubbles" (lenses) orbit the
#   center. Each one magnifies and bends the gradient behind it and fades
#   toward white in its middle. The bubbles also pulse in size as they orbit.
#
# Rendering approach:
#   The screen is an array of 128x128 PALETTE INDICES, like PICO-8's screen
#   memory, because the lens reads pixel values back and does arithmetic on
#   them. The gradient is generated once. Each frame we start from a copy of
#   it, draw the six bubbles, and upload the result to a texture, which is
#   scaled and centered in the viewport (nothing is drawn outside the
#   128x128 square).
# ============================================================================

# Size of the PICO-8 screen in pixels.
const SCREEN := 128

# Original gl=16: length of the animation cycle in seconds.
const GL := 16.0

# Number of entries in the original mypal (it drives the gradient length).
const MYPAL_COUNT := 10

# Original fpats: 4x4 dither patterns, 16 bits each, top-left pixel = top bit.
# A 0 bit draws the low-nibble color, a 1 bit draws the high-nibble color.
#   0x0000 -> 0%  of the second color
#   0x0a0a -> 25%
#   0x5a5a -> 50% (checkerboard)
#   0x5f5f -> 75%
const FPATS: Array[int] = [0x0000, 0x0a0a, 0x5a5a, 0x5f5f]

# Original palette: mypal={-13,3,-5,11,-6,7,6,12,-4,1}.
# IMPORTANT: pal(table) maps table[1] to screen index 1, table[2] to index 2,
# and so on (the table's keys ARE the indices), so index 0 keeps its default.
# Negative numbers select PICO-8's "secret" colors (-13 -> 131, -5 -> 139,
# -6 -> 138, -4 -> 140).
# Screen index -> actual color:
const PALETTE: Array[Color] = [
	Color8(0, 0, 0),         # 0  default black (unused)
	Color8(18, 83, 89),      # 1  -> -13 = 131 dark teal   (bottom of screen)
	Color8(0, 135, 81),      # 2  ->   3 dark green
	Color8(0, 181, 67),      # 3  ->  -5 = 139 green
	Color8(0, 228, 54),      # 4  ->  11 bright green
	Color8(168, 231, 46),    # 5  ->  -6 = 138 lime
	Color8(255, 241, 232),   # 6  ->   7 white             (lens center)
	Color8(194, 195, 199),   # 7  ->   6 light grey
	Color8(41, 173, 255),    # 8  ->  12 blue
	Color8(6, 90, 181),      # 9  ->  -4 = 140 dark blue
	Color8(29, 43, 83),      # 10 ->   1 dark navy         (top of screen)
	Color8(0, 228, 54),      # 11 default green (not remapped)
	Color8(41, 173, 255),    # 12 default blue
	Color8(131, 118, 156),   # 13 default lavender
	Color8(255, 119, 168),   # 14 default pink
	Color8(255, 204, 170),   # 15 default peach
]

# The screen: one palette index (0..15) per pixel.
var _screen := PackedByteArray()
# The pre-rendered gradient background, as indices and as RGBA bytes.
var _bg := PackedByteArray()
var _bg_rgba := PackedByteArray()
# RGBA bytes of the current frame (starts as a copy of _bg_rgba).
var _rgba := PackedByteArray()
# PALETTE as raw RGBA bytes, for fast writes.
var _pal_rgba := PackedByteArray()

# Lens lookup table (original dlu): 1 - p^3 for p = i/256, i = 0..256.
var _dlu := PackedFloat32Array()

var _image: Image
var _texture: ImageTexture
var _start_ms := 0   # start time, so t() begins at 0 like PICO-8


# ---------------------------------------------------------------------------
# PICO-8 math helpers
# ---------------------------------------------------------------------------

# PICO-8 sin() takes turns (0..1 = full circle) and is inverted: sin(0.25) = -1.
func _psin(turns: float) -> float:
	return -sin(TAU * turns)

# PICO-8 cos() takes turns (0..1 = full circle).
func _pcos(turns: float) -> float:
	return cos(TAU * turns)


func _ready() -> void:
	_start_ms = Time.get_ticks_msec()

	_screen.resize(SCREEN * SCREEN)
	_rgba.resize(SCREEN * SCREEN * 4)

	# Convert PALETTE to raw bytes once.
	_pal_rgba.resize(PALETTE.size() * 4)
	for i in PALETTE.size():
		_pal_rgba[i * 4 + 0] = PALETTE[i].r8
		_pal_rgba[i * 4 + 1] = PALETTE[i].g8
		_pal_rgba[i * 4 + 2] = PALETTE[i].b8
		_pal_rgba[i * 4 + 3] = 255

	# Lens lookup table (original: dlu[i] = 1 - p^3).
	_dlu.resize(257)
	for i in 257:
		var p := i / 256.0
		_dlu[i] = 1.0 - p * p * p

	_build_background()

	_image = Image.create(SCREEN, SCREEN, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)

	# Nearest filtering keeps pixels sharp when scaled up.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


# ---------------------------------------------------------------------------
# Gradient background (the setup loop of the original)
# ---------------------------------------------------------------------------
# The original draws circles of radius 131 down to 64, all centered at
# (32, -64) on a hidden 128x128 page, largest first, so each pixel ends up with
# the color of the SMALLEST circle that covers it. Each circle has a color
# value like 3.75, which means "mostly color 3 with some color 4": the integer
# part is the lower color, the fraction picks one of four dither patterns.
# Only the top-left 64x64 part of that page is ever shown (the original
# stretches it 2x to fill the screen), so we only compute that part.
func _build_background() -> void:
	var quad := PackedByteArray()
	quad.resize(64 * 64)

	var radius_range := 131 - 64

	for py in 64:
		for px in 64:
			# Distance from this pixel to the circle center (32, -64).
			var dx := px - 32
			var dy := py + 64
			var d2 := dx * dx + dy * dy

			# Smallest integer radius whose circle covers this pixel.
			var r := int(sqrt(float(d2)))
			if r * r < d2:
				r += 1
			r = clampi(r, 64, 131)

			# Progress 0..1 from the smallest circle to the largest.
			var prog := float(r - 64) / float(radius_range)

			# Color value: 10.25 at the top, falling to 1.25 at the bottom.
			var c := float(MYPAL_COUNT) + 0.25 - float(MYPAL_COUNT - 1) * prog

			# Dither pattern from the fractional part (0..3).
			var fp := int(floorf(fposmod(c, 1.0) * FPATS.size()))

			# Two colors: the integer part and the next one up.
			var lo := int(floorf(c))
			var hi := int(floorf(c + 1.0))

			# Pattern bit for this pixel position: bit 15 is the top-left
			# pixel of the 4x4 tile, bit 0 the bottom-right.
			var bit := (FPATS[fp] >> (15 - ((py & 3) * 4 + (px & 3)))) & 1

			quad[py * 64 + px] = hi if bit == 1 else lo

	# Stretch the 64x64 part 2x to fill the 128x128 screen
	# (original: sspr(0,0,64,64,0,0,128,128)).
	_bg.resize(SCREEN * SCREEN)
	_bg_rgba.resize(SCREEN * SCREEN * 4)
	for y in SCREEN:
		for x in SCREEN:
			var idx: int = quad[(y >> 1) * 64 + (x >> 1)] & 15
			var i := y * SCREEN + x
			_bg[i] = idx
			_bg_rgba[i * 4 + 0] = _pal_rgba[idx * 4 + 0]
			_bg_rgba[i * 4 + 1] = _pal_rgba[idx * 4 + 1]
			_bg_rgba[i * 4 + 2] = _pal_rgba[idx * 4 + 2]
			_bg_rgba[i * 4 + 3] = 255


# ---------------------------------------------------------------------------
# Screen access
# ---------------------------------------------------------------------------

# pset(): sets one pixel. Coordinates and the (possibly fractional) color are
# floored; anything outside the screen is ignored (clipping). Writes both the
# palette index and the final RGBA bytes, so no full-screen conversion is
# needed each frame.
func _pset(x: float, y: float, color: float) -> void:
	var px := int(floorf(x))
	var py := int(floorf(y))
	if px < 0 or px >= SCREEN or py < 0 or py >= SCREEN:
		return
	var idx := int(floorf(color)) & 15
	var i := py * SCREEN + px
	_screen[i] = idx
	var o := i * 4
	var k := idx * 4
	_rgba[o] = _pal_rgba[k]
	_rgba[o + 1] = _pal_rgba[k + 1]
	_rgba[o + 2] = _pal_rgba[k + 2]
	_rgba[o + 3] = 255


# ---------------------------------------------------------------------------
# Lens (original bubble())
# ---------------------------------------------------------------------------
# A round "glass ball". Each pixel inside the circle looks up the screen at a
# point pulled toward the circle's center (stronger toward the middle), which
# magnifies and curves the picture. The looked-up color is then blended toward
# palette value 6.5 (white) the closer the pixel is to the center.
func _bubble(cx: float, cy: float, rad: float) -> void:
	# The original copies the affected screen region to a spare page (sspr with
	# poke(0x5f54/0x5f55)) and reads from that copy while drawing, so the lens
	# never samples pixels it has already changed. A snapshot is equivalent.
	var snap := _screen.duplicate()

	var rr := rad - 0.5
	var rsqr := rad * rad

	# First and last scanline centers touched by the circle (clamped to the
	# screen; the original max(x) / min(x, 127) calls).
	var ys := maxf(floorf(cy - rr), 0.0) + 0.5
	var ye := minf(floorf(cy + rr), 127.0) + 0.5

	var y := ys
	while y <= ye:
		var dy := y - cy

		# Half-width of the circle on this scanline.
		var xr := sqrt(maxf(rsqr - dy * dy, 0.0)) - 0.5
		var xs := maxf(floorf(cx - xr), 0.0) + 0.5
		var xe := minf(floorf(cx + xr), 127.0) + 0.5

		var x := xs
		while x <= xe:
			var dx := x - cx

			# Normalized distance from the lens center: 0 (middle) .. 1 (edge).
			var ds := sqrt(dx * dx + dy * dy) / rad

			# Lens profile from the table: 1 at the center, 0 at the edge.
			var s := _dlu[clampi(int(floorf(ds * 256.0 + 0.5)), 0, 256)]

			# Source position: pulled toward the center by factor s.
			var sx := int(floorf(cx + dx * s))
			var sy := int(floorf(cy + dy * s))
			var c := 0
			if sx >= 0 and sx < SCREEN and sy >= 0 and sy < SCREEN:
				c = snap[sy * SCREEN + sx]

			# Blend the sampled color toward 6.5 (white) near the center:
			# ds = 0 -> 6.5, ds = 1 -> the sampled color. Floored by pset.
			_pset(x, y, 6.5 + (c - 6.5) * ds)
			x += 1.0
		y += 1.0


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

	# Start every frame from the gradient (the original redraws it with sspr).
	_screen = _bg.duplicate()
	_rgba = _bg_rgba.duplicate()

	# Six bubbles orbit the center, evenly spaced around the circle.
	for ao in 6:
		# Orbit angle in turns: slowly rotating, offset per bubble.
		var a := -p / 2.0 + ao / 6.0

		# The radius pulses between 6 and 18 as the bubble travels.
		var r := 12.0 - _psin(a - p) * 6.0

		# Orbit distance grows with the radius, so bubbles never touch
		# the center.
		var d := 24.0 + r

		_bubble(64.0 + _pcos(a) * d, 64.0 + _psin(a) * d, r)

	# Upload the finished frame to the GPU texture.
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