# Measuring RAM and startup

```
./build.py measure
./build/measure/measure startup     # 10 cold launches with the fake data, then 10 against the mock
./build/measure/measure memory      # the memory scenario, once with each
./build/measure/measure all         # both
./build/measure/measure frames      # frame rate and frame times, scrolling the fake data, 3 runs
./build/measure/measure compare a.json b.json
./build/measure/measure ab /tmp/a/measure/app/tidalfast build/measure/app/tidalfast   # two builds, taking turns
./build/measure/measure launches     # your own launches, from the app's launch log
./build/measure/measure html         # the app's memory snapshots as a page
```

`./build.py measure` builds an optimized app in `build/measure/app` (its own executable), `tests/mock_tidal` and the tool. The app is the release build plus `TIDALFAST_MOCK_API`, which keeps the test screens and the text bench and lets it read `TIDALFAST_API` and `TIDALFAST_PKCE_REDIRECT`. The real release build doesn't take them, so it can't run against the mock. With either one set it shows the fake data, as every build does without a mock URL it takes (see [Building](building.md)).

Each run is a cold launch with `TIDALFAST_MEASURE` set, `TIDALFAST_AUDIO_NULL=1` and a settings file of its own, so bit-perfect output is off and your settings stay as they are. The runs share a list cache folder in the logs folder: the mock's first run starts with an empty cache, and later runs read the sidebar and Liked Songs from it. Other `TIDALFAST_` variables in your environment are dropped. The tool prints a table per scenario and setup, writes `build/measure/<time>.json`, and keeps each run's stderr in `build/measure/logs-<time>/`. Flags: `-runs=N`, `-setup=fake` or `mock` or `fake,mock`, `-app=path`, `-timeout=seconds` and `-out=path`.

The setups:

- `fake` runs with `TIDALFAST_FAKE=1`: no account, no network, 10,000 fake rows.
- `mock` starts its own `mock_tidal` on a free loopback port and logs in with `TIDALFAST_PKCE_REDIRECT` under a Keychain item called `tidalfast-measure-` and a random suffix. So the first run logs in and later runs read the login from the Keychain, as you would. The tool deletes the item at the end with `security delete-generic-password`. Deleting it from the tool itself fails with -25244, because the item's access list names the app. The mock's audio goes in `build/measure/mock-audio`: the first start of a new mock binary encodes it, about 3 s, and later starts read it back.
- `-real` runs `build/tidalfast` against your own account and your `tidalfast` Keychain item. Build it with `./build.py release` first. It's for you to run by hand: macOS may ask for Keychain access, and the memory scenario plays a track from your longest list to the null device.

`measure compare a.json b.json` prints every number in both files with its change. A time or size that changed by 10% and at least 1 ms or MB is marked `worse` or `better`, and an instruction count that changed by 2%. Startup times move a few percent from run to run, so compare medians from the same machine.

## Frames

