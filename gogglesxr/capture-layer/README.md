# GogglesXR capture layer

Screenshots and recordings of what the headset shows. `libgogglesxr_capture.so` is an OpenXR
API layer: games load it (it is listed as an implicit layer in
`~/.local/share/openxr/1/api_layers/implicit.d/`, which `gogglesxr` installs), and it sits between
the game and the VR runtime.

It only passes calls on until `gogglesxr screenshot` or `gogglesxr record` asks for a capture
through a file in `~/.cache/gogglesxr/capture/`. Then, when the game hands a finished left-eye
image to the runtime, the layer copies it with the game's own Vulkan device:

- **Screenshot:** the full eye image, written as `shot.pam`; `gogglesxr` saves it as a PNG.
- **Recording:** a 16:9 crop around the point straight ahead, scaled to 1920x1080 at 30 fps,
  streamed as raw frames into `record.fifo`, which ffmpeg encodes.

Only Vulkan games are captured (that includes Proton games and SteamVR games through the
translator). The GogglesXR dashboard itself is never captured: it runs as an overlay session,
which the layer leaves alone. To switch the layer off for one game, add
`DISABLE_GOGGLESXR_CAPTURE=1` to its launch options.

## Building

```bash
./build.sh
```

Needs gcc and the Vulkan headers (`libvulkan-dev`). The built library is committed, so the ISO
build and Goggles Update don't need a compiler. It is linked against old glibc symbol versions
so it also loads in Steam's game containers, and the build fails if anything newer than glibc 2.17
slips in.

`include/openxr/` holds the Khronos OpenXR headers from the OpenXR SDK, release 1.1.47
(Apache-2.0 OR MIT).
