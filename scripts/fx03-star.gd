extends Node2D
# ============================================================================
# PICO-8 "260921" (sako, daily carts) port for Godot 4
#
# What the original does:
#   The screen is covered by a 32x32 grid of 4x4 cells. Each cell holds four
#   tiny 3-pixel line segments, and the cell's angle alternates in 90-degree
#   steps from cell to cell, which gives a woven, basket-like texture. The
#   segments are shaded by a wave (a phase per segment based on the angle
#   and the distance from the center) that sweeps over the screen. Shading
#   uses a 5-color ramp plus 2-color dither patterns (fillp) for smooth
#   in-between tones. Segments farther from the center are pushed to
#   a different phase, which warps the wave into a swirl.
#
# Rendering approach:
#   Everything is drawn into a 128x128 buffer of RGBA bytes. The segments are
#   static, so their pixel positions are baked once in _ready(). Each frame
#   only picks a color for each segment and writes its pixels, applying the
#   dither pattern by absolute screen position, just like fillp does. The
#   result is scaled and centered in the viewport (nothing is drawn outside
#   the 128x128 square).
# ============================================================================

# Size of the PICO-8 screen in pixels.
const SCREEN := 128

# Original gl=16 and the "*3" in p=t()/gl*3: the wave speed in turns/second.
const GL := 16.0
const WAVE_TURNS := 3.0

# Original ez=128: "eye z", used to shape the swirl.
const EZ := 128.0

# Original size=4: cell size in pixels.
const CELL := 4

# Original mypal={[0]=1,-4,13,14,10}. pal(table) maps the table's KEYS to
# screen indices, so this table (keys 0..4) remaps indices 0..4. Negative
# numbers are PICO-8's "secret" colors (-4 -> 140). Indices 5..15 keep their
# default colors; index 5 can be touched by the dither when the ramp tops out.
const PALETTE: Array[Color] = [
	Color8(29, 43, 83),      # 0 -> 1   dark navy (background, cls())
	Color8(6, 90, 181),      # 1 -> -4 = 140 dark blue
	Color8(131, 118, 156),   # 2 -> 13  lavender
	Color8(255, 119, 168),   # 3 -> 14  pink
	Color8(255, 236, 39),    # 4 -> 10  yellow
	Color8(95, 87, 79),      # 5 default dark grey
	Color8(194, 195, 199),   # 6 default light grey
	Color8(255, 241, 232),   # 7 default white
	Color8(255, 0, 77),      # 8 default red
	Color8(255, 163, 0),     # 9 default orange
	Color8(255, 236, 39),    # 10 default yellow
	Color8(0, 228, 54),      # 11 default green
	Color8(41, 173, 255),    # 12 default blue
	Color8(131, 118, 156),   # 13 default lavender
	Color8(255, 119, 168),   # 14 default pink
	Color8(255, 204, 170),   # 15 default peach
]

# Original fpats={[0]=0,0x5050,0x5a5a,0xfafa}: four 4x4 dither patterns, 16
# bits each. A 0 bit shows the LOW color of the pair, a 1 bit the HIGH color.
# Bit 15 is the top-left pixel of the 4x4 tile, bit 0 the bottom-right.
const FPATS: Array[int] = [0x0000, 0x5050, 0x5a5a, 0xfafa]

# Number of colors in the ramp: #mypal = 4 (the [0] entry is not counted).
const MYPAL_LEN := 4

# Derived constants of the original:
#   cr  = #mypal/2          : amplitude of the wave in color steps
#   c1c = cr + .5 - #fpats/pats/2 : center of the wave in color steps
# (#fpats = 3 and pats = #fpats + 1 = 4, since the [0] entry is not counted.)
const CR := MYPAL_LEN / 2.0
const C1C := CR + 0.5 - 3.0 / 4.0 / 2.0   # = 2.125

# Baked data, one entry per segment (same order as the original, which is also
# the drawing order, so later segments overwrite earlier ones).
var _pixels: Array[PackedInt32Array] = []   # x,y pairs of each segment's pixels
var _phases := PackedFloat32Array()         # phase offset of each segment

var _rgba := PackedByteArray()
var _pal_rgba := PackedByteArray()
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

# PICO-8 atan2(dx, dy): result in turns (0..1), with y pointing DOWN on screen.
func _patan2(dx: float, dy: float) -> float:
	return fposmod(atan2(-dy, dx) / TAU, 1.0)


func _ready() -> void:
	_start_ms = Time.get_ticks_msec()

	_rgba.resize(SCREEN * SCREEN * 4)

	# Convert PALETTE to raw bytes once, for fast pixel writes.
	_pal_rgba.resize(PALETTE.size() * 4)
	for i in PALETTE.size():
		_pal_rgba[i * 4 + 0] = PALETTE[i].r8
		_pal_rgba[i * 4 + 1] = PALETTE[i].g8
		_pal_rgba[i * 4 + 2] = PALETTE[i].b8
		_pal_rgba[i * 4 + 3] = 255

	_image = Image.create(SCREEN, SCREEN, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)

	# Nearest filtering keeps pixels sharp when scaled up.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	_build_lines()


