extends Node
## The VR view: a window on the desktop showing what the headset shows, the dashboard included.
##
## The picture underneath (the game, or Goggles Home) comes from the GogglesXR capture layer,
## which runs inside them: while ~/.cache/gogglesxr/capture/mirror.on exists it writes the left
## eye, small, to mirror.raw (see gogglesxr/capture-layer/capture.c). The dashboard is drawn on
## top of it here, by a second camera at your left eye with the same field of view, so its
## panels sit where they do in the headset.
##
## Only Vulkan apps can be captured (that includes Goggles Home, Proton games and SteamVR games
## through xrizer); for others the view shows the dashboard over black.

signal closed                             # the window was closed (by its close button)

const WIDTH := 960                        # pixels across the eye picture
const FPS := 30
const EYE_OFFSET := 0.032                 # metres from the middle of the head to the left eye

var window: Window
var picture: TextureRect                  # the game or Home underneath
var overlay_view: SubViewport             # the dashboard, seen from your eye
var overlay_camera: Camera3D
var note: Label
var texture: ImageTexture
var fov := Vector4(-0.87, 0.87, 0.87, -0.87)   # left, right, up, down (radians)
var head: Node3D                          # the XR camera to follow
var _dir := ""
var _last_frame := -1
var _wait := 0.0
var _reader: Thread
var _since_picture := 0.0


func _init(camera: Node3D) -> void:
	head = camera
	_dir = OS.get_environment("HOME").path_join(".cache/gogglesxr/capture")


func is_open() -> bool:
	return window != null


func open() -> void:
	if window:
		window.grab_focus()
		return
	DirAccess.make_dir_recursive_absolute(_dir)
	var request := FileAccess.open(_dir.path_join("mirror.on"), FileAccess.WRITE)
	if request:
		request.store_line("%d %d" % [WIDTH, FPS])
		request.close()
	get_tree().root.gui_embed_subwindows = false     # a real window on the desktop
	window = Window.new()
	window.title = "GogglesXR VR view"
	window.size = Vector2i(820, 860)
	window.min_size = Vector2i(320, 320)
	window.wrap_controls = false
	window.close_requested.connect(func():
		close()
		closed.emit())
	var back := ColorRect.new()
	back.color = Color.BLACK
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	window.add_child(back)
	picture = TextureRect.new()
	picture.set_anchors_preset(Control.PRESET_FULL_RECT)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var opaque := ShaderMaterial.new()        # the eye picture's alpha isn't meant for a window
	opaque.shader = Shader.new()
	opaque.shader.code = "shader_type canvas_item;\nvoid fragment() { COLOR = vec4(texture(TEXTURE, UV).rgb, 1.0); }\n"
	picture.material = opaque
	window.add_child(picture)
	overlay_view = SubViewport.new()
	overlay_view.transparent_bg = true
	overlay_view.size = Vector2i(WIDTH, WIDTH)
	overlay_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	overlay_camera = Camera3D.new()
	overlay_camera.projection = Camera3D.PROJECTION_FRUSTUM
	overlay_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	overlay_camera.near = 0.05
	overlay_camera.far = 400.0
	overlay_view.add_child(overlay_camera)
	window.add_child(overlay_view)
	var over := TextureRect.new()
	over.set_anchors_preset(Control.PRESET_FULL_RECT)
	over.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	over.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	over.texture = overlay_view.get_texture()
	window.add_child(over)
	note = Label.new()
	note.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	note.grow_horizontal = Control.GROW_DIRECTION_BOTH
	note.grow_vertical = Control.GROW_DIRECTION_BEGIN
	note.offset_bottom = -12
	note.add_theme_color_override("font_color", Color("9fbfb4"))
	note.text = "Waiting for the picture from the headset…"
	window.add_child(note)
	add_child(window)
	_apply_fov()
	_last_frame = -1
	_since_picture = 0.0


func close() -> void:
	if FileAccess.file_exists(_dir.path_join("mirror.on")):
		DirAccess.remove_absolute(_dir.path_join("mirror.on"))
	if _reader:
		_reader.wait_to_finish()
		_reader = null
	if window:
		window.queue_free()
		window = null
	texture = null


func _apply_fov() -> void:
	# The eye's (lopsided) field of view as a frustum: its height and centre at the near plane
	var n := overlay_camera.near
	var left := tan(fov.x) * n
	var right := tan(fov.y) * n
	var up := tan(fov.z) * n
	var down := tan(fov.w) * n
	overlay_camera.set_frustum(up - down, Vector2((left + right) / 2.0, (up + down) / 2.0), n, overlay_camera.far)
	var aspect := (right - left) / maxf(up - down, 0.001)
	overlay_view.size = Vector2i(WIDTH, maxi(16, roundi(WIDTH / aspect)))


func _process(delta: float) -> void:
	if window == null:
		return
	if head:
		overlay_camera.global_transform = head.global_transform.translated_local(Vector3(-EYE_OFFSET, 0, 0))
	_since_picture += delta
	if _since_picture > 3.0 and texture == null and note.text != "":
		note.text = "Only the dashboard can be shown: the game underneath can't be captured (only Vulkan games and Goggles Home can)."
	elif _since_picture > 1.5 and texture != null and picture.modulate.a > 0.5:
		# no new pictures: the app underneath has closed (or stopped drawing). Don't show a
		# frozen picture as if it were live.
		picture.modulate = Color(1, 1, 1, 0.3)
		note.text = "Waiting for the picture: the game or Goggles Home underneath isn't drawing right now."
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = 0.5 / FPS
	if _reader:
		if _reader.is_alive():
			return
		var got: Variant = _reader.wait_to_finish()
		_reader = null
		if got is Array:
			_show(got[0], got[1])
	var path := _dir.path_join("mirror.raw")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 32 or file.get_buffer(4).get_string_from_ascii() != "GXDM":
		return
	file.get_32()
	file.get_32()
	var frame := file.get_32()
	file.close()
	if frame == _last_frame:
		return
	_last_frame = frame
	_reader = Thread.new()
	_reader.start(read.bind(path))


## Runs on a thread: [Image, Vector4 fov] from a mirror.raw file, or null.
static func read(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)        # replaced whole by the layer
	if file == null or file.get_length() < 32 or file.get_buffer(4).get_string_from_ascii() != "GXDM":
		return null
	var w := file.get_32()
	var h := file.get_32()
	file.get_32()
	var angles := Vector4(file.get_float(), file.get_float(), file.get_float(), file.get_float())
	if w == 0 or h == 0 or w > 8192 or h > 8192 or file.get_length() < 32 + w * h * 4:
		return null
	return [Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, file.get_buffer(w * h * 4)), angles]


func _show(image: Image, angles: Vector4) -> void:
	if texture == null or texture.get_size() != Vector2(image.get_size()):
		texture = ImageTexture.create_from_image(image)
		picture.texture = texture
	else:
		texture.update(image)
	if not angles.is_equal_approx(fov) and absf(angles.y - angles.x) > 0.1:
		fov = angles
		_apply_fov()
	_since_picture = 0.0
	picture.modulate = Color.WHITE
	note.text = ""


func _exit_tree() -> void:
	close()
