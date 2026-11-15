extends RefCounted
## What the things in Goggles Home do, and the things made here rather than loaded.
##
## attach() gives a thing from furniture.gd a "Does" child node. main.gd talks to it:
##   press(hand)                      the trigger, while the laser is on it
##   in_hand(hand, input, delta)      every frame it is in a hand; -> true if it used the trigger
##   hold() -> Transform3D            how it sits on the grip pose ("held" things)
##   hit(point, push)                 a blaster's bolt landed on it
## `home` is main.gd: sounds (play_at), the desktop picture, where your head is, saying things.

const ACCENT := Color("3ddc84")
const PET_SPEED := 0.9
const CAR_FORCE := 12.0


# ------------------------------------------------------------------ things made here
static func _paint(colour: Color, glow := 0.0, rough := 0.6) -> StandardMaterial3D:
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


static func _mesh(mesh: Mesh, material: Material, at := Vector3.ZERO, parent: Node3D = null) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = at
	if parent:
		parent.add_child(node)
	return node


static func _cube(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


const BASKETBALL_SHADER := """
shader_type spatial;
varying vec3 p;
void vertex() { p = VERTEX; }
void fragment() {
	vec3 n = normalize(p);
	float seam = min(min(abs(n.x), abs(n.y)), abs(abs(n.z) - 0.55 * (1.0 - abs(n.y))));
	ALBEDO = mix(vec3(0.02), vec3(0.85, 0.36, 0.08), smoothstep(0.02, 0.04, seam));
	ROUGHNESS = 0.75;
}
"""


## A model for the catalogue entries that have no file. Origin: the bottom middle (wall
## things: the middle of their back).
static func make_model(id: String) -> Node3D:
	var root := Node3D.new()
	match id:
		"ball", "basketball", "balloon":
			var ball := SphereMesh.new()
			var r: float = {"ball": 0.11, "basketball": 0.12, "balloon": 0.16}[id]
			ball.radius = r
			ball.height = r * 2 if id != "balloon" else r * 2.4
			var paint: Material = _paint(Color("ff6bb5"), 0.0, 0.25)
			if id == "basketball":
				paint = ShaderMaterial.new()
				paint.shader = Shader.new()
				paint.shader.code = BASKETBALL_SHADER
			_mesh(ball, paint, Vector3(0, ball.height / 2, 0), root)
			if id == "balloon":                # the knot and a string hanging down
				var knot := CylinderMesh.new()
				knot.top_radius = 0.012
				knot.bottom_radius = 0.02
				knot.height = 0.03
				_mesh(knot, paint, Vector3(0, -0.012, 0), root)
				var string := CylinderMesh.new()
				string.top_radius = 0.002
				string.bottom_radius = 0.002
				string.height = 0.5
				_mesh(string, _paint(Color(0.95, 0.95, 0.95)), Vector3(0, -0.27, 0), root)
		"block":
			_mesh(_cube(Vector3(0.16, 0.16, 0.16)), _paint(Color.WHITE), Vector3(0, 0.08, 0), root)
		"poster", "frame":
			var w := 0.6 if id == "poster" else 0.5
			var h := 0.85 if id == "poster" else 0.4
			if id == "frame":
				var wood := _paint(Color(0.22, 0.14, 0.08), 0.0, 0.5)
				for side in [-1.0, 1.0]:
					_mesh(_cube(Vector3(w + 0.08, 0.04, 0.03)), wood, Vector3(0, side * (h / 2 + 0.02), 0.015), root)
					_mesh(_cube(Vector3(0.04, h, 0.03)), wood, Vector3(side * (w / 2 + 0.02), 0, 0.015), root)
			var picture := QuadMesh.new()
			picture.size = Vector2(w, h)
			var face := _mesh(picture, _paint(Color.WHITE, 0.0, 0.8), Vector3(0, 0, 0.006), root)
			face.name = "Picture"
			_mesh(_cube(Vector3(w, h, 0.004)), _paint(Color(0.9, 0.9, 0.9)), Vector3(0, 0, 0.002), root)
		"marker":
			var body := CylinderMesh.new()
			body.top_radius = 0.011
			body.bottom_radius = 0.011
			body.height = 0.13
			var holder := Node3D.new()
			holder.rotation.x = -PI / 2           # lying along -Z: the tip points where you point
			root.add_child(holder)
			_mesh(body, _paint(Color(0.92, 0.94, 0.93), 0.0, 0.4), Vector3(0, 0.065, 0), holder)
			var tip := CylinderMesh.new()
			tip.top_radius = 0.002
			tip.bottom_radius = 0.009
			tip.height = 0.025
			var ink := _mesh(tip, _paint(ACCENT, 0.8), Vector3(0, 0.142, 0), holder)
			ink.name = "Tip"
			var cap := _mesh(_cube(Vector3(0.024, 0.03, 0.024)), _paint(ACCENT, 0.4), Vector3(0, 0.015, 0), holder)
			cap.name = "Band"
		"remote":
			var case_paint := _paint(Color(0.12, 0.13, 0.14), 0.0, 0.5)
			_mesh(_cube(Vector3(0.11, 0.035, 0.16)), case_paint, Vector3(0, 0.0175, 0), root)
			var antenna := CylinderMesh.new()
			antenna.top_radius = 0.003
			antenna.bottom_radius = 0.004
			antenna.height = 0.16
			_mesh(antenna, _paint(Color(0.7, 0.7, 0.72), 0.0, 0.3), Vector3(0.04, 0.1, -0.06), root)
			var stick := CylinderMesh.new()
			stick.top_radius = 0.012
			stick.bottom_radius = 0.012
			stick.height = 0.02
			for x in [-0.028, 0.028]:
				_mesh(stick, _paint(Color(0.25, 0.25, 0.27)), Vector3(x, 0.04, 0.02), root)
			_mesh(_cube(Vector3(0.012, 0.008, 0.012)), _paint(Color("ff4040"), 1.5), Vector3(-0.04, 0.038, -0.06), root)
		"hoop":
			# backboard (its back on the wall), a ring sticking out, a net, a score
			var board := _paint(Color(0.95, 0.96, 0.96, 0.92), 0.0, 0.3)
			_mesh(_cube(Vector3(0.9, 0.6, 0.03)), board, Vector3(0, 0.1, 0.015), root)
			var square := _paint(Color("ff5533"), 0.3)
			for side in [-1.0, 1.0]:
				_mesh(_cube(Vector3(0.3, 0.02, 0.005)), square, Vector3(0, side * 0.1 + 0.0, 0.032), root)
				_mesh(_cube(Vector3(0.02, 0.2, 0.005)), square, Vector3(side * 0.15, 0, 0.032), root)
			var ring := TorusMesh.new()
			ring.inner_radius = 0.215
			ring.outer_radius = 0.235
			_mesh(ring, _paint(Color("ff5533"), 0.2, 0.4), Vector3(0, -0.15, 0.27), root)
			var net := CylinderMesh.new()
			net.top_radius = 0.22
			net.bottom_radius = 0.15
			net.height = 0.3
			var mesh_paint := _paint(Color(1, 1, 1, 0.45))
			mesh_paint.cull_mode = BaseMaterial3D.CULL_DISABLED
			net.cap_top = false
			net.cap_bottom = false
			_mesh(net, mesh_paint, Vector3(0, -0.3, 0.27), root)
		"wall_clock":
			var face := CylinderMesh.new()
			face.top_radius = 0.2
			face.bottom_radius = 0.2
			face.height = 0.04
			var dial := _mesh(face, _paint(Color(0.95, 0.95, 0.92), 0.0, 0.4), Vector3(0, 0, 0.02), root)
			dial.rotation.x = PI / 2
			var rim := TorusMesh.new()
			rim.inner_radius = 0.195
			rim.outer_radius = 0.215
			var edge := _mesh(rim, _paint(Color(0.1, 0.12, 0.12), 0.0, 0.3), Vector3(0, 0, 0.03), root)
			edge.rotation.x = PI / 2
			for i in 12:
				var mark := _mesh(_cube(Vector3(0.012, 0.035 if i % 3 == 0 else 0.02, 0.004)), _paint(Color(0.1, 0.1, 0.1)), Vector3.ZERO, root)
				var a := i * TAU / 12.0
				mark.position = Vector3(sin(a) * 0.165, cos(a) * 0.165, 0.042)
				mark.rotation.z = -a
			for hand_name in [["Hour", 0.1, 0.012, Color(0.1, 0.1, 0.1)], ["Minute", 0.15, 0.008, Color(0.1, 0.1, 0.1)], ["Second", 0.16, 0.003, Color("ff4040")]]:
				var pivot := Node3D.new()
				pivot.name = hand_name[0]
				pivot.position.z = 0.046 + (0.002 if hand_name[0] == "Second" else 0.0)
				root.add_child(pivot)
				_mesh(_cube(Vector3(hand_name[2], hand_name[1], 0.003)), _paint(hand_name[3]), Vector3(0, hand_name[1] / 2 - 0.02, 0), pivot)
		"neon_goggles", "neon_gameon", "neon_heart":
			var text: String = {"neon_goggles": "GOGGLES", "neon_gameon": "GAME ON", "neon_heart": "♥"}[id]
			var back := _mesh(_cube(Vector3(0.95 if text.length() > 2 else 0.45, 0.32 if text.length() > 2 else 0.42, 0.02)),
					_paint(Color(0.05, 0.05, 0.06, 0.6)), Vector3(0, 0, 0.01), root)
			back.name = "Glass"
			var label := Label3D.new()
			label.name = "Neon"
			label.text = text
			label.font_size = 160 if text.length() > 2 else 360
			label.pixel_size = 0.001
			label.outline_size = 22
			label.position.z = 0.03
			label.double_sided = false
			root.add_child(label)
	return root


# ------------------------------------------------------------------ behaviours
static func attach(item: Node3D, what: String, home: Node) -> void:
	var does: Node = null
	match what:
		"tv": does = Tv.new()
		"radio": does = Radio.new()
		"blaster": does = Blaster.new()
		"target": does = Target.new()
		"marker": does = Marker.new()
		"remote": does = Remote.new()
		"rc_car": does = RcCar.new()
		"balloon": does = Balloon.new()
		"hoop": does = Hoop.new()
		"basketball": does = Thing.new()
		"pet": does = Pet.new()
		"mirror": does = Mirror.new()
		"clock": does = Clock.new()
		"neon": does = Neon.new()
		"poster": does = Poster.new()
		"arcade": does = Arcade.new()
		_: does = Thing.new()
	does.name = "Does"
	does.set("item", item)
	does.set("home", home)
	item.add_child(does)


## What every behaviour has: nothing happens unless it says so.
class Thing extends Node:
	var item: Node3D
	var home: Node
	func press(_hand: Dictionary) -> void:
		pass
	func in_hand(_hand: Dictionary, _input: Dictionary, _delta: float) -> bool:
		return false
	func hold() -> Transform3D:
		return Transform3D.IDENTITY
	func hit(_point: Vector3, push: Vector3) -> void:
		if item is RigidBody3D and not (item as RigidBody3D).freeze:
			(item as RigidBody3D).apply_central_impulse(push)
	func sound(name: String, pitch := 1.0) -> void:
		if home and home.has_method("play_at"):
			home.play_at(name, item.global_position, pitch)


## A TV or monitor that shows the PC's desktop: the trigger switches it on and off.
class Tv extends Thing:
	var screen: MeshInstance3D
	var on := false
	func _ready() -> void:
		var size: Vector3 = item.get_meta("size")
		var id: String = item.get_meta("item")
		# where the glass is on each model (fractions of the model's size; front faces +Z)
		var area: Array = {"tv_modern": [0.92, 0.72, 0.62], "Television_01": [0.62, 0.62, 0.55], "computerScreen": [0.92, 0.66, 0.62]}.get(id, [0.85, 0.7, 0.55])
		var quad := QuadMesh.new()
		quad.size = Vector2(size.x * area[0], size.y * area[1])
		screen = MeshInstance3D.new()
		screen.name = "Screen"
		screen.mesh = quad
		screen.position = Vector3(0, size.y * area[2], size.z / 2.0 + 0.004)
		item.add_child(screen)
		_show()
	func press(_hand: Dictionary) -> void:
		on = not on
		sound("click", 1.1 if on else 0.9)
		_show()
	func _show() -> void:
		var paint := StandardMaterial3D.new()
		paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if on and home and home.has_method("desktop_picture"):
			paint.albedo_texture = home.desktop_picture(self, true)
		else:
			paint.albedo_color = Color(0.02, 0.03, 0.03)
			if home and home.has_method("desktop_picture"):
				home.desktop_picture(self, false)
		screen.material_override = paint
	func _process(_delta: float) -> void:
		if on and home and screen.material_override.albedo_texture == null:
			var picture: Texture2D = home.desktop_picture(self, true)
			if picture:
				(screen.material_override as StandardMaterial3D).albedo_texture = picture
	func _exit_tree() -> void:
		if on and home and home.has_method("desktop_picture"):
			home.desktop_picture(self, false)


## A radio: the trigger plays the next tune, and after the last one switches off.
class Radio extends Thing:
	var player: AudioStreamPlayer3D
	var track := -1
	func _ready() -> void:
		player = AudioStreamPlayer3D.new()
		player.unit_size = 4.0
		player.volume_db = -6.0
		item.add_child(player)
	func press(_hand: Dictionary) -> void:
		var tunes: Array = home.music() if home and home.has_method("music") else []
		track += 1
		if track >= tunes.size():
			track = -1
			player.stop()
			home.say("Radio off")
			return
		var stream: AudioStream = tunes[track][1]
		if stream is AudioStreamOggVorbis:
			(stream as AudioStreamOggVorbis).loop = true
		player.stream = stream
		player.play()
		home.say("♪  " + str(tunes[track][0]))


## A laser blaster: the trigger fires a bolt that knocks things over and hits targets.
class Blaster extends Thing:
	var wait := 0.0
	func hold() -> Transform3D:
		# the barrel along the controller's pointing direction, the grip in the hand
		return Transform3D(Basis(Vector3.UP, PI), Vector3(0, -0.02, 0.03))
	func in_hand(hand: Dictionary, input: Dictionary, delta: float) -> bool:
		wait = maxf(0.0, wait - delta)
		if input.trigger and not hand.trigger and wait == 0.0:
			wait = 0.18
			_fire()
		return true
	func _fire() -> void:
		var forward := -item.global_transform.basis.z.normalized()
		var size: Vector3 = item.get_meta("size")
		var from := item.global_position + forward * (size.z / 2.0) + item.global_transform.basis.y * (size.y * 0.6)
		sound("laser", randf_range(0.95, 1.08))
		if home and home.has_method("fire_bolt"):
			home.fire_bolt(from, forward, item)


## A target on a stand: falls back when hit, stands up again, and counts.
class Target extends Thing:
	var hits := 0
	var label: Label3D
	var down := false
	func _ready() -> void:
		label = Label3D.new()
		label.text = "0"
		label.font_size = 96
		label.pixel_size = 0.0012
		label.outline_size = 14
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.modulate = Color("f1ff9c")
		label.position.y = (item.get_meta("size") as Vector3).y + 0.15
		item.add_child(label)
	func hit(_point: Vector3, _push: Vector3) -> void:
		if down:
			return
		hits += 1
		label.text = str(hits)
		sound("ding")
		down = true
		var model: Node3D = item.get_node("Model")
		var t := create_tween()
		t.tween_property(model, "rotation:x", -1.3, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		t.tween_interval(1.2)
		t.tween_property(model, "rotation:x", 0.0, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_callback(func(): down = false)


## A marker: hold the trigger to draw in the air; A or X changes the colour.
class Marker extends Thing:
	const COLOURS := [Color("3ddc84"), Color("ff6bb5"), Color("3dc8dc"), Color("f1ff9c"), Color("ffa23d"), Color.WHITE, Color("a06bff")]
	var colour := 0
	var stroke: MeshInstance3D
	var points: PackedVector3Array = []
	func _ready() -> void:
		colour = int(item.get_meta("colour", 0)) % COLOURS.size()
		_tint()
	func hold() -> Transform3D:
		return Transform3D(Basis.IDENTITY, Vector3(0, 0.0, 0.02))
	func tip() -> Vector3:
		return item.global_transform * Vector3(0, 0, -0.155)
	func in_hand(hand: Dictionary, input: Dictionary, _delta: float) -> bool:
		if input.ax and not hand.ax:
			colour = (colour + 1) % COLOURS.size()
			item.set_meta("colour", colour)
			_tint()
			sound("click")
		if input.trigger:
			if stroke == null:
				_begin()
			var at := tip()
			if points.is_empty() or points[points.size() - 1].distance_to(at) > 0.004:
				points.append(at)
				_draw_stroke()
		elif stroke:
			stroke = null
			points = PackedVector3Array()
		return true
	func _tint() -> void:
		var paint := _paint_of(COLOURS[colour])
		for name in ["Tip", "Band"]:
			var node := item.find_child(name, true, false) as MeshInstance3D
			if node:
				node.material_override = paint
	static func _paint_of(c: Color) -> StandardMaterial3D:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = c
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		return m
	func _begin() -> void:
		stroke = MeshInstance3D.new()
		stroke.mesh = ImmediateMesh.new()
		stroke.material_override = _paint_of(COLOURS[colour])
		stroke.set_meta("drawing", true)
		points = PackedVector3Array()
		if home and home.has_method("drawings"):
			home.drawings().add_child(stroke)
	## A flat ribbon facing your head, 7 mm wide.
	func _draw_stroke() -> void:
		var mesh := stroke.mesh as ImmediateMesh
		mesh.clear_surfaces()
		if points.size() < 2:
			return
		var eye: Vector3 = home.head_position() if home and home.has_method("head_position") else Vector3.UP * 1.6
		mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		for i in points.size():
			var along := (points[mini(i + 1, points.size() - 1)] - points[maxi(i - 1, 0)]).normalized()
			var side := along.cross((eye - points[i]).normalized()).normalized() * 0.0035
			mesh.surface_add_vertex(points[i] - side)
			mesh.surface_add_vertex(points[i] + side)
		mesh.surface_end()


## The remote for the RC cars: while you hold it, the stick drives the nearest car.
class Remote extends Thing:
	func hold() -> Transform3D:
		return Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-30)), Vector3(0, -0.02, -0.02))
	func in_hand(_hand: Dictionary, input: Dictionary, _delta: float) -> bool:
		var car := _nearest_car()
		if car:
			car.get_node("Does").call("drive", input.stick.y, input.stick.x)
		return input.trigger
	func _nearest_car() -> Node3D:
		var best: Node3D = null
		for other in item.get_parent().get_children():
			if other.has_node("Does") and other.get_node("Does") is RcCar:
				if best == null or other.global_position.distance_to(item.global_position) < best.global_position.distance_to(item.global_position):
					best = other
		return best


