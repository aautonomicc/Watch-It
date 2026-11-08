cmake_minimum_required(VERSION 3.13)
# C is needed for the glib-compile-resources output (watchit_resources.c).
project(runner LANGUAGES C CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Window/taskbar icon embedded as a GResource — taskbars read _NET_WM_ICON
# from the running window, not the AppImage's .DirIcon. Every size under
# resources/icons/ ships (16…512 px, rendered from branding/icon.svg) so
# the window manager picks a native size instead of rescaling one bitmap.
find_program(GLIB_COMPILE_RESOURCES glib-compile-resources REQUIRED)
file(GLOB WATCHIT_ICON_FILES "${CMAKE_CURRENT_SOURCE_DIR}/resources/icons/*.png")
add_custom_command(
  OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/watchit_resources.c"
  COMMAND ${GLIB_COMPILE_RESOURCES}
    --target="${CMAKE_CURRENT_BINARY_DIR}/watchit_resources.c"
    --generate-source
    --sourcedir="${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/watchit.gresource.xml"
  DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/watchit.gresource.xml"
    ${WATCHIT_ICON_FILES}
)

# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${CMAKE_CURRENT_BINARY_DIR}/watchit_resources.c"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
