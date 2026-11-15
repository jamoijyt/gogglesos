extends Node3D
## The Goggles Home house: built from simple shapes in the Goggles look, so it needs no model
## files of its own (the things in it are furniture.gd's).
##
##   Ground floor (level 0)   the living room: a glass wall onto the sky (-Z), the game shelf on
##                            the right (+X) with the VHS corner next to it, the Goggles lenses
##                            on the back wall (+Z), and the stairs up along the left wall (-X)
##   Upstairs (level 1)       the bedroom: the same footprint, its own glass wall and starry
##                            ceiling, a railing round the stairwell
##
## Each floor has its own lights with a few moods (bright, warm, evening, night, party, off),
## set from a switch panel on its wall, and a glowing pad that takes you to the other floor.
## You start in the middle of the ground floor, facing the glass. Floors are at y = 0 and
## y = UP_FLOOR.

const WIDTH := 9.0                        # metres, along X
const DEPTH := 7.0                        # along Z
const HEIGHT := 3.2                       # ground floor, floor to ceiling
const SLAB := 0.15                        # the floor between the two
const UP_FLOOR := HEIGHT + SLAB           # height of the upstairs floor
const UP_HEIGHT := 2.9
const WALL := 0.15
const INK := Color("e6f3ee")
# The stairs: up along the left wall from the front (STAIR_Z0) to the back
const STAIR_X0 := -WIDTH / 2
const STAIR_X1 := -WIDTH / 2 + 1.15
const STAIR_Z0 := -1.25
const STEPS := 17
const STEP_RUN := 0.27
const STAIR_Z1 := STAIR_Z0 + STEPS * STEP_RUN
# Pads that take you between the floors, and where they put you
const PAD_DOWN := Vector3(-3.0, 0.0, -2.2)          # on the ground floor, by the foot of the stairs
const PAD_UP := Vector3(-2.4, UP_FLOOR, 2.6)        # upstairs, by the top of the stairs
# The VHS corner, by the game shelf (main.gd builds the player and the TV here)
const VHS_CORNER := Vector3(WIDTH / 2 - 0.42, 0.0, 2.75)

var accent := Color("3ddc84")
var parts := 0                            # how many pieces were built (for the self-test)
var shelf_boards: Array[Node3D] = []      # the game shelf's boards, bottom first

const FLOOR_SHADER := """
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;
uniform vec4 base : source_color = vec4(0.055, 0.12, 0.11, 1.0);
uniform vec4 line : source_color = vec4(0.24, 0.86, 0.52, 1.0);
uniform vec2 tile = vec2(1.0, 1.0);          // size of one tile or plank, metres
uniform float seams = 1.0;                   // 0 = none (carpet)
uniform float seam_glow = 0.12;
uniform float shine = 0.65;
uniform float ring = 1.0;                    // the ring of light where you start (ground floor only)
varying vec3 at;
void vertex() { at = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	// tiles or planks with thin seams (every other row of planks is shifted), and a soft ring
	// of light where you start
	vec2 p = at.xz / tile;
	p.x += step(1.0, mod(p.y, 2.0)) * 0.5 * step(tile.x, tile.y - 0.001);
	vec2 cell = abs(fract(p) - 0.5);
	vec2 width = 0.006 / tile;
	float seam = max(smoothstep(0.5 - width.x, 0.5 - width.x * 0.3, cell.x), smoothstep(0.5 - width.y, 0.5 - width.y * 0.3, cell.y)) * seams;
	float shade = 0.92 + 0.16 * fract(sin(dot(floor(p), vec2(12.9898, 78.233))) * 43758.5453);   // tiles differ a little
	float glow = smoothstep(0.05, 0.0, abs(length(at.xz) - 1.35)) * ring;
	ALBEDO = mix(base.rgb * shade, base.rgb * 0.45, seam);
	ROUGHNESS = 1.0 - shine;
	METALLIC = 0.1 * shine;
	EMISSION = line.rgb * (seam * seam_glow + glow * 0.9);
}
"""

