extends Node3D
## A hand in Goggles Home, in place of a controller: the low-poly hand from Godot XR Tools (CC0,
## by DigitalN8m4r3; hands/LICENSE.md). Its fingers follow the controller: grip closes the
## middle, ring and little fingers and the thumb, the trigger curls the index finger. Holding
## something closes the whole hand.
##
## Put it under an XRController3D on the "grip" pose. The poses come from XR Tools' animations
## ("Grip 5" open, "Grip" closed), read once and blended bone by bone.

const STYLES := {    # id -> [name, colour picture, normal map, roughness/metal map] ("" : see-through)
	"ghost": ["See-through", "", "", ""],
	"ghost_white": ["See-through white", "", "", ""],
	"light": ["Light skin", "caucasian_realistic_baseColor", "hands_normal", "hands_occlusionRoughnessMetallic"],
	"dark": ["Dark skin", "african_realistic_baseColor", "hands_normal", "hands_occlusionRoughnessMetallic"],
	"lab": ["White gloves", "labglove_baseColor", "glove_normal", "glove_occlusionRoughnessMetallic"],
	"camo": ["Green gloves", "glove_caucasian_green_camo", "glove_normal", "glove_occlusionRoughnessMetallic"],
}
const INDEX := ["Index_Metacarpal", "Index_Proximal", "Index_Intermediate", "Index_Distal"]

var side := "left"
var skeleton: Skeleton3D
var mesh: MeshInstance3D
var grip := 0.0                           # 0 open .. 1 closed (smoothed)
var trigger := 0.0
var holding := false                      # something is in this hand: close it round it
var _open := {}                           # bone index -> Quaternion
var _closed := {}
var _index_bones := {}                    # bone index -> true for the index finger
var _material: StandardMaterial3D


# See-through hands: faint inside, a glowing rim where you see the hand edge-on
const GHOST_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_always, cull_back;
uniform vec4 colour : source_color = vec4(0.24, 0.86, 0.52, 1.0);
void fragment() {
	float rim = pow(1.0 - clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0), 2.2);
	ALBEDO = mix(colour.rgb * 0.6, colour.rgb * 1.6 + vec3(0.15), rim);
	ALPHA = 0.12 + 0.75 * rim;
}
"""


func _init(which := "left", style := "ghost") -> void:
	side = which
	var letter := "L" if side == "left" else "R"
	var path := ProjectSettings.globalize_path("res://hands/Hand_low_%s.gltf" % letter)
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if not FileAccess.file_exists(path) or document.append_from_file(path, state) != OK:
		return
	var scene := document.generate_scene(state) as Node3D
	if scene == null:
		return
	add_child(scene)
	# Where XR Tools puts this hand on the grip pose: turned back by the grip's 45 degrees, and
	# moved so the palm sits round the controller
	scene.position = Vector3(0.01 if side == "left" else -0.01, 0.0, 0.05)
	transform.basis = Basis(Vector3.RIGHT, deg_to_rad(-45.0))
	var found := scene.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		return
	skeleton = found[0]
	var meshes := scene.find_children("*", "MeshInstance3D", true, false)
	if not meshes.is_empty():
		mesh = meshes[0]
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_read_pose("Grip 5", _open)
	_read_pose("Grip", _closed)
	for bone in skeleton.get_bone_count():
		var name := skeleton.get_bone_name(bone)
		for part in INDEX:
			if name.begins_with(part):
				_index_bones[bone] = true
	set_style(style)
	_apply()


## A pose from XR Tools' animation files: the first key of each bone's rotation track.
func _read_pose(name: String, into: Dictionary) -> void:
	var path := "res://hands/%s/%s.res" % [side, name]
	if not ResourceLoader.exists(path):
		return
	var animation := ResourceLoader.load(path) as Animation
	if animation == null:
		return
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_ROTATION_3D or animation.track_get_key_count(track) == 0:
			continue
		var bone := skeleton.find_bone(str(animation.track_get_path(track).get_concatenated_subnames()))
		if bone >= 0:
			into[bone] = animation.track_get_key_value(track, 0)


func set_style(style: String) -> void:
	if mesh == null:
		return
	var files: Array = STYLES.get(style, STYLES["ghost"])
	if files[1] == "":
		var ghost := ShaderMaterial.new()
		ghost.shader = Shader.new()
		ghost.shader.code = GHOST_SHADER
		ghost.set_shader_parameter("colour", Color("3ddc84") if style == "ghost" else Color(0.85, 0.95, 1.0))
		mesh.material_override = ghost
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		return
	_material = StandardMaterial3D.new()
	_material.albedo_texture = _picture(files[1])
	_material.normal_enabled = true
	_material.normal_texture = _picture(files[2])
	_material.orm_texture = _picture(files[3])
	_material.roughness = 1.0
	mesh.material_override = _material


static func _picture(name: String) -> Texture2D:
	var path := ProjectSettings.globalize_path("res://hands/%s.jpg" % name)
	var image := Image.load_from_file(path) if FileAccess.file_exists(path) else null
	return ImageTexture.create_from_image(image) if image else null


## Follow the controller's grip and trigger (0..1).
func follow(grip_value: float, trigger_value: float, delta: float) -> void:
	var want_grip := 1.0 if holding else grip_value
	var want_trigger := 1.0 if holding else trigger_value
	var step := 1.0 - pow(0.00005, delta)     # quick, but no snapping
	grip = lerpf(grip, want_grip, step)
	trigger = lerpf(trigger, want_trigger, step)
	_apply()


func _apply() -> void:
	if skeleton == null:
		return
	for bone in _open:
		if not _closed.has(bone):
			continue
		var amount := trigger if _index_bones.has(bone) else grip
		skeleton.set_bone_pose_rotation(bone, (_open[bone] as Quaternion).slerp(_closed[bone], clampf(amount, 0.0, 1.0)))
