#!/usr/bin/env luajit
-- jl_tui.lua — Standalone Julia Workspace TUI
--
-- Requires: luajit
-- Usage:    luajit scripts/jl_tui.lua [JULIA_PANE_ID]
--
-- JULIA_PANE_ID is the tmux pane target for the Julia REPL
-- (e.g. "%1" or "{left-of}").  Defaults to "{left-of}".
--
-- Keybindings:
--   j / k        — move cursor down / up
--   l / Enter    — expand module node (or print variable in REPL)
--   h            — collapse module node
--   d            — hide item from view (press D to restore all hidden)
--   q / Ctrl-c   — quit

local ffi = require("ffi")

-- ---------------------------------------------------------------------------
-- FFI: non-blocking stdin read via select(2) + read(2) + sockets
-- ---------------------------------------------------------------------------
ffi.cdef([[
  typedef long          ssize_t;
  typedef unsigned long size_t;
  typedef long          time_t;
  typedef long          suseconds_t;

  typedef struct {
    time_t      tv_sec;
    suseconds_t tv_usec;
  } timeval_t;

  typedef struct { unsigned long fds_bits[16]; } fd_set_t;

  int     select(int, fd_set_t *, fd_set_t *, fd_set_t *, timeval_t *);
  ssize_t read  (int, void *, size_t);

  struct sockaddr_un {
    unsigned short sun_family;
    char           sun_path[108];
  };

  int     socket(int domain, int type, int protocol);
  int     connect(int sockfd, const struct sockaddr_un *addr, unsigned int addrlen);
  int     close(int fd);
  ssize_t write(int fd, const void *buf, size_t count);
]])

local STDIN = 0

local function fd_set_new()
	local s = ffi.new("fd_set_t")
	for i = 0, 15 do
		s.fds_bits[i] = 0
	end
	return s
end

local function fd_set_set(s, fd)
	local word = math.floor(fd / 64)
	local b = fd % 64
	-- Use math.floor(2^b) to stay in integer range (safe for b < 53)
	s.fds_bits[word] = s.fds_bits[word] + math.floor(2 ^ b)
end

local function fd_set_isset(s, fd)
	local word = math.floor(fd / 64)
	local b = fd % 64
	local mask = math.floor(2 ^ b)
	return (s.fds_bits[word] % (2 * mask)) >= mask
end

local function get_project_dir()
	local handle = io.popen("pwd")
	local cwd = handle:read("*a"):gsub("%s+", "")
	handle:close()
	local dir = cwd
	while dir and dir ~= "" and dir ~= "/" do
		local f = io.open(dir .. "/Project.toml", "r")
		if f then
			f:close()
			return dir
		end
		local parent = dir:match("(.*)/[^/]+$")
		if not parent or parent == dir then
			break
		end
		dir = parent
	end
	return cwd
end

local function get_safe_name()
	local pdir = get_project_dir()
	return pdir:gsub("[^a-zA-Z0-9]", "_")
end

local safe_name = get_safe_name()
local socket_path = "/tmp/jemach_" .. safe_name .. ".sock"

local socket_fd = -1
local last_connect_try = 0
local socket_buffer = ""
local dirty = true

local function try_connect_socket()
	if socket_fd >= 0 then
		return
	end

	local now = os.time()
	if now - last_connect_try < 3 then
		return
	end
	last_connect_try = now

	local fd = ffi.C.socket(1, 1, 0) -- AF_UNIX = 1, SOCK_STREAM = 1
	if fd < 0 then
		return
	end

	local addr = ffi.new("struct sockaddr_un")
	addr.sun_family = 1
	ffi.copy(addr.sun_path, socket_path)

	local res = ffi.C.connect(fd, addr, 110)
	if res == 0 then
		socket_fd = fd
		ffi.C.write(socket_fd, "SUB\n", 4)
	else
		ffi.C.close(fd)
	end
end

local function handle_socket_read()
	local buf = ffi.new("char[4096]")
	local n = tonumber(ffi.C.read(socket_fd, buf, 4096))
	if not n or n <= 0 then
		ffi.C.close(socket_fd)
		socket_fd = -1
		return nil
	end

	local chunk = ffi.string(buf, n)
	socket_buffer = socket_buffer .. chunk

	local should_quit = false
	while true do
		local nl = socket_buffer:find("\n")
		if not nl then
			break
		end
		local line = socket_buffer:sub(1, nl - 1)
		socket_buffer = socket_buffer:sub(nl + 1)

		local ok, parsed = pcall(json_parse, line)
		if ok and parsed then
			if parsed.action == "close" or parsed.event == "stop" then
				should_quit = true
			else
				state = parsed
				last_state_ts = os.time()
				dirty = true
			end
		end
	end
	if should_quit then
		return "quit"
	end
	return nil
end

