# Startup time

On the same MacBook Air (M1, 2020), the app draws its first frame about four and a half times sooner on Asahi Linux than on macOS. This file records where the time goes on each system. Its numbers are the baseline for making macOS start faster.

The M1 Air is an old, low-end machine by now: a 2020 chip, 8 GB of memory and no fan. Most of macOS's extra time is CPU work on one thread (see [Why macOS is slower](#why-macos-is-slower)), so a recent chip such as the M6 should cut the gap in ms considerably. The ratio may change less, since the Linux side would get faster too. Asahi doesn't support every Apple silicon generation, so check which machines it runs on before planning the same comparison on newer hardware. Running both systems on one machine is what makes the comparison fair: the hardware is the same, so the difference is the OS.

## How to measure

```
./build.py measure
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

Run on 3 November 2026 at `d76f3f7`, which is the Linux run's code plus a Wayland scrolling fix, with the measure build (release, `-o:speed`), macOS 27.2 (26B123), 8 GB, 1100x700 window. The laptop was on battery and had restarted a few minutes before. Results: [startup/macos-2026-11-03.json](startup/macos-2026-11-03.json), which also has the memory scenario. A second `measure startup` two minutes later gave medians within 2 ms of these up to `window` and within 4 ms at `first_frame`.

Medians of runs 2 to 10, in ms since the process started:

| mark | fake | mock |
|---|---|---|
| main | 12.7 | 15.6 |
| launched | 87.9 | 92.5 |
| ns_window | 116.2 | 120.3 |
| metal_device | 120.4 | 125.3 |
| app_start | 124.3 | 127.3 |
| render_shaders | 125.5 | 128.4 |
| init_render | 126.2 | 129.2 |
| text_fonts | 128.3 | 131.3 |
| init_text | 128.4 | 131.4 |
| init_data | 128.4 | 131.5 |
| init_rows | 132.1 | 131.5 |
| init_playback | 132.2 | 131.6 |
| init | 133.1 | 132.4 |
| window | 146.2 | 146.9 |
| first_frame | 185.5 | 182.6 |
| library | 185.5 | 193.9 |
| tracks | 185.6 | 232.3 |

The steps for the fake data, as differences of the medians:

| step | ms |
|---|---|
| process start to `main`: dyld and the Odin runtime | 12.7 |
| `main` to `launched`: AppKit, the menu bar, the connection to WindowServer | 75.2 |
| `NSWindow` `initWithContentRect` | 28.3 |
| titlebar, toolbar, the view, and `MTLCreateSystemDefaultDevice` in its `makeBackingLayer` | 4.2 |
| the rest of the shell's setup: blur reference, display link, observers, remote commands | 3.9 |
| `newLibraryWithSource` | 1.2 |
| the rest of the renderer: white texture, pipelines | 0.7 |
| system and icon fonts | 2.1 |
| ui, library, data, playback, search | 1.1 |
| the fake rows (fake data only) | 3.7 |
| `init` to `window`: `makeKeyAndOrderFront` and `activateIgnoringOtherApps` | 13.1 |
| `window` to `first_frame`: the first drawable and the first frame | 39.3 |

`window` to `first_frame` takes one of two lengths. In 5 of 36 launches across both sittings it was 12 to 17 ms, and in the rest 35 to 47 ms. [Why macOS is slower](#why-macos-is-slower) has the likely reason.

On the mock, `first_frame` to `tracks` is another 50 ms.

The numbers this section had before came from `docs/measure-baseline.json`, taken on 15 October, when the app was still a dylib that the shell loaded after `launched`. That made `main` 4.8 ms, before the app's code was loaded. The other marks were close to these: `launched` 76.9, `init` 130.2, `first_frame` 154.2. `window` came 2 ms after `init` then, where now it comes 13 ms after.

## Comparison

Fake data, ms:

| step | macOS | Linux |
|---|---|---|
| process start to `main` | 12.7 | 11.3 |
| `main` to `launched` | 75.2 | 8.7 |
| `launched` to `init` | 45.2 | 13.6 |
| `init` to `first_frame` | 52.4 | 6.3 |
| total to `first_frame` | 185.5 | 39.9 |

The app runs the same code on both systems. The steps that differ are the ones that go through the OS:

- **`main` to `launched`.** AppKit sets up the application, the menu bar and its connection to WindowServer, against a Wayland client connecting to a socket. Some of this is a cost every macOS app pays.
- **`launched` to `init`.** 28 ms of the 45 is making the `NSWindow`. The other 17 ms are the titlebar and view with the Metal device (4.2), the shell's setup (3.9) and the app's `start` (8.8). On Linux the Vulkan device and `start` take 13.6. `newLibraryWithSource` compiles the shaders in 1.2 ms, so there is little left to save there, and Core Text loads the system and icon fonts in 2.1 ms.
- **`init` to `first_frame`.** Ordering the window front and activating the app take 13 ms, then the first frame takes 39 ms in most launches. Linux spends 6.3 ms on both.
- **Process start to `main`** is about the same on both. Before the app and shell were one executable, macOS reached `main` in 4.8 ms because the app's code loaded later.

## Why macOS is slower

Measured on 3 and 4 November 2026, on the same machine, with a minimal Cocoa app: one Objective-C file that starts `NSApplication`, makes a 1100x700 `NSWindow`, orders it front, commits it with `CATransaction flush` and waits for the first event. Each step prints the time since the process started, the main thread's CPU time (`thread_info`) and the Mach messages the process sent (`task_info` with `TASK_EVENTS_INFO`). "Waiting" is the time minus the CPU time, so it also counts time the thread was runnable but not running.

The minimal app gets to `applicationDidFinishLaunching` at 87 ms, makes its window in 26 ms and has its next run loop turn 36 ms after ordering it front. TIDALfast takes 87.9, 28.3 and 39.3 ms for the same steps. About 150 of TIDALfast's 185 ms is what any AppKit window costs on this machine.

Typical of five runs, in ms:

| step | time | main thread CPU | waiting | Mach messages |
|---|---|---|---|---|
| process start to `main` (a plain C binary: 3) | 7 | 5 | 2 | 68 |
| connecting to WindowServer (`CGSMainConnectionID`, private) | 22 | 2 | 20 | 79 |
| `NSApplication.sharedApplication` and `finishLaunching` | 35 | 26 | 9 | about 295 |
| the first `NSWindow` | 29 | 23 | 5 | 178 |
| a second `NSWindow` | 4 | 4 | 0 | 24 |
| the first commit (`CATransaction flush`) | 20 to 27 | 16 to 24 | 2 to 8 | 36 |
| a second window's commit | 11 | 1 | 10 | 30 |
| the first run loop pass | 21 | 9 | 12 | about 160 |

What this shows:

- **Most of it is AppKit's own work in the app's process.** About 85 of the 150 ms is CPU time on the main thread, and most of that is paid once per process. The second window costs 4 ms instead of 23, and its commit 1 ms of CPU instead of about 20. The Objective-C runtime called `+initialize` on 1,179 classes during this launch. The code inside those methods, and in the lazy setup behind them, is AppKit's own: it runs the first time a class is touched, whether the app needs what it sets up or not. A time profile would show how it splits between defaults, appearance, artwork and the rest. All of it runs cold. AppKit's code is already in memory, shared with other apps, so a launch has about 7,600 page faults and only 6 to 42 of them read the disk.
- **The connection to WindowServer is mostly waiting.** The main thread uses 2 ms of CPU and waits 20 ms over 79 messages. That's about 0.25 ms per message, much more than a Mach round trip, so the time goes into work WindowServer, or something it calls, does for a new client. A trace of the server side (Instruments' System Trace, with admin rights) would show what.
- **The Objective-C runtime itself is a few ms.** The launch realizes 1,360 classes. Realizing all 15,730 classes in the system at once takes 6.6 ms, 0.42 µs each, because the shared cache holds most of the class tables precomputed, so 1,360 come to about 0.6 ms. `objc_msgSend` costs nanoseconds, and the second window goes through the same dispatch in 4 ms. Before `main`, a Cocoa binary takes 2 to 4 ms more than a plain C one, which covers the runtime registering classes and everything else AppKit's libraries set up at load.
- **Memory pressure isn't the cause.** During these runs swap was empty and macOS reported 73% of memory free.

Win32 and Wayland are built differently, which explains the rest, though these numbers don't measure it. `CreateWindowEx` is a system call into `win32k.sys`, where the window manager's state lives, and DWM composites later without blocking the app. A Wayland client queues requests on a socket and waits for few replies, which fits Linux's 8.7 ms from `main` to `launched`. On macOS the window manager is a separate process, and this launch sends about 800 Mach messages to it and to other system services.

What doesn't change it:

- Turning off window state restoration (`ApplePersistenceIgnoreState`) or making no menu bar changed nothing measurable.
- `NSApplicationActivationPolicyAccessory` saves about 10 ms, but the app then has no Dock icon.
- Skipping AppKit for SkyLight's private window calls would still pay the 20 ms connection, and the app would have to rebuild input methods, accessibility, the menu bar, media keys and window management on APIs that change between macOS releases.

The minimal app also explains the two lengths of `window` to `first_frame`. Its first run loop pass takes about 20 ms whenever it comes. TIDALfast calls `request_redraw` after ordering the window front, so its first frame usually waits for that pass. In the launches where it took 12 to 17 ms, the frame most likely came first.

## Ideas

Ordered by what they could save.

1. **Draw the first frame before returning to the run loop.** Drawing right after `makeKeyAndOrderFront` instead of calling `request_redraw` would keep the first frame from waiting for the first run loop pass, about 20 to 25 ms.
2. **Set up in parallel with AppKit.** Everything is serial on the main thread now. The Metal device, the shader library and pipelines, the fonts, the list cache read and the workers don't need a window, and Metal and Core Text can run off the main thread. A thread started at the top of `shell_main` could do them while AppKit spends its 75 ms. `applicationDidFinishLaunching` would wait for it, give the device to the layer and run the rest. With the fake data the app's `start` is 8.8 ms, plus the Metal device inside the 4.2 ms step, so this saves at most about 13 ms, and less on the mock, which has no fake rows. This splits `app_init` in two, which changes `shell/platform.h` and `src/platform/platform.odin`.
3. **Find the extra 10 ms of ordering front.** It takes 3 ms in the minimal app and 13 ms in TIDALfast. `makeFirstResponder`, the toolbar and the blur reference are the differences.
4. **Prewarm fewer fallback fonts.** `text.init` asks the loader thread for the fallback faces of six scripts (`PREWARM` in `src/text/loader.odin`), and on macOS that came to 16 faces and 7 MB of parsed tables. The loader runs on its own thread, so this doesn't hold up `start`, but it competes with the main thread for the CPU during startup and the memory stays. Asking only when a glyph needs a face would save the memory, and a first CJK or emoji glyph would take a few ms when it appears. This is more about memory than startup.

An `MTLBinaryArchive` for the shaders, an earlier idea, would save at most the 1.2 ms of `newLibraryWithSource`.

AppKit and Metal themselves can't be dropped. OpenGL on macOS runs on top of Metal and is deprecated.
