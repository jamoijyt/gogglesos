extends RefCounted
## The real controller models (Quest, Rift, Index, Vive...), from the WebXR Input Profiles project
## (github.com/immersive-web/webxr-input-profiles, MIT licence). Goggles OS downloads a pinned
## set of them into /usr/share/gogglesos/gogglesxr-controllers (see chroot/apply-system.sh).
##
## Each model comes with a profile.json that says which parts of the model move for which
## input: for every button, trigger and stick there is a "value" node and two marker nodes for
## its resting and fully pressed positions, and the value node is placed between the two.
## The models are drawn at the controller's grip pose, the same pose WebXR uses for them.

const DEFAULT_DIR := "/usr/share/gogglesos/gogglesxr-controllers"
const GENERIC := "generic-trigger-squeeze-thumbstick"


static func models_dir() -> String:
	var dir := OS.get_environment("GOGGLESXR_CONTROLLERS")
	return dir if dir != "" else DEFAULT_DIR


## Which model set to use, from the headset's name (the runtime reports, for example,
## "Meta Quest 3 on WiVRn") and the controller's OpenXR interaction profile. "" = not known yet.
static func pick(system_name: String, profile: String) -> String:
	var headset := system_name.to_lower()
	if profile.contains("index_controller"):
		return "valve-index"
	if profile.contains("vive_controller"):
		return "htc-vive"
	if headset.contains("quest pro") or profile.contains("touch_controller_pro") or profile.contains("touch_pro"):
		return "meta-quest-touch-pro"
	if headset.contains("quest 3") or profile.contains("touch_controller_plus") or profile.contains("touch_plus"):
		return "meta-quest-touch-plus"      # Quest 3 and 3S
	if headset.contains("quest 2"):
		return "oculus-touch-v3"
	if headset.contains("quest") or headset.contains("rift s"):
		return "oculus-touch-v2"            # Quest 1 and Rift S
	if headset.contains("rift"):
		return "oculus-touch"               # Rift CV1
	if profile.contains("oculus/touch"):
		return "oculus-touch-v3"
	if profile == "":
		return ""                           # wait until the runtime says which controller it is
	return GENERIC


## The Godot action that drives a part of the model. Controllers with both a stick and a
## touchpad (Index) have the stick on "primary" and the touchpad on "secondary".
static func _input_for(component_id: String, type: String, has_stick: bool) -> String:
	match type:
		"trigger":
			return "trigger"
		"squeeze":
			return "grip"
		"thumbstick":
			return "primary"
		"touchpad":
			return "secondary" if has_stick else "primary"
	if component_id.begins_with("a-") or component_id.begins_with("x-"):
		return "ax_button"
	if component_id.begins_with("b-") or component_id.begins_with("y-"):
		return "by_button"
	if component_id.contains("menu"):
		return "menu_button"
	return ""                               # thumb rests and the like: drawn, never moved


## Load the model for one hand. Safe to run on a thread. Returns
## {"scene": Node3D, "responses": [...], "id": String}, or {} if the files are missing or broken.
static func load_model(id: String, side: String) -> Dictionary:
	var dir := models_dir().path_join(id)
	if not FileAccess.file_exists(dir.path_join("profile.json")):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("profile.json")))
	if not data is Dictionary:
		return {}
	var layouts: Dictionary = data.get("layouts", {})
	var layout: Dictionary = layouts.get(side, layouts.get("none", {}))
	var path := dir.path_join(str(layout.get("assetPath", "")))
	if layout.is_empty() or not FileAccess.file_exists(path):
		return {}
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(path, state) != OK:
		return {}
	var scene := document.generate_scene(state) as Node3D
	if scene == null:
		return {}
	var components: Dictionary = layout.get("components", {})
	var has_stick := components.values().any(func(c): return c.get("type", "") == "thumbstick")
	var responses := []
	for component_id in components:
		var component: Dictionary = components[component_id]
		var input := _input_for(component_id, str(component.get("type", "")), has_stick)
		var visuals: Dictionary = component.get("visualResponses", {})
		for visual in visuals.values():
			var node := scene.find_child(str(visual.get("valueNodeName", "")), true, false) as Node3D
			if node == null:
				continue
			var response := {"input": input, "property": str(visual.get("componentProperty", "button")),
					"kind": str(visual.get("valueNodeProperty", "transform")), "node": node,
					"states": visual.get("states", ["default", "touched", "pressed"])}
			if response.kind == "transform":
				var low := scene.find_child(str(visual.get("minNodeName", "")), true, false) as Node3D
				var high := scene.find_child(str(visual.get("maxNodeName", "")), true, false) as Node3D
				if low == null or high == null:
					continue
				response["min"] = low.transform
				response["max"] = high.transform
			responses.append(response)
	return {"scene": scene, "responses": responses, "id": id}


## What a controller's inputs are doing right now: {"trigger": {"button", "x", "y"}, ...}
static func read_inputs(controller: XRController3D) -> Dictionary:
	var out := {}
	for input in ["trigger", "grip", "primary", "secondary", "ax_button", "by_button", "menu_button"]:
		var value := {"button": 0.0, "x": 0.0, "y": 0.0}
		match input:
			"trigger", "grip":
				value.button = controller.get_float(input)
			"primary", "secondary":
				var stick := controller.get_vector2(input)
				if stick.length() > 1.0:
					stick = stick.normalized()
				value.x = stick.x
				value.y = stick.y
				value.button = 1.0 if controller.is_button_pressed(input + "_click") else 0.0
			_:
				value.button = 1.0 if controller.is_button_pressed(input) else 0.0
		out[input] = value
	return out


## Move the model's buttons, trigger and stick to match `inputs` (from read_inputs).
static func animate(responses: Array, inputs: Dictionary) -> void:
	for response in responses:
		var value: Dictionary = inputs.get(response.input, {"button": 0.0, "x": 0.0, "y": 0.0})
		var state := "default"
		if value.button > 0.9:
			state = "pressed"
		elif value.button > 0.05 or absf(value.x) > 0.1 or absf(value.y) > 0.1:
			state = "touched"
		var active: bool = (response.states as Array).has(state)
		var amount := 0.0
		match response.property:
			"button":
				amount = value.button if active else 0.0
			"xAxis":
				amount = (value.x + 1.0) / 2.0 if active else 0.5
			"yAxis":
				amount = (1.0 - value.y) / 2.0 if active else 0.5    # WebXR's y points down, OpenXR's up
			"state":
				amount = 1.0 if active else 0.0
		var node: Node3D = response.node
		if response.kind == "visibility":
			node.visible = amount > 0.5
		elif response.kind == "transform":
			var low: Transform3D = response.min
			var high: Transform3D = response.max
			var turn := low.basis.get_rotation_quaternion().slerp(high.basis.get_rotation_quaternion(), amount)
			node.transform = Transform3D(Basis(turn), low.origin.lerp(high.origin, amount))
