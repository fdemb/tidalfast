# Windows

The Windows build is a first pass. It runs the same app as macOS and Linux: a Win32 shell in C (`shell/shell_win32.c`), the Vulkan renderer Linux uses, FreeType text, miniaudio playback through WASAPI's shared mode and the login in the Credential Manager. It is built for x86-64 Windows 10 and 11, and it cross-compiles from macOS or Linux. There is no build on Windows itself yet.

## Building

`./build.sh windows` writes `build/windows/tidalfast.exe`. `./build.sh windows release` makes an optimized one with the windows subsystem, so it opens no console. The debug build keeps the console, where the log goes. It needs:

- Odin, the same release as the rest of the project, plus the Windows libraries Odin ships in its Windows release: `vendor/curl/lib/libcurl.lib` and `vendor/stb/lib/*.lib`. Copy them from `odin-windows-amd64-<release>.zip` into the same folders of the Odin install that builds. Odin's libcurl for Windows talks TLS through Schannel, so it trusts the system's certificate store.
- clang-cl and lld-link (`apt install clang lld llvm` or Homebrew's `llvm`), `llvm-lib` and `llvm-rc`, `glslangValidator`, `curl`, `sha256sum` and `tar`.
- The MSVC libraries and the Windows SDK, fetched with [xwin](https://github.com/Jake-Shadle/xwin) and named by `WINDOWS_SDK`:

```
xwin --accept-license --arch x86_64 splat --output ~/winsdk --use-winsysroot-style --preserve-ms-arch-notation --disable-symlinks
tools/winsdk_case.sh ~/winsdk
WINDOWS_SDK=~/winsdk ./build.sh windows
```

`tools/winsdk_case.sh` adds links for each spelling of the SDK's files that the headers, Odin and the CRT ask for (`Windows.h` and `windows.h`, `User32.lib` and `user32.lib`). A case-sensitive file system needs it; Windows and a default macOS volume don't care.

The C libraries are compiled with clang-cl into `build/windows`, apart from the native ones in `build`, so one checkout builds both. `third_party`'s bindings pick `build/windows/<name>/<name>.lib` on Windows. FreeType 2.13.3 comes from its release, checked against its SHA-256, and is built with only the modules the app uses (`third_party/freetype/tf_ftmodule.h`): TrueType and CFF outlines, the SFNT tables with CBDT colour bitmaps and variations, and the anti-aliasing rasterizer. Its zlib and OT-SVG options are off (`tf_ftoption.h`).

`packaging/windows` has the icon, the version resource and the manifest, which `llvm-rc` compiles into the executable. The manifest asks for per-monitor DPI awareness (v2) and UTF-8 as the process's code page.

## What's different

- **The shell.** The window is a plain `WS_OVERLAPPEDWINDOW` with the system's title bar, dark where Windows 10 20H1 and later let a window ask. The main loop waits in `MsgWaitForMultipleObjectsEx` on messages, an event `request_redraw` sets from any thread, and two waitable timers: the app's `wake_after` and the test driver. A frame draws once for everything that arrived. While a drag resizes the window, Windows runs its own loop, and a timer draws from inside it. While the app animates, the swapchain's FIFO present waits for the display. Sizes are in points of 96 DPI, and `WM_DPICHANGED` moves the window to the size Windows suggests.
- **The shared shell code.** `shell/common.c` has what the Linux and Windows shells share: the event queue, the mirror of the focused text field, the accessibility tree kept for tests, the Now Playing log and the test driver. Each shell adds its own test steps through `os_test_step`.
- **Keys and text.** Keys are mapped by scan code, the key's place on the keyboard, as evdev codes are on Linux. While a text field has the focus, a key that types something comes as text from `WM_CHAR`, surrogate pairs joined. An input method composes through IMM32: its composition string is marked text with the input method's caret, its result string is inserted, and its candidate window goes under the caret the app reports. The app draws the composition itself. Control is the primary modifier, as on Linux. Only the shared mirror behind the input method is tested (the `mark=` and `commit=` steps); the IMM32 messages themselves haven't met a real input method yet.
- **Pointer and wheel.** A whole wheel notch scrolls the user's "lines per notch" setting. A fraction of a notch, from a precision touchpad or a free-spinning wheel, is a precise scroll in points, 16 to a line. Windows sends touchpad scrolls without phases, so there is no momentum after the fingers lift beyond what the touchpad driver sends. The side buttons and `WM_APPCOMMAND` go back and forward.
- **Media keys.** The media keys reach the app while the window has the focus, as `VK_MEDIA_*` keys or `WM_APPCOMMAND`. Not yet the System Media Transport Controls, which would take them from anywhere and show Now Playing in the volume flyout.
- **Rendering.** `src/render/vulkan.odin` is the Linux backend, with the surface made in `vulkan_windows.odin` from the window. `vulkan-1.dll` is loaded when the renderer starts, so a machine without a Vulkan driver opens the window, draws nothing and logs why, as Linux does. Current GPU drivers for Windows ship Vulkan; it has only been tried on Wine's winevulkan over llvmpipe.
- **Text.** FreeType rasterizes as on Linux (`src/text/fonts_freetype.odin`). The text font is the built-in Noto Sans. Fallback fonts come from a list of the UI fonts Windows 10 and 11 use for each script, in the fonts folder (`fonts_windows.odin`): Segoe UI, Segoe UI Symbol, each script's UI font, and Segoe UI Emoji for emoji. Some of them come in optional font packages, and a font that isn't there is skipped. The list hasn't been checked against a real Windows install yet. Fonts the user installed aren't searched; DirectWrite's font fallback would find them. Segoe UI Emoji's colour layers (COLR) aren't drawn, so emoji are black and white. The Windows build's FreeType has no PNG decoder, so a font whose glyphs are only PNG bitmaps (CBDT or sbix, such as Noto Color Emoji) is skipped for the next font in the list.
- **Audio.** miniaudio plays through WASAPI in shared mode, where Windows mixes and resamples. There is no bit-perfect output (`audio.BIT_PERFECT` is false, and the Output menu leaves it out); WASAPI exclusive mode would give it.
- **Login.** The login is a generic credential in the Credential Manager, target `<service>/auth`, which Windows encrypts with the user's login. One credential holds at most 2560 bytes, so a longer login is split across `<service>/auth`, `<service>/auth#1` and so on. `TIDALFAST_KEYCHAIN` names another service against the mock, as on macOS.
- **Files.** Settings and snapshots go in `%APPDATA%\tidalfast` and caches in `%LOCALAPPDATA%\tidalfast`. The app joins paths with `/`, which Windows takes. The environment variables come first, as `XDG_CONFIG_HOME` does on Linux, so a test can point them elsewhere.
- **Memory.** The footprint is the private working set, what Task Manager's Memory column shows; where Windows doesn't report it (before Windows 10 1809, and Wine), the private bytes or the working set stand in. `sys.page_flags` counts a page as in the working set through `QueryWorkingSetEx`. The memory blocks the shell gives the app are committed with `VirtualAlloc`, which costs nothing until a page is written. `TIDALFAST_MEASURE` marks work as on the other systems; the cycle counters come from `QueryThreadCycleTime`, and there is no instruction count.
- **Quitting.** Ctrl-C in the console and SIGTERM, which `sys.quit` raises for `measure`, quit through the main loop, so the app's shutdown runs. There is no SIGUSR1: the shell's `snapshot` test step asks for a memory snapshot.

## Running it without Windows

The executable runs under Wine. On an ARM64 Linux machine, [Hangover](https://github.com/AndreRH/hangover)'s Wine runs x86-64 Windows programs through FEX, and its winevulkan hands Vulkan to the host's driver, Mesa's llvmpipe without a GPU. Wine draws to X11, so give it an Xvfb. A prefix of its own keeps it away from any other Wine setup:

```
export WINEPREFIX=~/.cache/wineprefix-tidalfast
wine wineboot -u
Xvfb :91 -screen 0 1600x1000x24 &
DISPLAY=:91 WINEDEBUG=-all TIDALFAST_FAKE=1 TIDALFAST_AUDIO_NULL=1 \
    APPDATA='Z:\tmp\tf\roaming' LOCALAPPDATA='Z:\tmp\tf\local' \
    TIDALFAST_CAPTURE='Z:\tmp\tf\last.tga' \
    TIDALFAST_SHELL_TEST='3:size=820,600;5:capture=Z:\tmp\tf\narrow.tga;6:key=ctrl+f;7:commit=Jóga;8:ime;9:ax-dump;10:quit' \
    wine build/windows/tidalfast.exe
```

Paths the app gets are Windows paths: Wine's `Z:` drive is the Linux root. A fresh prefix has no fonts beyond Tahoma, so characters outside its Latin, Greek and Cyrillic show as boxes; copying a font with them, such as DejaVu Sans, into the prefix's `windows/Fonts` as `arial.ttf` puts it in the fallback list. The same test steps work as on Linux (see `shell/common.c` and `shell_win32.c`); `move=x,y`, `click=x,y`, `type=text`, `vkey=name`, `wheel=n`, `touchpad=dy`, `minimize` and `restore` go through the window procedure as Windows' own messages would.

Under emulation the frame times say nothing about real hardware: the CPU is emulated and llvmpipe draws on it. The behaviour is the real app's, though. The same shell test script gives the same input method mirror and accessibility tree as on Linux, the double-clicked fake row plays a 220 Hz tone into `TIDALFAST_AUDIO_CAPTURE`, a PKCE login against `tests/mock_tidal` goes over curl and Schannel and is restored from the Credential Manager on the next launch, `type=` and `vkey=` edit the search field through `WM_CHAR` and `WM_KEYDOWN` with surrogate pairs joined, the layout and clicks scale at 144 DPI (Wine's `LogPixels`), CJK, Arabic, Hebrew, Devanagari and Thai fall back to the fonts in the list, the window survives being minimized, restored and resized six times in two seconds, a prefix without Vulkan opens the window, logs why it draws nothing and still takes input, and an idle window uses no CPU, minimized or not. `./build.sh windows` from a fresh checkout fetches and builds FreeType by itself.

## Not done yet

- A build on Windows itself (a `build.bat`, or `build.sh` in Git Bash with MSVC on `PATH`), and a CI job. `odin test tests` doesn't build for Windows from another system yet, since `odin test` takes no `-windows-sdk-root`.
- Packaging: an installer or a zip with the executable, and code signing. `./build.sh windows dist` writes only `build/dist/tidalfast.exe`. `./build.sh windows measure` refuses: `tools/measure` drives only Linux and macOS builds.
- WASAPI exclusive mode for bit-perfect output.
- The System Media Transport Controls, for media keys from anywhere and Now Playing.
- UI Automation for screen readers. The app's accessibility tree is there; the shell keeps it only for tests.
- Drawing into the title bar, as on macOS, with `DwmExtendFrameIntoClientArea` and `WM_NCHITTEST` for the drag regions the app already reports.
- DirectWrite font fallback for fonts the user installed, and COLR colour emoji.
- Drag and drop.
- Windows on ARM64. Odin has no `windows_arm64` target yet.
