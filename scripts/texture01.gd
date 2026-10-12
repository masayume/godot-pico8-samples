extends Node2D
# ============================================================================
# PICO-8 "260908" (sako, daily carts) port for Godot 4
#
# What the original does:
#   A grid of 8x8 cells, each containing 11 short diagonal line segments
#   ("slats"). Every slat has a phase based on its angle and distance from the
#   screen center. Over time each slat's length oscillates through zero and
#   flips sign, which makes the diagonals look like they fold and flip in a
#   wave radiating from the center.
#
# Slat ends are drawn with a slightly different palette index depending on the
# fractional part of their position, which acts as cheap anti-aliasing.
#
# Rendering approach:
#   We draw into a 128x128 Image (the PICO-8 screen), upload it to a texture
#   each frame, and draw that texture scaled and centered in the viewport.
#   Writing pixels by hand gives exact pset() behavior and makes sure nothing
#   is ever drawn outside the 128x128 area.
# ============================================================================

# Size of the PICO-8 screen in pixels.
const SCREEN := 128

# Original variable gl=16: the animation cycle length in seconds.
const GL := 16.0

# Palette. The original calls pal({8,14,15,7,6,12,-4},1), which remaps screen
# colors 0..6. Index 7 is left at its default (white).
# Screen index -> actual color:
const PALETTE: Array[Color] = [
	Color8(255, 0, 77),      # 0 -> PICO-8 color 8  (red, unused in practice)
	Color8(255, 119, 168),   # 1 -> color 14 (pink)
	Color8(255, 204, 170),   # 2 -> color 15 (peach)
	Color8(255, 241, 232),   # 3 -> color 7  (white)
	Color8(194, 195, 199),   # 4 -> color 6  (light grey), also the background
	Color8(41, 173, 255),    # 5 -> color 12 (blue)
	Color8(6, 90, 181),      # 6 -> color -4, i.e. secret palette color 140 (dark blue)
	Color8(255, 241, 232),   # 7 -> default color 7 (white)
]

# Background palette index (cls(4)).
const BG_INDEX := 4

# Per-line data, stored in parallel arrays (one entry per slat).
# The original uses a table {x, y, s, d, p} for each line.
var _lx := PackedFloat32Array()  # x position of the slat's center
var _ly := PackedFloat32Array()  # y position of the slat's center
var _ls := PackedFloat32Array()  # slope direction: +1 or -1
var _ld := PackedFloat32Array()  # maximum half-length of the slat
var _lp := PackedFloat32Array()  # phase offset, in turns (0..1 = one cycle)

var _image: Image            # the 128x128 "screen"
var _texture: ImageTexture   # texture uploaded from the image each frame
var _start_ms := 0           # time of start, so t() begins at 0 like PICO-8


# ---------------------------------------------------------------------------
# PICO-8 math helpers
# ---------------------------------------------------------------------------

# PICO-8 sin() takes turns (0..1 = full circle) and is inverted (sin(0.25) = -1).
func _psin(turns: float) -> float:
	return -sin(TAU * turns)

# PICO-8 sgn() returns 1 for zero (unlike Godot's sign(), which returns 0).
func _psgn(v: float) -> float:
	return 1.0 if v >= 0.0 else -1.0


func _ready() -> void:
	_start_ms = Time.get_ticks_msec()

	# Create the 128x128 screen image and its texture.
	_image = Image.create(SCREEN, SCREEN, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)

	# Nearest filtering keeps the pixels sharp when scaled up.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	_build_lines()


