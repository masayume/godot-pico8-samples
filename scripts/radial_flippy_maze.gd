extends Node2D
# ============================================================================
# PICO-8 "shifting maze" port for Godot 4
#
# The original program draws a grid of short diagonal-ish line segments.
# Each segment points in one of a few directions, picked by a mix of a fixed
# random choice and a sine wave that travels outward from the screen center.
# As the wave moves, segments rotate, so the maze appears to keep rebuilding
# itself from the middle.
#
# The PICO-8 screen is 128x128 pixels. We draw in that coordinate space and
# scale it to fit the viewport, centered, so everything stays inside the view.
# ============================================================================

# Grid extent from the original code (e=124). The loops run from -E..E in y
# and E..-6 in x, both in steps of 6 pixels.
const E := 124

# Size of the PICO-8 screen in pixels (width and height).
const SCREEN := 128.0

# PICO-8 uses 16.16 fixed-point numbers, which overflow past +-32768.
# (x-64)^2 + (z-64)^2 can exceed that, so the original wraps around.
# true  = emulate that wrap (matches the original look)
# false = use the mathematically exact value
const WRAP_LIKE_PICO8 := true

# --- PICO-8 palette colors used by the program ---
const C_BG    := Color8(255, 119, 168)  # color 14 (pink): background from cls(14)
const C_RED   := Color8(255, 0, 77)     # color 8  (red): first line of each pair
const C_LAV   := Color8(131, 118, 156)  # color 13 (lavender): second line, q = 0 and 1
const C_WHITE := Color8(255, 241, 232)  # color 7  (white): second line, q = 2

# One fixed random choice per grid cell: true -> base angle 0.25, false -> 0.
# This replaces rnd{0,.25}, which in the original returns the same values
# every frame because srand() is called each frame.
var _picks: Array[bool] = []


func _ready() -> void:
	# The original calls srand() (seed 0) at the start of every frame, so the
	# random sequence restarts each frame and every cell gets the same choice
	# each time. Instead of reseeding every frame, we generate the choices once
	# in the same loop order the drawing uses.
	# Note: Godot's RNG differs from PICO-8's, so the exact wall pattern is
	# different from the original, but it behaves the same way.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0
	for y in range(-E, E + 1, 6):
		for x in range(E, -7, -6):
			_picks.append(rng.randf() < 0.5)


func _process(_delta: float) -> void:
	# The scene is animated every frame, so request a redraw each frame.
	queue_redraw()


# Emulates signed 16.16 fixed-point overflow: maps any value into the
# range [-32768, 32768), like PICO-8 numbers do.
func _wrap(v: float) -> float:
	return fposmod(v + 32768.0, 65536.0) - 32768.0