# ---------------------------------------------------------------------------
# Segment setup (the setup loops of the original)
# ---------------------------------------------------------------------------
func _build_lines() -> void:
	var hl := CELL / 2.0 - 0.5   # half-length of a segment = 1.5

	# 'a' is the orientation (in turns) of the current cell. It grows by a
	# quarter turn per cell and per row, so neighbouring cells are rotated
	# by 90 degrees from each other, which creates the woven pattern.
	var a := 0.0

	# Cell centers: 2, 6, 10 ... 126 in both directions (32 x 32 cells).
	for gy in range(CELL / 2, 129, CELL):
		for gx in range(CELL / 2, 129, CELL):
			# Four parallel segments per cell, spread along the cell's
			# orientation: offsets -1.5, -0.5, 0.5, 1.5.
			for oi in range(4):
				var o := -hl + oi

				# Center of this segment.
				var x := gx + _pcos(a) * o
				var y := gy + _psin(a) * o

				# Distance and angle (turns) of the segment from the screen
				# center (64, 64).
				var dx := x - 64.0
				var dy := y - 64.0
				var cd := sqrt(dx * dx + dy * dy)
				var ca := _patan2(dx, dy)

				# Perspective-like scale: small near the center, growing
				# quickly toward the edges (distance to the 4th power).
				var s := 0.25 + pow(cd / 48.0, 4.0)

				# Depth of the segment under that scale.
				var z := EZ / s - EZ

				# The segment itself runs perpendicular to the offset
				# direction (a + 0.25 turns), 3 pixels long.
				var la := a + 0.25
				var x1 := x - _pcos(la) * hl
				var y1 := y - _psin(la) * hl
				var x2 := x + _pcos(la) * hl
				var y2 := y + _psin(la) * hl

				# Phase offset: depends on depth (distance), on the angle
				# around the center, and on a small 5-fold angular ripple.
				# This makes the wave a swirl instead of a plain ring.
				_phases.append(-z / 256.0 - ca + _psin(ca * 5.0) / 4.0)
				_pixels.append(_bake_line(x1, y1, x2, y2))

			# Next cell is rotated by a quarter turn.
			a += 0.25
		# Extra quarter turn at the end of each row.
		a += 0.25


# Computes the pixels of a line like PICO-8's line(): both end points are
# floored to whole pixels, and both are drawn. Pixels outside the screen are
# dropped here, so nothing is ever written outside the 128x128 area.
# Returns a flat array [x0, y0, x1, y1, ...].
func _bake_line(fx1: float, fy1: float, fx2: float, fy2: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var x0 := int(floorf(fx1))
	var y0 := int(floorf(fy1))
	var x1 := int(floorf(fx2))
	var y1 := int(floorf(fy2))

	# Bresenham line, end points included.
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	while true:
		if x0 >= 0 and x0 < SCREEN and y0 >= 0 and y0 < SCREEN:
			out.append(x0)
			out.append(y0)
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
	return out


func _process(_delta: float) -> void:
	# Re-render the "screen" every frame and request a redraw.
	_render()
	queue_redraw()


# Writes one pixel from a palette index.
func _put(x: int, y: int, idx: int) -> void:
	var o := (y * SCREEN + x) * 4
	var k := (idx & 15) * 4
	_rgba[o] = _pal_rgba[k]
	_rgba[o + 1] = _pal_rgba[k + 1]
	_rgba[o + 2] = _pal_rgba[k + 2]
	_rgba[o + 3] = 255


# ---------------------------------------------------------------------------
# Frame rendering (the main loop of the original code)
# ---------------------------------------------------------------------------
func _render() -> void:
	# Global wave phase in turns.
	var t := (Time.get_ticks_msec() - _start_ms) / 1000.0
	var p := t / GL * WAVE_TURNS

	# cls(): clear to palette index 0 (dark navy).
	for i in SCREEN * SCREEN:
		var o := i * 4
		_rgba[o] = _pal_rgba[0]
		_rgba[o + 1] = _pal_rgba[1]
		_rgba[o + 2] = _pal_rgba[2]
		_rgba[o + 3] = 255

	for i in _pixels.size():
		# This segment's phase (0..1) in the wave.
		var pd := fposmod(p - _phases[i], 1.0)

		# Color value along the ramp: swings around C1C by +-CR. The integer
		# part picks the ramp color, the fractional part is dithered.
		var c := C1C + _psin(pd) * CR

		# Dither pattern 0..3 from the fraction (original: c%1*pats\1).
		var fp := int(fposmod(c, 1.0) * 4.0)
		var pat: int = FPATS[fp]

		# The color pair: low = floor(c), high = floor(c + 1).
		# 0 pattern bits draw 'lo', 1 bits draw 'hi'.
		var lo := int(floorf(c))
		var hi := int(floorf(c + 1.0))

		var px := _pixels[i]
		for k in range(0, px.size(), 2):
			var x := px[k]
			var y := px[k + 1]
			# fillp is applied by ABSOLUTE screen position: the pattern is a
			# 4x4 tile repeated over the whole screen.
			var bit := (pat >> (15 - ((y & 3) * 4 + (x & 3)))) & 1
			_put(x, y, hi if bit == 1 else lo)

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