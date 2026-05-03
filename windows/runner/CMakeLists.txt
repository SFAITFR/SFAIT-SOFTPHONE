cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "sfait_pjsip_bridge.cpp"
  "sfait_windows_integration.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_definitions(${BINARY_NAME} PRIVATE "WIN32_LEAN_AND_MEAN")
target_compile_options(${BINARY_NAME} PRIVATE /wd"4005")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
set(SFAIT_PJPROJECT_ROOT "${CMAKE_SOURCE_DIR}/../vendor/pjproject" CACHE PATH "Path to pjproject")
file(GLOB_RECURSE SFAIT_PJPROJECT_LIBS
  "${SFAIT_PJPROJECT_ROOT}/pjlib/lib/*.lib"
  "${SFAIT_PJPROJECT_ROOT}/pjlib-util/lib/*.lib"
  "${SFAIT_PJPROJECT_ROOT}/pjmedia/lib/*.lib"
  "${SFAIT_PJPROJECT_ROOT}/pjnath/lib/*.lib"
  "${SFAIT_PJPROJECT_ROOT}/pjsip/lib/*.lib"
  "${SFAIT_PJPROJECT_ROOT}/third_party/lib/*.lib"
)

if(NOT SFAIT_PJPROJECT_LIBS)
  message(FATAL_ERROR
    "PJSIP Windows libraries were not found. Build vendor/pjproject/pjproject-vs14.sln "
    "for the active architecture/configuration before building SFAIT Softphone Windows."
  )
endif()

target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE
  ${SFAIT_PJPROJECT_LIBS}
  "comdlg32.lib"
  "dwmapi.lib"
  "dsound.lib"
  "iphlpapi.lib"
  "ole32.lib"
  "secur32.lib"
  "shell32.lib"
  "winmm.lib"
  "ws2_32.lib"
)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
target_include_directories(${BINARY_NAME} PRIVATE
  "${SFAIT_PJPROJECT_ROOT}/pjlib/include"
  "${SFAIT_PJPROJECT_ROOT}/pjlib-util/include"
  "${SFAIT_PJPROJECT_ROOT}/pjmedia/include"
  "${SFAIT_PJPROJECT_ROOT}/pjnath/include"
  "${SFAIT_PJPROJECT_ROOT}/pjsip/include"
)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
