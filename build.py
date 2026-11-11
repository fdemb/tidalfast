#!/usr/bin/env python3
"""Builds TIDALfast on macOS, Linux and Windows.

./build.py              debug build of the app: build/tidalfast, or
                        build/windows/tidalfast.exe on Windows
./build.py release      optimized build
./build.py measure      what tools/measure runs: an optimized app in build/measure/app that
                        also reads TIDALFAST_API, the mock server and the measure tool
./build.py libs         only the C libraries in third_party, into build/ (build/windows/ on Windows)
./build.py dist         release package in build/dist: TIDALfast.app and a .dmg on macOS,
                        an AppImage on Linux (needs linuxdeploy, or LINUXDEPLOY=path),
                        tidalfast.exe on Windows
./build.py windows ...  any of the above but measure, cross-built for Windows from macOS
                        or Linux with clang-cl against the xwin splat that WINDOWS_SDK
                        names (docs/windows.md)

On Windows, run it as `python build.py` from an x64 Native Tools Command
Prompt for Visual Studio, so cl, lib, rc and link are on PATH, with odin on
PATH too. fxc from the Windows SDK compiles the shaders when it's on PATH;
otherwise the build uses the bytecode in src/render/shaders/dxbc.

TIDALFAST_VERSION=1.2.3 sets the version, else a v1.2.3 tag on HEAD, else 0.0.0.

TIDALFAST_SIGN_IDENTITY=name signs the macOS app and the dist bundle with
that code signing identity (see `security find-identity -v -p codesigning`)
instead of ad hoc. The Keychain then knows the app by its identifier and
certificate rather than the hash of one build, so a rebuild doesn't ask
again for the saved login.
"""

import glob
import hashlib
import os
import platform
import shlex
import shutil
import subprocess
import sys

PROG = "build.py"
USAGE = "usage: build.py [windows] [release | measure | dist | libs], or build.py --help"

# The oldest macOS the app runs on. Odin and clang otherwise target the
# build machine's version, and the app won't start on anything older.
MACOS_MIN = "14.0"
BUNDLE_ID = "com.tidalfast.app"

# The C libraries live in third_party next to their Odin bindings, which
# link build/<name>/<lib>.a, or build/windows/<name>/<lib>.lib on Windows.
# kb_text_shape.c adds one export, tidalfast_bidi_class.
C_LIBS = [("kbts", "kb_text_shape"), ("miniaudio", "miniaudio"), ("dr_flac", "dr_flac")]

WAYLAND_PROTOCOLS = [
	"stable/xdg-shell/xdg-shell.xml",
	"stable/viewporter/viewporter.xml",
	"staging/fractional-scale/fractional-scale-v1.xml",
	"unstable/xdg-decoration/xdg-decoration-unstable-v1.xml",
	"unstable/text-input/text-input-unstable-v3.xml",
	"unstable/pointer-gestures/pointer-gestures-unstable-v1.xml",
]

# FreeType 2.13.3 for Windows, which doesn't have it, with the modules and
# options in third_party/freetype.
FREETYPE = "freetype-2.13.3"
FREETYPE_URL = "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz"
FREETYPE_SHA256 = "0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289"
FREETYPE_SOURCES = [
	"base/ftsystem.c", "base/ftinit.c", "base/ftdebug.c", "base/ftbase.c", "base/ftbbox.c",
	"base/ftbitmap.c", "base/ftmm.c", "truetype/truetype.c", "cff/cff.c", "sfnt/sfnt.c",
	"psaux/psaux.c", "psnames/psnames.c", "pshinter/pshinter.c", "smooth/smooth.c",
]

# The Direct3D 11 shaders, one entry point of rect.hlsl each, with its stage.
D3D_SHADERS = [("vs_rect", "vs"), ("ps_rect", "ps"), ("vs_blur", "vs"), ("ps_blur_down", "ps"), ("ps_blur_up", "ps")]

WINDOWS_LIBS = "user32.lib gdi32.lib imm32.lib dwmapi.lib shell32.lib ole32.lib advapi32.lib psapi.lib"


def fail(message):
	print(f"{PROG}: {message}", file=sys.stderr)
	sys.exit(1)


def flatten(args):
	out = []
	for arg in args:
		if isinstance(arg, (list, tuple)):
			out.extend(flatten(arg))
		else:
			out.append(str(arg))
	return out


