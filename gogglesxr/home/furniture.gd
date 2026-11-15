extends Node3D
## The things you put in Goggles Home: furniture, decorations, toys and gadgets.
##
## Models (models/README.md): textured, detailed pieces from Poly Haven (models/ph), Kenney's
## Furniture Kit (models/*.glb), and Kenney's toy cars, arcade machines, cube pets and blasters
## (models/toys); all CC0. A few things are made here (balls, blocks, balloons, posters, the
## marker, the remote, the hoop, the clock, neon signs). Each thing is a physics body, so the
## laser finds it, other things stand on it, and toys bounce off it. What does what is
## gadgets.gd's. The room is kept by main.gd (save() / restore()).
##
## Kinds (how a thing sits and moves):
##   floor    stands where you put it: on the floor or on other furniture
##   wall     hangs on a wall, facing out of it
##   ceiling  hangs from a ceiling
##   lamp     a floor kind with a light the trigger switches
##   prop     a toy: carry it, throw it
##   held     a gadget that sits in your hand the way you hold a controller (blaster, marker...)
##   roam     moves about by itself (pets, the RC car): carry it and put it down

const MODEL_DIR := "res://models"
const LAYER_FURNITURE := 2
const LAYER_PROP := 4
const MAX_ITEMS := 150
const KENNEY_SCALE := 2.0                 # the furniture kit is modelled at half size