# A ceiling that shows stars when the lights are down (upstairs, "Night")
const STARS_SHADER := """
shader_type spatial;
render_mode unshaded;
uniform vec4 base : source_color = vec4(0.05, 0.11, 0.1, 1.0);
uniform float stars = 0.0;
varying vec3 at;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void vertex() { at = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 grid = at.xz * 9.0;
	vec2 cell = floor(grid);
	float pick = hash(cell);
	float twinkle = 0.6 + 0.4 * sin(TIME * (1.0 + 3.0 * hash(cell + 3.0)) + pick * 40.0);
	float star = step(0.93, pick) * smoothstep(0.32, 0.05, length(fract(grid) - 0.5)) * twinkle;
	vec3 night = mix(base.rgb * 0.25, vec3(0.02, 0.03, 0.08), stars);
	ALBEDO = mix(base.rgb, night, stars) + vec3(0.85, 0.92, 1.0) * star * stars;
}
"""

# What the Home menu offers (Look): id -> [name, ...]
const WALLS := {
	"teal": ["Teal", Color(0.1, 0.21, 0.19)], "slate": ["Slate", Color(0.2, 0.22, 0.27)],
	"forest": ["Forest", Color(0.09, 0.24, 0.13)], "plum": ["Plum", Color(0.26, 0.14, 0.28)],
	"sand": ["Sand", Color(0.6, 0.54, 0.44)], "white": ["White", Color(0.74, 0.76, 0.75)],
}
const FLOORS := {     # name, colour, tile size, seams, seam glow, shine
	"tiles": ["Glow tiles", Color(0.055, 0.12, 0.11), Vector2(1, 1), 1.0, 0.12, 0.65],
	"wood": ["Wood", Color(0.36, 0.22, 0.12), Vector2(0.2, 1.6), 1.0, 0.0, 0.35],
	"stone": ["Stone", Color(0.42, 0.44, 0.43), Vector2(0.6, 0.6), 1.0, 0.0, 0.25],
	"carpet": ["Carpet", Color(0.17, 0.15, 0.24), Vector2(1, 1), 0.0, 0.0, 0.02],
}
const ACCENTS := {
	"green": ["Green", Color("3ddc84")], "cyan": ["Cyan", Color("3dc8dc")], "purple": ["Purple", Color("a06bff")],
	"pink": ["Pink", Color("ff6bb5")], "orange": ["Orange", Color("ffa23d")], "white": ["White", Color("e8f2ee")],
}
# Light moods: name, strength of the lamps, their colour, strength of the glowing strips
const MOODS := {
	"bright": ["Bright", 1.3, Color(0.9, 1.0, 0.95), 1.0],
	"warm": ["Warm", 0.95, Color(1.0, 0.8, 0.58), 0.8],
	"evening": ["Evening", 0.45, Color(1.0, 0.66, 0.42), 0.65],
	"night": ["Night", 0.12, Color(0.55, 0.65, 1.0), 0.35],
	"party": ["Party", 0.8, Color(1, 0.3, 0.6), 1.3],
	"off": ["Off", 0.0, Color.BLACK, 0.12],
}
const MOOD_ORDER := ["bright", "warm", "evening", "night", "party", "off"]

var floor_paints: Array[ShaderMaterial] = []
var wall_paint: StandardMaterial3D
var groove_paint: StandardMaterial3D
var strip_paint: StandardMaterial3D        # the accent-coloured light strips (both floors)
var glow_paint: StandardMaterial3D         # the logo
var shelf_light: StandardMaterial3D
var signs: Array[Label3D] = []             # labels in the accent colour
var body: StaticBody3D                     # what you can stand on and bump into
var floor_paint: ShaderMaterial:           # (the ground floor's, for older callers)
	get: return floor_paints[0]
var main_light: OmniLight3D:
	get: return levels[0].lamps[0]
# Per floor: {"lamps": [OmniLight3D], "base": [energy], "panels": [StandardMaterial3D], "strips":
# StandardMaterial3D, "ceiling": ShaderMaterial or null, "mood": String}
var levels: Array[Dictionary] = []
var brightness := 1.0                      # Look > Room lights (1 = as designed)
var switches: Array[StaticBody3D] = []     # the switch panels' buttons (meta "switch": [level, mood])
var pads: Array[StaticBody3D] = []         # meta "pad": where it takes you
var _party_time := 0.0