# Builds the list of slats (the setup loops at the top of the original code).
func _build_lines() -> void:
	# s alternates between -1 and 1 and decides the slope direction of the
	# slats in each cell, producing a checkerboard of "/" and "\" cells.
	var s := -1.0

	# y goes 8, 24, ... 120 and x the same (original: for y=8,128,16).
	for cy in range(8, 129, 16):
		for cx in range(8, 129, 16):
			# 11 slats per cell, laid out along the cell's anti-diagonal.
			for o in range(-5, 6):
				var x := cx - o * 1.5
				var y := cy + o * 1.5 * s

				# Original da(): returns the distance and the angle (in turns)
				# of the vector from the screen center (64, 64).
				# PICO-8's atan2(dx, dy) has y pointing down, so the equivalent
				# in standard math is atan2(-dy, dx), wrapped into 0..1 turns.
				var dx := x - 64.0
				var dy := y - 64.0
				var dist := sqrt(dx * dx + dy * dy)
				var a := fposmod(atan2(-dy, dx) / TAU, 1.0)

				_lx.append(x)
				_ly.append(y)
				_ls.append(s)
				# Slats near the middle of the cell are longer than the ends.
				_ld.append(8.0 - absf(o) * 1.5)
				# Phase depends on distance and angle, so the animation wave
				# sweeps around and outward from the center.
				_lp.append(dist / 128.0 - a)

			# Flip the slope direction after every cell...
			s *= -1.0
		# ...and once more after every row so rows alternate as well.
		s *= -1.0


func _process(_delta: float) -> void:
	# Re-render the "screen" every frame and request a redraw.
	_render()
	queue_redraw()


# Sets one pixel of the 128x128 screen. Coordinates are floored like pset(),
# and anything outside the screen is ignored (clipping).
# 'color' is a possibly fractional PICO-8 color value; the fraction is dropped
# and the result is used as an index into PALETTE.
func _pset(x: float, y: float, color: float) -> void:
	var px := int(floorf(x))
	var py := int(floorf(y))
	if px < 0 or px >= SCREEN or py < 0 or py >= SCREEN:
		return
	var idx := clampi(int(floorf(color)), 0, PALETTE.size() - 1)
	_image.set_pixel(px, py, PALETTE[idx])


# Draws one slat: a diagonal run of pixels centered at (mx, my).
#   s : slope direction (+1 or -1)
#   d : half-width in pixels (sign is ignored, only the length matters)
#   c : +3 or -3, which picks the color family and shading direction
func _slope(mx: float, my: float, s: float, d: float, c: float) -> void:
	d = absf(d)

	# Left end of the slat, then snap to the center of the pixel it lies in
	# (floor + 0.5). This keeps the slat symmetric around mx.
	var x1 := mx - d
	var rx1 := floorf(x1) + 0.5
	var rd := mx - rx1          # distance from the snapped left end to the center
	var rx2 := mx + rd          # mirrored right end

	# Color of the two end pixels: the fractional part of the original left end
	# shifts the color, which gives a poor man's anti-aliasing.
	var c2 := 4.5 + (1.0 - fposmod(x1, 1.0)) * c
	# Color of the body pixels: 7.5 (-> white) for c=+3, 1.5 (-> pink) for c=-3.
	c += 4.5

	# Walk from the left end to the right end one pixel at a time.
	# Positions are always multiples of 0.5, so float math is exact here.
	var x := rx1
	while x <= rx2:
		var y := my + (x - mx) * s
		if x == rx1 or x == rx2:
			_pset(x, y, c2)   # end pixels use the shaded color
		else:
			_pset(x, y, c)    # body pixels
		x += 1.0


# Draws the whole frame into the image (the main loop of the original code).
func _render() -> void:
	# Animation phase in turns: t() / gl. t() is time in seconds since start.
	var t := (Time.get_ticks_msec() - _start_ms) / 1000.0
	var p := t / GL

	# cls(4): clear the screen with the background color.
	_image.fill(PALETTE[BG_INDEX])

	for i in _lx.size():
		# Each slat's own phase, wrapped into 0..1 (PICO-8's % is a floored modulo).
		var lp := fposmod(p - _lp[i], 1.0)

		# Oscillation value in -1..1 over the cycle.
		var sp := _psin(lp)

		# Current half-length: it shrinks to zero and grows back as sp crosses 0.
		var d := _ld[i] * sp

		# When sp is negative the slat flips to the other color family.
		var c := 3.0 * _psgn(sp)

		_slope(_lx[i], _ly[i], _ls[i], d, c)

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
