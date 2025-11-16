#!/usr/bin/env bash

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Harper-nvim-julia Setup Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "📦 Checking Bun..."
if command -v bun >/dev/null 2>&1; then
    BUN_VERSION=$(bun --version)
    echo "   ✅ Bun found: v$BUN_VERSION"
else
    echo "   ⚠️  Bun not found (required for TypeScript features)"
    echo "      Install from: https://bun.sh/"
fi
echo ""

echo "⚡ Checking Zig..."
if command -v zig >/dev/null 2>&1; then
    ZIG_VERSION=$(zig version)
    echo "   ✅ Zig found: $ZIG_VERSION"
else
    echo "   ⚠️  Zig not found (required for build system and native module)"
    echo "      Install from: https://ziglang.org/"
fi
echo ""

echo "🖥️  Checking tmux..."
if command -v tmux >/dev/null 2>&1; then
    TMUX_VERSION=$(tmux -V)
    echo "   ✅ tmux found: $TMUX_VERSION"
else
    echo "   ⚠️  tmux not found (optional for vim-slime backend)"
fi
echo ""

echo "🔬 Checking Julia..."
if command -v julia >/dev/null 2>&1; then
    JULIA_VERSION=$(julia --version | head -1)
    echo "   ✅ Julia found: $JULIA_VERSION"
else
    echo "   ❌ Julia not found (REQUIRED)"
    echo "      Install from: https://julialang.org/downloads/"
fi
echo ""

echo "🔨 Checking TypeScript build..."
if [ -d "dist" ] && [ -f "dist/cli.js" ]; then
    echo "   ✅ TypeScript build found"

    if command -v bun >/dev/null 2>&1; then
        echo "   Testing CLI..."
        if bun dist/cli.js --version >/dev/null 2>&1; then
            echo "   ✅ CLI working"
        else
            echo "   ⚠️  CLI test failed"
        fi
    fi
else
    echo "   ⚠️  TypeScript build not found"
    echo "      Run: zig build install && zig build build-ts"
fi
echo ""

echo "⚡ Checking Zig or cpp native module..."
if [ -d "zig-out/lib" ] || [ -d "zig/zig-out/lib" ]; then
    if ls zig-out/lib/libjemach_julia_native.* 2>/dev/null | grep -q . || ls zig/zig-out/lib/libjemach_julia_native.* 2>/dev/null | grep -q .; then
        echo "   ✅ Zig native module built"
    else
        echo "   ⚠️  Native library not found"
    fi
else
    echo "   ⚠️  Zig build not found"
    echo "      Run: zig build build-native"
fi
echo ""

echo "📚 Checking dependencies..."
if [ -d "node_modules" ]; then
    echo "   ✅ Dependencies installed"
else
    echo "   ⚠️  Dependencies not installed"
    echo "      Run: zig build install"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

AVAILABLE=0
OPTIONAL=0

command -v bun >/dev/null 2>&1 && AVAILABLE=$((AVAILABLE + 1))
command -v zig >/dev/null 2>&1 && AVAILABLE=$((AVAILABLE + 1))
command -v tmux >/dev/null 2>&1 && OPTIONAL=$((OPTIONAL + 1))
command -v julia >/dev/null 2>&1 && AVAILABLE=$((AVAILABLE + 1))

echo "Required components:"
if command -v julia >/dev/null 2>&1; then
    echo "  ✅ Julia"
else
    echo "  ❌ Julia (INSTALL REQUIRED)"
fi
echo ""

echo "Optional components:"
command -v bun >/dev/null 2>&1 && echo "  ✅ Bun (TypeScript runtime)" || echo "  ⚠️  Bun (install from https://bun.sh/ for TypeScript features)"
command -v zig >/dev/null 2>&1 && echo "  ✅ Zig (build system and native module)" || echo "  ⚠️  Zig (install from https://ziglang.org/ for build system)"
command -v tmux >/dev/null 2>&1 && echo "  ✅ tmux (advanced integration available)" || echo "  ⚠️  tmux (install for enhanced workflow)"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Next Steps"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ ! -d "node_modules" ]; then
    echo "1. Install dependencies:"
    echo "   zig build install"
    echo ""
fi

if [ ! -d "dist" ]; then
    echo "2. Build TypeScript:"
    echo "   zig build build-ts"
    echo ""
fi

if command -v zig >/dev/null 2>&1 && [ ! -d "zig-out" ]; then
    echo "3. Build Zig native module:"
    echo "   zig build build-native"
    echo ""
fi


echo "   :JuliaNativeInfo     - Check native module status"
echo "   :JuliaTmuxStatus     - Check tmux integration"
echo "   :JuliaToggleREPL     - Start using the plugin!"
echo ""