## An RC car: drives about when a remote tells it to; its wheels turn.
class RcCar extends Thing:
	var throttle := 0.0
	var steer := 0.0
	var told := 0.0
	var engine: AudioStreamPlayer3D
	var wheels: Array[Node3D] = []
	func _ready() -> void:
		for node in item.find_children("wheel-*", "", true, false):
			wheels.append(node)
		var body := item as RigidBody3D
		body.linear_damp = 1.2
		body.angular_damp = 6.0
		body.mass = 1.5
		var tyres := PhysicsMaterial.new()      # its box slides; the push is the "engine"
		tyres.friction = 0.05
		tyres.bounce = 0.1
		body.physics_material_override = tyres
		engine = AudioStreamPlayer3D.new()
		engine.unit_size = 1.5
		engine.volume_db = -14.0
		item.add_child(engine)
		if home and home.has_method("sound_stream"):
			var s: AudioStream = home.sound_stream("engine")
			if s is AudioStreamOggVorbis:
				(s as AudioStreamOggVorbis).loop = true
			engine.stream = s
	func drive(forward: float, turn: float) -> void:
		throttle = forward if absf(forward) > 0.1 else 0.0
		steer = turn if absf(turn) > 0.1 else 0.0
		told = 0.3
	func _physics_process(delta: float) -> void:
		told = maxf(0.0, told - delta)
		if told == 0.0:
			throttle = 0.0
			steer = 0.0
		var body := item as RigidBody3D
		if body.freeze:
			return
		var forward := item.global_transform.basis.z.normalized()      # the toy cars face +Z
		forward.y = 0
		var speed := body.linear_velocity.dot(forward)
		if throttle != 0.0:
			body.apply_central_force(forward * throttle * CAR_FORCE)
		if steer != 0.0 and absf(speed) > 0.05:
			body.angular_velocity.y = -steer * 3.2 * signf(speed)
		for wheel in wheels:
			wheel.rotate_x(speed * delta / 0.03)
		if engine.stream:
			var going := absf(speed) > 0.05 or throttle != 0.0
			if going and not engine.playing:
				engine.play()
			elif not going and engine.playing:
				engine.stop()
			engine.pitch_scale = 0.7 + absf(speed) * 0.5


