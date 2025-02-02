cmake_minimum_required(VERSION 3.12)

project("K(eyboard) L(ayout) I(nstaller)"
  VERSION 1.0.0.0
  DESCRIPTION "An application that takes care of installing the specified keyboard layout for you."
  LANGUAGES C
)

configure_file("resources/kli.rc.in" "kli.rc")

add_executable(kli
  "main.c"

  "Config.c"
  "Config.h"
  "Dialog.c"
  "Dialog.h"
  "Input.c"
  "Input.h"
  "Layout.c"
  "Layout.h"
  "Str.c"
  "Str.h"

  "kli.rc"
  "resources/kli.manifest"
)

# Add the inih library from the source file.
add_library(inih STATIC ${CMAKE_CURRENT_SOURCE_DIR}/external/inih/ini.c)

# Specify the include directory for inih.
target_include_directories(inih PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/external/inih)

# Link the inih library target directly to your executable.
target_link_libraries(kli PRIVATE inih)

target_link_options(kli PRIVATE "/MANIFESTUAC:level='requireAdministrator'")

if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
  # Hide console while keeping main() as entry point
  target_link_options(kli PRIVATE
    "/SUBSYSTEM:WINDOWS"
    "/ENTRY:mainCRTStartup"
  )
endif()
