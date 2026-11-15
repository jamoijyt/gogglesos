extends Node3D
## The things you put in Goggles Home: furniture, lamps and toys.
##
## Models are Kenney's Furniture Kit (models/README.md), loaded when first needed. Each thing is
## a physics body, so the laser can find it, other things can stand on it, and toys bounce off
## it. What is in the room, and where, is kept in home.json by main.gd (save() / restore()).
##
## Kinds:
##   "floor"  stands where you put it (on the floor, or on top of other furniture)
##   "lamp"   the same, with a light that the trigger switches on and off
##   "prop"   a toy: pick it up, carry it, throw it

const MODEL_DIR := "res://models"
const SCALE := 2.0                        # the kit is modelled at half size
const LAYER_FURNITURE := 2
const LAYER_PROP := 4
const MAX_ITEMS := 120

# id -> [name, category, kind]. "ball" and "block" are made here, not loaded.
const CATALOGUE := {
	"loungeSofa": ["Sofa", "Seating", "floor"], "loungeSofaLong": ["Long sofa", "Seating", "floor"],
	"loungeSofaCorner": ["Corner sofa", "Seating", "floor"], "loungeSofaOttoman": ["Ottoman", "Seating", "floor"],
	"loungeDesignSofa": ["Design sofa", "Seating", "floor"], "loungeChair": ["Armchair", "Seating", "floor"],
	"loungeChairRelax": ["Recliner", "Seating", "floor"], "loungeDesignChair": ["Design chair", "Seating", "floor"],
	"chairCushion": ["Chair", "Seating", "floor"], "chairDesk": ["Desk chair", "Seating", "floor"],
	"chairModernCushion": ["Modern chair", "Seating", "floor"], "chairRounded": ["Round chair", "Seating", "floor"],
	"benchCushion": ["Bench", "Seating", "floor"], "stoolBar": ["Bar stool", "Seating", "floor"],
	"table": ["Table", "Tables", "floor"], "tableRound": ["Round table", "Tables", "floor"],
	"tableGlass": ["Glass table", "Tables", "floor"], "tableCross": ["Trestle table", "Tables", "floor"],
	"tableCoffee": ["Coffee table", "Tables", "floor"], "tableCoffeeGlass": ["Glass coffee table", "Tables", "floor"],
	"tableCoffeeSquare": ["Square coffee table", "Tables", "floor"], "desk": ["Desk", "Tables", "floor"],
	"deskCorner": ["Corner desk", "Tables", "floor"], "sideTable": ["Side table", "Tables", "floor"],
	"sideTableDrawers": ["Side table, drawers", "Tables", "floor"],
	"bookcaseOpen": ["Bookcase", "Storage", "floor"], "bookcaseOpenLow": ["Low bookcase", "Storage", "floor"],
	"bookcaseClosedWide": ["Wide bookcase", "Storage", "floor"], "bookcaseClosedDoors": ["Cupboard", "Storage", "floor"],
	"cabinetTelevision": ["TV cabinet", "Storage", "floor"], "cabinetTelevisionDoors": ["TV cabinet, doors", "Storage", "floor"],
	"cabinetBedDrawer": ["Bedside cabinet", "Storage", "floor"], "coatRackStanding": ["Coat stand", "Storage", "floor"],
	"kitchenBar": ["Bar counter", "Storage", "floor"], "kitchenFridge": ["Fridge", "Storage", "floor"],
	"bedDouble": ["Double bed", "Storage", "floor"], "bedSingle": ["Single bed", "Storage", "floor"],
	"bedBunk": ["Bunk bed", "Storage", "floor"],
	"lampRoundFloor": ["Floor lamp", "Lights & tech", "lamp"], "lampSquareFloor": ["Square floor lamp", "Lights & tech", "lamp"],
	"lampRoundTable": ["Table lamp", "Lights & tech", "lamp"], "lampSquareTable": ["Square table lamp", "Lights & tech", "lamp"],
	"televisionModern": ["Television", "Lights & tech", "floor"], "televisionVintage": ["Old television", "Lights & tech", "floor"],
	"computerScreen": ["Monitor", "Lights & tech", "floor"], "computerKeyboard": ["Keyboard", "Lights & tech", "floor"],
	"laptop": ["Laptop", "Lights & tech", "floor"], "speaker": ["Speaker", "Lights & tech", "floor"],
	"speakerSmall": ["Small speaker", "Lights & tech", "floor"], "radio": ["Radio", "Lights & tech", "floor"],
	"pottedPlant": ["Potted plant", "Decor", "floor"], "plantSmall1": ["Small plant", "Decor", "floor"],
	"plantSmall2": ["Leafy plant", "Decor", "floor"], "plantSmall3": ["Cactus", "Decor", "floor"],
	"rugRectangle": ["Rug", "Decor", "floor"], "rugRound": ["Round rug", "Decor", "floor"],
	"rugSquare": ["Square rug", "Decor", "floor"], "rugRounded": ["Soft-edged rug", "Decor", "floor"],
	"trashcan": ["Bin", "Decor", "floor"],
	"ball": ["Ball", "Toys", "prop"], "block": ["Block", "Toys", "prop"], "bear": ["Bear head", "Toys", "prop"],
	"pillow": ["Pillow", "Toys", "prop"], "pillowBlue": ["Blue pillow", "Toys", "prop"],
	"books": ["Books", "Toys", "prop"], "cardboardBoxClosed": ["Cardboard box", "Toys", "prop"],
	"computerMouse": ["Mouse", "Toys", "prop"],
}
const CATEGORIES := ["Seating", "Tables", "Storage", "Lights & tech", "Decor", "Toys"]
const BLOCK_COLOURS := [Color("3ddc84"), Color("f1ff9c"), Color("3dc8dc"), Color("ff6bb5"), Color("ffa23d"), Color("a06bff")]

