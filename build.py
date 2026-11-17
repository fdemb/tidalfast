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
                        tidalfast.exe and a .zip of it on Windows
./build.py test         what the tests link, then `odin test tests`; arguments after
                        -- go to odin, such as -- -define:ODIN_TEST_NAMES=tests.name

--out DIR puts what would go in build/ in DIR instead, such as
DIR/measure/app/tidalfast for measure, so a throwaway build leaves build/
alone. The C libraries, and on Linux the Wayland glue and the SPIR-V
shaders, stay in build/, since the code links and loads them from there.

On Windows, run it as `python build.py` from an x64 Native Tools Command
Prompt for Visual Studio, so cl, lib, rc and link are on PATH, with odin on
PATH too. fxc from the Windows SDK compiles the shaders when it's on PATH;
otherwise the build uses the bytecode in src/render/shaders/dxbc.

On macOS, the Metal compiler from Xcode (not the command line tools; since
Xcode 26 also `xcodebuild -downloadComponent MetalToolchain`) compiles the
shaders when rect.metal is newer than the library in
src/render/shaders/metallib and xcrun can run it; otherwise the build uses
that library as it is.

TIDALFAST_VERSION=1.2.3 sets the version, else a v1.2.3 tag on HEAD, else 0.0.0.

TIDALFAST_SIGN_IDENTITY=name signs the macOS app and the dist bundle with
that code signing identity (see `security find-identity -v -p codesigning`)
instead of ad hoc. The Keychain then knows the app by its identifier and
certificate rather than the hash of one build, so a rebuild doesn't ask
again for the saved login.
"""

import glob
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import zipfile

PROG = "build.py"
USAGE = "usage: build.py [release | measure | dist | libs | test] [--out DIR] [-- odin test args], or build.py --help"

# The oldest macOS the app runs on. Odin and clang otherwise target the
# build machine's version, and the app won't start on anything older.
MACOS_MIN = "14.0"
BUNDLE_ID = "com.tidalfast.app"

# The C libraries live in third_party next to their Odin bindings, which
# link build/<name>/<lib>.a, or build/windows/<name>/<lib>.lib on Windows.
# kb_text_shape.c adds one export, tidalfast_bidi_class.
C_LIBS = [("kbts", "kb_text_shape"), ("dr_flac", "dr_flac")]

WAYLAND_PROTOCOLS = [
	"stable/xdg-shell/xdg-shell.xml",
	"stable/viewporter/viewporter.xml",
	"staging/fractional-scale/fractional-scale-v1.xml",
	"unstable/xdg-decoration/xdg-decoration-unstable-v1.xml",
	"unstable/text-input/text-input-unstable-v3.xml",
	"unstable/pointer-gestures/pointer-gestures-unstable-v1.xml",
]

# The Direct3D 11 shaders, one entry point of rect.hlsl each, with its stage.
D3D_SHADERS = [("vs_rect", "vs"), ("ps_rect", "ps"), ("vs_blur", "vs"), ("ps_blur_down", "ps"), ("ps_blur_up", "ps")]

WINDOWS_LIBS = "user32.lib gdi32.lib imm32.lib dwmapi.lib shell32.lib ole32.lib advapi32.lib psapi.lib"

# Odin's own linker on Windows, rad-link, has failed here without a message
# or an exit code, and it's the default, so MSVC's link does it.
WINDOWS_LINKER = "-linker:msvc"


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


class Build:
	"""What one run of the script builds, and where it puts it."""

	def __init__(self, target, mode, out, test_args):
		self.target = target
		self.mode = mode
		self.out = out
		self.test_args = test_args
		self.version = ""
		self.version_numbers = ""
		self.app_flags = []

	def odin_flags(self):
		return ["-o:speed"] if self.mode == "release" else ["-debug"]


def main(argv):
	target = "all"
	mode = "debug"
	out = "build"
	test_args = []
	i = 0
	while i < len(argv):
		arg = argv[i]
		if arg == "release":
			mode = "release"
		elif arg in ("measure", "libs", "test"):
			target = arg
		elif arg == "dist":
			target = "dist"
			mode = "release"
		elif arg == "--out" and i + 1 < len(argv):
			i += 1
			out = argv[i]
		elif arg.startswith("--out="):
			out = arg[len("--out="):]
		elif arg == "--":
			test_args = argv[i + 1:]
			break
		elif arg in ("-h", "--help", "help"):
			print(__doc__.strip())
			return
		else:
			print(USAGE, file=sys.stderr)
			sys.exit(1)
		i += 1
	if test_args and target != "test":
		fail("arguments after -- are for test")
	if not out:
		fail("--out needs a folder")

	os.chdir(os.path.dirname(os.path.abspath(__file__)))
	check_odin_version()
	b = Build(target, mode, os.path.normpath(out), test_args)

	# The commit goes into the app for the launch log (launch_log.odin), in
	# full: a short hash of only digits would read as a number.
	commit = try_output("git", "rev-parse", "HEAD")
	if commit and subprocess.run(["git", "diff", "--quiet", "HEAD"], stderr=subprocess.DEVNULL).returncode != 0:
		commit += "-dirty"
	b.app_flags = [f"-define:TIDALFAST_COMMIT={commit or 'unknown'}"]

	# A tag v1.2.3 gives 1.2.3, and v1.2.3-beta 1.2.3-beta. Info.plist and the
	# Windows resource want only numbers, so they get version_numbers, 1.2.3.
	version = os.environ.get("TIDALFAST_VERSION") or try_output(
		"git", "describe", "--tags", "--exact-match", "--match", "v[0-9]*")
	if version.startswith("v"):
		version = version[1:]
	b.version = version or "0.0.0"
	b.version_numbers = version_numbers(b.version)

	if sys.platform == "win32":
		build_windows(b)
	else:
		build_unix(b)
	if target == "test":
		run("odin", "test", "tests", [WINDOWS_LINKER] if sys.platform == "win32" else [], test_args)


def version_numbers(version):
	"""The leading 1 to 3 numbers of a version, padded to three: 1.2-rc gives 1.2.0."""
	numbers = re.match(r"\d+(\.\d+){0,2}", version)
	parts = numbers.group(0).split(".") if numbers else []
	return ".".join(parts + ["0"] * (3 - len(parts)))


def check_odin_version():
	"""Warns when odin isn't the release in .odin-version, which CI uses too."""
	try:
		want = open(".odin-version").read().strip()
	except OSError:
		return
	have = try_output("odin", "version")
	if not have:
		fail("odin isn't on PATH")
	if want not in have:
		print(f"{PROG}: warning: the project builds with Odin {want}, and this is {have.split()[-1]}", file=sys.stderr)


