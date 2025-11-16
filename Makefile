.PHONY: all install build-ts build-zig test clean help deprecation-warning

# Show deprecation warning for all targets
deprecation-warning:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "⚠️  DEPRECATION WARNING"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "The Makefile is deprecated and will be removed in a future version."
	@echo ""
	@echo "Please use the Zig build system instead:"
	@echo "  make              →  zig build"
	@echo "  make install      →  zig build install"
	@echo "  make build-ts     →  zig build build-ts"
	@echo "  make build-zig    →  zig build build-native"
	@echo "  make test         →  zig build test"
	@echo "  make clean        →  zig build clean"
	@echo ""
	@echo "See MIGRATION.md for complete migration guide."
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@sleep 3

# Default target
all: deprecation-warning install build-ts build-zig

# Install dependencies
install: deprecation-warning
	@echo "Installing dependencies with bun..."
	bun install
	@echo "Done!"

# Build TypeScript
build-ts: deprecation-warning
	@echo "Building TypeScript utilities..."
	bun run build
	@echo "TypeScript build complete!"

# Build Zig native module (if Zig is available)
build-zig: deprecation-warning
	@if command -v zig >/dev/null 2>&1; then \
		echo "Building Zig native module..."; \
		cd zig && zig build -Doptimize=ReleaseFast; \
		echo "Zig build complete!"; \
	else \
		echo "Zig not found, skipping native module build"; \
		echo "Install Zig from https://ziglang.org/ for performance benefits"; \
	fi

# Run tests
test: deprecation-warning
	@echo "Running TypeScript lint..."
	bun run lint || true
	@if command -v zig >/dev/null 2>&1; then \
		echo "Running Zig tests..."; \
		cd zig && zig build test; \
	fi
	@echo "Tests complete!"

# Clean build artifacts
clean: deprecation-warning
	@echo "Cleaning build artifacts..."
	rm -rf node_modules dist zig-out zig-cache zig/zig-cache zig/zig-out .zig-cache
	@echo "Clean complete!"

# Development mode (watch TypeScript)
dev: deprecation-warning
	@echo "Starting TypeScript watch mode..."
	bun run dev

# Help
help:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "⚠️  MAKEFILE IS DEPRECATED - USE ZIG BUILD INSTEAD"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "jemach Build System (LEGACY)"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all         - Install dependencies and build everything (default)"
	@echo "  install     - Install dependencies with bun"
	@echo "  build-ts    - Build TypeScript utilities"
	@echo "  build-zig   - Build Zig native module (requires Zig)"
	@echo "  test        - Run tests"
	@echo "  clean       - Remove build artifacts"
	@echo "  dev         - Start TypeScript watch mode"
	@echo "  help        - Show this help message"
	@echo ""
	@echo "RECOMMENDED: Use 'zig build' instead!"
	@echo ""
	@echo "Migration:"
	@echo "  make              →  zig build"
	@echo "  make install      →  zig build install"
	@echo "  make build-ts     →  zig build build-ts"
	@echo "  make build-zig    →  zig build build-native"
	@echo "  make test         →  zig build test"
	@echo "  make clean        →  zig build clean"
	@echo ""
	@echo "See MIGRATION.md for details."
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
