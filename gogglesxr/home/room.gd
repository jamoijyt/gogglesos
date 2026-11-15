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
varying vec3 at;
void vertex() { at = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	// one-metre tiles with thin seams, and a soft ring of light where you start
	vec2 cell = abs(fract(at.xz) - 0.5);
	float seam = smoothstep(0.488, 0.498, max(cell.x, cell.y));
	float ring = smoothstep(0.05, 0.0, abs(length(at.xz) - 1.35));
	ALBEDO = mix(base.rgb, base.rgb * 1.9, seam);
	ROUGHNESS = 0.35;
	METALLIC = 0.1;
	EMISSION = line.rgb * (seam * 0.12 + ring * 0.9);
}
"""


func _init(accent_colour := Color("3ddc84")) -> void:
	accent = accent_colour
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
	var floor_paint := ShaderMaterial.new()
	floor_paint.shader = Shader.new()
	floor_paint.shader.code = FLOOR_SHADER
	floor_paint.set_shader_parameter("line", accent)
	_box(Vector3(WIDTH, 0.1, DEPTH), Vector3(0, -0.05, 0), floor_paint)
	var wall := _paint(Color(0.1, 0.21, 0.19))
	var ceiling := _paint(Color(0.05, 0.11, 0.1))
	_box(Vector3(WIDTH + WALL * 2, 0.1, DEPTH + WALL * 2), Vector3(0, HEIGHT + 0.05, 0), ceiling)
	_box(Vector3(WIDTH + WALL * 2, HEIGHT, WALL), Vector3(0, HEIGHT / 2, DEPTH / 2 + WALL / 2), wall)       # behind you
	for side in [-1.0, 1.0]:
		_box(Vector3(WALL, HEIGHT, DEPTH), Vector3(side * (WIDTH / 2 + WALL / 2), HEIGHT / 2, 0), wall)
	# panel lines on the walls, so they aren't flat slabs
	var groove := _paint(Color(0.05, 0.12, 0.105))
	for x in range(-3, 4):
		_box(Vector3(0.02, HEIGHT - 0.5, 0.01), Vector3(x * 1.25, HEIGHT / 2, DEPTH / 2 - 0.004), groove)
	for side in [-1.0, 1.0]:
		for z in range(-2, 3):
			_box(Vector3(0.01, HEIGHT - 0.5, 0.02), Vector3(side * (WIDTH / 2 - 0.004), HEIGHT / 2, z * 1.25), groove)
	# light strips: along the floor and around the ceiling
	var strip := _paint(accent, 1.1)
	var soft := _paint(Color(0.62, 0.95, 0.8), 0.95)
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
	_box(Vector3(WIDTH, 0.03, 0.03), Vector3(0, 0.135, z + 0.02), _paint(accent, 1.1))


func _lights() -> void:
	var main := OmniLight3D.new()
	main.position = Vector3(0, HEIGHT - 0.4, 0)
	main.omni_range = 9.0
	main.light_energy = 1.5
	main.light_color = Color(0.85, 1.0, 0.93)
	add_child(main)
	for x in [-3.2, 3.2]:
		var fill := OmniLight3D.new()
		fill.position = Vector3(x, 1.2, -DEPTH / 2 + 0.8)
		fill.omni_range = 5.0
		fill.light_energy = 0.7
		fill.light_color = accent
		add_child(fill)
	var back := OmniLight3D.new()
	back.position = Vector3(0, 2.0, DEPTH / 2 - 1.0)
	back.omni_range = 6.0
	back.light_energy = 0.8
	back.light_color = Color(0.8, 0.95, 1.0)
	add_child(back)


## The game shelf on the right-hand wall: empty for now, lit from under each board.
func _shelf() -> void:
	var shelf := Node3D.new()
	shelf.name = "GameShelf"
	shelf.position = Vector3(WIDTH / 2 - 0.2, 0, 0)
	add_child(shelf)
	var wood := _paint(Color(0.09, 0.18, 0.16), 0.0, 0.5)
	var length := 4.2
	for end in [-1.0, 1.0]:
		_box(Vector3(0.36, 2.1, 0.05), Vector3(0, 1.05, end * length / 2), wood, shelf)
	for i in 4:
		var y := 0.5 + i * 0.5
		var board := _box(Vector3(0.36, 0.04, length), Vector3(0, y, 0), wood, shelf)
		shelf_boards.append(board)
		_box(Vector3(0.015, 0.012, length - 0.1), Vector3(-0.16, y - 0.026, 0), _paint(accent, 1.4), shelf)
	var sign := Label3D.new()
	sign.text = "GAMES"
	sign.font_size = 96
	sign.pixel_size = 0.0012
	sign.modulate = Color(accent, 0.9)
	sign.outline_size = 0
	sign.position = Vector3(-0.19, 2.35, 0)
	sign.rotation.y = -PI / 2                 # facing into the room
	shelf.add_child(sign)


## The Goggles lenses, glowing on the wall behind you.
func _logo() -> void:
	var logo := Node3D.new()
	logo.name = "Logo"
	logo.position = Vector3(0, 1.95, DEPTH / 2 - 0.03)
	add_child(logo)
	var glow := _paint(accent, 1.25)
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