func _init(accent_colour := Color("3ddc84")) -> void:
	accent = accent_colour
	body = StaticBody3D.new()
	body.name = "Shell"
	add_child(body)
	wall_paint = _paint(Color(0.1, 0.21, 0.19))
	groove_paint = _paint(Color(0.05, 0.12, 0.105))
	strip_paint = _paint(accent, 1.1)
	glow_paint = _paint(accent, 1.25)
	shelf_light = _paint(accent, 1.4)
	for level in 2:
		levels.append({"lamps": [], "base": [], "panels": [], "strips": strip_paint, "ceiling": null, "mood": "bright"})
	_floor(0)
	_floor(1)
	_stairs()
	_window_wall(0)
	_window_wall(1)
	_lights(0)
	_lights(1)
	_shelf()
	_logo()
	_switch_panel(0, Vector3(-WIDTH / 2 + 0.012, 1.3, -2.0), PI / 2)
	_switch_panel(1, Vector3(-1.6, UP_FLOOR + 1.3, DEPTH / 2 - 0.012), PI)
	_pad(PAD_DOWN, "Upstairs", PAD_UP + Vector3(0.6, 0, -0.6))
	_pad(PAD_UP, "Downstairs", PAD_DOWN + Vector3(0.6, 0, -0.4))
	set_mood(0, "bright")
	set_mood(1, "warm")


func _process(delta: float) -> void:
	_party_time += delta
	for level in 2:
		if levels[level].mood == "party":
			_apply_mood(level)


func _paint(colour: Color, glow := 0.0, rough := 0.7) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = rough
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = colour
		m.emission_energy_multiplier = glow
	if colour.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _box(size: Vector3, at: Vector3, material: Material, parent: Node3D = self) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = material
	node.position = at
	parent.add_child(node)
	parts += 1
	return node


## Something solid, without a picture of its own (the walls' and floor's thickness).
func _solid(size: Vector3, at: Vector3, basis := Basis.IDENTITY) -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.transform = Transform3D(basis, at)
	body.add_child(shape)


static func floor_y(level: int) -> float:
	return UP_FLOOR if level == 1 else 0.0


## Which floor a height is on.
static func level_at(y: float) -> int:
	return 1 if y > UP_FLOOR - 0.6 else 0


