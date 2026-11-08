# gmcl_audioprop: optional native backend of audioprop (Steam Audio simulation).
# Licence of this directory: Apache-2.0 (see native/LICENSE) - decision pending, see docs/JOURNAL.md.
# Dependencies: python -I native/fetch_deps.py  (Steam Audio SDK + gmod-module-base into native/deps)
# Build (x64 Developer prompt): cmake -S native -B native/build -G Ninja -DCMAKE_BUILD_TYPE=Release
#                               cmake --build native/build
cmake_minimum_required(VERSION 3.20)
project(audioprop_native LANGUAGES CXX)

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
add_library(gmcl_audioprop SHARED src/audioprop_native.cpp src/render.cpp src/streams.cpp)
target_include_directories(gmcl_audioprop PRIVATE "${GMB_ROOT}" "${MA_ROOT}")
if(WIN32)
	# phonon.dll is delay-loaded and loaded explicitly from the module's folder (lua/bin), so a
	# missing phonon.dll is a clean Lua error instead of a failed require().
	target_link_libraries(gmcl_audioprop PRIVATE phonon delayimp)
	target_link_options(gmcl_audioprop PRIVATE "/DELAYLOAD:phonon.dll")
else()
	target_link_libraries(gmcl_audioprop PRIVATE phonon)
endif()
set_target_properties(gmcl_audioprop PROPERTIES PREFIX "" SUFFIX ".dll" OUTPUT_NAME "gmcl_audioprop_${MODULE_SUFFIX}")