func _draw() -> void:
	# --- Fit the 128x128 PICO-8 screen into the viewport, centered ---
	var vp := get_viewport_rect().size
	var s := minf(vp.x, vp.y) / SCREEN                         # uniform scale factor
	var origin := (vp - Vector2(SCREEN, SCREEN) * s) * 0.5     # top-left of the square

	# Black bars around the square if the viewport isn't square.
	draw_rect(Rect2(Vector2.ZERO, vp), Color.BLACK)

	# From here on, all drawing is in PICO-8 pixel coordinates (0..128),
	# automatically translated and scaled to the viewport.
	draw_set_transform(origin, 0.0, Vector2(s, s))

	# cls(14): fill the PICO-8 screen with the background color.
	draw_rect(Rect2(0, 0, SCREEN, SCREEN), C_BG)

	# t() in PICO-8 is the time in seconds since the program started.
	var t := Time.get_ticks_msec() / 1000.0

	# Index into the precomputed random choices (same order as in _ready).
	var i := 0

	# Walk the grid exactly like the original nested for loops.
	for y in range(-E, E + 1, 6):
		for x in range(E, -7, -6):
			# z shifts each row diagonally by x, which gives the skewed,
			# isometric-looking layout of the grid.
			var z := y + x

			# Squared distance from the screen center (64, 64).
			# This drives the wave that expands outward from the middle.
			var d: float
			if WRAP_LIKE_PICO8:
				d = _wrap(_wrap(float((x - 64) * (x - 64))) + _wrap(float((z - 64) * (z - 64))))
			else:
				d = float((x - 64) * (x - 64) + (z - 64) * (z - 64))

			# Wave value in -1..1. The phase depends on distance (d>>14, i.e.
			# d / 16384) minus time/4, so rings travel outward over time.
			# PICO-8's sin() takes turns (0..1 = a full circle) and is
			# inverted, hence TAU * (...) and the minus sign.
			var sn := -sin(TAU * (d / 16384.0 - t / 4.0))

			# Final angle in turns: the fixed random base (0 or 0.25) plus the
			# wave clamped to 0..0.25. The original mid(0.25, sin(...)) has a
			# missing third argument that counts as 0, so it is a clamp(0, 0.25).
			var a := (0.25 if _picks[i] else 0.0) + clampf(sn, 0.0, 0.25)
			i += 1

			# Direction vector of the segment, 5 pixels long. Again, turns and
			# inverted sine in PICO-8, so we use TAU * a and -sin.
			var u := cos(TAU * a) * 5.0
			var v := -sin(TAU * a) * 5.0

			# Each segment is drawn 3 times with a 1-pixel offset to make it
			# look thick, with a shadowed look.
			for q in 3:
				# Red line, offset diagonally: (x-q, z+q).
				_line(Vector2(x - q, z + q), Vector2(x + u - q, z + v + q), C_RED)

				# Second line, offset vertically: (x, z-q).
				# Original color: 13 - (q\2)*6 -> q = 0,1 gives 13 (lavender),
				# q = 2 gives 7 (white).
				_line(Vector2(x, z - q), Vector2(x + u, z + v - q), C_WHITE if q >= 2 else C_LAV)


# Draws a line like PICO-8's line(): endpoints snapped to integer pixels and
# clipped to the 128x128 screen, so nothing is drawn outside the viewport area.
# Uses Liang-Barsky clipping to cut the line at the screen borders.
func _line(p0: Vector2, p1: Vector2, col: Color) -> void:
	# PICO-8 works with whole pixels, so floor the endpoints.
	var a := p0.floor()
	var b := p1.floor()
	var dx := b.x - a.x
	var dy := b.y - a.y

	# t0..t1 is the visible part of the line, as a fraction 0..1 along it.
	var t0 := 0.0
	var t1 := 1.0

	# Liang-Barsky setup: for each of the 4 screen edges (left, right, top,
	# bottom), p is the direction of the line relative to that edge and qv is
	# the distance from the start point to that edge.
	var p := [-dx, dx, -dy, dy]
	var qv := [a.x, SCREEN - 1.0 - a.x, a.y, SCREEN - 1.0 - a.y]

	for k in 4:
		if p[k] == 0.0:
			# Line is parallel to this edge; if it's outside, skip it entirely.
			if qv[k] < 0.0:
				return
		else:
			var r: float = qv[k] / p[k]
			if p[k] < 0.0:
				# Line enters the screen across this edge.
				if r > t1: return
				t0 = maxf(t0, r)
			else:
				# Line leaves the screen across this edge.
				if r < t0: return
				t1 = minf(t1, r)

	# Compute the clipped endpoints, snap them to whole pixels, and add 0.5 so
	# the 1px-wide line is centered on pixel centers (keeps it crisp).
	var c0 := (a + Vector2(dx, dy) * t0).round() + Vector2(0.5, 0.5)
	var c1 := (a + Vector2(dx, dy) * t1).round() + Vector2(0.5, 0.5)

	# Draw with antialiasing off for the pixel-art look.
	draw_line(c0, c1, col, 1.0, false)