# ------------------------------------------------------------------ floors, walls, ceilings
func _floor(level: int) -> void:
	var y0 := floor_y(level)
	var high := HEIGHT if level == 0 else UP_HEIGHT
	var paint := ShaderMaterial.new()
	paint.shader = Shader.new()
	paint.shader.code = FLOOR_SHADER
	paint.set_shader_parameter("line", accent)
	paint.set_shader_parameter("ring", 1.0 if level == 0 else 0.0)
	floor_paints.append(paint)
	if level == 0:
		_box(Vector3(WIDTH, 0.1, DEPTH), Vector3(0, -0.05, 0), paint)
		_solid(Vector3(WIDTH + 2, 1.0, DEPTH + 2), Vector3(0, -0.5, 0))
	else:
		# the slab between the floors, with the stairwell left open
		var under := _paint(Color(0.05, 0.11, 0.1))
		var main_w := WIDTH / 2 - STAIR_X1
		var front_d := STAIR_Z0 + DEPTH / 2
		for piece in [[Vector3(main_w, SLAB, DEPTH), Vector3(STAIR_X1 + main_w / 2, HEIGHT + SLAB / 2, 0)],
				[Vector3(STAIR_X1 - STAIR_X0, SLAB, front_d), Vector3((STAIR_X0 + STAIR_X1) / 2, HEIGHT + SLAB / 2, -DEPTH / 2 + front_d / 2)]]:
			_box(piece[0] - Vector3(0, 0.02, 0), piece[1] - Vector3(0, 0.01, 0), under)     # the ground floor's ceiling
			_box(Vector3(piece[0].x, 0.02, piece[0].z), piece[1] + Vector3(0, SLAB / 2 - 0.01, 0), paint)
			_solid(piece[0], piece[1])
	# walls (the glass wall is _window_wall's), with panel lines so they aren't flat slabs
	var mid := y0 + high / 2
	_box(Vector3(WIDTH + WALL * 2, high, WALL), Vector3(0, mid, DEPTH / 2 + WALL / 2), wall_paint)
	_solid(Vector3(WIDTH + 2, high, 1.0), Vector3(0, mid, DEPTH / 2 + 0.5))
	_solid(Vector3(WIDTH + 2, high, 1.0), Vector3(0, mid, -DEPTH / 2 - 0.5))
	for side in [-1.0, 1.0]:
		_box(Vector3(WALL, high, DEPTH), Vector3(side * (WIDTH / 2 + WALL / 2), mid, 0), wall_paint)
		_solid(Vector3(1.0, high, DEPTH + 2), Vector3(side * (WIDTH / 2 + 0.5), mid, 0))
	for x in range(-3, 4):
		_box(Vector3(0.02, high - 0.5, 0.01), Vector3(x * 1.25, mid, DEPTH / 2 - 0.004), groove_paint)
	for side in [-1.0, 1.0]:
		for z in range(-2, 3):
			_box(Vector3(0.01, high - 0.5, 0.02), Vector3(side * (WIDTH / 2 - 0.004), mid, z * 1.25), groove_paint)
	# light strips: along the floor and round the ceiling
	var soft := _paint(Color(0.62, 0.95, 0.8), 0.95)
	levels[level].panels.append(soft)
	for y in [y0 + 0.06, y0 + high - 0.06]:
		var paint_strip: StandardMaterial3D = strip_paint if y < y0 + 1.0 else soft
		_box(Vector3(WIDTH, 0.03, 0.03), Vector3(0, y, DEPTH / 2 - 0.02), paint_strip)
		for side in [-1.0, 1.0]:
			_box(Vector3(0.03, 0.03, DEPTH), Vector3(side * (WIDTH / 2 - 0.02), y, 0), paint_strip)
	# a lit frame in the ceiling over the middle of the room
	var top := y0 + high
	for z in [-1.4, 1.4]:
		_box(Vector3(3.6, 0.03, 0.12), Vector3(0.4, top - 0.015, z), soft)
	for x in [-1.4, 2.2]:
		_box(Vector3(0.12, 0.03, 2.92), Vector3(x, top - 0.015, 0), soft)
	if level == 1:
		# the roof: a ceiling that can show stars
		var stars := ShaderMaterial.new()
		stars.shader = Shader.new()
		stars.shader.code = STARS_SHADER
		levels[1].ceiling = stars
		_box(Vector3(WIDTH + WALL * 2, 0.1, DEPTH + WALL * 2), Vector3(0, top + 0.05, 0), stars)
		_solid(Vector3(WIDTH + 2, 1.0, DEPTH + 2), Vector3(0, top + 0.5, 0))
		# a railing round the stairwell, so you don't step into it
		var glass := _paint(Color(0.55, 1.0, 0.8, 0.08), 0.0, 0.05)
		glass.cull_mode = BaseMaterial3D.CULL_DISABLED
		var rail := _paint(Color(0.02, 0.05, 0.045), 0.0, 0.4)
		var run := STAIR_Z1 - STAIR_Z0
		_box(Vector3(0.02, 0.95, run), Vector3(STAIR_X1, y0 + 0.5, (STAIR_Z0 + STAIR_Z1) / 2), glass)
		_box(Vector3(0.05, 0.05, run), Vector3(STAIR_X1, y0 + 1.0, (STAIR_Z0 + STAIR_Z1) / 2), rail)
		_box(Vector3(STAIR_X1 - STAIR_X0, 0.95, 0.02), Vector3((STAIR_X0 + STAIR_X1) / 2, y0 + 0.5, STAIR_Z0), glass)
		_box(Vector3(STAIR_X1 - STAIR_X0, 0.05, 0.05), Vector3((STAIR_X0 + STAIR_X1) / 2, y0 + 1.0, STAIR_Z0), rail)
		_solid(Vector3(0.06, 1.0, run - 0.9), Vector3(STAIR_X1, y0 + 0.5, (STAIR_Z0 + STAIR_Z1) / 2 - 0.45))
		_solid(Vector3(STAIR_X1 - STAIR_X0, 1.0, 0.06), Vector3((STAIR_X0 + STAIR_X1) / 2, y0 + 0.5, STAIR_Z0))