# macOS and Linux

def build_unix(b):
	system = platform.system()
	lib_flags = ["-O2", "-fPIC"]
	if system == "Darwin":
		lib_flags.append(f"-mmacosx-version-min={MACOS_MIN}")
	mkdir("build")
	for name, lib in C_LIBS:
		c_lib(name, lib, lib_flags)
	if b.target == "libs":
		return
	if system == "Linux":
		build_linux(b)
	elif system == "Darwin":
		build_macos(b)
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


def build_measure_tools(b):
	measure = os.path.join(b.out, "measure")
	run("odin", "build", "tests/mock_tidal", f"-out:{measure}/mock_tidal", "-o:speed")
	run("odin", "build", "tools/measure", f"-out:{measure}/measure", "-vet", "-strict-style")


# Linux: a Wayland shell in C and a Vulkan renderer. The protocol glue comes
# from wayland-scanner and the shaders from glslangValidator; the app #loads
# the SPIR-V, so shaders are compiled before it.
def build_linux(b):
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
	clang_flags = ["-O2"] if b.mode == "release" else ["-g", "-O0"]

	def shell_object(c, out_dir, flags):
		run("cc", "-std=gnu11", "-fPIC", "-c", c, "-o", f"{out_dir}/{stem(c)}.o",
			"-Ishell", "-Ibuild/wayland", "-Wall", "-Wno-unused-parameter", flags, shell_cflags)

	def shell_objects(out_dir, flags):
		remove(out_dir)
		mkdir(out_dir)
		sources = ["shell/shell_wayland.c", "shell/common.c", "shell/scroll.c", "shell/mpris.c", "shell/png.c"]
		for c in sources + sorted(glob.glob("build/wayland/*-protocol.c")):
			shell_object(c, out_dir, flags)

	def app_build(out, objects_dir, flags):
		objects = " ".join(sorted(glob.glob(f"{objects_dir}/*.o")))
		run("odin", "build", "src/app", f"-out:{out}", "-vet", "-strict-style", flags, b.app_flags,
			f"-extra-linker-flags:{objects} {shell_libs}")

	if b.target == "test":
		# tests/scroll_linux.odin and mpris_linux.odin link the shell's
		# scrolling, MPRIS and PNG code.
		mkdir("build/shell")
		for c in ["shell/scroll.c", "shell/mpris.c", "shell/png.c"]:
			shell_object(c, "build/shell", ["-O2"])
		return

	if b.target == "dist":
		# An AppDir with the app in usr/bin. linuxdeploy copies the libraries
		# it links into usr/lib and packs the AppImage. It leaves out glibc,
		# fontconfig and FreeType by itself. Wayland, xkbcommon and the Vulkan
		# loader must come from the system too, to match its compositor,
		# keymaps and GPU drivers.
		dist = os.path.join(b.out, "dist")
		appdir = f"{dist}/AppDir"
		remove(dist)
		mkdir(f"{appdir}/usr/bin")
		shell_objects(f"{dist}/shell", clang_flags)
		app_build(f"{appdir}/usr/bin/tidalfast", f"{dist}/shell", b.odin_flags())
		remove(f"{dist}/shell")
		env = dict(os.environ)
		env["OUTPUT"] = f"{dist}/TIDALfast-{b.version}-{platform.machine()}.AppImage"
		env["LINUXDEPLOY_OUTPUT_VERSION"] = b.version
		run(os.environ.get("LINUXDEPLOY") or "linuxdeploy", "--appdir", appdir,
			"--executable", f"{appdir}/usr/bin/tidalfast",
			"--exclude-library", "libwayland-*", "--exclude-library", "libxkbcommon.so*",
			"--exclude-library", "libvulkan.so*",
			"--desktop-file", "packaging/linux/tidalfast.desktop", "--icon-file", "packaging/linux/tidalfast.png",
			"--output", "appimage", env=env)
		return

	if b.target == "measure":
		measure = os.path.join(b.out, "measure")
		mkdir(f"{measure}/app")
		shell_objects(f"{measure}/shell", ["-O2"])
		app_build(f"{measure}/app/tidalfast", f"{measure}/shell", ["-o:speed", "-define:TIDALFAST_MOCK_API=true"])
		build_measure_tools(b)
		return

	mkdir(os.path.join(b.out, "measure"))
	shell_objects(os.path.join(b.out, "shell"), clang_flags)
	app_build(os.path.join(b.out, "tidalfast.tmp"), os.path.join(b.out, "shell"), b.odin_flags())
	os.replace(os.path.join(b.out, "tidalfast.tmp"), os.path.join(b.out, "tidalfast"))
	run("odin", "build", "tools/measure", f"-out:{b.out}/measure/measure", "-vet", "-strict-style")