## A balloon: floats up slowly and bobs against the ceiling.
class Balloon extends Thing:
	func _ready() -> void:
		var body := item as RigidBody3D
		body.gravity_scale = -0.06
		body.linear_damp = 1.6
		body.angular_damp = 2.0
		body.mass = 0.02
		var c: Color = Color.from_hsv(randf(), 0.7, 1.0) if not item.has_meta("colour") else Color.from_string(str(item.get_meta("colour")), Color.HOT_PINK)
		item.set_meta("colour", c.to_html(false))
		var paint := StandardMaterial3D.new()
		paint.albedo_color = c
		paint.roughness = 0.2
		paint.metallic = 0.15
		var model: Node3D = item.get_node("Model")
		for mesh in model.find_children("*", "MeshInstance3D", true, false):
			if (mesh as MeshInstance3D).mesh is SphereMesh or (mesh as MeshInstance3D).mesh is CylinderMesh and ((mesh as MeshInstance3D).mesh as CylinderMesh).height < 0.1:
				(mesh as MeshInstance3D).material_override = paint
	func hit(_point: Vector3, push: Vector3) -> void:
		sound("pop")
		(item as RigidBody3D).apply_central_impulse(push * 0.05)


## A basketball hoop on the wall: a ball dropping through the ring scores.
class Hoop extends Thing:
	var score := 0
	var label: Label3D
	var ring := Vector3(0, -0.15, 0.27)
	var inside := {}
	func _ready() -> void:
		label = Label3D.new()
		label.text = "0"
		label.font_size = 120
		label.pixel_size = 0.001
		label.outline_size = 0
		label.modulate = Color("ff5533")
		label.position = Vector3(0, 0.28, 0.035)
		item.add_child(label)
		# only the backboard is solid, and the ring: a circle of small boxes, so balls bounce
		# off its edge and drop through the middle
		var body := item as CollisionObject3D
		for child in item.get_children():
			if child is CollisionShape3D:
				var board := BoxShape3D.new()
				board.size = Vector3(0.9, 0.6, 0.04)
				(child as CollisionShape3D).shape = board
				(child as CollisionShape3D).position = Vector3(0, 0.1, 0.02)
				break
		for i in 16:
			var a := i * TAU / 16.0
			var piece := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(0.09, 0.02, 0.02)
			piece.shape = box
			piece.position = ring + Vector3(cos(a) * 0.225, 0, sin(a) * 0.225)
			piece.rotation.y = -a + PI / 2
			body.add_child(piece)
	func _physics_process(_delta: float) -> void:
		var centre := item.global_transform * ring
		for ball in item.get_parent().get_children():
			if not (ball is RigidBody3D) or not str(ball.get_meta("item", "")) in ["ball", "basketball"]:
				continue
			var offset: Vector3 = ball.global_position - centre
			var flat := Vector2(offset.x, offset.z).length()
			var key := ball.get_instance_id()
			if flat < 0.2 and offset.y > 0.0 and offset.y < 0.25:
				inside[key] = true
			elif inside.has(key) and offset.y < -0.05:
				inside.erase(key)
				if flat < 0.24 and (ball as RigidBody3D).linear_velocity.y < 0.0:
					score += 1
					label.text = str(score)
					sound("score")
					if home and home.has_method("say"):
						home.say("Score!  %d" % score)
			elif offset.length() > 1.0:
				inside.erase(key)