# id -> [name, category, kind, model file (or "" when made here), size (largest side, metres;
# 0: as modelled), what it does (gadgets.gd)]
const CATALOGUE := {
	# Seating
	"ArmChair_01": ["Leather armchair", "Seating", "floor", "ph/ArmChair_01/ArmChair_01.gltf", 0, ""],
	"GreenChair_01": ["Velvet armchair", "Seating", "floor", "ph/GreenChair_01/GreenChair_01.gltf", 0, ""],
	"modern_arm_chair_01": ["Modern armchair", "Seating", "floor", "ph/modern_arm_chair_01/modern_arm_chair_01.gltf", 0, ""],
	"Rockingchair_01": ["Rocking chair", "Seating", "floor", "ph/Rockingchair_01/Rockingchair_01.gltf", 0, ""],
	"chinese_armchair": ["Carved armchair", "Seating", "floor", "ph/chinese_armchair/chinese_armchair.gltf", 0, ""],
	"Sofa_01": ["Sofa", "Seating", "floor", "ph/Sofa_01/Sofa_01.gltf", 0, ""],
	"sofa_02": ["Long sofa", "Seating", "floor", "ph/sofa_02/sofa_02.gltf", 0, ""],
	"sofa_03": ["Chesterfield", "Seating", "floor", "ph/sofa_03/sofa_03.gltf", 0, ""],
	"Ottoman_01": ["Ottoman", "Seating", "floor", "ph/Ottoman_01/Ottoman_01.gltf", 0, ""],
	"dining_chair_02": ["Dining chair", "Seating", "floor", "ph/dining_chair_02/dining_chair_02.gltf", 0, ""],
	"painted_wooden_chair_01": ["Painted chair", "Seating", "floor", "ph/painted_wooden_chair_01/painted_wooden_chair_01.gltf", 0, ""],
	"wooden_stool_01": ["Stool", "Seating", "floor", "ph/wooden_stool_01/wooden_stool_01.gltf", 0, ""],
	"chairDesk": ["Desk chair", "Seating", "floor", "chairDesk.glb", 0, ""],
	"loungeSofaCorner": ["Corner sofa", "Seating", "floor", "loungeSofaCorner.glb", 0, ""],
	"stoolBar": ["Bar stool", "Seating", "floor", "stoolBar.glb", 0, ""],
	# Tables
	"CoffeeTable_01": ["Coffee table", "Tables", "floor", "ph/CoffeeTable_01/CoffeeTable_01.gltf", 0, ""],
	"modern_coffee_table_01": ["Low table", "Tables", "floor", "ph/modern_coffee_table_01/modern_coffee_table_01.gltf", 0, ""],
	"modern_coffee_table_02": ["Modern coffee table", "Tables", "floor", "ph/modern_coffee_table_02/modern_coffee_table_02.gltf", 0, ""],
	"coffee_table_round_01": ["Round coffee table", "Tables", "floor", "ph/coffee_table_round_01/coffee_table_round_01.gltf", 0, ""],
	"round_wooden_table_01": ["Round table", "Tables", "floor", "ph/round_wooden_table_01/round_wooden_table_01.gltf", 0, ""],
	"WoodenTable_01": ["Long table", "Tables", "floor", "ph/WoodenTable_01/WoodenTable_01.gltf", 0, ""],
	"WoodenTable_03": ["Farmhouse table", "Tables", "floor", "ph/WoodenTable_03/WoodenTable_03.gltf", 0, ""],
	"wooden_table_02": ["Rustic table", "Tables", "floor", "ph/wooden_table_02/wooden_table_02.gltf", 0, ""],
	"gallinera_table": ["Side table", "Tables", "floor", "ph/gallinera_table/gallinera_table.gltf", 0, ""],
	"desk": ["Desk", "Tables", "floor", "desk.glb", 0, ""],
	"deskCorner": ["Corner desk", "Tables", "floor", "deskCorner.glb", 0, ""],
	"sideTableDrawers": ["Bedside table", "Tables", "floor", "sideTableDrawers.glb", 0, ""],
	# Storage and beds
	"wooden_bookshelf_worn": ["Bookshelf", "Storage & beds", "floor", "ph/wooden_bookshelf_worn/wooden_bookshelf_worn.gltf", 0, ""],
	"Shelf_01": ["Wall shelf unit", "Storage & beds", "floor", "ph/Shelf_01/Shelf_01.gltf", 0, ""],
	"wooden_display_shelves_01": ["Display shelves", "Storage & beds", "floor", "ph/wooden_display_shelves_01/wooden_display_shelves_01.gltf", 0, ""],
	"modern_wooden_cabinet": ["Sideboard", "Storage & beds", "floor", "ph/modern_wooden_cabinet/modern_wooden_cabinet.gltf", 0, ""],
	"chinese_cabinet": ["Tall cabinet", "Storage & beds", "floor", "ph/chinese_cabinet/chinese_cabinet.gltf", 0, ""],
	"vintage_wooden_drawer_01": ["Chest of drawers", "Storage & beds", "floor", "ph/vintage_wooden_drawer_01/vintage_wooden_drawer_01.gltf", 0, ""],
	"GothicCommode_01": ["Commode", "Storage & beds", "floor", "ph/GothicCommode_01/GothicCommode_01.gltf", 0, ""],
	"barrel_03": ["Barrel", "Storage & beds", "floor", "ph/barrel_03/barrel_03.gltf", 0, ""],
	"wooden_crate_01": ["Crate", "Storage & beds", "floor", "ph/wooden_crate_01/wooden_crate_01.gltf", 0, ""],
	"cabinetTelevision": ["TV stand", "Storage & beds", "floor", "cabinetTelevision.glb", 0, ""],
	"kitchenFridge": ["Fridge", "Storage & beds", "floor", "kitchenFridge.glb", 0, ""],
	"GothicBed_01": ["Four-poster bed", "Storage & beds", "floor", "ph/GothicBed_01/GothicBed_01.gltf", 0, ""],
	"bedDouble": ["Double bed", "Storage & beds", "floor", "bedDouble.glb", 0, ""],
	"bedSingle": ["Single bed", "Storage & beds", "floor", "bedSingle.glb", 0, ""],
	"bedBunk": ["Bunk bed", "Storage & beds", "floor", "bedBunk.glb", 0, ""],
	# Lights
	"desk_lamp_arm_01": ["Desk lamp", "Lights", "lamp", "ph/desk_lamp_arm_01/desk_lamp_arm_01.gltf", 0, ""],
	"vintage_oil_lamp": ["Oil lamp", "Lights", "lamp", "ph/vintage_oil_lamp/vintage_oil_lamp.gltf", 0, ""],
	"modern_ceiling_lamp_01": ["Ceiling lamp", "Lights", "ceiling", "ph/modern_ceiling_lamp_01/modern_ceiling_lamp_01.gltf", 0, "light"],
	"lampRoundFloor": ["Floor lamp", "Lights", "lamp", "lampRoundFloor.glb", 0, ""],
	"lampSquareFloor": ["Square floor lamp", "Lights", "lamp", "lampSquareFloor.glb", 0, ""],
	"lampRoundTable": ["Table lamp", "Lights", "lamp", "lampRoundTable.glb", 0, ""],
	"neon_goggles": ["Neon: Goggles", "Lights", "wall", "", 0, "neon"],
	"neon_gameon": ["Neon: Game on", "Lights", "wall", "", 0, "neon"],
	"neon_heart": ["Neon: Heart", "Lights", "wall", "", 0, "neon"],
	# Decor
	"potted_plant_04": ["Plant", "Decor", "floor", "ph/potted_plant_04/potted_plant_04.gltf", 0, ""],
	"pottedPlant": ["Tall plant", "Decor", "floor", "pottedPlant.glb", 0, ""],
	"ceramic_vase_01": ["Vase", "Decor", "floor", "ph/ceramic_vase_01/ceramic_vase_01.gltf", 0, ""],
	"ceramic_vase_02": ["Round vase", "Decor", "floor", "ph/ceramic_vase_02/ceramic_vase_02.gltf", 0, ""],
	"marble_bust_01": ["Marble bust", "Decor", "floor", "ph/marble_bust_01/marble_bust_01.gltf", 0, ""],
	"horse_statue_01": ["Horse statue", "Decor", "floor", "ph/horse_statue_01/horse_statue_01.gltf", 0, ""],
	"concrete_cat_statue": ["Cat statue", "Decor", "floor", "ph/concrete_cat_statue/concrete_cat_statue.gltf", 0, ""],
	"carved_wooden_elephant": ["Wooden elephant", "Decor", "floor", "ph/carved_wooden_elephant/carved_wooden_elephant.gltf", 0, ""],
	"vintage_grandfather_clock_01": ["Grandfather clock", "Decor", "floor", "ph/vintage_grandfather_clock_01/vintage_grandfather_clock_01.gltf", 0, ""],
	"alarm_clock_01": ["Alarm clock", "Decor", "floor", "ph/alarm_clock_01/alarm_clock_01.gltf", 0, ""],
	"standing_picture_frame_01": ["Photo frame", "Decor", "floor", "ph/standing_picture_frame_01/standing_picture_frame_01.gltf", 0, ""],
	"standing_chalkboard_01": ["Chalkboard", "Decor", "floor", "ph/standing_chalkboard_01/standing_chalkboard_01.gltf", 0, ""],
	"jug_01": ["Jug", "Decor", "floor", "ph/jug_01/jug_01.gltf", 0, ""],
	"wooden_bowl_02": ["Bowl", "Decor", "floor", "ph/wooden_bowl_02/wooden_bowl_02.gltf", 0, ""],
	"rugRectangle": ["Rug", "Decor", "floor", "rugRectangle.glb", 0, ""],
	"rugRound": ["Round rug", "Decor", "floor", "rugRound.glb", 0, ""],
	"rugRounded": ["Soft rug", "Decor", "floor", "rugRounded.glb", 0, ""],
	# On the walls
	"poster": ["Poster", "Walls", "wall", "", 0, "poster"],
	"frame": ["Framed picture", "Walls", "wall", "", 0, "poster"],
	"hanging_picture_frame_02": ["Painting", "Walls", "wall", "ph/hanging_picture_frame_02/hanging_picture_frame_02.gltf", 0, ""],
	"fancy_picture_frame_01": ["Gilded painting", "Walls", "wall", "ph/fancy_picture_frame_01/fancy_picture_frame_01.gltf", 0, ""],
	"ornate_mirror_01": ["Mirror", "Walls", "wall", "ph/ornate_mirror_01/ornate_mirror_01.gltf", 0, "mirror"],
	"wall_clock": ["Wall clock", "Walls", "wall", "", 0, "clock"],
	"hoop": ["Basketball hoop", "Walls", "wall", "", 0, "hoop"],
	"security_camera_01": ["Security camera", "Walls", "wall", "ph/security_camera_01/security_camera_01.gltf", 0, ""],
	# Gadgets
	"tv_modern": ["Desktop TV", "Gadgets", "floor", "televisionModern.glb", 0, "tv"],
	"Television_01": ["Old TV (desktop)", "Gadgets", "floor", "ph/Television_01/Television_01.gltf", 0, "tv"],
	"computerScreen": ["Desktop monitor", "Gadgets", "floor", "computerScreen.glb", 0, "tv"],
	"radio": ["Radio", "Gadgets", "floor", "radio.glb", 0, "radio"],
	"rc_racer": ["RC car", "Gadgets", "roam", "toys/vehicle-racer.glb", 0.42, "rc_car"],
	"rc_truck": ["RC monster truck", "Gadgets", "roam", "toys/vehicle-monster-truck.glb", 0.42, "rc_car"],
	"remote": ["RC remote", "Gadgets", "held", "", 0, "remote"],
	"blaster": ["Laser blaster", "Gadgets", "held", "toys/blaster-h.glb", 0.36, "blaster"],
	"blaster_small": ["Laser pistol", "Gadgets", "held", "toys/blaster-a.glb", 0.24, "blaster"],
	"target": ["Target", "Gadgets", "floor", "toys/target-large.glb", 0.6, "target"],
	"marker": ["Marker", "Gadgets", "held", "", 0, "marker"],
	"balloon": ["Balloon", "Gadgets", "prop", "", 0, "balloon"],
	# Toys
	"ball": ["Ball", "Toys", "prop", "", 0, ""],
	"basketball": ["Basketball", "Toys", "prop", "", 0, "basketball"],
	"block": ["Block", "Toys", "prop", "", 0, ""],
	"rubber_duck_toy": ["Rubber duck", "Toys", "prop", "ph/rubber_duck_toy/rubber_duck_toy.gltf", 0, ""],
	"food_apple_01": ["Apple", "Toys", "prop", "ph/food_apple_01/food_apple_01.gltf", 0, ""],
	"Ukulele_01": ["Ukulele", "Toys", "prop", "ph/Ukulele_01/Ukulele_01.gltf", 0, ""],
	"throw_pillows_01": ["Cushions", "Toys", "prop", "ph/throw_pillows_01/throw_pillows_01.gltf", 0, ""],
	"cardboard_box_01": ["Cardboard box", "Toys", "prop", "ph/cardboard_box_01/cardboard_box_01.gltf", 0, ""],
	"cone": ["Traffic cone", "Toys", "prop", "toys/item-cone.glb", 0.3, ""],
	"books": ["Books", "Toys", "prop", "books.glb", 0, ""],
	# Arcade (they light up; the trigger plays a little tune)
	"arcade-machine": ["Arcade cabinet", "Arcade & pets", "floor", "toys/arcade-machine.glb", 1.8, "arcade"],
	"pinball": ["Pinball", "Arcade & pets", "floor", "toys/pinball.glb", 1.5, "arcade"],
	"claw-machine": ["Claw machine", "Arcade & pets", "floor", "toys/claw-machine.glb", 1.9, "arcade"],
	"air-hockey": ["Air hockey", "Arcade & pets", "floor", "toys/air-hockey.glb", 1.9, "arcade"],
	"dance-machine": ["Dance machine", "Arcade & pets", "floor", "toys/dance-machine.glb", 1.9, "arcade"],
	"vending-machine": ["Vending machine", "Arcade & pets", "floor", "toys/vending-machine.glb", 1.9, "arcade"],
	"prize-wheel": ["Prize wheel", "Arcade & pets", "floor", "toys/prize-wheel.glb", 1.7, "arcade"],
	# Pets: they wander about, follow you, and the dog fetches
	"pet_dog": ["Dog", "Arcade & pets", "roam", "toys/animal-dog.glb", 0.42, "pet"],
	"pet_cat": ["Cat", "Arcade & pets", "roam", "toys/animal-cat.glb", 0.38, "pet"],
	"pet_bunny": ["Bunny", "Arcade & pets", "roam", "toys/animal-bunny.glb", 0.36, "pet"],
	"pet_penguin": ["Penguin", "Arcade & pets", "roam", "toys/animal-penguin.glb", 0.4, "pet"],
	"pet_panda": ["Panda", "Arcade & pets", "roam", "toys/animal-panda.glb", 0.45, "pet"],
}
const CATEGORIES := ["Seating", "Tables", "Storage & beds", "Lights", "Decor", "Walls", "Gadgets", "Toys", "Arcade & pets"]
const BRIGHT := [Color("3ddc84"), Color("f1ff9c"), Color("3dc8dc"), Color("ff6bb5"), Color("ffa23d"), Color("a06bff"), Color("ff5555")]
const Gadgets := preload("res://gadgets.gd")

