# Linux

The Linux build runs on Wayland, draws with Vulkan, plays through miniaudio and keeps the login in the Secret Service. It needs Odin, clang (Odin links with it), a C compiler and pkg-config, plus the development files for wayland-client, wayland-cursor, wayland-protocols, xkbcommon, Vulkan, FreeType, fontconfig and curl, and the `wayland-scanner` and `glslangValidator` tools. On Debian and Ubuntu:

```
apt install build-essential clang pkg-config libwayland-dev wayland-protocols libxkbcommon-dev libvulkan-dev \
    glslang-tools libfreetype-dev libfontconfig-dev libcurl4-openssl-dev
```

The text is in Noto Sans, with Noto Color Emoji for emoji. On Debian and Ubuntu, `fonts-noto-core` has only its Regular and Bold; Medium and SemiBold are in `fonts-noto-extra`, and without it fontconfig gives Regular for Medium and Bold for SemiBold. Fedora's variable Noto Sans has all four as named instances. Without Noto Sans the app uses whatever fontconfig gives for it. The `linux-text` workflow checks all three setups.

Odin's `vendor:miniaudio` and `vendor:stb` link static libraries that Odin doesn't ship built for Linux. Build them once in the Odin install by running `build_miniaudio.sh` in `$(odin root)/vendor/miniaudio/src` and `build_stb.sh` in `$(odin root)/vendor/stb/src`. libsecret is opened with `dlopen` when the login is first saved or read, so it's only needed at run time, and only to keep the login.

`./build.sh` takes the same arguments as on macOS and writes `build/tidalfast` and `build/app.so`. It generates the Wayland protocol code into `build/wayland` and compiles the shaders in `src/render/shaders` to SPIR-V in `build/shaders`, which the app `#load`s, so a shader change goes out with `./build.sh app` and hot reloads.

What's different from macOS:

- The shell (`shell/shell_wayland.c`) uses xdg-shell, with server-side decorations where the compositor offers xdg-decoration (GNOME doesn't, so there the window has no title bar yet), fractional-scale with viewporter, text-input-v3 for input methods, `wl_data_device` for the clipboard and xkbcommon with compose for keys. Frames are paced by `wl_surface.frame` callbacks, and input waits for the pending one too, since Wayland doesn't merge pointer motion the way AppKit does. libinput sends touchpad scrolls at the finger's speed, so the shell accelerates fast swipes up to 4x, keeping slow drags 1:1, and a wheel notch scrolls three lines. Inertial scrolling is the shell's own: wheel and touchpad deltas stop when the fingers lift, so the shell carries on with an exponential decay (time constant 0.35 s) until the velocity drops below a point a frame or new input arrives. `build/` is watched with inotify, and SIGINT and SIGTERM quit cleanly through a signalfd.
- The renderer's Vulkan backend (`vulkan_linux.odin`) keeps the same design as Metal: one pipeline, three frames in flight each with their own instance buffer, and textures written through staging buffers recorded into the frame's upload command buffer. The swapchain is `B8G8R8A8_SRGB` and presents with MAILBOX when there is one, else FIFO. Vulkan handles are plain data and survive a reload; the procedure pointers are loaded again by each dylib.
- Fonts come from fontconfig (`FcFontMatch` for Noto Sans at each weight, `FcFontSort` for the fallback that has a character, with the emoji family first for characters drawn as emoji) and are rasterized with FreeType, unhinted, at the same quarter-pixel offsets as CoreText. Colour emoji fonts with bitmap strikes (Noto Color Emoji's CBDT) are scaled down from the nearest strike with a box filter. kb_text_shape does all the shaping; nothing is reshaped by the OS as Geeza Pro and Apple Color Emoji are on macOS.
- `os_services_linux.odin` keeps the login in the Secret Service (GNOME Keyring, KWallet) under the schema `com.tidalfast.Login`, opens URLs with `xdg-open`, and puts settings and caches in `$XDG_CONFIG_HOME/tidalfast` and `$XDG_CACHE_HOME/tidalfast` (`~/.config` and `~/.cache` by default). With no Secret Service running the login works but isn't saved.
- The memory numbers come from `/proc/self/status`. The footprint is `RssAnon` plus `RssShmem`, and its peak is the highest the app has seen.
- Primary shortcuts use Control where macOS uses Command. Control-A and Control-E don't move to the line's start and end, and Control-click isn't a right click.

Not done yet: bit-perfect output (the Output menu hides the setting, and a saved one is ignored), media keys and MPRIS, the screen reader tree (AT-SPI) and client-side decorations. The Vulkan backend gives each texture its own `VkDeviceMemory`, which is fine for the few hundred textures the app makes but could use a sub-allocator.

To check the Linux build without a display, run a headless Weston and point the app at it. Mesa's lavapipe gives a software Vulkan device, so this works with no GPU too:

```
mkdir -p /tmp/xdg && chmod 700 /tmp/xdg
XDG_RUNTIME_DIR=/tmp/xdg weston --backend=headless --socket=wl-test --width=1600 --height=1000 &
XDG_RUNTIME_DIR=/tmp/xdg WAYLAND_DISPLAY=wl-test TIDALFAST_FAKE=1 TIDALFAST_AUDIO_NULL=1 \
    TIDALFAST_CAPTURE=/tmp/frame.tga TIDALFAST_SHELL_TEST="2:size=820,600;3:capture=/tmp/narrow.tga;4:quit" ./build/tidalfast
```

One test, `keychain_round_trip`, needs a Secret Service. The login tests keep the login in memory. Run the tests inside a private D-Bus session with a throwaway keyring, so that test never touches yours:

```
dbus-run-session -- sh -c 'export HOME=$(mktemp -d); eval "$(echo x | gnome-keyring-daemon --unlock --components=secrets)"; odin test tests'
```