## A pet: wanders about, comes to you when you're far away, and the dog fetches balls.
class Pet extends Thing:
	var goal := Vector3.ZERO
	var has_goal := false
	var wait := 0.0
	var carrying: RigidBody3D
	var chasing: RigidBody3D
	var hop := 0.0
	var model: Node3D
	var base_y := 0.0
	func _ready() -> void:
		model = item.get_node("Model")
		base_y = model.position.y
		var body := item as RigidBody3D
		body.linear_damp = 3.0
		body.angular_damp = 8.0
	func press(_hand: Dictionary) -> void:
		sound("pet", randf_range(0.9, 1.25))
		var t := create_tween()                # a happy little jump
		t.tween_property(model, "position:y", base_y + 0.12, 0.12).set_ease(Tween.EASE_OUT)
		t.tween_property(model, "position:y", base_y, 0.18).set_ease(Tween.EASE_IN)
	func _physics_process(delta: float) -> void:
		var body := item as RigidBody3D
		if body.freeze:
			has_goal = false
			_drop()
			return
		var head: Vector3 = home.head_position() if home and home.has_method("head_position") else Vector3.ZERO
		var feet := Vector3(head.x, item.global_position.y, head.z)
		var same_floor := absf(head.y - 1.5 - item.global_position.y) < 1.5
		wait = maxf(0.0, wait - delta)
		# The dog fetches: a ball lying (or rolling) on its floor, not in anyone's hand
		if str(item.get_meta("item", "")) == "pet_dog" and carrying == null and chasing == null:
			for other in item.get_parent().get_children():
				if other is RigidBody3D and str(other.get_meta("item", "")) in ["ball", "basketball"] and not other.freeze \
						and absf(other.global_position.y - item.global_position.y) < 0.8 and other.global_position.distance_to(feet) > 1.2:
					chasing = other
					break
		if chasing and (not is_instance_valid(chasing) or chasing.freeze):
			chasing = null
		if chasing:
			goal = chasing.global_position
			has_goal = true
			if item.global_position.distance_to(Vector3(goal.x, item.global_position.y, goal.z)) < 0.3:
				carrying = chasing
				chasing = null
				carrying.freeze = true
				carrying.collision_layer = 0
				sound("pet", 1.3)
		elif carrying:
			goal = feet
			has_goal = true
			if item.global_position.distance_to(feet) < 0.7:
				_drop()
				wait = 2.0
		elif same_floor and item.global_position.distance_to(feet) > 3.0:
			goal = feet
			has_goal = true
		elif not has_goal and wait == 0.0:
			var a := randf() * TAU
			goal = item.global_position + Vector3(cos(a), 0, sin(a)) * randf_range(0.6, 1.8)
			has_goal = true
		if carrying:
			carrying.global_position = item.global_transform * Vector3(0, (item.get_meta("size") as Vector3).y * 0.55, (item.get_meta("size") as Vector3).z * 0.55)
		var to := goal - item.global_position
		to.y = 0
		var moving := has_goal and to.length() > 0.25
		if moving:
			var dir := to.normalized()
			var speed := PET_SPEED * (1.6 if chasing or carrying else 1.0)
			body.linear_velocity = Vector3(dir.x * speed, body.linear_velocity.y, dir.z * speed)
			var want := atan2(dir.x, dir.z)
			item.rotation.y = lerp_angle(item.rotation.y, want, 1.0 - pow(0.001, delta))
			hop += delta * 14.0
			model.position.y = base_y + absf(sin(hop)) * 0.03
		else:
			if has_goal:
				has_goal = false
				wait = randf_range(1.0, 4.0)
			body.linear_velocity = Vector3(0, body.linear_velocity.y, 0)
			model.position.y = lerpf(model.position.y, base_y, 0.2)
	func _drop() -> void:
		if carrying and is_instance_valid(carrying):
			carrying.collision_layer = 4
			carrying.freeze = false
			carrying.linear_velocity = Vector3(0, 1.0, 0)
		carrying = null