`measure frames` runs `TIDALFAST_MEASURE=frames` with the fake data (it skips the other setups), three times unless `-runs` says otherwise. Once the first track rows show and 3 s pass, the app scrolls the 10,000 rows with the library bench (`TIDALFAST_BENCH=1`'s phases: warm scrolls back and forth over rows it has built, cold 3 new rows a frame, jump a new page a frame) and asks for each frame as soon as the last one is done. So the frame rate is what the display and the GPU let through, at most the display's refresh rate. For each phase it prints the frame rate, the 95th percentile of the time between frames, and the median and 95th percentile of the CPU time a frame took and of the GPU's (`render.Renderer.gpu_ms`, from the command buffer's start and end on the GPU on macOS and from timestamp queries around the frame's drawing on Windows, a frame or two behind; 0 on Linux). The CPU time is building and encoding the frame without the two waits in it, which the renderer times on their own: for the GPU to finish with the frame's slot of the instance buffer (`slot_wait_ms`, in `begin_frame`) and for a drawable (`drawable_wait_ms`, in `end_frame`). The waits say more about the window and the display than about the frame: in an A/B on 20 October, two runs of six came out at about 16 ms of CPU a frame where the rest took 1 to 1.5 ms, with the same code on both sides, and in another the window was covered and parked, drawing 119 frames a second at a pixel's size. So they're printed apart (`slot_wait_*`, `drawable_wait_*`, and the larger 95th percentile in the table) and left out of the CPU time. The overlay's frame time still has them. The tool prints the medians over the runs. A frame rate is marked when it changes by 5% and at least 1 fps, and more is better.

The window has to be on screen and the Mac awake: a covered window parks its drawables and draws no real frames. Battery power, Low Power Mode and heat lower the GPU's clock, which shows in its times, so compare builds in one sitting with `measure ab`.

## Comparing two builds

Times measured on different days don't compare. On 17 October a commit measured again came out 50 ms (fake) and 109 ms (mock) slower to `tracks` than two days before. The code was the same; the machine wasn't. Load, heat and background work such as Spotlight, Photos analysis and XProtect's scans move startup by tens of percent.

`measure ab <app a> <app b>` measures two builds against each other in one sitting. How they are built is up to you. With the mock setup both have to be measure builds, since only those take `TIDALFAST_API`. For a change against the code before it, build that code with `--out`, which leaves `build/` alone:

```
git stash && ./build.py measure --out /tmp/a && git stash pop
./build.py measure
./build/measure/measure ab /tmp/a/measure/app/tidalfast build/measure/app/tidalfast
```

The two take turns, a then b, then b then a, so whatever the machine does during the run weighs on both. Each build has its own settings, list cache, Keychain item and mock, both started from `build/measure/mock_tidal`. A shared mock keeps one refresh token per user, so each build's login would end the other's. Flags are the same as `startup`'s, apart from `-app`. With the fake data the frames scenario runs three times each, taking turns, compared by its medians and marked as `compare` marks. With `-memory` the memory scenario also runs once each after the startup runs.

For each startup mark it prints the median of a and of b, then the median and middle half (25th to 75th percentile) of the differences between runs next to each other, in how many of those pairs b was higher, and a sign test's p-value: the chance that two builds doing the same work split the pairs at least that unevenly. Each build's first run is left out. A change is `worse` or `better` only when p is under 0.05 (with the default 9 pairs, 8 of them going the same way) and the median difference is at least 1% (and 1 ms for times). An earlier rule, the middle half of the differences on one side of zero, marked two builds with the same startup code apart: b was faster in 7 of 9 pairs, which happens by chance 18% of the time. Memory runs only with `-memory`, once per build, and is printed without marks: a build measured against itself came out 12 MB apart at the mock's `list_open`. Without the flag `ab` is about two thirds shorter. To judge memory, compare `measure memory -runs=N` of each build.

Two builds of the same commit, measured against each other on 17 October, got no marks. The UI thread's instructions differed by 0.1 to 0.3% at every mark, lower for b in 7 of 9 pairs, a small offset between two copies of one build; times differed by up to 3.7% in their medians with no pattern in the pairs. It writes `<out>-a.json` and `<out>-b.json`.

Judge a change on `ui_instructions` first: it moves least from run to run (see The numbers). Times are what a person waits for, but they need the change to be several percent before the middle half clears zero.

## Snapshots

The memory scenario runs for a minute on a script. To see where the memory of a real session goes, take snapshots while you use the app, in any build, release included: the app menu's **Take Memory Snapshot** on macOS, or `kill -USR1 <pid>`. Linux has no menu bar, so there it's `kill`. A build from before snapshots quits on SIGUSR1; the macOS shell ignores it from the first line of `main` until the app has set its handler.

On the next frame the app splits its footprint into groups, `api`, `playback`, `ui`, `gpu` and `system`, with the items in each, and a thread writes it to `snapshots/<UTC time>.json` next to the settings file (`~/Library/Application Support/tidalfast/` on macOS, `~/.config/tidalfast/` on Linux), or to the folder `TIDALFAST_SNAPSHOTS` names. A file also has the build, uptime, window size in points, peak footprint and a few counts (covers, rows, kept lists). The files hold sizes and counts, nothing about the account. A snapshot costs about 60 ms of CPU, most of it walking the address space, and nothing runs between them: the signal handler only writes to a pipe whose thread sleeps until then.

`./build/measure/measure html [folder] [page.html]` puts every snapshot in the folder on one page, `build/measure/snapshots.html` unless named: a stacked bar per snapshot, a group's items on hover, and a table of every item with the peak, uptime, window and build of each. After a few snapshots over a session it shows which groups grew.

The breakdown comes from two views of the same moment:

- The OS's. On macOS, `os_memory` walks the address space with `mach_vm_region_recurse` and sums each region's dirty and compressed pages by its tag, the way `footprint(1)` does. That splits the footprint into pools: untagged anonymous memory (the app's arenas and the shell's memory blocks), malloc, Metal's memory (the task's graphics ledger, which includes graphics memory that's mapped nowhere), IOSurfaces (the drawables and the window's backing), and the rest (binaries' `__DATA`, thread stacks, other tagged regions, and what the walk can't place, the page tables among it). Against `footprint -p` the pools came out within timing noise of its categories.
- The app's. For each arena and buffer it owns, the pages `mincore` says count toward the footprint (`MINCORE_MODIFIED` or `MINCORE_PAGED_OUT` on macOS, resident on Linux). That counts pages given back with `MADV_FREE_REUSABLE` as gone, as the footprint does. Pages in `State` and the persistent arena go to the field or the step of `start` whose range holds the page's first byte, so none counts twice. Heap buffers count what `malloc_size` says, and textures and buffers on the GPU their `allocatedSize`.

