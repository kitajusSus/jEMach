#!/bin/bash


set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "  jemach Performance Benchmark Runner"
echo "=================================================="

LUA_CMD=""
if command -v luajit &> /dev/null; then
    LUA_CMD="luajit"
    echo "✅ LuaJIT found: $(luajit -v 2>&1 | head -n1)"
    echo "   FFI support available for native module"
elif command -v lua &> /dev/null; then
    LUA_CMD="lua"
    echo "⚠️  Using standard Lua: $(lua -v 2>&1 | head -n1)"
    echo "   ⚠️  FFI not available - native module will not load"
    echo "   💡 Install LuaJIT for native module support: apt-get install luajit"
else
    echo "❌ Error: Neither lua nor luajit is installed"
    echo "Please install lua or luajit to run benchmarks:"
    echo "  - Ubuntu/Debian: sudo apt-get install luajit"
    echo "  - macOS: brew install luajit"
    exit 1
fi
echo ""


if [ -f "lib/libjemach_julia_native.so" ] || \
   [ -f "zig-out/lib/libjemach_julia_native.dylib" ] || \
   [ -f "zig-out/lib/jemach_julia_native.dll" ]; then
    echo "✅ Native module found"
else

    echo "⚠️  Native module not found"
    echo "   The benchmark will run in Lua-only mode"
    echo ""
    echo "   💡 To build the native module:"
    echo "      Option 1 (Makefile): cd native && make install"
    echo "      Option 2 (Zig):      zig build build-cpp"
    echo "      Option 3 (All):      zig build"
fi
echo ""


$LUA_CMD benchmark.lua

echo ""
