extends Node3D
## The first-time tour of Goggles Home: a card that floats a little below your view and walks
## you through the controls, one step at a time. Each step ends when you have done it (main.gd
## calls did("teleport") and so on), or with the trigger on "Next". It can be replayed from the
## Home menu (Settings), and skipped.

signal finished

const STEPS := [
	["welcome", "Welcome to Goggles Home", "This is your place between games. Point at the card and pull the trigger on Next.", true],
	["teleport", "Moving around", "Push a stick forward, point at the floor and let go: you jump there.", false],
	["turn", "Turning", "Push a stick left or right to turn.", false],
	["menu", "The Home menu", "Press B or Y. It has furniture, gadgets, your pictures, the look of the house and settings.", false],
	["spawn", "Bring something in", "Pick anything in the Furniture tab: it appears in front of you.", false],
	["grab", "Move things", "Point at something and hold grip. Furniture slides where you point; the stick turns it. A or X takes it away.", false],
	["use", "Use things", "Pull the trigger on a lamp, TV, radio or pet. Pick up the blaster, the marker or the RC remote and use the trigger.", true],
	["tape", "Play a game", "Your games are VHS tapes on the shelf by the right-hand wall. Take one and put it into the VHS player next to it.", true],
	["upstairs", "Upstairs", "Walk up the stairs, or point at a green pad and pull the trigger. The light switches set the mood.", true],
	["done", "That's it", "The menu button on the left controller opens the GogglesXR dashboard. Have fun!", true],
]

var step := -1
var card: Node3D
var title: Label3D
var body: Label3D
var progress: Label3D
var next_button: StaticBody3D
var skip_button: StaticBody3D
var head: Node3D                           # the XR camera, to stay in view


func _init(camera: Node3D) -> void:
	head = camera
	card = Node3D.new()
	card.visible = false
	add_child(card)
	var back := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.62, 0.3)
	back.mesh = quad
	var paint := StandardMaterial3D.new()
	paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	paint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	paint.albedo_color = Color(0.03, 0.1, 0.09, 0.9)
	back.material_override = paint
	card.add_child(back)
	var edge := MeshInstance3D.new()
	var line := QuadMesh.new()
	line.size = Vector2(0.62, 0.006)
	edge.mesh = line
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color("3ddc84")
	edge.material_override = glow
	edge.position = Vector3(0, 0.147, 0.001)
	card.add_child(edge)
	title = _text(54, Vector3(-0.29, 0.1, 0.002), Color("3ddc84"))
	body = _text(36, Vector3(-0.29, 0.055, 0.002), Color("e6f3ee"))
	body.width = 1080
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	progress = _text(28, Vector3(-0.29, -0.118, 0.002), Color("9fbfb4"))
	next_button = _button("Next  ▶", Vector3(0.21, -0.11, 0.003), "next")
	skip_button = _button("Skip tour", Vector3(0.07, -0.11, 0.003), "skip")


func _text(size: int, at: Vector3, colour: Color) -> Label3D:
	var label := Label3D.new()
	label.font_size = size
	label.pixel_size = 0.0005
	label.modulate = colour
	label.outline_size = 0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.position = at
	card.add_child(label)
	return label


func _button(text: String, at: Vector3, what: String) -> StaticBody3D:
	var button := StaticBody3D.new()
	button.collision_layer = 16
	button.set_meta("tour", what)
	button.position = at
	card.add_child(button)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.12, 0.045, 0.01)
	shape.shape = box
	button.add_child(shape)
	var face := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.12, 0.045)
	face.mesh = quad
	var paint := StandardMaterial3D.new()
	paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	paint.albedo_color = Color("3ddc84") if what == "next" else Color(1, 1, 1, 0.12)
	paint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	face.material_override = paint
	button.add_child(face)
	var label := Label3D.new()
	label.text = text
	label.font_size = 30
	label.pixel_size = 0.0005
	label.outline_size = 0
	label.modulate = Color("052012") if what == "next" else Color("e6f3ee")
	label.position.z = 0.001
	button.add_child(label)
	return button


func running() -> bool:
	return step >= 0


func start() -> void:
	step = 0
	card.visible = true
	_show()
	_place(true)


func stop() -> void:
	step = -1
	card.visible = false
	finished.emit()


## Something was done: move on if it's what this step asks for.
func did(what: String) -> void:
	if step < 0:
		return
	if STEPS[step][0] == what:
		_next()


## The trigger on one of the card's buttons.
func press(what: String) -> void:
	if what == "skip":
		stop()
	elif what == "next":
		_next()


func _next() -> void:
	step += 1
	if step >= STEPS.size():
		stop()
		return
	_show()
	# a little pop, so you notice it changed
	card.scale = Vector3.ONE * 0.9
	create_tween().tween_property(card, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _show() -> void:
	var s: Array = STEPS[step]
	title.text = s[1]
	body.text = s[2]
	progress.text = "%d / %d" % [step + 1, STEPS.size()]
	var label := next_button.get_child(2) as Label3D
	label.text = "Done  ✓" if step == STEPS.size() - 1 else ("Next  ▶" if s[3] else "Skip step  ▶")


## Keep the card low in front of you; it follows when you turn away or walk off.
func _place(now := false) -> void:
	var forward := -head.global_transform.basis.z
	forward.y = 0
	forward = forward.normalized() if forward.length() > 0.05 else Vector3.FORWARD
	var want := head.global_position + forward * 0.85 + Vector3.DOWN * 0.32
	var to_card := card.global_position - head.global_position
	to_card.y = 0
	var off_angle := forward.angle_to(to_card.normalized()) if to_card.length() > 0.05 else PI
	if now or off_angle > deg_to_rad(40) or card.global_position.distance_to(want) > 0.8:
		var t := Transform3D(Basis.looking_at(-(head.global_position - want).normalized() * Vector3(1, 0, 1), Vector3.UP), want)
		if now:
			card.global_transform = t
		else:
			card.global_transform = card.global_transform.interpolate_with(t, 0.08)
	# lean back a little, towards your eyes
	card.rotation.x = deg_to_rad(-22)


func _process(_delta: float) -> void:
	if step >= 0:
		_place()