var _models := {}                         # id -> Node3D to copy from (or null if it couldn't be loaded)
var _made := 0


static func kind_of(id: String) -> String:
	return str(CATALOGUE[id][2]) if CATALOGUE.has(id) else ""


func items() -> Array[Node]:
	return get_children().filter(func(n): return n.has_meta("item") and not n.is_queued_for_deletion())


## The model for a catalogue id, ready to be copied; null if there is no such file.
func _model(id: String) -> Node3D:
	if _models.has(id):
		return _models[id]
	var node: Node3D = null
	if id == "ball" or id == "block":
		var shape := MeshInstance3D.new()
		if id == "ball":
			var ball := SphereMesh.new()
			ball.radius = 0.11
			ball.height = 0.22
			shape.mesh = ball
		else:
			var cube := BoxMesh.new()
			cube.size = Vector3(0.16, 0.16, 0.16)
			shape.mesh = cube
		shape.position.y = 0.11 if id == "ball" else 0.08
		node = Node3D.new()
		node.add_child(shape)
	else:
		var path := ProjectSettings.globalize_path(MODEL_DIR.path_join(id + ".glb"))
		if FileAccess.file_exists(path):
			var document := GLTFDocument.new()
			var state := GLTFState.new()
			if document.append_from_file(path, state) == OK:
				var scene := document.generate_scene(state)
				if scene is Node3D:
					node = Node3D.new()
					scene.scale = Vector3.ONE * SCALE
					node.add_child(scene)
	_models[id] = node
	return node