## A mirror: shows the room, your hands and a Goggles head where yours is.
class Mirror extends Thing:
	const LAYER := 1 << 19
	const GLASS_LAYER := 1 << 18
	var view: SubViewport
	var eye: Camera3D
	var glass: MeshInstance3D
	var size := Vector2(0.4, 0.6)
	func _ready() -> void:
		var whole: Vector3 = item.get_meta("size")
		size = Vector2(whole.x * 0.72, whole.y * 0.78)
		view = SubViewport.new()
		view.size = Vector2i(512, int(512 * size.y / size.x))
		view.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
		item.add_child(view)
		eye = Camera3D.new()
		eye.projection = Camera3D.PROJECTION_FRUSTUM
		eye.cull_mask = 0xFFFFF & ~GLASS_LAYER       # everything but mirror glass (itself)
		view.add_child(eye)
		var quad := QuadMesh.new()
		quad.size = size
		glass = MeshInstance3D.new()
		glass.name = "Glass"
		glass.mesh = quad
		glass.position = Vector3(0, 0, whole.z + 0.003)
		var paint := StandardMaterial3D.new()
		paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		paint.albedo_texture = view.get_texture()
		paint.uv1_scale = Vector3(-1, 1, 1)    # a mirror shows left as right
		paint.uv1_offset = Vector3(1, 0, 0)
		glass.material_override = paint
		glass.layers = GLASS_LAYER
		item.add_child(glass)
		if home and home.has_method("show_avatar"):
			home.show_avatar(LAYER)
	func _process(_delta: float) -> void:
		if not (home and home.has_method("head_position")):
			return
		var head: Vector3 = home.head_position()
		var plane := glass.global_transform
		var normal := plane.basis.z.normalized()
		var local := plane.affine_inverse() * head
		if local.z < 0.05 or local.length() > 6.0:     # behind it, or far away: don't bother
			view.render_target_update_mode = SubViewport.UPDATE_DISABLED
			return
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		# the eye behind the glass, at your mirror image, looking straight through it
		var mirrored := head - 2.0 * normal * (head - plane.origin).dot(normal)
		eye.global_transform = Transform3D(Basis.looking_at(-normal, plane.basis.y), mirrored)
		var near := maxf(local.z, 0.05)
		eye.set_frustum(size.y, Vector2(-local.x, -local.y), near, 40.0)
		eye.keep_aspect = Camera3D.KEEP_HEIGHT