-- Read a single key-press (or escape sequence) with a timeout in ms.
-- Also reads from socket if connected.
-- Returns nil if no input arrived within the timeout.
local function read_key(timeout_ms)
	try_connect_socket()

	local fds = fd_set_new()
	fd_set_set(fds, STDIN)

	local max_fd = STDIN
	if socket_fd >= 0 then
		fd_set_set(fds, socket_fd)
		if socket_fd > max_fd then
			max_fd = socket_fd
		end
	end

	local tv = ffi.new("timeval_t", { tv_sec = 0, tv_usec = (timeout_ms or 100) * 1000 })
	local ready = ffi.C.select(max_fd + 1, fds, nil, nil, tv)
	if ready <= 0 then
		return nil
	end

	if socket_fd >= 0 and fd_set_isset(fds, socket_fd) then
		local sres = handle_socket_read()
		if sres == "quit" then
			return "q"
		end
	end

	if fd_set_isset(fds, STDIN) then
		local buf = ffi.new("char[8]")
		local n = tonumber(ffi.C.read(STDIN, buf, 8))
		if not n or n <= 0 then
			return nil
		end

		local s = ""
		for i = 0, n - 1 do
			s = s .. string.char(buf[i])
		end
		return s
	end

	return nil
end

-- ---------------------------------------------------------------------------
-- Terminal control helpers (ANSI/VT100)
-- ---------------------------------------------------------------------------
local ESC = "\27"
local CLEAR = ESC .. "[2J" .. ESC .. "[H"
local HIDE_CUR = ESC .. "[?25l"
local SHOW_CUR = ESC .. "[?25h"
local BOLD = ESC .. "[1m"
local DIM = ESC .. "[2m"
local RESET = ESC .. "[0m"
local REV = ESC .. "[7m" -- reverse video (selection highlight)
local FG_CYAN = ESC .. "[36m"
local FG_GREEN = ESC .. "[32m"
local FG_YELLOW = ESC .. "[33m"
local FG_RED = ESC .. "[31m"
local FG_WHITE = ESC .. "[37m"

local function move(row, col)
	return ESC .. "[" .. row .. ";" .. col .. "H"
end

local function get_terminal_size()
	local handle = io.popen("tput lines && tput cols 2>/dev/null")
	if not handle then
		return 24, 80
	end
	local lines = tonumber(handle:read("*l")) or 24
	local cols = tonumber(handle:read("*l")) or 80
	handle:close()
	return lines, cols
end

local function raw_mode_on()
	os.execute("stty raw -echo 2>/dev/null")
end

local function raw_mode_off()
	os.execute("stty sane 2>/dev/null")
end

