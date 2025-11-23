local M = {}

M.config = {
    picker = "auto", -- auto, telescope, snacks, select
}

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

function M.detect_picker()
    if M.config.picker ~= "auto" then
        return M.config.picker
    end

    if pcall(require, "snacks") then
        return "snacks"
    elseif pcall(require, "telescope") then
        return "telescope"
    else
        return "select"
    end
end

function M.show_history(history, on_select)
    local picker_type = M.detect_picker()

    if picker_type == "snacks" then
        local snacks = require("snacks")
        local items = {}
        for i, cmd in ipairs(history) do
            table.insert(items, { text = cmd, idx = i })
        end

        snacks.picker.pick({
            title = "Julia History",
            items = items,
            format = "text",
            actions = {
                confirm = function(picker, item)
                    picker:close()
                    if item then
                        on_select(item.text)
                    end
                end
            }
        })

    elseif picker_type == "telescope" then
        local pickers = require("telescope.pickers")
        local finders = require("telescope.finders")
        local conf = require("telescope.config").values
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")

        pickers.new({}, {
            prompt_title = "📜 Julia REPL History",
            finder = finders.new_table({
                results = history,
                entry_maker = function(entry)
                    return {
                        value = entry,
                        display = entry,
                        ordinal = entry,
                    }
                end,
            }),
            sorter = conf.generic_sorter({}),
            attach_mappings = function(prompt_bufnr, map)
                actions.select_default:replace(function()
                    actions.close(prompt_bufnr)
                    local selection = action_state.get_selected_entry()
                    if selection then
                        on_select(selection.value)
                    end
                end)
                return true
            end,
        }):find()

    else
        vim.ui.select(history, {
            prompt = "📜 Julia REPL History",
        }, function(choice)
            if choice then
                on_select(choice)
            end
        end)
    end
end

return M
