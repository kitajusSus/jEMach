.PHONY: all clean install

# Detect OS
UNAME_S := $(shell uname -s)

# Set library extension based on OS
ifeq ($(UNAME_S),Linux)
    LIB_EXT = .so
    LIB_PREFIX = lib
endif
ifeq ($(UNAME_S),Darwin)
    LIB_EXT = .dylib
    LIB_PREFIX = lib
endif
ifeq ($(OS),Windows_NT)
    LIB_EXT = .dll
    LIB_PREFIX =
endif

# Output paths
BUILD_DIR = build
LIB_DIR = $(BUILD_DIR)/lib
TARGET = $(LIB_DIR)/$(LIB_PREFIX)jemach_julia_native$(LIB_EXT)

ZIG_CHECK := $(shell which zig 2>/dev/null)
ifdef ZIG_CHECK
    CXX = zig c++
    COMPILER_NAME = zig c++ (clang-based)
else
    CLANG_CHECK := $(shell which clang++ 2>/dev/null)
    ifdef CLANG_CHECK
        CXX = clang++
        COMPILER_NAME = clang++
    else
        CXX = g++
        COMPILER_NAME = g++
    endif
endif

CXXFLAGS = -std=c++11 -O3 -fPIC -Wall -Wextra

# Build target
all:
	@echo "Building with: $(COMPILER_NAME)"
	@$(MAKE) --no-print-directory $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(LIB_DIR): $(BUILD_DIR)
	mkdir -p $(LIB_DIR)

$(TARGET): native.cpp | $(LIB_DIR)
	$(CXX) $(CXXFLAGS) -shared -o $(TARGET) native.cpp

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)

# Install to parent lib directory
install: $(TARGET)
	mkdir -p ../lib
	cp $(TARGET) ../lib/

# Help
help:
	@echo "jemach Julia Native Module (C++ Build)"
	@echo ""
	@echo "Compiler: $(COMPILER_NAME)"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all     - Build the native module (default)"
	@echo "  clean   - Remove build artifacts"
	@echo "  install - Build and copy to ../lib/"
	@echo "  help    - Show this help message"
	@echo ""
	@echo "Compiler priority: zig c++ > clang++ > g++"