## A clock on the wall that shows the time.
class Clock extends Thing:
	func _process(_delta: float) -> void:
		var now := Time.get_time_dict_from_system()
		var model: Node3D = item.get_node("Model")
		var s := float(now.second)
		var m := float(now.minute) + s / 60.0
		var h := float(now.hour % 12) + m / 60.0
		model.get_node("Second").rotation.z = -s / 60.0 * TAU
		model.get_node("Minute").rotation.z = -m / 60.0 * TAU
		model.get_node("Hour").rotation.z = -h / 12.0 * TAU


## A neon sign: glows on the wall; the trigger changes its colour.
class Neon extends Thing:
	const COLOURS := [Color("3ddc84"), Color("ff3fa4"), Color("3dc8ff"), Color("ffd23d"), Color("b06bff"), Color("ff5a3d")]
	var light: OmniLight3D
	func _ready() -> void:
		light = OmniLight3D.new()
		light.position = Vector3(0, 0, 0.3)
		light.omni_range = 2.2
		light.light_energy = 0.8
		item.add_child(light)
		_tint()
	func press(_hand: Dictionary) -> void:
		item.set_meta("colour", (int(item.get_meta("colour", 0)) + 1) % COLOURS.size())
		sound("click")
		_tint()
	func _tint() -> void:
		var c: Color = COLOURS[int(item.get_meta("colour", 0)) % COLOURS.size()]
		var label := item.find_child("Neon", true, false) as Label3D
		if label:
			label.modulate = c.lightened(0.55)
			label.outline_modulate = Color(c, 0.85)
		light.light_color = c


