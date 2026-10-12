extends Node2D
# ============================================================================
# PICO-8 "260927" (sako, daily carts) port for Godot 4
#
# What the original does:
#   An 8x8 grid of flat square tiles (16px each, centered on the screen) on a
#   white background. Every tile flips over in 3D like a card turning around
#   an axis in its own plane. Unlike the previous cart, each tile gets a fully
#   random flip axis (one of 8 directions), a random phase, and two random
#   face colors (PICO-8 colors 8..14), so the flipping looks chaotic.
#   Pressing X (PICO-8's ❎) generates a new random arrangement.
#
# Rendering approach:
#   Everything is drawn into a 128x128 Image (the PICO-8 screen). The
#   triangle filler is a line-by-line port of the original trifill(), so
#   it produces the same pixels. The image is then scaled to fit the viewport
#   and centered, so nothing is drawn outside the visible square.
# ============================================================================

# Size of the PICO-8 screen in pixels.
const SCREEN := 128

# Original gl=16: length of one animation cycle in seconds. Each tile flips
# twice per cycle (see p2 = p * 2 in _render).
const GL := 16.0

# Original ez=128: "eye z", the focal distance used for perspective.
const EZ := 128.0

# Original camera(-64,-64): shifts the origin to the screen center.
# We add this to every coordinate right before writing pixels.
const CAM := 64.0

# Default PICO-8 palette (indices 0..15). Only 7 and 8..14 are used here.
const PALETTE: Array[Color] = [
	Color8(0, 0, 0),         # 0  black
	Color8(29, 43, 83),      # 1  dark blue
	Color8(126, 37, 83),     # 2  dark purple
	Color8(0, 135, 81),      # 3  dark green
	Color8(171, 82, 54),     # 4  brown
	Color8(95, 87, 79),      # 5  dark grey
	Color8(194, 195, 199),   # 6  light grey
	Color8(255, 241, 232),   # 7  white (background, cls(7))
	Color8(255, 0, 77),      # 8  red
	Color8(255, 163, 0),     # 9  orange
	Color8(255, 236, 39),    # 10 yellow
	Color8(0, 228, 54),      # 11 green
	Color8(41, 173, 255),    # 12 blue
	Color8(131, 118, 156),   # 13 lavender
	Color8(255, 119, 168),   # 14 pink
	Color8(255, 204, 170),   # 15 peach
]

# Palette index of the background color.
const BG_INDEX := 7

# List of tiles. Each entry is a Dictionary with:
#   x, y : tile center (relative to the screen center)
#   c1   : color index of one face
#   c2   : color index of the other face (always different from c1)
#   a    : flip axis angle in turns (one of 8 directions: 0, 1/8, ... 7/8)
#   p    : phase offset in turns (0..1), random per tile
var _sqrs: Array[Dictionary] = []

var _image: Image            # the 128x128 "screen"
var _texture: ImageTexture   # texture uploaded from the image each frame
var _start_ms := 0           # start time, so t() begins at 0 like PICO-8
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

# PICO-8 atan2(dx, dy): result in turns (0..1), with y pointing DOWN on screen.
func _patan2(dx: float, dy: float) -> float:
	return fposmod(atan2(-dy, dx) / TAU, 1.0)

# PICO-8 sgn(): returns 1 for zero (Godot's sign() returns 0).
func _psgn(v: float) -> float:
	return 1.0 if v >= 0.0 else -1.0

# PICO-8 division: dividing by zero doesn't crash, it gives the largest
# representable number (about 32767.99) with the sign of the numerator.
func _pdiv(a: float, b: float) -> float:
	if b == 0.0:
		return 0.0 if a == 0.0 else _psgn(a) * 32767.99998
	return a / b


func _ready() -> void:
	_start_ms = Time.get_ticks_msec()
	_rng.randomize()

	# Create the 128x128 screen image and its texture.
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
# Tile generation (original gen())
# ---------------------------------------------------------------------------
func _gen() -> void:
	_sqrs.clear()

	# Original loops: y,x = 56,40,24,8 (descending by 16). Mirroring each
	# position with fx/fy in {-1, 1} fills all four quadrants: 8x8 tiles.
	for by in range(56, -1, -16):
		for bx in range(56, -1, -16):
			for fx in [-1, 1]:
				for fy in [-1, 1]:
					# First face color: random index 0..6 -> colors 8..14.
					# (original: 8 + rnd(7)\1)
					var c1o := _rng.randi() % 7

					# Second face color: offset from the first by 1..6 steps
					# (mod 7), so it can never equal the first color.
					# (original: 8 + (c1-7 + rnd(6)\1) % 7, where c1-7 = c1o+1)
					var c2o := (c1o + 1 + _rng.randi() % 6) % 7

					_sqrs.append({
						"x": float(bx * fx),
						"y": float(by * fy),
						"c1": 8 + c1o,
						"c2": 8 + c2o,
						# Flip axis: one of 8 directions (original rnd(8)\1/8).
						"a": float(_rng.randi() % 8) / 8.0,
						# Random phase in 0..1 (original rnd()).
						"p": _rng.randf(),
					})


