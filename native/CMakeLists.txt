cmake_minimum_required(VERSION 3.10)
project(jemach_julia_native)

# Set C++ standard
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Use Zig C++ compiler if available
find_program(ZIG_EXECUTABLE zig)
if(ZIG_EXECUTABLE)
    set(CMAKE_CXX_COMPILER "${ZIG_EXECUTABLE}")
    set(CMAKE_CXX_COMPILER_ARG1 "c++")
    message(STATUS "Using Zig C++ compiler: ${ZIG_EXECUTABLE}")
endif()

# Build shared library
add_library(jemach_julia_native SHARED native.cpp)

# Set output directory
set_target_properties(jemach_julia_native PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)

# Platform-specific settings
if(WIN32)
    set_target_properties(jemach_julia_native PROPERTIES
        PREFIX ""
        SUFFIX ".dll"
    )
elseif(APPLE)
    set_target_properties(jemach_julia_native PROPERTIES
        PREFIX "lib"
        SUFFIX ".dylib"
    )
else()
    set_target_properties(jemach_julia_native PROPERTIES
        PREFIX "lib"
        SUFFIX ".so"
    )
endif()

# Install target
install(TARGETS jemach_julia_native
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION lib
)
