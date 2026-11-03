# Startup time

On the same MacBook Air (M1, 2020), the app draws its first frame about four times sooner on Asahi Linux than on macOS. This file records where the time goes on each system. Its numbers are the baseline for making macOS start faster.

## How to measure

```
./build.sh measure
./build/measure/measure startup              # 10 cold launches each with fake data and the mock
./build/measure/measure ab main -setup=fake  # a change against main, in one sitting
```

[Measuring](measuring.md) explains how the tool works. Each step of startup has a mark, the time since the kernel started the process. The marks between `app_start` and `init` split the app's own setup, and each OS has a few marks the other lacks (`ns_window`, `metal_device` and `render_shaders` on macOS, `render_device` on Linux). The table of marks is in [What the app prints](measuring.md#what-the-app-prints).

Compare runs from the same sitting. On Linux the medians move by a few ms from one run of the tool to the next, and a single launch can take twice the median.

## Linux

Run on 3 November 2026 at `a002af1` plus the marks, release build (`-o:speed`), Asahi Linux (Arch Linux ARM, kernel 7.2.12, the asahi Mesa driver), 1100x700 window. Results: [startup/linux-2026-11-03.json](startup/linux-2026-11-03.json), which also has the memory scenario.

Medians of runs 2 to 10, in ms since the process started:

| mark | fake | mock |
|---|---|---|
| main | 11.3 | 8.8 |
| launched | 20.0 | 17.0 |
| app_start | 20.0 | 17.0 |
| render_device | 26.2 | 26.1 |
| init_render | 27.4 | 27.4 |
| text_fonts | 28.5 | 28.6 |
| init_text | 28.6 | 28.6 |
| init_data | 28.6 | 29.8 |
| init_rows | 32.9 | 29.8 |
| init_playback | 33.1 | 30.7 |
| init | 33.6 | 31.2 |
| first_frame | 39.9 | 37.3 |
| library | 39.9 | 64.0 |
| tracks | 39.9 | 104.6 |

The steps for the fake data, as differences of the medians:

| step | ms |
|---|---|
| process start to `main`: the dynamic linker and the Odin runtime | 11.3 |
| `main` to `launched`: connecting to the Wayland compositor | 8.7 |
| Vulkan instance and device | 6.2 |
| the rest of the renderer: pools, white texture, pipelines from SPIR-V | 1.2 |
| system and icon fonts | 1.1 |
| ui, library, data, playback, search | 0.7 |
| the fake rows (fake data only) | 4.3 |
| `init` to `first_frame`: waiting for the compositor's configure, the swapchain, the first frame | 6.3 |

On the mock, `first_frame` to `tracks` is another 67 ms: the sidebar and Liked Songs come from the list cache, then the app waits for covers.

## macOS

These are the numbers from `docs/measure-baseline.json`, taken before the marks inside `init` existed. Fake data, medians:

| mark | ms |
|---|---|
| main | 4.8 |
| launched | 76.9 |
| init | 130.2 |
| window | 132.1 |
| first_frame | 154.2 |
| tracks | 162.6 |

To do: run `measure startup` on macOS at the same commit as the Linux run, save it as `startup/macos-<date>.json`, and fill in the step table the way the Linux section has it.

## Comparison

| step | macOS | Linux |
|---|---|---|
| process start to `main` | 4.8 | 11.3 |
| `main` to `launched` | 72 | 8.7 |
| `launched` to `init` | 53 | 13.6 |
| `init` to `first_frame` | 24 | 6.3 |
| total to `first_frame` | 154 | 39.9 |

The app runs the same code on both systems. The steps that differ are the ones that go through the OS:

- **`main` to `launched`.** AppKit sets up the application, the menu bar and its connection to WindowServer, against a Wayland client connecting to a socket. Some of this is a cost every macOS app pays.
- **`launched` to `init`.** On macOS this also includes making the `NSWindow` and the Metal device in the shell. Inside `start`, Metal compiles the shaders from source with `newLibraryWithSource`, and Core Text loads the system font. Linux loads SPIR-V that was compiled at build time, and its text font is Noto Sans, embedded in the binary.
- **`init` to `first_frame`.** Core Animation and Metal set up the first drawable.
- **Process start to `main`** is the only step where Linux is slower, probably because the dynamic linker loads shared libraries one by one where macOS has its shared cache.

Objective-C dispatch isn't the cause. `objc_msgSend` costs nanoseconds, and the runtime's setup happens before `main`, where macOS is the faster of the two. The likely cost is the main thread waiting on other processes: WindowServer, `cfprefsd`, `MTLCompilerService` and `fontd`. Instruments' App Launch template can confirm that by showing how long the main thread is blocked in `mach_msg`.

## Ideas

Ordered by what they could save. Which one comes first depends on the macOS step table.

1. **Set up in parallel with AppKit.** Everything is serial on the main thread now. The Metal device, the shader library and pipelines, the fonts, the list cache read and the workers don't need a window, and Metal and Core Text can run off the main thread. A thread started at the top of `shell_main` could do them while AppKit spends its 72 ms. `applicationDidFinishLaunching` would wait for it, give the device to the layer and run the rest. This splits `app_init` in two, which changes `shell/platform.h` and `src/platform/platform.odin`.
2. **Don't compile shaders from source at every launch.** An `MTLBinaryArchive` written to the cache folder on the first launch lets later launches skip `MTLCompilerService`. A `.metallib` built ahead of time would also work, but needs full Xcode to build.
3. **Prewarm fewer fallback fonts.** `text.init` asks the loader thread for the fallback faces of six scripts (`PREWARM` in `src/text/loader.odin`), and on macOS that came to 16 faces and 7 MB of parsed tables. The loader runs on its own thread, so this doesn't hold up `start`, but it competes with the main thread for the CPU during startup and the memory stays. Asking only when a glyph needs a face would save the memory, and a first CJK or emoji glyph would take a few ms when it appears. This is more about memory than startup.

AppKit and Metal themselves can't be dropped. OpenGL on macOS runs on top of Metal and is deprecated.