# Rotates the 2D vector (dx, dy) by 'a' turns (original rot()).
func _rot(dx: float, dy: float, a: float) -> Vector2:
	var ca := _pcos(a)
	var sa := _psin(a)
	return Vector2(dx * ca - dy * sa, dx * sa + dy * ca)


func _process(_delta: float) -> void:
	# Re-render the "screen" every frame and request a redraw.
	_render()
	queue_redraw()


# ---------------------------------------------------------------------------
# Low-level pixel drawing
# ---------------------------------------------------------------------------

# Draws a 1-pixel-high horizontal run, like PICO-8's rectfill(x0,y,x1,y).
# Coordinates are in camera space (origin at screen center), floored to pixels,
# swapped if reversed, and clipped to the screen.
func _hline(x0: float, x1: float, y: float, col: Color) -> void:
	var py := int(floorf(y + CAM))
	if py < 0 or py >= SCREEN:
		return
	var a := int(floorf(x0 + CAM))
	var b := int(floorf(x1 + CAM))
	if a > b:
		var tmp := a
		a = b
		b = tmp
	a = maxi(a, 0)
	b = mini(b, SCREEN - 1)
	for px in range(a, b + 1):
		_image.set_pixel(px, py, col)


# Filled triangle, line-by-line port of the original trifill().
# It is written to match PICO-8's pixel coverage rules (sampling at pixel
# centers), so adjacent triangles share edges without gaps or overlap.
func _trifill(x0: float, y0: float, x1: float, y1: float,
		x2: float, y2: float, col: Color) -> void:
	var tmp: float

	# Sort the vertices by y so that y0 <= y1 <= y2.
	if y0 > y1:
		tmp = x0; x0 = x1; x1 = tmp
		tmp = y0; y0 = y1; y1 = tmp
	if y0 > y2:
		tmp = x0; x0 = x2; x2 = tmp
		tmp = y0; y0 = y2; y2 = tmp
	if y1 > y2:
		tmp = x1; x1 = x2; x2 = tmp
		tmp = y1; y1 = y2; y2 = tmp

	# Edge vectors: 0->1 (upper left/right), 0->2 (long edge), 1->2 (lower).
	var x01 := x1 - x0
	var y01 := y1 - y0
	var x02 := x2 - x0
	var y02 := y2 - y0
	var x12 := x2 - x1
	var y12 := y2 - y1

	# Slopes (x change per 1 y) of the three edges.
	var s01 := _pdiv(x01, y01)
	var s02 := _pdiv(x02, y02)
	var s12 := _pdiv(x12, y12)

	# --- Upper half: from vertex 0 down to vertex 1 ---

	# First and last scanline centers (y = pixel row + 0.5) of the upper half.
	var ys := floorf(y0 + 0.5) + 0.5
	var ye := floorf(y1 - 0.5) + 0.5

	# x of the long edge at the height of vertex 1 (used to tell whether the
	# middle vertex lies left or right of the long edge).
	var mx := x0 + _pdiv(x02 * y01, y02)

	# Distance from vertex 0 to the first scanline; shift x by half a pixel
	# so we sample at pixel centers.
	var y0s := ys - y0
	x0 += 0.5

	# Start x of the left/right edges at the first scanline.
	var xs := x0 + x01 * _pdiv(y0s, y01)
	var xe := x0 + x02 * _pdiv(y0s, y02)

	# Skip leading scanlines where both edges fall into the same pixel
	# (the triangle tip is too thin to cover any pixel center).
	while ys <= ye:
		if floorf(xs) != floorf(xe):
			break
		ys += 1.0
		xs += s01
		xe += s02

	# Fine adjustment so edges are included/excluded consistently, depending
	# on which side the middle vertex is on.
	var omh := _psgn(mx - x1) / 2.01 - 0.5
	var oph := omh + 1.0
	xs += omh
	xe -= oph

	# Fill the upper half scanline by scanline.
	var y := ys
	while y <= ye:
		_hline(xs, xe, y, col)
		xs += s01
		xe += s02
		y += 1.0

	# --- Lower half: from vertex 2 upward to vertex 1 ---
	# Same idea, but walking upward from the bottom vertex.
	ys = floorf(y2 - 0.5) + 0.5
	ye = floorf(y1 + 0.5) + 0.5
	var y2s := ys - y2
	x2 += 0.5
	xs = x2 + x12 * _pdiv(y2s, y12)
	xe = x2 + x02 * _pdiv(y2s, y02)

	# Skip trailing scanlines that are too thin to cover a pixel center.
	while ys >= ye:
		if floorf(xs) != floorf(xe):
			break
		ys -= 1.0
		xs -= s12
		xe -= s02

	xs += omh
	xe -= oph

	y = ys
	while y >= ye:
		_hline(xs, xe, y, col)
		xs -= s12
		xe -= s02
		y -= 1.0


