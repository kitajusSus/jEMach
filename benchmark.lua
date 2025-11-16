#!/usr/bin/env lua

local function print_header(title)
	print("\n" .. string.rep("=", 60))
	print(title)
	print(string.rep("=", 60))
end

local function print_result(label, time_ms, iterations)
	local avg_time = time_ms / iterations
	print(string.format("%-30s %8.2f ms total | %8.4f ms/op", label, time_ms, avg_time))
end

local function benchmark(name, fn, iterations)
	iterations = iterations or 1000

	for i = 1, math.min(10, iterations) do
		fn()
	end

	collectgarbage("collect")
	local start_time = os.clock()

	for i = 1, iterations do
		fn()
	end

	local end_time = os.clock()
	local elapsed_ms = (end_time - start_time) * 1000

	print_result(name, elapsed_ms, iterations)
	return elapsed_ms
end

if not vim then
	vim = {
		trim = function(s)
			return s:match("^%s*(.-)%s*$")
		end,
		fn = {
			stdpath = function()
				return "/tmp"
			end,
		},
		log = {
			levels = {
				INFO = 1,
				WARN = 2,
				ERROR = 3,
			},
		},
	}
end

local function generate_julia_code(lines_count, block_type)
	local lines = {}

	if block_type == "function" then
		table.insert(lines, "function test_function(x, y)")
		for i = 1, lines_count - 2 do
			table.insert(lines, "    z = x + y + " .. i)
		end
		table.insert(lines, "end")
	elseif block_type == "for" then
		table.insert(lines, "for i in 1:100")
		for i = 1, lines_count - 2 do
			table.insert(lines, "    println(i + " .. i .. ")")
		end
		table.insert(lines, "end")
	elseif block_type == "module" then
		table.insert(lines, "module TestModule")
		for i = 1, lines_count - 2 do
			table.insert(lines, "    const VAR_" .. i .. " = " .. i)
		end
		table.insert(lines, "end")
	else
		for i = 1, lines_count do
			table.insert(lines, "x = " .. i)
		end
	end

	return lines
end

local native_ok, native = pcall(require, "lua.jemach.native")
if not native_ok then
	print("Error loading native module: " .. tostring(native))
	print("Trying alternative path...")
	native_ok, native = pcall(dofile, "lua/jemach/native/init.lua")
end

if not native_ok then
	print("ERROR: Could not load native module")
	os.exit(1)
end

print_header("jemach Module Performance Benchmark")

print("\n📊 Module Information:")
local info = native.get_info()
print(string.format("  Backend: %s", info.backend))
print(string.format("  FFI Available: %s", tostring(info.ffi_available)))
print(string.format("  Native Module: %s", tostring(info.has_native)))

print_header("Benchmark 1: Block Detection (Small Code - 10 lines)")

local small_lines = generate_julia_code(10, "function")
local iterations = 10000

if info.has_native then
	benchmark("Native (Zig)", function()
		native.detect_block_native(small_lines, 1)
	end, iterations)
end

benchmark("Lua Fallback", function()
	native.detect_block_lua(small_lines, 1)
end, iterations)

if info.has_native then
	local native_time = benchmark("Native via API", function()
		native.detect_block(small_lines, 1)
	end, iterations)

	local lua_time = benchmark("Lua via API", function()
		native.detect_block_lua(small_lines, 1)
	end, iterations)

	if native_time > 0 then
		local speedup = lua_time / native_time
		print(string.format("\n⚡ Native speedup: %.2fx faster", speedup))
	end
end

print_header("Benchmark 2: Block Detection (Medium Code - 50 lines)")

local medium_lines = generate_julia_code(50, "function")
iterations = 5000

if info.has_native then
	benchmark("Native (Zig)", function()
		native.detect_block_native(medium_lines, 1)
	end, iterations)
end

benchmark("Lua Fallback", function()
	native.detect_block_lua(medium_lines, 1)
end, iterations)

print_header("Benchmark 3: Block Detection (Large Code - 200 lines)")

local large_lines = generate_julia_code(200, "module")
iterations = 1000

if info.has_native then
	benchmark("Native (Zig)", function()
		native.detect_block_native(large_lines, 1)
	end, iterations)
end

benchmark("Lua Fallback", function()
	native.detect_block_lua(large_lines, 1)
end, iterations)

print_header("Benchmark 4: Block Type Detection (50 lines each)")

local block_types = { "function", "for", "module" }
iterations = 2000

for _, btype in ipairs(block_types) do
	print("\n" .. btype:upper() .. " blocks:")
	local test_lines = generate_julia_code(50, btype)

	if info.has_native then
		benchmark("  Native", function()
			native.detect_block_native(test_lines, 1)
		end, iterations)
	end

	benchmark("  Lua", function()
		native.detect_block_lua(test_lines, 1)
	end, iterations)
end

-- Benchmark 5: Nested blocks
print_header("Benchmark 5: Nested Block Detection")

local nested_lines = {
	"function outer(x)",
	"    for i in 1:x",
	"        if i > 0",
	"            println(i)",
	"        end",
	"    end",
	"    return x",
	"end",
}
iterations = 5000

if info.has_native then
	benchmark("Native (nested)", function()
		native.detect_block_native(nested_lines, 1)
	end, iterations)
end

benchmark("Lua (nested)", function()
	native.detect_block_lua(nested_lines, 1)
end, iterations)

print_header("Summary")

if info.has_native then
	print("✅ Native module is loaded and active")
	print("✅ Performance benefits are available")
	print("\n💡 The native Zig implementation provides significant speedup")
	print("   for Julia code parsing and block detection operations.")
else
	print("⚠️  Native module not found - using Lua fallback")
	print("⚠️  Performance will be slower than with native module")
	print("\n💡 To enable native performance:")
	print("   Run: zig build")
	print("   This will compile the Zig native module for better performance")
end

print("\n" .. string.rep("=", 60))
print("Benchmark completed!")
print(string.rep("=", 60) .. "\n")