# macOS: Odin links the executable: src/app has main, which calls the
# shell's shell_main. The shell goes in as objects, with the frameworks it
# uses.
def build_macos(b):
	if b.target == "test":
		return

	# The library is checked in, so a build without the Metal compiler, which
	# only comes with Xcode and not the command line tools, still has it.
	# Xcode without its Metal toolchain has a metal that only prints how to
	# get it, so the check runs the compiler.
	metal, metallib = "src/render/shaders/rect.metal", "src/render/shaders/metallib/rect.metallib"
	if stale(metallib, metal) and try_output("xcrun", "metal", "--version"):
		run("xcrun", "metal", f"-mmacosx-version-min={MACOS_MIN}", "-Wall", metal, "-o", metallib)

	sign_identity = os.environ.get("TIDALFAST_SIGN_IDENTITY", "")
	clang_flags = ["-O2"] if b.mode == "release" else ["-g", "-O0"]

	def shell_objects(out_dir, flags):
		remove(out_dir)
		mkdir(out_dir)
		for source, arc in [("shell/shell_cocoa.m", ["-fobjc-arc"]), ("shell/common.c", [])]:
			run("clang", "-c", source, "-o", f"{out_dir}/{stem(source)}.o", arc, f"-mmacosx-version-min={MACOS_MIN}",
				"-Wall", "-Wno-unused-parameter", flags)

	def app_build(out, objects_dir, flags):
		objects = " ".join(sorted(glob.glob(f"{objects_dir}/*.o")))
		run("odin", "build", "src/app", f"-out:{out}", "-vet", "-strict-style", f"-minimum-os-version:{MACOS_MIN}",
			flags, b.app_flags,
			f"-extra-linker-flags:{objects} -framework Cocoa -framework Metal -framework QuartzCore -framework MediaPlayer")

	if b.target == "dist":
		# TIDALfast.app holds the app in Contents/MacOS and is signed ad hoc:
		# an Apple silicon Mac runs nothing unsigned. The .dmg has the app and
		# a link to /Applications to drag it to.
		dist = os.path.join(b.out, "dist")
		bundle = f"{dist}/TIDALfast.app"
		remove(dist)
		mkdir(f"{bundle}/Contents/MacOS", f"{bundle}/Contents/Resources", f"{dist}/dmg")
		shell_objects(f"{dist}/shell", clang_flags)
		app_build(f"{bundle}/Contents/MacOS/tidalfast", f"{dist}/shell", b.odin_flags())
		remove(f"{bundle}/Contents/MacOS/tidalfast.dSYM", f"{dist}/shell")
		fill_template("packaging/macos/Info.plist", f"{bundle}/Contents/Info.plist",
			{"@VERSION@": b.version_numbers, "@MACOS_MIN@": MACOS_MIN})
		shutil.copy("packaging/macos/AppIcon.icns", f"{bundle}/Contents/Resources/")
		run("codesign", "--force", "--sign", sign_identity or "-", bundle)
		shutil.copytree(bundle, f"{dist}/dmg/TIDALfast.app", symlinks=True)
		os.symlink("/Applications", f"{dist}/dmg/Applications")
		run("hdiutil", "create", "-quiet", "-volname", "TIDALfast", "-srcfolder", f"{dist}/dmg", "-format", "ULFO",
			f"{dist}/TIDALfast-{b.version}-macos-{platform.machine()}.dmg")
		remove(f"{dist}/dmg")
		return

	if b.target == "measure":
		measure = os.path.join(b.out, "measure")
		mkdir(f"{measure}/app")
		shell_objects(f"{measure}/shell", ["-O2"])
		app_build(f"{measure}/app/tidalfast", f"{measure}/shell", ["-o:speed", "-define:TIDALFAST_MOCK_API=true"])
		build_measure_tools(b)
		return

	# Link to a temp name, sign, and rename, so a running app keeps the
	# binary it mapped. Without TIDALFAST_SIGN_IDENTITY each build has a new
	# ad hoc signature, which the login Keychain treats as a different app:
	# it asks again for access to the saved TIDAL login.
	out = b.out
	mkdir(f"{out}/measure")
	shell_objects(f"{out}/shell", clang_flags)
	app_build(f"{out}/tidalfast.tmp", f"{out}/shell", b.odin_flags())
	remove(f"{out}/tidalfast.dSYM")
	if os.path.isdir(f"{out}/tidalfast.tmp.dSYM"):
		os.rename(f"{out}/tidalfast.tmp.dSYM", f"{out}/tidalfast.dSYM")
	if sign_identity:
		run("codesign", "--force", "--sign", sign_identity, "--identifier", BUNDLE_ID, f"{out}/tidalfast.tmp")
	os.replace(f"{out}/tidalfast.tmp", f"{out}/tidalfast")
	run("odin", "build", "tools/measure", f"-out:{out}/measure/measure", "-vet", "-strict-style")