# ---------------------------------------------------------------------------
# Frame rendering (the main loop of the original code)
# ---------------------------------------------------------------------------
func _render() -> void:
	# Global animation phase in turns. t() = seconds since start.
	var t := (Time.get_ticks_msec() - _start_ms) / 1000.0
	var gp := t / GL

	# cls(7): clear the screen with the white background.
	_image.fill(PALETTE[BG_INDEX])

	for sqr in _sqrs:
		# This tile's own phase (0..1), offset by its random phase.
		# fposmod matches PICO-8's floored modulo.
		var p := fposmod(gp - sqr["p"], 1.0)

		# The four corners of a 16x16 tile centered at the origin, z = 0.
		# Order matches the original loops: (8,-8), (-8,-8), (8,8), (-8,8).
		var pts: Array[Vector3] = [
			Vector3(8, -8, 0),
			Vector3(-8, -8, 0),
			Vector3(8, 8, 0),
			Vector3(-8, 8, 0),
		]

		# Flip angle in turns. The phase is doubled so there are two flips
		# per cycle. For each flip (p2 % 1) is clamped to .25 .. .75, so the
		# tile rests flat at the start and end of each flip and turns in
		# between; the sine eases the motion. floor(p2) adds half a turn on
		# the second flip so the tile continues rotating the same way.
		var p2 := p * 2.0
		var a := clampf(fposmod(p2, 1.0), 0.25, 0.75)
		a = 0.25 + _psin(a) / 4.0 + floorf(p2) / 2.0

		for i in 4:
			var pt := pts[i]

			# 1) Rotate the corner in the xy plane so the flip axis lines up
			#    with the y axis.
			var r := _rot(pt.x, pt.y, sqr["a"])
			pt.x = r.x
			pt.y = r.y

			# 2) Flip: rotate in the x/z plane by the flip angle.
			r = _rot(pt.x, pt.z, a)
			pt.x = r.x
			pt.z = r.y

			# 3) Rotate the xy plane back to the tile's original orientation.
			r = _rot(pt.x, pt.y, -sqr["a"])
			pt.x = r.x
			pt.y = r.y

			# 4) Move the corner to the tile's position on the grid.
			pt.x += sqr["x"]
			pt.y += sqr["y"]

			# 5) Perspective projection: points with larger z shrink toward
			#    the center, points with negative z grow.
			var s := EZ / (pt.z + EZ)
			pt.x *= s
			pt.y *= s

			pts[i] = pt

		var x1 := pts[0].x
		var y1 := pts[0].y
		var x2 := pts[1].x
		var y2 := pts[1].y
		var x3 := pts[2].x
		var y3 := pts[2].y
		var x4 := pts[3].x
		var y4 := pts[3].y

		# Winding test: compare the angles of edges 1->2 and 1->3. The sign of
		# their difference (wrapped to -0.5..0.5) tells whether we see the
		# front or the back of the tile, which selects the face color.
		var a1 := _patan2(x1 - x2, y1 - y2)
		var a2 := _patan2(x1 - x3, y1 - y3)
		var ad := fposmod(a2 - a1 + 0.5, 1.0) - 0.5

		var ci: int = sqr["c1"] if ad > 0.0 else sqr["c2"]
		var col := PALETTE[ci]

		# The projected tile is a quad; draw it as two triangles.
		_trifill(x1, y1, x2, y2, x4, y4, col)
		_trifill(x1, y1, x4, y4, x3, y3, col)

	# Upload the finished image to the GPU texture.
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
