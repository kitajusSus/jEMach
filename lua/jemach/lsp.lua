local M = {}

M.config = {
	enabled = false,
	auto_start = true,
	detect_imports = true,
	show_import_status = true,
	languageserver_path = nil,
	julia_project = nil, -- nil means auto-detect using on_new_config logic
	default_environment = "v#.#", -- Fallback environment: path or "v#.#" for default
	startup_file = false,
	history_file = false,
}

local lsp_client_id = nil
local detected_imports = {}

local function has_lspconfig()
	local ok, _ = pcall(require, "lspconfig")
	return ok
end

local function detect_languageserver()
	if M.config.languageserver_path then
		return M.config.languageserver_path
	end

	local handle = io.popen('julia -e "using Pkg; println(Pkg.Types.Context().env.project_file)"')
	if handle then
		local project_file = handle:read("*l")
		handle:close()

		if project_file and project_file ~= "" then
			return true
		end
	end

	return false
end

local function get_project_flag(root_dir)
	-- If user specifically forced a project in config, use it
	if M.config.julia_project then
		return M.config.julia_project
	end

	-- Check if we found a real project root
	if root_dir and (vim.fn.filereadable(root_dir .. "/Project.toml") == 1 or vim.fn.filereadable(root_dir .. "/JuliaProject.toml") == 1) then
		return "@."
	end

	-- Fallback to default environment
	local env = M.config.default_environment
	if not env or env == "v#.#" then
		return "@v#.#" -- Standard Julia syntax for default env (e.g. ~/.julia/environments/v1.12)
	end

	return env
end

function M.setup_lsp(opts)
	if not M.config.enabled then
		return
	end

	if not has_lspconfig() then
		vim.notify("nvim-lspconfig not found. LSP integration disabled.", vim.log.levels.WARN)
		return
	end

	local startup_flag = M.config.startup_file and "yes" or "no"
	local history_flag = M.config.history_file and "yes" or "no"

	local lsp_config = {
		cmd = {
			"julia",
			"--project=@.", -- Placeholder, will be updated in on_new_config
			"--startup-file=" .. startup_flag,
			"--history-file=" .. history_flag,
			"-e",
			[[
				using Pkg
				-- We don't need Pkg.instantiate() here necessarily if we trust the env,
				-- but it's safer. However, for default envs it might be slow.
				-- Let's keep it but be aware.
				try
					using LanguageServer
				catch
					@warn "LanguageServer not found in current environment"
					exit(1)
				end

				depot_path = get(ENV, "JULIA_DEPOT_PATH", "")

				# Ensure we resolve the project path correctly from the julia process perspective
				project_path = let
					dirname(something(
						Base.load_path_expand((
							p = get(ENV, "JULIA_PROJECT", nothing);
							p === nothing ? nothing : isempty(p) ? nothing : p
						)),
						Base.current_project(),
						get(Base.load_path(), 1, nothing),
						Base.load_path_expand("@v#.#"),
					))
				end

				@info "Running Julia Language Server" VERSION pwd() project_path depot_path

				server = LanguageServer.LanguageServerInstance(stdin, stdout, project_path, depot_path)
				server.runlinter = true
				run(server)
			]],
		},

		filetypes = { "julia" },

		root_dir = function(fname)
			local util = require("lspconfig.util")
			return util.root_pattern("Project.toml", "JuliaProject.toml", ".git")(fname)
				or util.find_git_ancestor(fname)
				or vim.fn.getcwd()
		end,

		on_new_config = function(new_config, new_root_dir)
			local project_flag = get_project_flag(new_root_dir)

			-- Update the --project arg
			for i, arg in ipairs(new_config.cmd) do
				if arg:match("^%-%-project=") then
					new_config.cmd[i] = "--project=" .. project_flag
					vim.notify("Julia LSP: Using environment " .. project_flag, vim.log.levels.DEBUG)
					break
				end
			end

			-- User might have provided their own on_new_config
			if opts and opts.on_new_config then
				opts.on_new_config(new_config, new_root_dir)
			end
		end,

		on_attach = function(client, bufnr)
			lsp_client_id = client.id

			M.setup_import_detection(client, bufnr)

			if opts and opts.on_attach then
				opts.on_attach(client, bufnr)
			end

			vim.notify("Julia LSP started", vim.log.levels.INFO)
		end,

		settings = {
			julia = {
				format = {
					indent = 4,
				},
				lint = {
					run = true,
					missingrefs = "all",
					iter = true,
					lazy = true,
					modname = true,
				},
				symbolCacheDownload = true,
				runtimeCompletions = true,
			},
		},

		flags = {
			debounce_text_changes = 150,
		},

		capabilities = opts and opts.capabilities or nil,
	}

	-- Deep merge user options, but handle function keys carefully if needed.
	-- tbl_deep_extend overwrites keys.
	-- We handled on_new_config and on_attach manually inside our wrappers to ensure
	-- our logic runs AND user logic runs.
	-- However, if the user provides `on_attach` in `opts`, `tbl_deep_extend` will overwrite
	-- our `on_attach` wrapper if we just do this:
	-- lsp_config = vim.tbl_deep_extend("force", lsp_config, opts)

	-- So we must separate the "safe to merge" options from the functional hooks.

	local user_on_attach = opts and opts.on_attach
	local user_on_new_config = opts and opts.on_new_config

	-- Remove them from opts before merging to avoid overwriting our wrappers
	local safe_opts = vim.deepcopy(opts or {})
	safe_opts.on_attach = nil
	safe_opts.on_new_config = nil

	lsp_config = vim.tbl_deep_extend("force", lsp_config, safe_opts)

	vim.lsp.config("julials", lsp_config)
	vim.lsp.enable("julials")