## The space a model takes up, in its own coordinates.
static func bounds(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mesh in node.find_children("*", "MeshInstance3D", true, false) + ([node] if node is MeshInstance3D else []):
		var m := mesh as MeshInstance3D
		if m.mesh == null:
			continue
		var to_root := Transform3D.IDENTITY
		var n: Node3D = m
		while n != node and n != null:
			to_root = n.transform * to_root
			n = n.get_parent() as Node3D
		var part := to_root * m.mesh.get_aabb()
		box = part if first else box.merge(part)
		first = false
	return box


## Put a new thing in the room. -> the thing (a physics body), or null.
func spawn(id: String, at: Transform3D, lit := true) -> Node3D:
	if not CATALOGUE.has(id) or items().size() >= MAX_ITEMS:
		return null
	var source := _model(id)
	if source == null:
		return null
	var model := source.duplicate() as Node3D
	var kind := kind_of(id)
	var item: PhysicsBody3D
	if kind == "prop":
		var toy := RigidBody3D.new()
		toy.mass = 0.4
		toy.continuous_cd = true
		toy.collision_layer = LAYER_PROP
		toy.collision_mask = 1 | LAYER_FURNITURE | LAYER_PROP
		var bounce := PhysicsMaterial.new()
		bounce.bounce = 0.75 if id == "ball" else 0.15
		bounce.friction = 0.6
		toy.physics_material_override = bounce
		item = toy
	else:
		var solid := StaticBody3D.new()
		solid.collision_layer = LAYER_FURNITURE
		item = solid
	_made += 1
	item.name = "%s_%d" % [id, _made]
	item.set_meta("item", id)
	item.set_meta("kind", kind)
	# Centre the model over the body's origin, standing on it, so things turn around their middle
	var box := bounds(model)
	model.position = Vector3(-box.get_center().x, -box.position.y, -box.get_center().z)
	item.add_child(model)
	var shape := CollisionShape3D.new()
	if id == "ball":
		var round_shape := SphereShape3D.new()
		round_shape.radius = 0.11
		shape.shape = round_shape
	else:
		var box_shape := BoxShape3D.new()
		box_shape.size = Vector3(maxf(box.size.x, 0.04), maxf(box.size.y, 0.03), maxf(box.size.z, 0.04))
		shape.shape = box_shape
	shape.position.y = maxf(box.size.y, 0.03) / 2.0
	item.add_child(shape)
	item.set_meta("size", box.size)
	if id == "ball" or id == "block":
		var paint := StandardMaterial3D.new()
		paint.albedo_color = BLOCK_COLOURS[_made % BLOCK_COLOURS.size()]
		paint.roughness = 0.4
		(model.get_child(0) as MeshInstance3D).material_override = paint
	if kind == "lamp":
		var light := OmniLight3D.new()
		light.name = "Light"
		light.position.y = box.size.y * 0.85
		light.omni_range = 4.5
		light.light_energy = 1.6
		light.light_color = Color(1.0, 0.86, 0.66)
		item.add_child(light)
		var bulb := MeshInstance3D.new()      # a glow you can see when it is on
		bulb.name = "Bulb"
		var ball := SphereMesh.new()
		ball.radius = 0.05
		ball.height = 0.1
		bulb.mesh = ball
		var glow := StandardMaterial3D.new()
		glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glow.albedo_color = Color(1.0, 0.9, 0.7)
		bulb.material_override = glow
		bulb.position.y = box.size.y * 0.85
		item.add_child(bulb)
		set_lit(item, lit)
	add_child(item)
	item.global_transform = at
	return item


static func set_lit(item: Node3D, on: bool) -> void:
	if item.has_node("Light"):
		item.get_node("Light").visible = on
		item.get_node("Bulb").visible = on
		item.set_meta("lit", on)


static func is_lit(item: Node3D) -> bool:
	return bool(item.get_meta("lit", false))


func remove(item: Node3D) -> void:
	item.remove_meta("item")
	item.queue_free()


func clear() -> void:
	for item in items():
		remove(item)


## A glow around something the laser is on (or none).
static func highlight(item: Node3D, on: bool) -> void:
	if item == null or not is_instance_valid(item):
		return
	for mesh in item.find_children("*", "MeshInstance3D", true, false):
		if mesh.name == "Bulb":
			continue
		var overlay: StandardMaterial3D = null
		if on:
			overlay = StandardMaterial3D.new()
			overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			overlay.albedo_color = Color(0.24, 0.86, 0.52, 0.22)
		(mesh as MeshInstance3D).material_overlay = overlay


# ------------------------------------------------------------------ remembering the room
func save() -> Array:
	var list := []
	for item in items():
		var t: Transform3D = item.global_transform
		var entry := {"id": item.get_meta("item"), "x": snappedf(t.origin.x, 0.001), "y": snappedf(t.origin.y, 0.001),
				"z": snappedf(t.origin.z, 0.001), "turn": snappedf(t.basis.get_euler().y, 0.001)}
		if item.get_meta("kind") == "prop":
			# toys can lie any way up
			var q := t.basis.get_rotation_quaternion()
			entry["q"] = [snappedf(q.x, 0.001), snappedf(q.y, 0.001), snappedf(q.z, 0.001), snappedf(q.w, 0.001)]
		if item.get_meta("kind") == "lamp":
			entry["lit"] = is_lit(item)
		list.append(entry)
	return list


func restore(list: Variant) -> void:
	clear()
	if not list is Array:
		return
	for entry in list:
		if not entry is Dictionary or not CATALOGUE.has(str(entry.get("id", ""))):
			continue
		var basis := Basis(Vector3.UP, float(entry.get("turn", 0.0)))
		var q: Variant = entry.get("q")
		if q is Array and q.size() == 4:
			basis = Basis(Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3])).normalized())
		var at := Vector3(float(entry.get("x", 0)), maxf(float(entry.get("y", 0)), 0.0), float(entry.get("z", 0)))
		spawn(str(entry.id), Transform3D(basis, at), bool(entry.get("lit", true)))
