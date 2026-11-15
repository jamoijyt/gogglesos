extends Node3D
## The Goggles Home room: built from simple shapes in the Goggles look, so it needs no model
## files. One long wall is glass and looks out over the night grid (the sky picture shared with
## the dashboard). Furniture, the game shelf's contents and your own things come on top of this.
##
## The room is centred on the origin with the floor at y = 0; you start in the middle, facing
## the glass (-Z).

const WIDTH := 9.0                        # metres, along X
const DEPTH := 7.0                        # along Z
const HEIGHT := 3.2
const WALL := 0.15
const INK := Color("e6f3ee")

var accent := Color("3ddc84")
var parts := 0                            # how many pieces were built (for the self-test)
var shelf_boards: Array[Node3D] = []      # the game shelf's boards, bottom first (games go here later)

const FLOOR_SHADER := """
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;
uniform vec4 base : source_color = vec4(0.055, 0.12, 0.11, 1.0);
uniform vec4 line : source_color = vec4(0.24, 0.86, 0.52, 1.0);
uniform vec2 tile = vec2(1.0, 1.0);          // size of one tile or plank, metres
uniform float seams = 1.0;                   // 0 = none (carpet)
uniform float seam_glow = 0.12;
uniform float shine = 0.65;
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
	float ring = smoothstep(0.05, 0.0, abs(length(at.xz) - 1.35));
	ALBEDO = mix(base.rgb * shade, base.rgb * 0.45, seam);
	ROUGHNESS = 1.0 - shine;
	METALLIC = 0.1 * shine;
	EMISSION = line.rgb * (seam * seam_glow + ring * 0.9);
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

var floor_paint: ShaderMaterial
var wall_paint: StandardMaterial3D
var groove_paint: StandardMaterial3D
var strip_paint: StandardMaterial3D        # the accent-coloured light strips
var glow_paint: StandardMaterial3D         # the logo
var soft_paint: StandardMaterial3D         # the pale ceiling lights
var shelf_light: StandardMaterial3D
var main_light: OmniLight3D
var fill_lights: Array[OmniLight3D] = []
var back_light: OmniLight3D
var signs: Array[Label3D] = []             # labels in the accent colour
var body: StaticBody3D                     # what you can stand on and bump into


func _init(accent_colour := Color("3ddc84")) -> void:
	accent = accent_colour
	body = StaticBody3D.new()
	body.name = "Shell"
	add_child(body)
	_shell()
	_window_wall()
	_lights()
	_shelf()
	_logo()


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


## Floor, ceiling and the three solid walls, with glowing strips along their edges.
func _shell() -> void:
	floor_paint = ShaderMaterial.new()
	floor_paint.shader = Shader.new()
	floor_paint.shader.code = FLOOR_SHADER
	floor_paint.set_shader_parameter("line", accent)
	_box(Vector3(WIDTH, 0.1, DEPTH), Vector3(0, -0.05, 0), floor_paint)
	_solid(Vector3(WIDTH + 2, 1.0, DEPTH + 2), Vector3(0, -0.5, 0))
	_solid(Vector3(WIDTH + 2, 1.0, DEPTH + 2), Vector3(0, HEIGHT + 0.5, 0))
	_solid(Vector3(WIDTH + 2, HEIGHT, 1.0), Vector3(0, HEIGHT / 2, DEPTH / 2 + 0.5))
	_solid(Vector3(WIDTH + 2, HEIGHT, 1.0), Vector3(0, HEIGHT / 2, -DEPTH / 2 - 0.5))
	for side in [-1.0, 1.0]:
		_solid(Vector3(1.0, HEIGHT, DEPTH + 2), Vector3(side * (WIDTH / 2 + 0.5), HEIGHT / 2, 0))
	wall_paint = _paint(Color(0.1, 0.21, 0.19))
	var wall := wall_paint
	var ceiling := _paint(Color(0.05, 0.11, 0.1))
	_box(Vector3(WIDTH + WALL * 2, 0.1, DEPTH + WALL * 2), Vector3(0, HEIGHT + 0.05, 0), ceiling)
	_box(Vector3(WIDTH + WALL * 2, HEIGHT, WALL), Vector3(0, HEIGHT / 2, DEPTH / 2 + WALL / 2), wall)       # behind you
	for side in [-1.0, 1.0]:
		_box(Vector3(WALL, HEIGHT, DEPTH), Vector3(side * (WIDTH / 2 + WALL / 2), HEIGHT / 2, 0), wall)
	# panel lines on the walls, so they aren't flat slabs
	groove_paint = _paint(Color(0.05, 0.12, 0.105))
	var groove := groove_paint
	for x in range(-3, 4):
		_box(Vector3(0.02, HEIGHT - 0.5, 0.01), Vector3(x * 1.25, HEIGHT / 2, DEPTH / 2 - 0.004), groove)
	for side in [-1.0, 1.0]:
		for z in range(-2, 3):
			_box(Vector3(0.01, HEIGHT - 0.5, 0.02), Vector3(side * (WIDTH / 2 - 0.004), HEIGHT / 2, z * 1.25), groove)
	# light strips: along the floor and around the ceiling
	strip_paint = _paint(accent, 1.1)
	soft_paint = _paint(Color(0.62, 0.95, 0.8), 0.95)
	var strip := strip_paint
	var soft := soft_paint
	for y in [0.06, HEIGHT - 0.06]:
		var paint: StandardMaterial3D = strip if y < 1.0 else soft
		_box(Vector3(WIDTH, 0.03, 0.03), Vector3(0, y, DEPTH / 2 - 0.02), paint)
		for side in [-1.0, 1.0]:
			_box(Vector3(0.03, 0.03, DEPTH), Vector3(side * (WIDTH / 2 - 0.02), y, 0), paint)
	# a lit frame in the ceiling over the middle of the room
	for z in [-1.4, 1.4]:
		_box(Vector3(3.6, 0.03, 0.12), Vector3(0, HEIGHT - 0.015, z), soft)
	for x in [-1.8, 1.8]:
		_box(Vector3(0.12, 0.03, 2.92), Vector3(x, HEIGHT - 0.015, 0), soft)


## The glass wall: thin posts and rails, with barely-there glass between them.
func _window_wall() -> void:
	var z := -DEPTH / 2
	var frame := _paint(Color(0.02, 0.05, 0.045), 0.0, 0.4)
	_box(Vector3(WIDTH + WALL * 2, 0.12, WALL), Vector3(0, 0.06, z - WALL / 2), frame)
	_box(Vector3(WIDTH + WALL * 2, 0.2, WALL), Vector3(0, HEIGHT - 0.1, z - WALL / 2), frame)
	for i in 7:
		_box(Vector3(0.06, HEIGHT, 0.08), Vector3(-WIDTH / 2 + i * WIDTH / 6.0, HEIGHT / 2, z - WALL / 2), frame)
	var glass := _paint(Color(0.55, 1.0, 0.8, 0.045), 0.0, 0.05)
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	_box(Vector3(WIDTH, HEIGHT - 0.32, 0.01), Vector3(0, HEIGHT / 2 - 0.04, z - WALL / 2), glass)
	_box(Vector3(WIDTH, 0.03, 0.03), Vector3(0, 0.135, z + 0.02), strip_paint)


func _lights() -> void:
	var main := OmniLight3D.new()
	main.position = Vector3(0, HEIGHT - 0.4, 0)
	main.omni_range = 9.0
	main.light_energy = 1.5
	main.light_color = Color(0.85, 1.0, 0.93)
	add_child(main)
	main_light = main
	for x in [-3.2, 3.2]:
		var fill := OmniLight3D.new()
		fill.position = Vector3(x, 1.2, -DEPTH / 2 + 0.8)
		fill.omni_range = 5.0
		fill.light_energy = 0.7
		fill.light_color = accent
		add_child(fill)
		fill_lights.append(fill)
	var back := OmniLight3D.new()
	back.position = Vector3(0, 2.0, DEPTH / 2 - 1.0)
	back.omni_range = 6.0
	back.light_energy = 0.8
	back.light_color = Color(0.8, 0.95, 1.0)
	add_child(back)
	back_light = back


## The game shelf on the right-hand wall: empty for now, lit from under each board.
func _shelf() -> void:
	var shelf := Node3D.new()
	shelf.name = "GameShelf"
	shelf.position = Vector3(WIDTH / 2 - 0.2, 0, 0)
	add_child(shelf)
	var wood := _paint(Color(0.09, 0.18, 0.16), 0.0, 0.5)
	shelf_light = _paint(accent, 1.4)
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
	logo.position = Vector3(0, 1.95, DEPTH / 2 - 0.03)
	add_child(logo)
	glow_paint = _paint(accent, 1.25)
	var glow := glow_paint
	for x in [-0.42, 0.42]:
		var lens := MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = 0.27
		ring.outer_radius = 0.33
		ring.rings = 48
		ring.ring_segments = 12
		lens.mesh = ring
		lens.material_override = glow
		lens.position.x = x
		lens.rotation.x = PI / 2
		lens.scale = Vector3(1, 0.35, 1)      # flattened against the wall
		logo.add_child(lens)
		parts += 1
	_box(Vector3(0.2, 0.05, 0.02), Vector3(0, 0.05, 0), glow, logo)
	var name_label := Label3D.new()
	name_label.text = "GOGGLES HOME"
	name_label.font_size = 72
	name_label.pixel_size = 0.0011
	name_label.modulate = INK
	name_label.outline_size = 0
	name_label.position = Vector3(0, -0.6, 0)
	name_label.rotation.y = PI
	logo.add_child(name_label)


## Something solid, without a picture of its own (the walls' and floor's thickness).
func _solid(size: Vector3, at: Vector3) -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = at
	body.add_child(shape)


# ------------------------------------------------------------------ making it yours
func set_accent(id: String) -> void:
	accent = ACCENTS.get(id, ACCENTS["green"])[1]
	for paint in [strip_paint, glow_paint, shelf_light]:
		paint.albedo_color = accent
		paint.emission = accent
	floor_paint.set_shader_parameter("line", accent)
	for light in fill_lights:
		light.light_color = accent
	for sign in signs:
		sign.modulate = Color(accent, 0.9)


func set_walls(id: String) -> void:
	var colour: Color = WALLS.get(id, WALLS["teal"])[1]
	wall_paint.albedo_color = colour
	groove_paint.albedo_color = colour * 0.55


func set_floor(id: String) -> void:
	var style: Array = FLOORS.get(id, FLOORS["tiles"])
	floor_paint.set_shader_parameter("base", style[1])
	floor_paint.set_shader_parameter("tile", style[2])
	floor_paint.set_shader_parameter("seams", style[3])
	floor_paint.set_shader_parameter("seam_glow", style[4])
	floor_paint.set_shader_parameter("shine", style[5])


## 0 (dim) to 100 (bright): the room's own lights.
func set_brightness(percent: float) -> void:
	var f := clampf(percent, 0.0, 100.0) / 50.0          # 50 is the look it was designed with
	main_light.light_energy = 1.5 * f
	back_light.light_energy = 0.8 * f
	for light in fill_lights:
		light.light_energy = 0.7 * f
	soft_paint.emission_energy_multiplier = 0.95 * clampf(f, 0.3, 1.6)
