# gmcl_pba: optional native backend of pba (Steam Audio simulation).
# Licence of this directory: MIT (see native/LICENSE).
# Dependencies: python -I native/fetch_deps.py  (Steam Audio SDK + gmod-module-base into native/deps)
# Build (x64 Developer prompt): cmake -S native -B native/build -G Ninja -DCMAKE_BUILD_TYPE=Release
#                               cmake --build native/build
cmake_minimum_required(VERSION 3.20)
project(pba_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(SA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/deps/steamaudio" CACHE PATH "Steam Audio SDK root")
set(GMB_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/deps/gmod-module-base/include" CACHE PATH "gmod-module-base include")

if(WIN32)
	set(SA_LIBDIR "${SA_ROOT}/lib/windows-x64")
	add_library(phonon SHARED IMPORTED)
	set_target_properties(phonon PROPERTIES
		IMPORTED_LOCATION "${SA_LIBDIR}/phonon.dll"
		IMPORTED_IMPLIB "${SA_LIBDIR}/phonon.lib"
		INTERFACE_INCLUDE_DIRECTORIES "${SA_ROOT}/include")
	set(MODULE_SUFFIX "win64")
else()
	set(SA_LIBDIR "${SA_ROOT}/lib/linux-x64")
	add_library(phonon SHARED IMPORTED)
	set_target_properties(phonon PROPERTIES
		IMPORTED_LOCATION "${SA_LIBDIR}/libphonon.so"
		INTERFACE_INCLUDE_DIRECTORIES "${SA_ROOT}/include")
	set(MODULE_SUFFIX "linux64")
endif()

set(MA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/deps/miniaudio" CACHE PATH "miniaudio dir")
add_library(gmcl_pba SHARED src/pba_native.cpp src/render.cpp src/streams.cpp src/trace.cpp)
target_include_directories(gmcl_pba PRIVATE "${GMB_ROOT}" "${MA_ROOT}")
if(WIN32)
	# phonon.dll is delay-loaded and loaded explicitly from the module's folder (lua/bin), so a
	# missing phonon.dll is a clean Lua error instead of a failed require().
	target_link_libraries(gmcl_pba PRIVATE phonon delayimp)
	target_link_options(gmcl_pba PRIVATE "/DELAYLOAD:phonon.dll")
else()
	target_link_libraries(gmcl_pba PRIVATE phonon)
endif()
set_target_properties(gmcl_pba PROPERTIES PREFIX "" SUFFIX ".dll" OUTPUT_NAME "gmcl_pba_${MODULE_SUFFIX}")

# Version of the module, written into it at build time from the addon's own version (pba.VERSION in
# lua/autorun/pba_init.lua, the one tools/make_release.py checks against the release): the Lua reads it with
# pba_native.ModuleVersion(). -DPBA_VERSION=x.y.z overrides it.
set(PBA_INIT_LUA "${CMAKE_CURRENT_SOURCE_DIR}/../lua/autorun/pba_init.lua")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${PBA_INIT_LUA}")
file(STRINGS "${PBA_INIT_LUA}" PBA_VERSION_LINE REGEX "^pba[.]VERSION *= *\"")
string(REGEX REPLACE "^pba[.]VERSION *= *\"([^\"]*)\".*$" "\\1" PBA_VERSION_FROM_LUA "${PBA_VERSION_LINE}")
if(NOT PBA_VERSION_FROM_LUA)
	message(FATAL_ERROR "pba.VERSION not found in ${PBA_INIT_LUA}")
endif()
set(PBA_VERSION "" CACHE STRING "version written into the module (empty: pba.VERSION of pba_init.lua)")
if(PBA_VERSION)
	set(PBA_MODULE_VERSION "${PBA_VERSION}")
else()
	set(PBA_MODULE_VERSION "${PBA_VERSION_FROM_LUA}")
endif()
message(STATUS "gmcl_pba module version: ${PBA_MODULE_VERSION}")
target_compile_definitions(gmcl_pba PRIVATE PBA_MODULE_VERSION="${PBA_MODULE_VERSION}")