## The stairs: a solid flight up the left wall, each tread lit along its front edge.
func _stairs() -> void:
	var rise := UP_FLOOR / STEPS
	var width := STAIR_X1 - STAIR_X0
	var tread := _paint(Color(0.12, 0.2, 0.18), 0.0, 0.5)
	var side := _paint(Color(0.07, 0.14, 0.13), 0.0, 0.6)
	for i in STEPS:
		var top := rise * (i + 1)
		var z := STAIR_Z0 + STEP_RUN * (i + 0.5)
		_box(Vector3(width, top, STEP_RUN), Vector3((STAIR_X0 + STAIR_X1) / 2, top / 2, z), side)
		_box(Vector3(width, 0.02, STEP_RUN), Vector3((STAIR_X0 + STAIR_X1) / 2, top + 0.01, z), tread)
		_box(Vector3(width - 0.1, 0.012, 0.02), Vector3((STAIR_X0 + STAIR_X1) / 2, top + 0.006, z - STEP_RUN / 2 + 0.02), strip_paint)
		_solid(Vector3(width, top, STEP_RUN), Vector3((STAIR_X0 + STAIR_X1) / 2, top / 2, z))
	# a handrail up the open side
	var rail := _paint(Color(0.02, 0.05, 0.045), 0.0, 0.4)
	var length := sqrt(pow(STEPS * STEP_RUN, 2) + pow(UP_FLOOR, 2))
	var slope := atan2(UP_FLOOR, STEPS * STEP_RUN)
	var middle := Vector3(STAIR_X1 - 0.03, UP_FLOOR / 2 + 0.95, (STAIR_Z0 + STAIR_Z1) / 2)
	var bar := _box(Vector3(0.05, 0.05, length), middle, rail)
	bar.rotation.x = -slope
	for i in range(0, STEPS, 4):
		var top := rise * (i + 1)
		_box(Vector3(0.03, 0.95, 0.03), Vector3(STAIR_X1 - 0.03, top + 0.475, STAIR_Z0 + STEP_RUN * (i + 0.5)), rail)


## A glass wall onto the sky: thin posts and rails, barely-there glass between them.
func _window_wall(level: int) -> void:
	var y0 := floor_y(level)
	var high := HEIGHT if level == 0 else UP_HEIGHT
	var z := -DEPTH / 2
	var frame := _paint(Color(0.02, 0.05, 0.045), 0.0, 0.4)
	_box(Vector3(WIDTH + WALL * 2, 0.12, WALL), Vector3(0, y0 + 0.06, z - WALL / 2), frame)
	_box(Vector3(WIDTH + WALL * 2, 0.2, WALL), Vector3(0, y0 + high - 0.1, z - WALL / 2), frame)
	for i in 7:
		_box(Vector3(0.06, high, 0.08), Vector3(-WIDTH / 2 + i * WIDTH / 6.0, y0 + high / 2, z - WALL / 2), frame)
	var glass := _paint(Color(0.55, 1.0, 0.8, 0.045), 0.0, 0.05)
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	_box(Vector3(WIDTH, high - 0.32, 0.01), Vector3(0, y0 + high / 2 - 0.04, z - WALL / 2), glass)
	_box(Vector3(WIDTH, 0.03, 0.03), Vector3(0, y0 + 0.135, z + 0.02), strip_paint)


func _lights(level: int) -> void:
	var y0 := floor_y(level)
	var high := HEIGHT if level == 0 else UP_HEIGHT
	var spots := [[Vector3(0.4, y0 + high - 0.4, 0), 9.0, 1.5], [Vector3(-3.2, y0 + 1.2, -DEPTH / 2 + 0.8), 5.0, 0.7],
			[Vector3(3.2, y0 + 1.2, -DEPTH / 2 + 0.8), 5.0, 0.7], [Vector3(0, y0 + 2.0, DEPTH / 2 - 1.0), 6.0, 0.8]]
	for spot in spots:
		var lamp := OmniLight3D.new()
		lamp.position = spot[0]
		lamp.omni_range = spot[1]
		lamp.light_energy = spot[2]
		add_child(lamp)
		levels[level].lamps.append(lamp)
		levels[level].base.append(spot[2])


## The game shelf on the right-hand wall: the VHS boxes stand on it (game_shelf.gd).
func _shelf() -> void:
	var shelf := Node3D.new()
	shelf.name = "GameShelf"
	shelf.position = Vector3(WIDTH / 2 - 0.2, 0, -0.2)
	add_child(shelf)
	var wood := _paint(Color(0.09, 0.18, 0.16), 0.0, 0.5)
	var length := 4.2
	for end in [-1.0, 1.0]:
		_box(Vector3(0.36, 2.1, 0.05), Vector3(0, 1.05, end * length / 2), wood, shelf)
	for i in 4:
		var y := 0.5 + i * 0.5
		var board := _box(Vector3(0.36, 0.04, length), Vector3(0, y, 0), wood, shelf)
		shelf_boards.append(board)
		_box(Vector3(0.015, 0.012, length - 0.1), Vector3(-0.16, y - 0.026, 0), shelf_light, shelf)
	var sign := Label3D.new()
	sign.text = "GAMES"
	sign.font_size = 96
	sign.pixel_size = 0.0012
	sign.modulate = Color(accent, 0.9)
	sign.outline_size = 0
	sign.position = Vector3(-0.19, 2.35, 0)
	sign.rotation.y = -PI / 2                 # facing into the room
	shelf.add_child(sign)
	signs.append(sign)