end

function M.setup_import_detection(client, bufnr)
	if not M.config.detect_imports then
		return
	end

	local function detect_imports_in_buffer()
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local imports = {}

		for _, line in ipairs(lines) do
			local using_match = line:match("^%s*using%s+([%w%.]+)")
			if using_match then
				table.insert(imports, { type = "using", name = using_match })
			end

			local import_match = line:match("^%s*import%s+([%w%.]+)")
			if import_match then
				table.insert(imports, { type = "import", name = import_match })
			end
		end

		detected_imports = imports
		return imports
	end

	detect_imports_in_buffer()

	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function()
			vim.schedule(function()
				detect_imports_in_buffer()
			end)
		end,
	})
end

function M.get_imports()
	return detected_imports
end

function M.is_package_imported(package_name)
	for _, import in ipairs(detected_imports) do
		if import.name == package_name or import.name:match("^" .. package_name .. "%.") then
			return true
		end
	end
	return false
end

function M.get_diagnostics()
	if not lsp_client_id then
		return {}
	end

	local diagnostics = vim.diagnostic.get(0, { severity = { min = vim.diagnostic.severity.HINT } })
	return diagnostics
end

function M.show_import_status()
	if #detected_imports == 0 then
		vim.notify("No imports detected", vim.log.levels.INFO)
		return
	end

	local lines = { "Detected imports:" }
	for _, import in ipairs(detected_imports) do
		table.insert(lines, string.format("  %s %s", import.type, import.name))
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.goto_definition()
	if not lsp_client_id then
		vim.notify("LSP not running", vim.log.levels.WARN)
		return
	end

	vim.lsp.buf.definition()
end

function M.find_references()
	if not lsp_client_id then
		vim.notify("LSP not running", vim.log.levels.WARN)
		return
	end

	vim.lsp.buf.references()
end

function M.hover_doc()
	if not lsp_client_id then
		vim.notify("LSP not running", vim.log.levels.WARN)
		return
	end

	vim.lsp.buf.hover()
end

function M.rename_symbol()
	if not lsp_client_id then
		vim.notify("LSP not running", vim.log.levels.WARN)
		return
	end

	vim.lsp.buf.rename()
end

function M.code_action()
	if not lsp_client_id then
		vim.notify("LSP not running", vim.log.levels.WARN)
		return
	end

	vim.lsp.buf.code_action()
end

function M.format_buffer()
	if not lsp_client_id then
		vim.notify("LSP not running", vim.log.levels.WARN)
		return
	end

	vim.lsp.buf.format({ async = true })
end

function M.get_package_info(package_name)
	local cmd = string.format(
		'julia -e "using Pkg; try pkg = Pkg.TOML.parsefile(joinpath(pkgdir(%s), \\"Project.toml\\")); println(pkg[\\"version\\"]); catch; println(\\"not found\\"); end"',
		vim.inspect(package_name)
	)

	local handle = io.popen(cmd)
	if not handle then
		return nil
	end

	local version = handle:read("*l")
	handle:close()

	if version == "not found" then
		return nil
	end

	return {
		name = package_name,
		version = version,
	}
end

function M.install_package(package_name, callback)
	local cmd = string.format('julia -e "using Pkg; Pkg.add(\\"%s\\")"', package_name)

	vim.notify(string.format("Installing %s...", package_name), vim.log.levels.INFO)

	vim.fn.jobstart(cmd, {
		on_exit = function(_, exit_code)
			if exit_code == 0 then
				vim.notify(string.format("%s installed successfully", package_name), vim.log.levels.INFO)
				if callback then
					callback(true)
				end
			else
				vim.notify(string.format("Failed to install %s", package_name), vim.log.levels.ERROR)
				if callback then
					callback(false)
				end
			end
		end,
	})
end

function M.get_status()
	return {
		enabled = M.config.enabled,
		lsp_running = lsp_client_id ~= nil,
		has_lspconfig = has_lspconfig(),
		languageserver_available = detect_languageserver(),
		imports_detected = #detected_imports,
		imports = detected_imports,
	}
end

function M.enable()
	M.config.enabled = true
	vim.notify("Julia LSP integration enabled. Restart Neovim to apply.", vim.log.levels.INFO)
end

function M.disable()
	M.config.enabled = false
	vim.notify("Julia LSP integration disabled. Restart Neovim to apply.", vim.log.levels.INFO)
end

return M