## A poster or framed picture: one of your pictures (meta "picture"), or a game's cover.
class Poster extends Thing:
	func _ready() -> void:
		var face := item.find_child("Picture", true, false) as MeshInstance3D
		if face == null:
			return
		var path := str(item.get_meta("picture", ""))
		var image := Image.load_from_file(path) if path != "" and FileAccess.file_exists(path) else null
		if image == null and home and home.has_method("default_picture"):
			image = home.default_picture()
			if image:
				item.set_meta("picture", str(image.get_meta("path", "")))
		if image == null:
			return
		if maxi(image.get_width(), image.get_height()) > 1024:
			var f := 1024.0 / maxf(image.get_width(), image.get_height())
			image.resize(int(image.get_width() * f), int(image.get_height() * f), Image.INTERPOLATE_LANCZOS)
		image.generate_mipmaps()
		var quad := face.mesh as QuadMesh
		var longest := maxf(quad.size.x, quad.size.y)
		var aspect := float(image.get_width()) / image.get_height()
		quad.size = Vector2(longest, longest / aspect) if aspect >= 1.0 else Vector2(longest * aspect, longest)
		var paint := StandardMaterial3D.new()
		paint.albedo_texture = ImageTexture.create_from_image(image)
		paint.roughness = 0.8
		face.material_override = paint
		# the frame (or the poster's backing) follows the picture's shape
		for node in item.get_node("Model").get_children():
			if node != face and node is MeshInstance3D and (node as MeshInstance3D).mesh is BoxMesh:
				var box := (node as MeshInstance3D).mesh as BoxMesh
				if box.size.z < 0.01:
					box.size = Vector3(quad.size.x, quad.size.y, box.size.z)
				elif box.size.x > box.size.y:
					box.size.x = quad.size.x + 0.08
					node.position.y = signf(node.position.y) * (quad.size.y / 2 + 0.02)
				else:
					box.size.y = quad.size.y
					node.position.x = signf(node.position.x) * (quad.size.x / 2 + 0.02)


## An arcade machine: lit up; the trigger plays a little tune and flashes it.
class Arcade extends Thing:
	var light: OmniLight3D
	var t := 0.0
	func _ready() -> void:
		light = OmniLight3D.new()
		var size: Vector3 = item.get_meta("size")
		light.position = Vector3(0, size.y * 0.7, size.z * 0.6)
		light.omni_range = 1.6
		light.light_energy = 0.6
		light.light_color = Color("3dc8ff")
		item.add_child(light)
	func press(_hand: Dictionary) -> void:
		sound("arcade")
		t = 1.5
	func _process(delta: float) -> void:
		t = maxf(0.0, t - delta)
		light.light_color = Color.from_hsv(fmod(Time.get_ticks_msec() / 3000.0, 1.0), 0.6, 1.0) if t > 0 else Color("3dc8ff")
		light.light_energy = 0.6 + (0.8 * absf(sin(t * 12.0)) if t > 0 else 0.15 * sin(Time.get_ticks_msec() / 700.0))