## The Goggles lenses, glowing on the wall behind you.
func _logo() -> void:
	var logo := Node3D.new()
	logo.name = "Logo"
	logo.position = Vector3(0.6, 1.95, DEPTH / 2 - 0.03)
	add_child(logo)
	for x in [-0.42, 0.42]:
		var lens := MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = 0.27
		ring.outer_radius = 0.33
		ring.rings = 48
		ring.ring_segments = 12
		lens.mesh = ring
		lens.material_override = glow_paint
		lens.position.x = x
		lens.rotation.x = PI / 2
		lens.scale = Vector3(1, 0.35, 1)      # flattened against the wall
		logo.add_child(lens)
		parts += 1
	_box(Vector3(0.2, 0.05, 0.02), Vector3(0, 0.05, 0), glow_paint, logo)
	var name_label := Label3D.new()
	name_label.text = "GOGGLES HOME"
	name_label.font_size = 72
	name_label.pixel_size = 0.0011
	name_label.modulate = INK
	name_label.outline_size = 0
	name_label.position = Vector3(0, -0.6, 0)
	name_label.rotation.y = PI
	logo.add_child(name_label)


# ------------------------------------------------------------------ light switches and pads
## A switch panel on a wall: one button per mood. `turn`: which way it faces (around Y).
func _switch_panel(level: int, at: Vector3, turn: float) -> void:
	var panel := Node3D.new()
	panel.name = "Switches%d" % level
	panel.position = at
	panel.rotation.y = turn
	add_child(panel)
	_box(Vector3(0.34, 0.27, 0.012), Vector3(0, 0, 0.006), _paint(Color(0.88, 0.92, 0.9), 0.0, 0.4), panel)
	var title := Label3D.new()
	title.text = "LIGHTS"
	title.font_size = 36
	title.pixel_size = 0.0006
	title.modulate = Color(0.1, 0.2, 0.18)
	title.outline_size = 0
	title.position = Vector3(0, 0.105, 0.014)
	panel.add_child(title)
	for i in MOOD_ORDER.size():
		var mood: String = MOOD_ORDER[i]
		var button := StaticBody3D.new()
		button.collision_layer = 16
		button.set_meta("switch", [level, mood])
		button.position = Vector3(-0.1 + (i % 3) * 0.1, 0.035 - (i / 3) * 0.11, 0.018)
		panel.add_child(button)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.085, 0.085, 0.03)
		shape.shape = box
		button.add_child(shape)
		var face := _box(Vector3(0.08, 0.06, 0.015), Vector3.ZERO, _paint(Color(0.8, 0.84, 0.82), 0.0, 0.3), button)
		face.name = "Face"
		var lamp := _box(Vector3(0.05, 0.006, 0.004), Vector3(0, 0.018, 0.0085), _paint(Color(0.3, 0.3, 0.3)), button)
		lamp.name = "Lamp"
		var word := Label3D.new()
		word.text = str(MOODS[mood][0])
		word.font_size = 28
		word.pixel_size = 0.0005
		word.modulate = Color(0.1, 0.2, 0.18)
		word.outline_size = 0
		word.position = Vector3(0, -0.008, 0.009)
		button.add_child(word)
		switches.append(button)