# Windows: the Win32 shell in C and the Direct3D 11 renderer, for x86-64,
# built with MSVC. The C libraries go to build/windows/<name>.

def build_windows(b):
	if not shutil.which("cl"):
		fail("cl isn't on PATH, run this from a x64 Native Tools Command Prompt")
	arch = os.environ.get("VSCMD_ARG_TGT_ARCH", "")
	if arch and arch.lower() != "x64":
		fail(f"the prompt targets {arch}, use the x64 one")
	join = os.path.join
	libs_dir = join("build", "windows")
	mkdir(libs_dir)

	for name, lib in C_LIBS:
		out = join(libs_dir, name, f"{lib}.lib")
		src = join("third_party", name)
		if stale(out, join(src, f"{lib}.c"), join(src, f"{lib}.h")):
			mkdir(join(libs_dir, name))
			obj = join(libs_dir, name, f"{lib}.obj")
			cl(join(src, f"{lib}.c"), obj, "/O2", "/W3")
			run("lib", "/nologo", f"/out:{out}", obj)
			remove(obj)
	if b.target in ("libs", "test"):
		return

	# The bytecode is checked in, so a build without fxc still has it.
	if shutil.which("fxc"):
		hlsl = join("src", "render", "shaders", "rect.hlsl")
		for entry, stage in D3D_SHADERS:
			run("fxc", "/nologo", "/O3", "/WX", "/T", f"{stage}_5_0", "/E", entry,
				"/Fo", join("src", "render", "shaders", "dxbc", f"{entry}.dxbc"), hlsl, quiet=True)

	# The icon and the version go into the executable as resources.
	out_dir = join(b.out, "windows")
	shell_dir = join(out_dir, "shell")
	mkdir(shell_dir)
	rc = join(shell_dir, "tidalfast.rc")
	res = join(shell_dir, "tidalfast.res")
	fill_template(join("packaging", "windows", "tidalfast.rc"), rc,
		{"@VERSION_COMMAS@": b.version_numbers.replace(".", ",") + ",0", "@VERSION@": b.version})
	shutil.copy(join("packaging", "windows", "tidalfast.ico"), shell_dir)
	shutil.copy(join("packaging", "windows", "tidalfast.manifest"), shell_dir)
	run("rc", "/nologo", "/fo", res, rc)
	measure = b.target == "measure"
	optimize = ["/O2"] if b.mode == "release" or measure else ["/Od", "/Z7"]
	objects = []
	for c in ["shell_win32.c", "common.c", "smtc_win32.c", "png.c"]:
		obj = join(shell_dir, f"{stem(c)}.obj")
		cl(join("shell", c), obj, optimize, "/W3", "/Ishell")
		objects.append(obj)

	# The subsystem is the console in debug builds, so the log shows in the
	# terminal that started the app, and windows in release builds. The
	# measure tool reads the app's stderr, so its app keeps the console.
	out = join(out_dir, "tidalfast.exe")
	subsystem = "windows" if b.mode == "release" else "console"
	flags = b.odin_flags()
	if b.target == "dist":
		mkdir(join(b.out, "dist"))
		out = join(b.out, "dist", "tidalfast.exe")
	elif measure:
		mkdir(join(b.out, "measure", "app"))
		out = join(b.out, "measure", "app", "tidalfast.exe")
		flags = ["-o:speed", "-define:TIDALFAST_MOCK_API=true"]
		subsystem = "console"
	linker_flags = " ".join([f"/subsystem:{subsystem}", "/ignore:4099"] + objects + [res, WINDOWS_LIBS])
	run("odin", "build", join("src", "app"), f"-out:{out}", "-target:windows_amd64", WINDOWS_LINKER,
		"-vet", "-strict-style", flags, b.app_flags, f"-extra-linker-flags:{linker_flags}")
	if b.target == "dist":
		archive = join(b.out, "dist", f"TIDALfast-{b.version}-windows-x86_64.zip")
		with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
			z.write(out, "tidalfast.exe")
	if measure:
		run("odin", "build", join("tests", "mock_tidal"), "-out:" + join(b.out, "measure", "mock_tidal.exe"),
			"-o:speed", WINDOWS_LINKER)
		run("odin", "build", join("tools", "measure"), "-out:" + join(b.out, "measure", "measure.exe"),
			"-vet", "-strict-style", WINDOWS_LINKER)


def cl(source, obj, *flags):
	run("cl", "/nologo", "/c", "/MT", "/std:c11", "/experimental:c11atomics", flags, source, f"/Fo{obj}")

if __name__ == "__main__":
	try:
		main(sys.argv[1:])
	except KeyboardInterrupt:
		sys.exit(130)