-- ---------------------------------------------------------------------------
-- Minimal JSON parser (handles the format emitted by jl_watcher.jl)
-- ---------------------------------------------------------------------------
local function json_parse(s)
	local pos = 1

	local function skip_ws()
		while pos <= #s and s:sub(pos, pos):match("%s") do
			pos = pos + 1
		end
	end

	local parse_value -- forward declaration

	local function parse_string()
		assert(s:sub(pos, pos) == '"', "expected '\"' at pos " .. pos)
		pos = pos + 1
		local buf = {}
		while pos <= #s do
			local c = s:sub(pos, pos)
			if c == '"' then
				pos = pos + 1
				break
			end
			if c == "\\" then
				pos = pos + 1
				local esc = s:sub(pos, pos)
				if esc == '"' then
					buf[#buf + 1] = '"'
				elseif esc == "\\" then
					buf[#buf + 1] = "\\"
				elseif esc == "n" then
					buf[#buf + 1] = "\n"
				elseif esc == "r" then
					buf[#buf + 1] = "\r"
				elseif esc == "t" then
					buf[#buf + 1] = "\t"
				else
					buf[#buf + 1] = esc
				end
			else
				buf[#buf + 1] = c
			end
			pos = pos + 1
		end
		return table.concat(buf)
	end

	local function parse_number()
		local start = pos
		if s:sub(pos, pos) == "-" then
			pos = pos + 1
		end
		while pos <= #s and s:sub(pos, pos):match("[%d%.eE+%-]") do
			pos = pos + 1
		end
		return tonumber(s:sub(start, pos - 1))
	end

	local function parse_object()
		assert(s:sub(pos, pos) == "{", "expected '{' at pos " .. pos)
		pos = pos + 1
		local obj = {}
		skip_ws()
		if s:sub(pos, pos) == "}" then
			pos = pos + 1
			return obj
		end
		while true do
			skip_ws()
			local key = parse_string()
			skip_ws()
			assert(s:sub(pos, pos) == ":", "expected ':' at pos " .. pos)
			pos = pos + 1
			skip_ws()
			obj[key] = parse_value()
			skip_ws()
			local sep = s:sub(pos, pos)
			if sep == "}" then
				pos = pos + 1
				break
			end
			assert(sep == ",", "expected ',' or '}' at pos " .. pos)
			pos = pos + 1
		end
		return obj
	end

	local function parse_array()
		assert(s:sub(pos, pos) == "[", "expected '[' at pos " .. pos)
		pos = pos + 1
		local arr = {}
		skip_ws()
		if s:sub(pos, pos) == "]" then
			pos = pos + 1
			return arr
		end
		while true do
			skip_ws()
			arr[#arr + 1] = parse_value()
			skip_ws()
			local sep = s:sub(pos, pos)
			if sep == "]" then
				pos = pos + 1
				break
			end
			assert(sep == ",", "expected ',' or ']' at pos " .. pos)
			pos = pos + 1
		end
		return arr
	end

	parse_value = function()
		skip_ws()
		local c = s:sub(pos, pos)
		if c == '"' then
			return parse_string()
		elseif c == "{" then
			return parse_object()
		elseif c == "[" then
			return parse_array()
		elseif c == "t" then
			pos = pos + 4
			return true
		elseif c == "f" then
			pos = pos + 5
			return false
		elseif c == "n" then
			pos = pos + 4
			return nil
		else
			return parse_number()
		end
	end

	skip_ws()
	return parse_value()
end

-- ---------------------------------------------------------------------------
-- State management
-- ---------------------------------------------------------------------------
local STATE_FILE = "/tmp/jl_tui_state_" .. safe_name .. ".json"
local REFRESH_MS = 1500 -- state file poll interval (ms)

local repl_pane = arg and arg[1] or "{left-of}"

-- hidden[key] = true  means the item is hidden from view
-- key = "ModuleName" for a module header, "ModuleName/ItemName" for items
local hidden = {}
-- collapsed[module_name] = true
local collapsed = {}

-- Flat list of "display rows" rebuilt each render pass
--   { kind="module", name, row_idx }
--   { kind="item",   module_name, name, item_type, item_kind, value, row_idx }
--   { kind="gap" }
local active_tab = 1 -- 1: Workspace, 2: History, 3: Procedures, 4: Packages
local TAB_NAMES = { "Workspace", "History", "Procedures", "Packages" }
local tab_cursors = { 1, 1, 1, 1 }
local history_selected = {}
local proc_view_code = false

-- Modal dialog state
local modal_active = false
local modal_title = ""
local modal_input = ""
local modal_callback = nil

-- Toast notifications
local toast_msg = nil
local toast_expires = 0

local function set_toast(msg, duration)
	toast_msg = msg
	toast_expires = os.time() + (duration or 3)
	dirty = true
end

local function split_lines(s)
	local lines = {}
	for line in (s .. "\n"):gmatch("(.-)\r?\n") do
		table.insert(lines, line)
	end
	return lines
end

local function prompt_input(prompt_str)
	raw_mode_off()
	io.write(SHOW_CUR)
	io.write("\n" .. prompt_str)
	io.flush()
	local val = io.read("*l")
	raw_mode_on()
	io.write(HIDE_CUR)
	return val
end

local display_rows = {}
local cursor = 1
local col_cursor = 1 -- 1: Name, 2: Type, 3: Value
local state = nil -- last parsed JSON state
local last_mtime = 0
local last_state_ts = 0

-- ---------------------------------------------------------------------------
-- Read & refresh state
-- ---------------------------------------------------------------------------
local function file_mtime(path)
	local h = io.popen("stat -c %Y " .. path .. " 2>/dev/null")
	if not h then
		return 0
	end
	local v = tonumber(h:read("*l")) or 0
	h:close()
	return v
end

local function load_state()
	if socket_fd >= 0 then
		return false
	end

	local mt = file_mtime(STATE_FILE)
	if mt == 0 or mt == last_mtime then
		return false
	end
	last_mtime = mt

	local f = io.open(STATE_FILE, "r")
	if not f then
		return false
	end
	local content = f:read("*a")
	f:close()

	local ok, parsed = pcall(json_parse, content)
	if ok and parsed then
		state = parsed
		last_state_ts = os.time()
		dirty = true
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Build the flat display_rows list from current state + collapsed/hidden sets
-- ---------------------------------------------------------------------------
local function build_display_rows()
	display_rows = {}

	if active_tab == 4 then
		if not state or not state.packages then
			display_rows[1] = {
				kind = "msg",
				text = "Waiting for packages state…",
			}
			return
		end

		for _, pkg in ipairs(state.packages) do
			table.insert(display_rows, {
				kind = "package",
				name = pkg.name,
				version = pkg.version,
			})
		end

		if #display_rows == 0 then
			display_rows[1] = { kind = "msg", text = "No packages in active environment." }
		end
		return
	end

	if active_tab == 2 then
		local hist = state and state.history or {}
		if #hist == 0 then
			display_rows[1] = {
				kind = "msg",
				text = "No REPL commands captured yet in this session.",
			}
			return
		end
		for i, cmd in ipairs(hist) do
			table.insert(display_rows, {
				kind = "history",
				idx = i,
				cmd = cmd,
				selected = history_selected[i] or false,
			})
		end
		return
	end

	if active_tab == 3 then
		local procs = state and state.procedures or {}
		if #procs == 0 then
			display_rows[1] = { kind = "msg", text = "No procedures defined yet." }
			display_rows[2] = { kind = "msg", text = "  → Press '2' for History, select commands with Space, and press 'p'" }
			display_rows[3] = { kind = "msg", text = "  → In REPL: run jEMach.make_procedure(:name, last=3)" }
			return
		end
		for i, p in ipairs(procs) do
			table.insert(display_rows, {
				kind = "procedure",
				idx = i,
				name = p.name,
				signature = p.signature or (p.name .. "()"),
				file = p.file or "",
				doc = p.doc or "",
				code = p.code or "",
				time_ms = p.time_ms or 0.0,
				alloc_bytes = p.alloc_bytes or 0,
				status = p.status or "never",
				last_run = p.last_run or "-",
			})
		end
		return
	end

	-- active_tab == 1 (Workspace)
	if not state or (not state.modules and not state.columns) then
		display_rows[1] = {
			kind = "msg",
			text = "Waiting for Julia watcher… (using jEMach)",
		}
		return
	end

	if state.columns then
		local cols = state.columns
		local count = #(cols.names or {})
		local skip_until_depth = -1
		local current_mod = nil

		for i = 1, count do
			local mname = (cols.modules and cols.modules[i]) or "Main"
			if mname ~= current_mod then
				current_mod = mname
				if not hidden[mname] then
					local is_collapsed = collapsed[mname]
					local icon = is_collapsed and "▶" or "▼"
					table.insert(display_rows, {
						kind = "module",
						name = mname,
						collapsed = is_collapsed,
						icon = icon,
					})
				end
			end

			if hidden[current_mod] or collapsed[current_mod] then
				goto continue
			end

			local depth = (cols.depths and cols.depths[i]) or 0
			if skip_until_depth >= 0 then
				if depth > skip_until_depth then
					goto continue
				else
					skip_until_depth = -1
				end
			end

			local iname = cols.names[i] or "?"
			local key = current_mod .. "/" .. ((cols.exprs and cols.exprs[i]) or iname)
			if hidden[key] then
				goto continue
			end

			local has_children = cols.has_children and cols.has_children[i] or false
			local is_collapsed = collapsed[key]
			local icon = ""
			if has_children then
				icon = is_collapsed and "▶" or "▼"
			end

			table.insert(display_rows, {
				kind = "item",
				module_name = current_mod,
				name = iname,
				item_kind = (cols.kinds and cols.kinds[i]) or "variable",
				item_type = (cols.types and cols.types[i]) or "",
				value = (cols.values and cols.values[i]) or "",
				expr = (cols.exprs and cols.exprs[i]) or iname,
				depth = depth,
				path = key,
				has_children = has_children,
				icon = icon,
			})

			if has_children and is_collapsed then
				skip_until_depth = depth
			end

			::continue::
		end

		if #display_rows == 0 then
			display_rows[1] = { kind = "msg", text = "No variables in workspace." }
		end
		return
	end

	local function add_item_rows(mname, item, depth, path)
		local iname = item.name or "?"
		local key = path .. "/" .. iname
		if hidden[key] then
			return
		end

		local has_children = item.children and #item.children > 0
		local is_collapsed = collapsed[key]
		local icon = ""
		if has_children then
			icon = is_collapsed and "▶" or "▼"
		end

		table.insert(display_rows, {
			kind = "item",
			module_name = mname,
			name = iname,
			item_kind = item.kind or "variable",
			item_type = item.type or "",
			value = item.value or "",
			expr = item.expr or iname,
			depth = depth,
			path = key,
			has_children = has_children,
			icon = icon,
		})

		if has_children and not is_collapsed then
			for _, child in ipairs(item.children) do
				add_item_rows(mname, child, depth + 1, key)
			end
		end
	end

	for _, mod in ipairs(state.modules) do
		local mname = mod.name or "?"
		if not hidden[mname] then
			local is_collapsed = collapsed[mname]
			local icon = is_collapsed and "▶" or "▼"
			table.insert(display_rows, {
				kind = "module",
				name = mname,
				collapsed = is_collapsed,
				icon = icon,
			})

			if not is_collapsed and mod.items then
				for _, item in ipairs(mod.items) do
					add_item_rows(mname, item, 0, mname)
				end
			end
		end
	end

	if #display_rows == 0 then
		display_rows[1] = { kind = "msg", text = "Workspace is empty." }
	end
end

-- ---------------------------------------------------------------------------
-- Clamp cursor to valid range
-- ---------------------------------------------------------------------------
local function clamp_cursor()
	if cursor < 1 then
		cursor = 1
	end
	if cursor > #display_rows then
		cursor = #display_rows
	end
	if cursor < 1 then
		cursor = 1
	end
	tab_cursors[active_tab] = cursor
end

local function switch_tab(new_tab)
	tab_cursors[active_tab] = cursor
	active_tab = new_tab
	build_display_rows()
	cursor = tab_cursors[active_tab] or 1
	clamp_cursor()
	dirty = true
end

-- ---------------------------------------------------------------------------
-- tmux send-keys to Julia REPL
-- ---------------------------------------------------------------------------
local function tmux_send(code)
	-- Escape single-quotes for shell
	local escaped = code:gsub("'", "'\\''")
	os.execute(string.format("tmux send-keys -t '%s' '%s' Enter", repl_pane, escaped))
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------
local function pad_right(s, width)
	s = tostring(s or "")
	if #s >= width then
		return s:sub(1, width)
	end
	return s .. string.rep(" ", width - #s)
end

local KIND_COLOR = {
	["function"] = FG_CYAN,
	["type"] = FG_YELLOW,
	["variable"] = FG_WHITE,
	["module"] = FG_GREEN,
}

local function render(term_rows, term_cols)
	local out_buf = {}
	table.insert(out_buf, HIDE_CUR .. CLEAR)

	-- Title / Tab bar
	table.insert(out_buf, move(1, 1))
	local tab_parts = {}
	for i = 1, 4 do
		local name = TAB_NAMES[i]
		local badge = ""
		if i == 2 and state and state.history and #state.history > 0 then
			badge = " (" .. #state.history .. ")"
		elseif i == 3 and state and state.procedures and #state.procedures > 0 then
			badge = " (" .. #state.procedures .. ")"
		elseif i == 4 and state and state.packages and #state.packages > 0 then
			badge = " (" .. #state.packages .. ")"
		end
		local t_str = " [" .. i .. "] " .. name .. badge .. " "
		if i == active_tab then
			table.insert(tab_parts, REV .. BOLD .. FG_GREEN .. t_str .. RESET)
		else
			table.insert(tab_parts, DIM .. t_str .. RESET)
		end
	end
	local left_title = table.concat(tab_parts, " ")

	local right_info
	if toast_msg and os.time() <= toast_expires then
		right_info = REV .. BOLD .. FG_GREEN .. " " .. toast_msg .. " " .. RESET
	else
		local sock_icon = (socket_fd >= 0) and (FG_GREEN .. "●" .. RESET) or (DIM .. "○" .. RESET)
		local ts_str = (last_state_ts > 0) and os.date("%H:%M:%S", last_state_ts) or "--:--:--"
		right_info = DIM .. "[" .. repl_pane .. "] " .. sock_icon .. " " .. ts_str .. RESET
	end

	table.insert(out_buf, left_title .. "  " .. right_info)

	-- Separator
	table.insert(out_buf, move(2, 1))
	table.insert(out_buf, DIM .. string.rep("─", term_cols) .. RESET)

	local content_rows = term_rows - 4
	local total = #display_rows

	if active_tab == 3 and total > 0 and display_rows[1].kind == "procedure" then
		-- Split view for procedures: top part list, bottom part code preview
		local list_max_h = math.min(total, math.max(3, math.floor(content_rows * 0.45)))
		local preview_h = content_rows - list_max_h - 1

		local win_start = 1
		if cursor > list_max_h then
			win_start = cursor - list_max_h + 1
		end

		local row_idx = 3
		for i = win_start, math.min(win_start + list_max_h - 1, total) do
			local dr = display_rows[i]
			local sel = (i == cursor)
			table.insert(out_buf, move(row_idx, 1))

			local icon = (dr.status == "ok") and (FG_GREEN .. "✓ " .. RESET) or (dr.status == "error") and (FG_RED .. "✗ " .. RESET) or (DIM .. "○ " .. RESET)
			local sig_col = pad_right(dr.signature, 36)
			local metrics = (dr.status ~= "never") and string.format("%6.2fms %6dB  %s", dr.time_ms, dr.alloc_bytes, dr.last_run) or "never run"
			metrics = pad_right(metrics, 26)
			local file_col = pad_right(dr.file, math.max(0, term_cols - 36 - 26 - 6))

			if sel then
				table.insert(out_buf, icon .. REV .. FG_CYAN .. sig_col .. RESET .. " " .. FG_YELLOW .. metrics .. RESET .. " " .. DIM .. file_col .. RESET)
			else
				table.insert(out_buf, icon .. FG_CYAN .. sig_col .. RESET .. " " .. FG_YELLOW .. metrics .. RESET .. " " .. DIM .. file_col .. RESET)
			end
			row_idx = row_idx + 1
		end

		-- Preview separator
		local split_row = 3 + list_max_h
		table.insert(out_buf, move(split_row, 1))
		local sel_proc = display_rows[cursor]
		local preview_title = sel_proc and (" Source: " .. sel_proc.file .. " ") or " Source Preview "
		table.insert(out_buf, DIM .. "──" .. FG_CYAN .. preview_title .. RESET .. DIM .. string.rep("─", math.max(0, term_cols - #preview_title - 2)) .. RESET)

		-- Preview body
		local preview_row = split_row + 1
		if sel_proc and sel_proc.code and sel_proc.code ~= "" then
			local code_lines = split_lines(sel_proc.code)
			for li = 1, math.min(#code_lines, preview_h) do
				table.insert(out_buf, move(preview_row, 1))
				table.insert(out_buf, FG_WHITE .. pad_right("  " .. code_lines[li], term_cols) .. RESET)
				preview_row = preview_row + 1
			end
		end
	else
		-- Full height list for Workspace, History, Packages
		local win_start = 1
		if cursor > content_rows then
			win_start = cursor - content_rows + 1
		end

		local row_idx = 3
		for i = win_start, math.min(win_start + content_rows - 1, total) do
			local dr = display_rows[i]
			local sel = (i == cursor)
			table.insert(out_buf, move(row_idx, 1))

			if dr.kind == "module" then
				local color = FG_GREEN
				local line = string.format("  %s %-20s", dr.icon, dr.name)
				if sel then
					table.insert(out_buf, REV .. BOLD .. pad_right(line, term_cols) .. RESET)
				else
					table.insert(out_buf, color .. BOLD .. pad_right(line, term_cols) .. RESET)
				end
			elseif dr.kind == "item" then
				local kc = KIND_COLOR[dr.item_kind] or FG_WHITE
				local indent = string.rep("  ", dr.depth or 0)
				local item_icon = dr.icon ~= "" and (dr.icon .. " ") or "  "
				local name_text = "    " .. indent .. item_icon .. dr.name
				local name_col = pad_right(name_text, 26)
				local type_col = pad_right(dr.item_type, 18)
				local val_col = dr.value
				local fixed_w = 26 + 18 + 4
				local val_max = math.max(0, term_cols - fixed_w - 1)
				if #val_col > val_max then
					val_col = val_col:sub(1, val_max - 1) .. "…"
				end
				val_col = pad_right(val_col, term_cols - 26 - 18 - 4)

				if sel then
					local out_str
					if col_cursor == 1 then
						out_str = REV .. name_col .. RESET .. kc .. "  " .. type_col .. "  " .. val_col
					elseif col_cursor == 2 then
						out_str = name_col .. "  " .. REV .. type_col .. RESET .. kc .. "  " .. val_col
					else
						out_str = name_col .. "  " .. type_col .. "  " .. REV .. val_col .. RESET
					end
					table.insert(out_buf, kc .. out_str .. RESET)
				else
					table.insert(out_buf, kc .. name_col .. "  " .. type_col .. "  " .. val_col .. RESET)
				end
			elseif dr.kind == "history" then
				local is_sel = history_selected[dr.idx]
				local check = is_sel and (FG_GREEN .. BOLD .. "[x] " .. RESET) or (DIM .. "[ ] " .. RESET)
				local num = FG_YELLOW .. string.format("%3d: ", dr.idx) .. RESET
				local cmd_text = dr.cmd:gsub("\n", " ⏎ ")
				local max_w = math.max(10, term_cols - 12)
				if #cmd_text > max_w then
					cmd_text = cmd_text:sub(1, max_w - 1) .. "…"
				end
				local line_text = pad_right(cmd_text, max_w)
				if sel then
					table.insert(out_buf, check .. num .. REV .. line_text .. RESET)
				else
					table.insert(out_buf, check .. num .. line_text)
				end
			elseif dr.kind == "package" then
				local name_col = pad_right("  📦 " .. dr.name, 35)
				local ver_col = pad_right("v" .. dr.version, 15)
				if sel then
					table.insert(out_buf, REV .. FG_CYAN .. name_col .. "  " .. FG_GREEN .. ver_col .. RESET)
				else
					table.insert(out_buf, FG_CYAN .. name_col .. "  " .. FG_YELLOW .. ver_col .. RESET)
				end
			elseif dr.kind == "msg" then
				table.insert(out_buf, DIM .. pad_right("  " .. (dr.text or ""), term_cols) .. RESET)
			end

			row_idx = row_idx + 1
		end
	end

	-- Bottom separator + help line
	table.insert(out_buf, move(term_rows - 1, 1))
	table.insert(out_buf, DIM .. string.rep("─", term_cols) .. RESET)

	table.insert(out_buf, move(term_rows, 1))
	local help
	if active_tab == 1 then
		help = " 1..4:tabs  j/k:move  h/l:col/fold  ↵:eval  TAB:next tab  i:inspect  s:save  q:quit"
	elseif active_tab == 2 then
		help = " 1..4:tabs  j/k:move  Space:select  a:all  p:Make Procedure  ↵:send to REPL  q:quit"
	elseif active_tab == 3 then
		help = " 1..4:tabs  j/k:move  ↵:Run  e:Edit args  d:delete  r:reload  q:quit"
	elseif active_tab == 4 then
		help = " 1..4:tabs  j/k:move  a:add  d:remove  u:update  q:quit"
	end
	table.insert(out_buf, DIM .. pad_right(help, term_cols) .. RESET)

	-- Modal popup overlay if active
	if modal_active then
		local box_w = math.min(54, term_cols - 4)
		local box_h = 5
		local top = math.floor((term_rows - box_h) / 2)
		local left = math.floor((term_cols - box_w) / 2)

		local title = " " .. modal_title .. " "
		local fill_w = math.max(0, box_w - 4 - #title)
		local top_border = "┌─" .. title .. string.rep("─", fill_w) .. "┐"
		local bot_border = "└" .. string.rep("─", box_w - 2) .. "┘"
		local prompt_line = "  Name: " .. modal_input .. REV .. " " .. RESET
		local hint_line = "  [Enter] Confirm   [Esc] Cancel"

		table.insert(out_buf, move(top, left) .. BOLD .. FG_CYAN .. top_border .. RESET)
		table.insert(out_buf, move(top + 1, left) .. BOLD .. FG_CYAN .. "│" .. RESET .. pad_right(prompt_line, box_w - 2) .. BOLD .. FG_CYAN .. "│" .. RESET)
		table.insert(out_buf, move(top + 2, left) .. BOLD .. FG_CYAN .. "│" .. RESET .. DIM .. pad_right(hint_line, box_w - 2) .. RESET .. BOLD .. FG_CYAN .. "│" .. RESET)
		table.insert(out_buf, move(top + 3, left) .. BOLD .. FG_CYAN .. bot_border .. RESET)
	end

	io.write(table.concat(out_buf))
	io.flush()
end

-- ---------------------------------------------------------------------------
-- Input handling
-- ---------------------------------------------------------------------------
local function handle_key(key, term_rows, term_cols)
	if not key then
		return
	end

	-- Global Quit
	if key == "\3" then -- Ctrl-C
		return "quit"
	end

	-- Modal input interception
	if modal_active then
		if key == "\27" then -- ESC
			modal_active = false
			dirty = true
			return
		elseif key == "\r" or key == "\n" then -- Enter
			local cb = modal_callback
			local val = modal_input
			modal_active = false
			dirty = true
			if cb then
				cb(val)
			end
			return
		elseif key == "\127" or key == "\8" then -- Backspace
			if #modal_input > 0 then
				modal_input = modal_input:sub(1, #modal_input - 1)
				dirty = true
			end
			return
		elseif #key == 1 and key:byte(1) >= 32 and key:byte(1) <= 126 then
			modal_input = modal_input .. key
			dirty = true
			return
		end
		return
	end

	-- Normal mode quit
	if key == "q" then
		return "quit"
	end

	-- Direct tab jump keys
	if key == "1" then switch_tab(1); return end
	if key == "2" then switch_tab(2); return end
	if key == "3" then switch_tab(3); return end
	if key == "4" then switch_tab(4); return end

	-- Tab cycle keys
	if key == "\t" or key == "]" then
		switch_tab((active_tab % 4) + 1)
		return
	elseif key == "[" then
		switch_tab((active_tab == 1) and 4 or (active_tab - 1))
		return
	end

	-- Movement: j / k / Down / Up
	if key == "j" or key == "\27[B" then
		cursor = cursor + 1
		clamp_cursor()
		return
	elseif key == "k" or key == "\27[A" then
		cursor = cursor - 1
		clamp_cursor()
		return
	end

	-- -----------------------------------------------------------------------
	-- Tab 1: Workspace
	-- -----------------------------------------------------------------------
	if active_tab == 1 then
		if key == "h" or key == "\27[D" then
			local dr = display_rows[cursor]
			if dr then
				if dr.kind == "module" then
					collapsed[dr.name] = true
				elseif dr.kind == "item" then
					if col_cursor > 1 then
						col_cursor = col_cursor - 1
					elseif dr.has_children and not collapsed[dr.path] then
						collapsed[dr.path] = true
					else
						local parent_path = dr.path:match("(.*)/[^/]+$")
						if parent_path and parent_path ~= dr.module_name then
							collapsed[parent_path] = true
							build_display_rows()
							for i, r in ipairs(display_rows) do
								if r.kind == "item" and r.path == parent_path then
									cursor = i
									break
								end
							end
						else
							collapsed[dr.module_name] = true
							build_display_rows()
							for i, r in ipairs(display_rows) do
								if r.kind == "module" and r.name == dr.module_name then
									cursor = i
									break
								end
							end
						end
					end
				end
				build_display_rows()
				clamp_cursor()
			end
		elseif key == "l" or key == "\27[C" then
			local dr = display_rows[cursor]
			if dr then
				if dr.kind == "module" then
					if dr.collapsed then
						collapsed[dr.name] = nil
						build_display_rows()
						clamp_cursor()
					end
				elseif dr.kind == "item" then
					if dr.has_children and collapsed[dr.path] then
						collapsed[dr.path] = nil
						build_display_rows()
						clamp_cursor()
					elseif col_cursor < 3 then
						col_cursor = col_cursor + 1
					end
				end
			end
		elseif key == "\r" or key == "\n" then
			local dr = display_rows[cursor]
			if dr then
				if dr.kind == "module" and dr.collapsed then
					collapsed[dr.name] = nil
					build_display_rows()
					clamp_cursor()
				elseif dr.kind == "item" then
					if dr.expr:match("^[%a_][%w_!%.%[%]%s%\"%:%']*$") then
						local code
						if col_cursor == 1 then
							code = "println(" .. dr.expr .. ")"
						elseif col_cursor == 2 then
							code = "typeof(" .. dr.expr .. ")"
						else
							code = "dump(" .. dr.expr .. ")"
						end
						tmux_send(code)
					end
				end
			end
		elseif key == "i" then
			local dr = display_rows[cursor]
			if dr and dr.kind == "item" then
				if dr.expr:match("^[%a_][%w_!%.%[%]%s%\"%:%']*$") then
					local code = string.format("jEMach.inspect_var(%s, %q)", dr.module_name, dr.expr)
					tmux_send(code)
				end
			end
		elseif key == "c" then
			os.execute(string.format("tmux send-keys -t '%s' C-l", repl_pane))
		elseif key == "s" then
			tmux_send("jEMach.save_clean_session()")
		elseif key == "e" then
			local dr = display_rows[cursor]
			if dr and dr.kind == "item" then
				if dr.expr:match("^[%a_][%w_!%.%[%]%s%\"%:%']*$") then
					if dr.item_kind == "function" then
						os.execute(string.format("tmux send-keys -t '%s' '%s()' Left", repl_pane, dr.expr))
					else
						os.execute(string.format("tmux send-keys -t '%s' '%s '", repl_pane, dr.expr))
					end
				end
			end
		elseif key == "d" then
			local dr = display_rows[cursor]
			if dr then
				if dr.kind == "module" then
					hidden[dr.name] = true
				elseif dr.kind == "item" then
					hidden[dr.path] = true
				end
				build_display_rows()
				if cursor > #display_rows then
					cursor = #display_rows
				end
				clamp_cursor()
			end
		elseif key == "D" then
			hidden = {}
			build_display_rows()
			clamp_cursor()
		elseif key == "r" then
			last_mtime = 0
		end

	-- -----------------------------------------------------------------------
	-- Tab 2: History
	-- -----------------------------------------------------------------------
	elseif active_tab == 2 then
		if key == " " then
			local dr = display_rows[cursor]
			if dr and dr.kind == "history" then
				history_selected[dr.idx] = not history_selected[dr.idx]
				build_display_rows()
			end
		elseif key == "a" then
			local any = false
			local hist = state and state.history or {}
			for i = 1, #hist do
				if history_selected[i] then any = true; break end
			end
			for i = 1, #hist do
				history_selected[i] = not any
			end
			build_display_rows()
		elseif key == "\r" or key == "\n" then
			local dr = display_rows[cursor]
			if dr and dr.kind == "history" then
				tmux_send(dr.cmd)
				set_toast("Sent command to REPL")
			end
		elseif key == "p" then
			local default_name = "proc_" .. tostring(#(state and state.procedures or {}) + 1)
			modal_active = true
			modal_title = "Create Procedure"
			modal_input = default_name
			modal_callback = function(name)
				name = name:gsub("%s+", "")
				if name == "" then return end
				local sel_indices = {}
				local hist = state and state.history or {}
				for i = 1, #hist do
					if history_selected[i] then
						table.insert(sel_indices, tostring(i))
					end
				end
				if #sel_indices == 0 and display_rows[cursor] then
					table.insert(sel_indices, tostring(display_rows[cursor].idx))
				end
				local cmd = string.format("jEMach.make_procedure(:%s; indices=[%s])", name, table.concat(sel_indices, ","))
				tmux_send(cmd)
				set_toast("✓ Generated procedure '" .. name .. "'!")
				switch_tab(3)
			end
		elseif key == "c" then
			os.execute(string.format("tmux send-keys -t '%s' C-l", repl_pane))
		end

	-- -----------------------------------------------------------------------
	-- Tab 3: Procedures
	-- -----------------------------------------------------------------------
	elseif active_tab == 3 then
		local dr = display_rows[cursor]
		if key == "\r" or key == "\n" then
			if dr and dr.kind == "procedure" then
				tmux_send(string.format("jEMach.run_procedure(:%s)", dr.name))
				set_toast("▶ Running procedure " .. dr.name .. "...")
			end
		elseif key == "e" then
			if dr and dr.kind == "procedure" then
				os.execute(string.format("tmux send-keys -t '%s' '%s()' Left", repl_pane, dr.name))
				set_toast("Pasted " .. dr.name .. "() into REPL")
			end
		elseif key == "d" then
			if dr and dr.kind == "procedure" then
				local confirm = prompt_input("Delete procedure '" .. dr.name .. "'? (y/n): ")
				if confirm == "y" or confirm == "yes" or confirm == "Y" then
					tmux_send(string.format("rm(%q); jEMach._load_procedures!(); jEMach.publish_state()", dr.file))
					set_toast("Deleted procedure " .. dr.name)
				end
			end
		elseif key == "r" then
			tmux_send("jEMach._load_procedures!(); jEMach.publish_state()")
			set_toast("Reloaded procedures")
		end

	-- -----------------------------------------------------------------------
	-- Tab 4: Packages
	-- -----------------------------------------------------------------------
	elseif active_tab == 4 then
		local dr = display_rows[cursor]
		if key == "a" then
			local pkg_name = prompt_input("Enter package name to add: ")
			if pkg_name and pkg_name ~= "" then
				tmux_send(string.format("import Pkg; Pkg.add(%q)", pkg_name))
			end
		elseif key == "d" then
			if dr and dr.kind == "package" then
				local confirm = prompt_input("Remove package '" .. dr.name .. "'? (y/n): ")
				if confirm == "y" or confirm == "yes" or confirm == "Y" then
					tmux_send(string.format("import Pkg; Pkg.rm(%q)", dr.name))
				end
			end
		elseif key == "u" then
			if dr and dr.kind == "package" then
				tmux_send(string.format("import Pkg; Pkg.update(%q)", dr.name))
			else
				tmux_send("import Pkg; Pkg.update()")
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------
local function main()
	raw_mode_on()

	-- Ensure terminal is restored on exit
	local function cleanup()
		raw_mode_off()
		io.write(SHOW_CUR .. CLEAR)
		io.flush()
	end

	-- Run cleanup on normal exit or Lua error
	local ok, err = pcall(function()
		local last_render_key = 0
		local term_rows, term_cols = get_terminal_size()
		local resize_counter = 0

		load_state()
		build_display_rows()
		clamp_cursor()
		render(term_rows, term_cols)
		dirty = false

		while true do
			-- Poll terminal size every ~20 cycles (~2s)
			resize_counter = resize_counter + 1
			if resize_counter >= 20 then
				resize_counter = 0
				local new_rows, new_cols = get_terminal_size()
				if new_rows ~= term_rows or new_cols ~= term_cols then
					term_rows, term_cols = new_rows, new_cols
					dirty = true
				end
			end

			if load_state() then
				dirty = true
			end

			if dirty then
				build_display_rows()
				clamp_cursor()
				render(term_rows, term_cols)
				dirty = false
			end

			local key = read_key(REFRESH_MS)
			if key then
				dirty = true
				local result = handle_key(key, term_rows, term_cols)
				if result == "quit" then
					break
				end
			end
		end
	end)

	cleanup()

	if not ok then
		io.stderr:write("jl_tui error: " .. tostring(err) .. "\n")
		os.exit(1)
	end
end

main()