## A glowing disc on the floor; point at it and pull the trigger (or teleport onto it) to go
## to the other floor.
func _pad(at: Vector3, text: String, to: Vector3) -> void:
	var pad := StaticBody3D.new()
	pad.collision_layer = 16
	pad.set_meta("pad", to)
	pad.position = at
	add_child(pad)
	var shape := CollisionShape3D.new()
	var round_shape := CylinderShape3D.new()
	round_shape.radius = 0.4
	round_shape.height = 0.06
	shape.shape = round_shape
	pad.add_child(shape)
	var disc := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.4
	mesh.bottom_radius = 0.42
	mesh.height = 0.03
	disc.mesh = mesh
	disc.material_override = _paint(Color(accent, 1.0), 0.9)
	disc.position.y = 0.015
	pad.add_child(disc)
	parts += 1
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.44
	torus.outer_radius = 0.47
	ring.mesh = torus
	ring.material_override = strip_paint
	ring.scale = Vector3(1, 0.3, 1)
	ring.position.y = 0.02
	pad.add_child(ring)
	var label := Label3D.new()
	label.text = ("▲  " if text == "Upstairs" else "▼  ") + text
	label.font_size = 64
	label.pixel_size = 0.0011
	label.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	label.modulate = INK
	label.outline_size = 10
	label.position.y = 0.45
	pad.add_child(label)
	signs.append(label)
	pads.append(pad)


# ------------------------------------------------------------------ making it yours
func set_mood(level: int, mood: String) -> void:
	if not MOODS.has(mood):
		mood = "bright"
	levels[level].mood = mood
	for button in switches:
		var which: Array = button.get_meta("switch")
		if which[0] == level:
			var lamp := button.get_node("Lamp") as MeshInstance3D
			var on: bool = which[1] == mood
			lamp.material_override = _paint(accent, 1.6) if on else _paint(Color(0.3, 0.3, 0.3))
	_apply_mood(level)


func mood_of(level: int) -> String:
	return levels[level].mood


func _apply_mood(level: int) -> void:
	var info: Dictionary = levels[level]
	var mood: Array = MOODS[info.mood]
	var colour: Color = mood[2]
	if info.mood == "party":                  # the colours drift round, each lamp its own way
		colour = Color.from_hsv(fmod(_party_time * 0.08, 1.0), 0.75, 1.0)
	for i in info.lamps.size():
		var lamp: OmniLight3D = info.lamps[i]
		lamp.light_energy = info.base[i] * float(mood[1]) * brightness
		lamp.light_color = colour if info.mood != "party" else Color.from_hsv(fmod(_party_time * 0.08 + i * 0.25, 1.0), 0.75, 1.0)
		lamp.visible = lamp.light_energy > 0.001
	for panel in info.panels:
		var p := panel as StandardMaterial3D
		p.emission = colour.lerp(Color.WHITE, 0.35) if float(mood[1]) > 0.0 else Color.BLACK
		p.emission_energy_multiplier = 0.95 * clampf(float(mood[1]), 0.0, 1.4) * clampf(brightness, 0.3, 1.6)
		p.albedo_color = Color(0.62, 0.95, 0.8) * (0.3 + 0.7 * clampf(float(mood[1]), 0.0, 1.0))
	strip_paint.emission_energy_multiplier = 1.1 * maxf(float(MOODS[levels[0].mood][3]), float(MOODS[levels[1].mood][3]))
	if info.ceiling:
		(info.ceiling as ShaderMaterial).set_shader_parameter("stars", 1.0 if info.mood in ["night", "off", "evening"] else 0.0)


func set_accent(id: String) -> void:
	accent = ACCENTS.get(id, ACCENTS["green"])[1]
	for paint in [strip_paint, glow_paint, shelf_light]:
		paint.albedo_color = accent
		paint.emission = accent
	for paint in floor_paints:
		paint.set_shader_parameter("line", accent)
	for sign in signs:
		if sign.get_parent() is StaticBody3D:
			continue                          # the pads' words stay white
		sign.modulate = Color(accent, 0.9)
	for level in 2:
		set_mood(level, levels[level].mood)


func set_walls(id: String) -> void:
	var colour: Color = WALLS.get(id, WALLS["teal"])[1]
	wall_paint.albedo_color = colour
	groove_paint.albedo_color = colour * 0.55


func set_floor(id: String) -> void:
	var style: Array = FLOORS.get(id, FLOORS["tiles"])
	for paint in floor_paints:
		paint.set_shader_parameter("base", style[1])
		paint.set_shader_parameter("tile", style[2])
		paint.set_shader_parameter("seams", style[3])
		paint.set_shader_parameter("seam_glow", style[4])
		paint.set_shader_parameter("shine", style[5])


## 0 (dim) to 100 (bright): how strong the lights are in every mood. 50 is as designed.
func set_brightness(percent: float) -> void:
	brightness = clampf(percent, 0.0, 100.0) / 50.0
	for level in 2:
		_apply_mood(level)
