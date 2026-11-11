# Linux

The Linux build runs on Wayland, draws with Vulkan, plays through miniaudio, or a PipeWire stream for bit-perfect output, and keeps the login in the Secret Service. It needs Odin, clang (Odin links with it), a C compiler and pkg-config, plus the development files for wayland-client, wayland-cursor, wayland-protocols, xkbcommon, Vulkan, FreeType, fontconfig and curl, and the `wayland-scanner` and `glslangValidator` tools. On Debian and Ubuntu:

```
apt install build-essential clang pkg-config libwayland-dev wayland-protocols libxkbcommon-dev libvulkan-dev \
    glslang-tools libfreetype-dev libfontconfig-dev libcurl4-openssl-dev
```

The text is in Noto Sans, which the app has built in (see [Text](text.md#text-font)). Other scripts and emoji come from the system's fonts through fontconfig: on Debian and Ubuntu `fonts-noto-core`, `fonts-noto-cjk` and `fonts-noto-color-emoji` cover them. The `linux-text` workflow runs the tests and captures frames with the system's Noto Sans removed.

Odin's `vendor:stb` links static libraries that Odin doesn't ship built for Linux. Build them once in the Odin install by running `build_stb.sh` in `$(odin root)/vendor/stb/src`. `build.py` builds miniaudio and dr_flac itself. libsecret is opened with `dlopen` when the login is first saved or read, so it's only needed at run time, and only to keep the login. libpipewire is opened the same way when bit-perfect output first plays ([Playback](playback.md#bit-perfect-output-on-linux)).

`./build.py` takes the same arguments as on macOS and writes `build/tidalfast`. It generates the Wayland protocol code into `build/wayland` and compiles the shaders in `src/render/shaders` to SPIR-V in `build/shaders`, which the app `#load`s. The shell and the protocol code are compiled to objects in `build/shell`, which Odin links into the app with the Wayland and xkbcommon libraries.

What's different from macOS:

- The shell (`shell/shell_wayland.c`) uses xdg-shell, with server-side decorations where the compositor offers xdg-decoration (GNOME doesn't, so there the window has no title bar yet), fractional-scale with viewporter, text-input-v3 for input methods, `wl_data_device` for the clipboard and xkbcommon with compose for keys. Frames are paced by `wl_surface.frame` callbacks, and input waits for the pending one too, since Wayland doesn't merge pointer motion the way AppKit does. A configure doesn't wait for the callback. The shell draws once after a batch of configures, so the compositor soon gets a frame at the new size. Touchpad scrolling and its momentum follow GTK 4, as [Touchpad scrolling](#touchpad-scrolling) describes, and a wheel notch scrolls three lines. `build/` is watched with inotify, and SIGINT and SIGTERM quit cleanly through a signalfd.
- Another client's selection is read as soon as it arrives, up to 64 KiB, and wiped when the window loses the keyboard. A paste with nothing received asks for it again, since some compositors don't send it again when the window gets the keyboard back. A paste waits up to 100 ms for a selection that is still arriving and pastes nothing if it hasn't all come.
- The renderer's Vulkan backend (`vulkan.odin`, with the Wayland surface in `vulkan_linux.odin`) keeps the same design as Metal. It has one pipeline for the rects, three frames in flight each with their own instance buffer, and textures written through staging buffers recorded into the frame's upload command buffer. The player bar's blur runs as on Metal, in passes ahead of the swapchain's ([Renderer](renderer.md#backdrops)). The swapchain is `B8G8R8A8_SRGB` and presents with MAILBOX when there is one, else FIFO.
- Fallback fonts come from fontconfig (`FcFontSort` for the one that has a character, with the emoji family first for characters drawn as emoji). All fonts are rasterized with FreeType, unhinted, at the same quarter-pixel offsets as CoreText. Colour emoji fonts with bitmap strikes (Noto Color Emoji's CBDT) are scaled down from the nearest strike with a box filter. kb_text_shape does all the shaping; nothing is reshaped by the OS as Geeza Pro and Apple Color Emoji are on macOS.
- `os_services_linux.odin` keeps the login in the Secret Service (GNOME Keyring, KWallet) under the schema `com.tidalfast.Login`, opens URLs with `xdg-open`, and puts settings and caches in `$XDG_CONFIG_HOME/tidalfast` and `$XDG_CACHE_HOME/tidalfast` (`~/.config` and `~/.cache` by default). With no Secret Service running the login works but isn't saved.
- The memory numbers come from `/proc/self/status`. The footprint is `RssAnon` plus `RssShmem`, and its peak is the highest the app has seen.
- Primary shortcuts use Control where macOS uses Command. Control-A and Control-E don't move to the line's start and end, and Control-click isn't a right click.

## Touchpad scrolling

Wayland sends finger scrolls as they happen and nothing after the fingers lift, so the momentum is the client's to make. Rather than imitate macOS, the shell does what GTK 4's `GtkScrolledWindow` does (GTK 4.24: `gtkscrolledwindow.c`, `gtkeventcontrollerscroll.c`, `gtkkineticscrolling.c`), since that is how scrolling feels in the rest of a Linux desktop. The model is in `shell/scroll.c`, which has no Wayland in it, and `tests/scroll_linux.odin` checks each part of it:

- Finger deltas are scaled by 2.5 (GTK's `MAGIC_SCROLL_FACTOR`) at any speed. The shell adds no acceleration of its own. Any acceleration comes from libinput and the compositor, where the user sets it.
- The speed at release comes from the compositor's event times, not from when the shell reads the events. It is the distance moved in the last 150 ms before the fingers lift, divided by the time from the first of those frames to the lift. Fingers that stopped before lifting leave no momentum.
- The momentum glides as `v0 / 4 * (1 - e^(-4t))`, so it covers a quarter of the release speed in all. Each frame takes the glide's position at the time it is drawn, from `draw_frame`, so a frame moves by as much as its own interval and a hidden window stops gliding.
- A new fling in the same direction while the glide still moves, and at least a third as fast, adds the glide's speed scaled by how much faster it is, up to six times that speed. GTK calls this velocity accumulation, and it makes repeated flicks carry further.
- One or two fingers resting on the touchpad stop the glide (`zwp_pointer_gestures_v1` holds), as does a new scroll. A wheel scroll stops it and forgets its speed.
- One axis stopping while the other still moves isn't the end of the gesture, as in GDK.

The shell differs from GTK in three places. The glide ends once less than a quarter point is left on both axes and sends that rest at once, so an idle window uses no CPU. GTK runs until the speed is under 0.1 points per second. The wheel keeps the app's three lines with easing, where GTK jumps by the view's height to the power 2/3. There is no overshoot. GTK lets fingers pull up to 100 points past an edge and then springs back, critically damped. The views here stop at their edges, on macOS too, and the spring needs the view's bounds, which only `src/ui` knows.

Not done yet: media keys and MPRIS, the screen reader tree (AT-SPI) and client-side decorations. The Vulkan backend gives each texture its own `VkDeviceMemory`, which is fine for the few hundred textures the app makes but could use a sub-allocator.

One test, `keychain_round_trip`, needs a Secret Service. The login tests keep the login in memory. Run the tests in a private D-Bus session with a throwaway keyring.

A temp `HOME` alone doesn't make the keyring throwaway. gnome-keyring keeps its keyrings in `$XDG_DATA_HOME/keyrings` and its control socket in `$XDG_RUNTIME_DIR/keyring`, and desktop sessions often set both. With them pointing at the user's folders, `gnome-keyring-daemon --unlock` creates a real `login.keyring` with the password `x`. Programs that look in the login keyring before the default one, such as the GitHub CLI, then stop finding their secrets. So point all of them at a temp folder. The keyring daemon exits with the D-Bus session.

```
t=$(mktemp -d) && mkdir -m 700 "$t/run"
env HOME="$t" XDG_DATA_HOME="$t/data" XDG_CONFIG_HOME="$t/config" XDG_CACHE_HOME="$t/cache" XDG_RUNTIME_DIR="$t/run" \
    dbus-run-session -- sh -c 'echo x | gnome-keyring-daemon --unlock --components=secrets > /dev/null; ./build.py test'
rm -rf "$t"
```