def run(*args, env=None, quiet=False):
	"""Runs a command and stops the build when it fails. Lists in args are spliced in."""
	command = flatten(args)
	try:
		result = subprocess.run(command, env=env, stdout=subprocess.DEVNULL if quiet else None)
	except FileNotFoundError:
		fail(f"{command[0]} isn't on PATH")
	if result.returncode != 0:
		fail(f"{os.path.basename(command[0])} failed with exit code {result.returncode}")


def capture(*args):
	"""Runs a command and returns its output, stopping the build when it fails."""
	command = flatten(args)
	try:
		result = subprocess.run(command, stdout=subprocess.PIPE, text=True)
	except FileNotFoundError:
		fail(f"{command[0]} isn't on PATH")
	if result.returncode != 0:
		fail(f"{os.path.basename(command[0])} failed with exit code {result.returncode}")
	return result.stdout.strip()


def try_output(*args):
	"""A command's output, or "" when it fails or isn't there."""
	try:
		result = subprocess.run(flatten(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
	except OSError:
		return ""
	return result.stdout.strip() if result.returncode == 0 else ""


def newer(a, b):
	"""Whether a is newer than b, or exists when b doesn't, as test's -nt."""
	if not os.path.exists(a):
		return False
	if not os.path.exists(b):
		return True
	return os.path.getmtime(a) > os.path.getmtime(b)


def stale(out, *sources):
	return not os.path.exists(out) or any(newer(source, out) for source in sources)


def mkdir(*paths):
	for path in paths:
		os.makedirs(path, exist_ok=True)


def remove(*paths):
	for path in paths:
		if os.path.isdir(path) and not os.path.islink(path):
			shutil.rmtree(path)
		elif os.path.lexists(path):
			os.remove(path)


def stem(path):
	return os.path.splitext(os.path.basename(path))[0]


def fill_template(source, out, values):
	data = open(source, "rb").read()
	for key, value in values.items():
		data = data.replace(key.encode(), value.encode())
	with open(out, "wb") as f:
		f.write(data)


def main(argv):
	mode = "debug"
	target = "all"
	windows = False
	for arg in argv:
		if arg == "release":
			mode = "release"
		elif arg == "measure":
			target = "measure"
		elif arg == "dist":
			target = "dist"
			mode = "release"
		elif arg == "libs":
			target = "libs"
		elif arg == "windows":
			windows = True
		elif arg in ("-h", "--help", "help"):
			print(__doc__.strip())
			return
		else:
			print(USAGE, file=sys.stderr)
			sys.exit(1)

	os.chdir(os.path.dirname(os.path.abspath(__file__)))

	# The commit goes into the app for the launch log (launch_log.odin), in
	# full: a short hash of only digits would read as a number.
	commit = try_output("git", "rev-parse", "HEAD")
	if commit and subprocess.run(["git", "diff", "--quiet", "HEAD"], stderr=subprocess.DEVNULL).returncode != 0:
		commit += "-dirty"
	app_flags = [f"-define:TIDALFAST_COMMIT={commit or 'unknown'}"]

	# A tag v1.2.3 gives 1.2.3. Info.plist wants numbers, so anything else is 0.0.0.
	version = os.environ.get("TIDALFAST_VERSION") or try_output(
		"git", "describe", "--tags", "--exact-match", "--match", "v[0-9]*")
	if version.startswith("v"):
		version = version[1:]
	version = version or "0.0.0"

	if windows or sys.platform == "win32":
		build_windows(mode, target, app_flags, version, native=sys.platform == "win32")
	else:
		build_unix(mode, target, app_flags, version)


# macOS and Linux

def build_unix(mode, target, app_flags, version):
	if mode == "release":
		odin_flags = ["-o:speed"]
		clang_flags = ["-O2"]
	else:
		odin_flags = ["-debug"]
		clang_flags = ["-g", "-O0"]
	system = platform.system()
	lib_flags = ["-O2", "-fPIC"]
	if system == "Darwin":
		lib_flags.append(f"-mmacosx-version-min={MACOS_MIN}")

	mkdir("build", "build/measure")
	for name, lib in C_LIBS:
		c_lib(name, lib, lib_flags)
	if target == "libs":
		return

	if system == "Linux":
		build_linux(target, app_flags, version, odin_flags, clang_flags)
	elif system == "Darwin":
		build_macos(target, app_flags, version, odin_flags, clang_flags)
	else:
		fail(f"no build for {system}; build.py builds on macOS, Linux and Windows")


def c_lib(name, lib, flags):
	"""Rebuilds build/<name>/<lib>.a when its source is newer or the flags change."""
	src = f"third_party/{name}"
	out = f"build/{name}/{lib}.a"
	flags_file = f"build/{name}/flags"
	try:
		old_flags = open(flags_file).read().strip()
	except OSError:
		old_flags = None
	if not stale(out, f"{src}/{lib}.h", f"{src}/{lib}.c") and old_flags == " ".join(flags):
		return
	mkdir(f"build/{name}")
	with open(flags_file, "w") as f:
		f.write(" ".join(flags) + "\n")
	obj = f"build/{name}/{lib}.o"
	run("cc", flags, "-c", f"{src}/{lib}.c", "-o", obj)
	remove(out)
	run("ar", "-rcs", out, obj)
	remove(obj)


def build_measure_tools():
	run("odin", "build", "tests/mock_tidal", "-out:build/measure/mock_tidal", "-o:speed")
	run("odin", "build", "tools/measure", "-out:build/measure/measure", "-vet", "-strict-style")


# Linux: a Wayland shell in C and a Vulkan renderer. The protocol glue comes
# from wayland-scanner and the shaders from glslangValidator; the app #loads
# the SPIR-V, so shaders are compiled before it.
def build_linux(target, app_flags, version, odin_flags, clang_flags):
	protocols = capture("pkg-config", "--variable=pkgdatadir", "wayland-protocols")
	mkdir("build/wayland", "build/shaders")
	for xml in WAYLAND_PROTOCOLS:
		name = stem(xml)
		if not os.path.exists(f"build/wayland/{name}-protocol.c"):
			run("wayland-scanner", "client-header", f"{protocols}/{xml}", f"build/wayland/{name}-client-protocol.h")
			run("wayland-scanner", "private-code", f"{protocols}/{xml}", f"build/wayland/{name}-protocol.c")
	for shader in sorted(glob.glob("src/render/shaders/*.vert")) + sorted(glob.glob("src/render/shaders/*.frag")):
		spv = f"build/shaders/{os.path.basename(shader)}.spv"
		if stale(spv, shader):
			run("glslangValidator", "-V", "--quiet", shader, "-o", spv)

	# Odin links the executable: src/app has main, which calls the shell's
	# shell_main. The shell and the protocol glue go in as objects.
	packages = ["wayland-client", "wayland-cursor", "xkbcommon"]
	shell_cflags = shlex.split(capture("pkg-config", "--cflags", packages))
	shell_libs = capture("pkg-config", "--libs", packages) + " -lm"

	def shell_objects(out_dir, flags):
		remove(out_dir)
		mkdir(out_dir)
		sources = ["shell/shell_wayland.c", "shell/common.c", "shell/scroll.c"]
		for c in sources + sorted(glob.glob("build/wayland/*-protocol.c")):
			run("cc", "-std=gnu11", "-fPIC", "-c", c, "-o", f"{out_dir}/{stem(c)}.o",
				"-Ishell", "-Ibuild/wayland", "-Wall", "-Wno-unused-parameter", flags, shell_cflags)

	def app_build(out, objects_dir, flags):
		objects = " ".join(sorted(glob.glob(f"{objects_dir}/*.o")))
		run("odin", "build", "src/app", f"-out:{out}", "-vet", "-strict-style", flags, app_flags,
			f"-extra-linker-flags:{objects} {shell_libs}")

	if target == "dist":
		# An AppDir with the app in usr/bin. linuxdeploy copies the libraries
		# it links into usr/lib and packs the AppImage. It leaves out glibc,
		# fontconfig and FreeType by itself. Wayland, xkbcommon and the Vulkan
		# loader must come from the system too, to match its compositor,
		# keymaps and GPU drivers.
		appdir = "build/dist/AppDir"
		remove("build/dist")
		mkdir(f"{appdir}/usr/bin")
		shell_objects("build/dist/shell", clang_flags)
		app_build(f"{appdir}/usr/bin/tidalfast", "build/dist/shell", odin_flags)
		remove("build/dist/shell")
		env = dict(os.environ)
		env["OUTPUT"] = f"build/dist/TIDALfast-{version}-{platform.machine()}.AppImage"
		env["LINUXDEPLOY_OUTPUT_VERSION"] = version
		run(os.environ.get("LINUXDEPLOY") or "linuxdeploy", "--appdir", appdir,
			"--executable", f"{appdir}/usr/bin/tidalfast",
			"--exclude-library", "libwayland-*", "--exclude-library", "libxkbcommon.so*",
			"--exclude-library", "libvulkan.so*",
			"--desktop-file", "packaging/linux/tidalfast.desktop", "--icon-file", "packaging/linux/tidalfast.png",
			"--output", "appimage", env=env)
		return

	if target == "measure":
		mkdir("build/measure/app")
		shell_objects("build/measure/shell", ["-O2"])
		app_build("build/measure/app/tidalfast", "build/measure/shell",
			["-o:speed", "-define:TIDALFAST_MOCK_API=true"])
		build_measure_tools()
		return

	shell_objects("build/shell", clang_flags)
	app_build("build/tidalfast.tmp", "build/shell", odin_flags)
	os.replace("build/tidalfast.tmp", "build/tidalfast")
	run("odin", "build", "tools/measure", "-out:build/measure/measure", "-vet", "-strict-style")


# macOS: Odin links the executable: src/app has main, which calls the
# shell's shell_main. The shell goes in as an object, with the frameworks it
# uses.
def build_macos(target, app_flags, version, odin_flags, clang_flags):
	sign_identity = os.environ.get("TIDALFAST_SIGN_IDENTITY", "")

	def shell_object(out, flags):
		run("clang", "-c", "shell/shell.m", "-o", out, "-fobjc-arc", f"-mmacosx-version-min={MACOS_MIN}",
			"-Wall", "-Wno-unused-parameter", flags)

	def app_build(out, obj, flags):
		run("odin", "build", "src/app", f"-out:{out}", "-vet", "-strict-style", f"-minimum-os-version:{MACOS_MIN}",
			flags, app_flags,
			f"-extra-linker-flags:{obj} -framework Cocoa -framework Metal -framework QuartzCore -framework MediaPlayer")

	if target == "dist":
		# TIDALfast.app holds the app in Contents/MacOS and is signed ad hoc:
		# an Apple silicon Mac runs nothing unsigned. The .dmg has the app and
		# a link to /Applications to drag it to.
		bundle = "build/dist/TIDALfast.app"
		remove("build/dist")
		mkdir(f"{bundle}/Contents/MacOS", f"{bundle}/Contents/Resources", "build/dist/dmg")
		shell_object("build/dist/shell.o", clang_flags)
		app_build(f"{bundle}/Contents/MacOS/tidalfast", "build/dist/shell.o", odin_flags)
		remove(f"{bundle}/Contents/MacOS/tidalfast.dSYM", "build/dist/shell.o")
		fill_template("packaging/macos/Info.plist", f"{bundle}/Contents/Info.plist",
			{"@VERSION@": version, "@MACOS_MIN@": MACOS_MIN})
		shutil.copy("packaging/macos/AppIcon.icns", f"{bundle}/Contents/Resources/")
		run("codesign", "--force", "--sign", sign_identity or "-", bundle)
		shutil.copytree(bundle, "build/dist/dmg/TIDALfast.app", symlinks=True)
		os.symlink("/Applications", "build/dist/dmg/Applications")
		run("hdiutil", "create", "-quiet", "-volname", "TIDALfast", "-srcfolder", "build/dist/dmg", "-format", "ULFO",
			f"build/dist/TIDALfast-{version}-macos-{platform.machine()}.dmg")
		remove("build/dist/dmg")
		return

	if target == "measure":
		mkdir("build/measure/app")
		shell_object("build/measure/shell.o", ["-O2"])
		app_build("build/measure/app/tidalfast", "build/measure/shell.o",
			["-o:speed", "-define:TIDALFAST_MOCK_API=true"])
		build_measure_tools()
		return

	# Link to a temp name, sign, and rename, so a running app keeps the
	# binary it mapped. Without TIDALFAST_SIGN_IDENTITY each build has a new
	# ad hoc signature, which the login Keychain treats as a different app:
	# it asks again for access to the saved TIDAL login.
	shell_object("build/shell.o", clang_flags)
	app_build("build/tidalfast.tmp", "build/shell.o", odin_flags)
	remove("build/tidalfast.dSYM")
	if os.path.isdir("build/tidalfast.tmp.dSYM"):
		os.rename("build/tidalfast.tmp.dSYM", "build/tidalfast.dSYM")
	if sign_identity:
		run("codesign", "--force", "--sign", sign_identity, "--identifier", BUNDLE_ID, "build/tidalfast.tmp")
	os.replace("build/tidalfast.tmp", "build/tidalfast")
	run("odin", "build", "tools/measure", "-out:build/measure/measure", "-vet", "-strict-style")


# Windows: the Win32 shell in C and the Direct3D 11 renderer, for x86-64.
# On Windows it builds with MSVC. From macOS or Linux it cross-builds with
# clang-cl and lld-link against the MSVC libraries and the Windows SDK that
# xwin fetches (docs/windows.md), in the folder WINDOWS_SDK names, laid out
# for /winsysroot. The C libraries go to build/windows, apart from the
# native ones in build.

class WindowsTools:
	def __init__(self, native):
		if native:
			if not shutil.which("cl"):
				fail("cl isn't on PATH, run this from a x64 Native Tools Command Prompt")
			arch = os.environ.get("VSCMD_ARG_TGT_ARCH", "")
			if arch and arch.lower() != "x64":
				fail(f"the prompt targets {arch}, use the x64 one")
			self.cc = ["cl", "/nologo", "/c", "/MT"]
			self.lib = "lib"
			self.rc = "rc"
			self.c_flags = ["/W3", "/std:c11", "/experimental:c11atomics"]
			self.shell_flags = self.c_flags
			self.freetype_flags = ["/W0"]
			# Odin's own linker on Windows, rad-link, can fail without a
			# message or an exit code, so MSVC's link does it.
			self.odin_flags = ["-linker:default"]
		else:
			sdk = os.environ.get("WINDOWS_SDK") or fail("set WINDOWS_SDK to the xwin splat folder, see docs/windows.md")
			clang_cl = (os.environ.get("CLANG_CL") or shutil.which("clang-cl") or shutil.which("clang-cl-19")
				or "clang-cl")
			self.cc = [clang_cl, "/nologo", "/c", "/MT", "/winsysroot", sdk, "--target=x86_64-pc-windows-msvc"]
			self.lib = "llvm-lib"
			self.rc = "llvm-rc"
			self.c_flags = ["/W3"]
			self.shell_flags = ["/W3", "-Wno-unused-parameter"]
			self.freetype_flags = ["/W3", "-Wno-everything"]
			self.odin_flags = [f"-windows-sdk-root:{sdk}", "-linker:lld"]

	def compile(self, source, obj, *flags):
		run(self.cc, flags, source, f"/Fo{obj}")

	def archive(self, out, objects):
		run(self.lib, "/nologo", f"/out:{out}", objects)


def build_windows(mode, target, app_flags, version, native):
	if target == "measure":
		if not native:
			fail("measure isn't cross-built for Windows; build it on Windows with python build.py measure")
		mode = "release"
	tools = WindowsTools(native)
	join = os.path.join
	out_dir = join("build", "windows")
	mkdir(out_dir)

	for name, lib in C_LIBS:
		out = join(out_dir, name, f"{lib}.lib")
		src = join("third_party", name)
		if stale(out, join(src, f"{lib}.c"), join(src, f"{lib}.h")):
			mkdir(join(out_dir, name))
			obj = join(out_dir, name, f"{lib}.obj")
			tools.compile(join(src, f"{lib}.c"), obj, "/O2", tools.c_flags)
			tools.archive(out, obj)
			remove(obj)
	freetype(tools, out_dir)
	if target == "libs":
		return

	# The bytecode is checked in, so a build without fxc, or a cross-build,
	# still has it.
	if native and shutil.which("fxc"):
		hlsl = join("src", "render", "shaders", "rect.hlsl")
		for entry, stage in D3D_SHADERS:
			run("fxc", "/nologo", "/O3", "/WX", "/T", f"{stage}_5_0", "/E", entry,
				"/Fo", join("src", "render", "shaders", "dxbc", f"{entry}.dxbc"), hlsl, quiet=True)

	# The icon and the version go into the executable as resources.
	shell_dir = join(out_dir, "shell")
	mkdir(shell_dir)
	rc = join(shell_dir, "tidalfast.rc")
	res = join(shell_dir, "tidalfast.res")
	fill_template(join("packaging", "windows", "tidalfast.rc"), rc,
		{"@VERSION_COMMAS@": version.replace(".", ",") + ",0", "@VERSION@": version})
	shutil.copy(join("packaging", "windows", "tidalfast.ico"), shell_dir)
	shutil.copy(join("packaging", "windows", "tidalfast.manifest"), shell_dir)
	run(tools.rc, "/nologo", "/fo", res, rc)
	optimize = ["/O2"] if mode == "release" else ["/Od", "/Z7"]
	objects = []
	for c in ["shell_win32.c", "common.c"]:
		obj = join(shell_dir, f"{stem(c)}.obj")
		tools.compile(join("shell", c), obj, optimize, "-Ishell", tools.shell_flags)
		objects.append(obj)

	# The subsystem is the console in debug builds, so the log shows in the
	# terminal that started the app, and windows in release builds. The
	# measure tool reads the app's stderr, so its app keeps the console.
	out = join(out_dir, "tidalfast.exe")
	subsystem = "windows" if mode == "release" else "console"
	defines = []
	if target == "dist":
		mkdir(join("build", "dist"))
		out = join("build", "dist", "tidalfast.exe")
	elif target == "measure":
		mkdir(join("build", "measure", "app"))
		out = join("build", "measure", "app", "tidalfast.exe")
		defines = ["-define:TIDALFAST_MOCK_API=true"]
		subsystem = "console"
	odin_flags = ["-o:speed"] if mode == "release" else ["-debug"]
	linker_flags = " ".join([f"/subsystem:{subsystem}", "/ignore:4099"] + objects + [res, WINDOWS_LIBS])
	run("odin", "build", join("src", "app"), f"-out:{out}", "-target:windows_amd64", tools.odin_flags,
		"-vet", "-strict-style", odin_flags, defines, app_flags, f"-extra-linker-flags:{linker_flags}")
	if not os.path.exists(out):
		fail(f"odin wrote no {out}")
	if target == "measure":
		run("odin", "build", join("tests", "mock_tidal"), "-out:" + join("build", "measure", "mock_tidal.exe"),
			"-o:speed", tools.odin_flags)
		run("odin", "build", join("tools", "measure"), "-out:" + join("build", "measure", "measure.exe"),
			"-vet", "-strict-style", tools.odin_flags)


def freetype(tools, out_dir):
	"""FreeType from its release, checked against its SHA-256, with only the modules the app uses."""
	join = os.path.join
	out = join(out_dir, "freetype", "freetype.lib")
	config = join("third_party", "freetype")
	if not stale(out, join(config, "tf_ftmodule.h"), join(config, "tf_ftoption.h")):
		return
	ft = join(out_dir, FREETYPE)
	if not os.path.isdir(ft):
		archive = ft + ".tar.xz"
		run("curl", "-fsSL", "-o", archive, FREETYPE_URL)
		with open(archive, "rb") as f:
			digest = hashlib.sha256(f.read()).hexdigest()
		if digest != FREETYPE_SHA256:
			remove(archive)
			fail(f"{FREETYPE}.tar.xz doesn't match its SHA-256")
		run("tar", "xf", archive, "-C", out_dir)
		remove(archive)
	obj_dir = join(out_dir, "freetype", "obj")
	mkdir(obj_dir)
	objects = []
	for c in FREETYPE_SOURCES:
		obj = join(obj_dir, f"{stem(c)}.obj")
		tools.compile(join(ft, "src", *c.split("/")), obj, "/O2", tools.freetype_flags,
			"-I" + join(ft, "include"), "-I" + config, "-DFT2_BUILD_LIBRARY",
			"-DFT_CONFIG_MODULES_H=<tf_ftmodule.h>", "-DFT_CONFIG_OPTIONS_H=<tf_ftoption.h>")
		objects.append(obj)
	tools.archive(out, objects)
	remove(obj_dir)


if __name__ == "__main__":
	try:
		main(sys.argv[1:])
	except KeyboardInterrupt:
		sys.exit(130)
