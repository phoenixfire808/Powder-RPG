# Catch2 test suite. Only configured when -Dbuild_tests=true, so the normal game
# build (and D:\The-Powder-Toy\build) is completely unaffected and powder.exe is
# never relinked by running tests.
#
# Configure and run in a SEPARATE build dir so a running game cannot be disturbed:
#   meson setup build-tests -Dbuild_tests=true
#   ninja -C build-tests tests/engine_tests.exe
#   meson test -C build-tests -v

# tests=false stops Catch2 building its own ~4000-case SelfTest suite, which otherwise
# dominates CI time and tells us nothing about this engine.
catch2_dep = dependency(
	'catch2-with-main',
	fallback: [ 'catch2', 'catch2_with_main_dep' ],
	default_options: [ 'tests=false' ],
)

# libsimulation has undefined references to Renderer (flame/plasma colour tables),
# GameSave (Simulation::Load/Save) and Gravity. Those live in powder_files, not in the
# 'gui' or 'common' static libs, so linking gui here would drag in SDL2 and still leave
# 12 unresolved externals.
#
# The headless 'render' target (meson.build, build_render) already solves exactly this
# closure: common + simulation + these four files, and no SDL, Lua, curl or gui. Mirror
# it, minus PowderToyRenderer.cpp, which carries the main() that Catch2Main provides.
engine_support_files = files(
	'../src/client/GameSave.cpp',
	'../src/common/clipboard/Null.cpp',
	'../src/graphics/Renderer.cpp',
	'../src/simulation/gravity/Null.cpp',
)

engine_tests_exe = executable(
	'engine_tests',
	sources: files(
		'test_plane.cpp',
		'test_elements.cpp',
		'test_camzoom.cpp',
		'test_air_perf.cpp',
		'test_particle_perf.cpp',
		'test_terrainlayer.cpp',
		'test_loopvariants.cpp',
		'test_parallel.cpp',
		'_debug_repro.cpp',
	) + engine_support_files,
	include_directories: include_directories('../src'),
	dependencies: [
		catch2_dep,
		sta_libs['simulation'],
		sta_libs['common'],
	],
	# Match the ABI (exception model, RTTI, NDEBUG) the static libs were built with.
	cpp_args: project_cpp_args,
	override_options: target_options,
	# tpt-libs is a dynamic build here, so jsoncpp/libpng/zlib/bz2 DLLs must land in the
	# build root or the test exe dies with 0xC0000135 (DLL not found) before main().
	link_depends: copied_dlls,
	build_by_default: true,
)

# The DLLs are copied to the build root, but the exe lives in build-tests/tests, so the
# loader needs the build root on PATH.
test_env = environment()
test_env.prepend('PATH', meson.project_build_root())

test(
	'engine',
	engine_tests_exe,
	protocol: 'tap',
	args: [ '--reporter', 'tap' ],
	env: test_env,
	timeout: 300,
)

# Catch2 hides [!benchmark] cases from the default run, so they need their own
# invocation - otherwise CI would silently never execute the performance assertion.
test(
	'engine-benchmark',
	engine_tests_exe,
	protocol: 'tap',
	args: [ '[!benchmark]', '--reporter', 'tap' ],
	env: test_env,
	timeout: 300,
)