var home: Node                            # main.gd, for gadgets that need the room (sounds, the desktop...)
var _models := {}                         # file -> Node3D to copy from (or null if it couldn't be loaded)
var _made := 0


static func kind_of(id: String) -> String:
	return str(CATALOGUE[id][2]) if CATALOGUE.has(id) else ""


static func does(id: String) -> String:
	return str(CATALOGUE[id][5]) if CATALOGUE.has(id) else ""


func items() -> Array[Node]:
	return get_children().filter(func(n): return n.has_meta("item") and not n.is_queued_for_deletion())


## The model for a catalogue id, ready to be copied; null if there is no such file.
func _model(id: String) -> Node3D:
	var file := str(CATALOGUE[id][3])
	if file == "":
		return Gadgets.make_model(id)
	if _models.has(file):
		return _models[file]
	var node: Node3D = null
	var path := ProjectSettings.globalize_path(MODEL_DIR.path_join(file))
	if FileAccess.file_exists(path):
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		if document.append_from_file(path, state) == OK:
			var scene := document.generate_scene(state)
			if scene is Node3D:
				node = Node3D.new()
				node.add_child(scene)
				if not file.contains("/"):
					scene.scale = Vector3.ONE * KENNEY_SCALE
				var fit := float(CATALOGUE[id][4])
				if fit > 0.0:
					var box := bounds(node)
					var biggest := maxf(box.size.x, maxf(box.size.y, box.size.z))
					if biggest > 0.0:
						scene.scale *= fit / biggest
				for mesh in node.find_children("*", "MeshInstance3D", true, false):
					(mesh as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_models[file] = node
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


## Put a new thing in the room. `extra`: what it carries along (a poster's picture...).
## -> the thing (a physics body), or null.
func spawn(id: String, at: Transform3D, lit := true, extra := {}) -> Node3D:
	if not CATALOGUE.has(id) or items().size() >= MAX_ITEMS:
		return null
	var source := _model(id)
	if source == null:
		return null
	var model := source.duplicate() as Node3D
	var kind := kind_of(id)
	var item: PhysicsBody3D
	if kind in ["prop", "held", "roam"]:
		var toy := RigidBody3D.new()
		toy.mass = 0.4
		toy.continuous_cd = true
		toy.collision_layer = LAYER_PROP
		toy.collision_mask = 1 | LAYER_FURNITURE | LAYER_PROP
		var bounce := PhysicsMaterial.new()
		bounce.bounce = 0.75 if id in ["ball", "basketball"] else 0.15
		bounce.friction = 0.6
		toy.physics_material_override = bounce
		if kind == "roam":                    # stays upright, turns only round Y
			toy.axis_lock_angular_x = true
			toy.axis_lock_angular_z = true
			toy.mass = 2.0
		item = toy
	else:
		var solid := StaticBody3D.new()
		solid.collision_layer = LAYER_FURNITURE
		item = solid
	_made += 1
	item.name = "%s_%d" % [id, _made]
	item.set_meta("item", id)
	item.set_meta("kind", kind)
	for key in extra:
		item.set_meta(key, extra[key])
	# Centre the model over the body's origin (standing on it, or hanging from a wall or ceiling)
	var box := bounds(model)
	match kind:
		"wall":                               # its back against the wall: the body's origin
			model.position = Vector3(-box.get_center().x, -box.get_center().y, -box.position.z)
		"ceiling":                            # its top against the ceiling
			model.position = Vector3(-box.get_center().x, -box.end.y, -box.get_center().z)
		_:
			model.position = Vector3(-box.get_center().x, -box.position.y, -box.get_center().z)
	model.name = "Model"
	item.add_child(model)
	var size := Vector3(maxf(box.size.x, 0.04), maxf(box.size.y, 0.03), maxf(box.size.z, 0.03))
	var shape := CollisionShape3D.new()
	if id in ["ball", "basketball", "balloon"]:
		var round_shape := SphereShape3D.new()
		round_shape.radius = box.size.x / 2.0
		shape.shape = round_shape
	else:
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
	match kind:
		"wall":
			shape.position = Vector3(0, 0, size.z / 2.0)
		"ceiling":
			shape.position = Vector3(0, -size.y / 2.0, 0)
		_:
			shape.position = Vector3(0, size.y / 2.0, 0)
	item.add_child(shape)
	item.set_meta("size", size)
	if id in ["ball", "block"]:
		var paint := StandardMaterial3D.new()
		paint.albedo_color = BRIGHT[_made % BRIGHT.size()]
		paint.roughness = 0.4
		for mesh in model.find_children("*", "MeshInstance3D", true, false):
			(mesh as MeshInstance3D).material_override = paint
	if kind == "lamp" or does(id) == "light":
		var light := OmniLight3D.new()
		light.name = "Light"
		light.position.y = size.y * 0.85 if kind == "lamp" else -size.y * 0.9
		light.omni_range = 4.5
		light.light_energy = 1.6
		light.light_color = Color(1.0, 0.86, 0.66)
		item.add_child(light)
		var bulb := MeshInstance3D.new()      # a glow you can see when it is on
		bulb.name = "Bulb"
		var ball := SphereMesh.new()
		ball.radius = 0.04
		ball.height = 0.08
		bulb.mesh = ball
		var glow := StandardMaterial3D.new()
		glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glow.albedo_color = Color(1.0, 0.9, 0.7)
		bulb.material_override = glow
		bulb.position = light.position
		item.add_child(bulb)
		set_lit(item, lit)
	add_child(item)
	item.global_transform = at
	if does(id) != "":
		Gadgets.attach(item, does(id), home)
	return item


static func set_lit(item: Node3D, on: bool) -> void:
	if item.has_node("Light"):
		item.get_node("Light").visible = on
		item.get_node("Bulb").visible = on
		item.set_meta("lit", on)


static func is_lit(item: Node3D) -> bool:
	return bool(item.get_meta("lit", false))


## Take a thing out of the room: it shrinks away.
func remove(item: Node3D, animate := false) -> void:
	item.remove_meta("item")
	if animate and item.is_inside_tree():
		if item is RigidBody3D:
			(item as RigidBody3D).freeze = true
		var t := item.create_tween()
		t.tween_property(item, "scale", Vector3.ONE * 0.01, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		t.tween_callback(item.queue_free)
	else:
		item.queue_free()


func clear() -> void:
	for item in items():
		remove(item)


## A glow around something the laser is on (or none).
static func highlight(item: Node3D, on: bool) -> void:
	if item == null or not is_instance_valid(item):
		return
	for mesh in item.find_children("*", "MeshInstance3D", true, false):
		if mesh.name in ["Bulb", "Screen", "Glass"]:
			continue
		var overlay: StandardMaterial3D = null
		if on:
			overlay = StandardMaterial3D.new()
			overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			overlay.albedo_color = Color(0.24, 0.86, 0.52, 0.2)
		(mesh as MeshInstance3D).material_overlay = overlay


# ------------------------------------------------------------------ remembering the room
const SAVED_META := ["picture", "text", "colour"]

func save() -> Array:
	var list := []
	for item in items():
		var t: Transform3D = item.global_transform
		var entry := {"id": item.get_meta("item"), "x": snappedf(t.origin.x, 0.001), "y": snappedf(t.origin.y, 0.001),
				"z": snappedf(t.origin.z, 0.001), "turn": snappedf(t.basis.get_euler().y, 0.001)}
		if item.get_meta("kind") in ["prop", "held"]:
			# toys can lie any way up
			var q := t.basis.get_rotation_quaternion()
			entry["q"] = [snappedf(q.x, 0.001), snappedf(q.y, 0.001), snappedf(q.z, 0.001), snappedf(q.w, 0.001)]
		if item.has_node("Light"):
			entry["lit"] = is_lit(item)
		for key in SAVED_META:
			if item.has_meta(key):
				entry[key] = item.get_meta(key)
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
		var extra := {}
		for key in SAVED_META:
			if entry.has(key):
				extra[key] = entry[key]
		spawn(str(entry.id), Transform3D(basis, at), bool(entry.get("lit", true)), extra)