Each item comes out of its pool, and what's left of a pool becomes an item of its own: `other anonymous memory`, `malloc outside the app's buffers`, `other GPU memory (driver, pipelines)` and `drawables and window surfaces`. The items:

| group | items |
|---|---|
| api | `session` (the TIDAL session's arena), `sidebar`, `open list`, `list refresh`, `queued list` (the list the queue follows), `kept lists` (closed lists kept in memory), `freed list (debug)`, `artist pages`, `home`, `search results`, `liked and followed ids`, `worker scratch` (the workers' temp blocks, malloc), `data state` (`Data` in `State` without the cover index, and what `data_start` took from the persistent arena) |
| playback | `player` (the Player, its ring and scratch buffers), `stream windows`, `track data` (URLs, segment tables, headers), `queue`, `playback state` |
| ui | `text caches` (shaped runs, glyph pool, shaper memory, coverage, atlas entries), `font tables` (kb_text_shape's parsed tables, malloc), `cover index`, `fake rows`, `frame arena`, `app state` (the rest of `State` and of the persistent arena) |
| gpu | `glyph atlas`, `cover pages`, `instance buffers`, `upload buffers` (Vulkan on Linux), `backdrop blur`, and the two rests above |
| system | `malloc outside the app's buffers`, `other anonymous memory`, `binaries' data`, `thread stacks`, `other tagged regions`, `page tables and unaccounted` |

Malloc that the app has no pointer to, such as AppKit's, Core Text's, libcurl's connections and dr_flac's decoder, goes in `system` as the malloc rest; Instruments' Allocations can say whose it is. On Linux the pools are the footprint and the device memory Vulkan reports, which a GPU keeps outside the footprint; with lavapipe it's host memory and counts twice.

## Launch log

Every launch that gets to its first track rows appends a line to `launches.jsonl` next to the settings file (`~/Library/Application Support/tidalfast/` on macOS, `~/.config/tidalfast/` on Linux): the time, the commit the app was built from (with `-dirty` when the tree had changes), debug or release, the `init`, `first_frame`, `library` and `tracks` marks in ms, the UI thread's and the process's instructions, and footprint. `measure launches` sums it up per build: how many launches, and the median and middle half of `tracks`, `first_frame`, instructions and footprint. These are the launches the app really has, on your machine, with your account, cache and whatever else is running, so they show what a build is like to use, where `ab` shows what a change did.

A worker appends the line, so the UI thread never waits on the disk. Past 512 KB, about 2,000 launches, the file keeps its newer half. Nothing in it leaves the machine, and it holds no account data. The fake data starts no workers, so it isn't logged; neither are runs with `TIDALFAST_MEASURE`. Runs against the mock are logged only when `TIDALFAST_LAUNCH_LOG` names a file. `TIDALFAST_LAUNCH_LOG=off` turns the log off. `./build.py` passes the commit with `-define:TIDALFAST_COMMIT`; other builds log it as "".

## What the app prints

With `TIDALFAST_MEASURE` set, the shell and the app print lines like these to stderr:

```
measure: {"mark":"main","ms":10.4}
measure: {"mark":"tracks","ms":312.1,"footprint":84210000,"resident":137700000,"gpu":32100000,...}
measure: {"sample":"scrolled","ms":31291.9,...,"fonts_mapped_bytes":630429612,"fonts_resident":31195136}
```

`ms` is milliseconds since the kernel started the process (`p_starttime` from `sysctl` `KERN_PROC_PID`), so time spent in dyld before `main` counts. The lines never hold tokens or addresses. `=1` prints the marks and nothing more. `=startup` quits once it reaches `tracks`. `=memory` runs the memory scenario and quits. The tool sets the mode.

The startup marks, in order:

| mark | what has happened |
|---|---|
| `main` | `shell_main` started: dyld has loaded the executable and its frameworks, and the Odin runtime has run its `@(init)` procedures |
| `launched` | `applicationDidFinishLaunching`: AppKit is set up. On Linux: connected to the Wayland compositor |
| `ns_window` | macOS: the `NSWindow` is made |
| `metal_device` | macOS: `MTLCreateSystemDefaultDevice` returned, in the view's `makeBackingLayer` |
| `app_start` | the shell calls `app_init` |
| `render_device` | Linux: the Vulkan instance and device are made |
| `render_shaders` | macOS: `newLibraryWithData` loaded the shader library |
| `init_render` ... `init_search` | each step of the app's `start` returned, in order: render, text, ui, library, data, rows, playback, search |
| `text_fonts` | inside the text step: the system font and the icon fonts are loaded, before the fallback faces |
| `init` | the app's `init` returned: renderer, shaders, fonts, caches, workers |
| `window` | the window is ordered front |
| `first_frame` | the first frame is committed and its drawable presented |
| `library` | the first frame with the sidebar's playlists (fake: the first frame) |
| `tracks` | the first frame with track rows and every cover on screen ready |

"Presented" means the app called `presentDrawable` and committed. The frame reaches the display a vsync or two later.

The shell's marks and the marks inside `init` carry only their time. The rest also carry the memory and the instruction counts. [Startup time](startup.md) uses these marks to compare macOS and Linux.

Samples carry the same memory numbers as the marks plus the mapped fonts. The memory scenario takes one after each of these stages:

1. `startup_idle`: the library is up and its covers are in, then 5 s with nothing happening.
2. `list_open`: the longest list is open with every row loaded: the mock's 3,000-track playlist, or the fake data's 10,000 rows. 3 s to settle.
3. `scrolled`: the bench's auto-scroll went through it (`TIDALFAST_BENCH=covers` on the mock: 600 rows one a frame, then 1,200 four a frame; the library bench on the fake data), covers loading as it went. 3 s to settle.
4. `playing`: 8 s after playback started on the first playable row. It was 30 s until 31 October, but in the tick lines of a mock run and a real-account run the footprint was within 0.5 MB of its final value a second after playback started.
5. `idle_after`: playback stopped, then 10 s, which shows what stays allocated. The footprint drops 5 to 7 s after the stop, so this wait can't be shorter.

Then it quits through SIGTERM, the same path as Ctrl-C, so shutdown runs. A stage of the memory or frames scenario that hasn't moved on after 30 s (120 s against a real account, whose longest list can take a while to load) is stuck: the app prints an `error` line naming it and quits, so the tool reports the run as failed instead of waiting out its timeout.

A run takes about 40 s, so `measure memory` with both setups about 80 s. Running the two setups at the same time would halve that, but on 31 October it measured 19 MB less GPU memory at every stage: the two windows cover each other, and the shell shrinks a covered window's drawables.

## The numbers

- **footprint** is `phys_footprint` from `task_info(TASK_VM_INFO)`. It's what Activity Monitor's Memory column shows and what macOS counts against the app under memory pressure: dirty memory the app owns, compressed or swapped memory included. On Apple silicon it includes Metal's allocations, since the GPU uses the same RAM. So gpu is part of footprint, not on top of it.
- **resident** is the pages in RAM right now, clean ones included. That takes in the code of the app and every framework it touched, and mapped files. Pages of a mapped file that nobody wrote to are clean: the kernel can drop them and read them back from disk, so they count toward resident but not footprint.
- **gpu** is the Metal device's `currentAllocatedSize`: glyph atlas pages, cover pages, instance buffers, the drawables' textures.
- **fonts map** and **fonts res** are the fallback fonts the text loader mapped with `mmap`, and how much of them is resident (from `mincore`). Apple Color Emoji alone is 180 MB of file, but only the pages of glyphs drawn get read in. Those pages count toward resident and not footprint.
- **instructions** and **cycles** are what every thread of the process has run since it started, dyld included, from `proc_pid_rusage` (`rusage_info_v4`). **ui_instructions** and **ui_cycles** are the UI thread's alone, from the `thread_selfcounts` system call, which isn't public API; a kernel without it gives zeros, and so does Linux for now. Unlike times, instruction counts hardly move with load, clock speed or heat: a fixed piece of work counted the same to 0.1% on an idle machine and with every core busy, while its time grew 25%. In the app they still vary, because how far other threads get by a mark, and how many frames run before it, differ from run to run. Over nine launches on 17 October the UI thread's count at `tracks` had a standard deviation of about 1% (fake and mock), the whole process's 0.7% (mock) to 3.7% (fake), and the time at `tracks` 6 to 7%. Only the app's marks and samples carry them; the shell's marks have times only.
- The rest is the app's own accounting: `arena` (the persistent arena's used bytes), `frame_peak` (the frame arena's high-water mark), `atlas_pages`, `runs` (shaped runs in the text cache), `covers` and `cover_bytes` (the cover cache's entries and its pages' bytes), `rows` and `view_bytes` (the open list and its arena).

With `TIDALFAST_MEASURE` unset, measuring costs two additions per drawn row and cover, the marks until `tracks` is reached, and the launch log's one line. With it set, marks and samples come from frames that happen anyway. Only the memory scenario starts a thread, which samples once a second (`tick` lines) and wakes the UI when a stage's wait is over. A sample costs a few milliseconds because of `mincore` over 600 MB of fonts, so marks leave that out. That pass also makes the kernel build about 3 MB of page tables for the font mappings, which count toward the footprint until the kernel takes them back, usually during an idle stage. So a sample's footprint can be 3 MB under the next sample's for no change in the app. An idle window shows 0 CPU time over 10 s with it unset and with `=1`.

The frame-time overlay (backtick) shows footprint and gpu under the frame times.

## Where the memory went

On a MacBook Air (M1, 8 GB) in October, before the memory work, the footprint was 104 MB at `startup_idle` with the fake data and 114 MB with the mock, 174 MB on the mock after scrolling and 185 MB after playing, with a 198 MB peak, and `tracks` came at 312 and 581 ms. What took it down, in the order it went in, measured each time against the build before:

- Covers in shared pages of exact-size covers, without mips, within 8 MB: the mock's scrolled footprint went from 174 to 119 MB, gpu from 103 to 51 MB. See Covers.
- Opening the dylib in place in release builds: `tracks` 320 to 187 ms with the fake data, 589 to 437 ms on the mock, all of it between `launched` and `dylib`.
- The persistent arena not zeroing what it hands out: about 16 to 17 MB at every stage.
- One draw call for a colour and a coverage texture: the mock's library from 37 draw calls a frame to 3. No memory change.
- The fake rows made only for the fake data: 2.5 MB with an account.
- Inter's embedded bytes used in place in release builds: 3.3 MB.
- 3 MB stream windows given back when cleared: nothing on the mock's memory scenario, whose tracks are smaller than either window. After the hi-res album played out, the old build still counted 5.9 MB of window and the new one none.
- Two drawables while idle: 12 MB at every idle stage.
- Glyph pages starting at a quarter size: 3.3 to 6.7 MB.
- Idle workers giving back their temp pages: about 2.3 MB on the mock.

What's left at idle with the fake data: two drawables (24 MB of gpu, as IOSurfaces), about 25 MB of malloc (7 MB of it kb_text_shape's tables for the 16 fallback faces the loader loads at start, the rest mostly AppKit, Core Text and Metal), and a few MB of the persistent arena actually written.
