-- Pickers backed by fzf-lua (with split keys) or vim.ui.select.
local config = require("claude-deck.config")

local M = {}

local HEADER = "enter: open / ctrl-v: split right / ctrl-s: split below"

local function use_fzf()
    local picker = config.options.picker
    if picker == "select" then
        return false
    end
    local ok = pcall(require, "fzf-lua")
    if not ok and picker == "fzf-lua" then
        vim.notify("claude-deck: fzf-lua is not installed", vim.log.levels.WARN)
    end
    return ok
end

-- items: { { value = any, text = string } }
-- on_select(value, where) where `where` is nil, "right" or "below"
-- opts.extra_actions: { [fzf key] = function(value) } (fzf-lua only; the picker closes first;
-- value is nil when no item is selected)
-- opts.header: text added to the key help (fzf-lua only)
function M.pick(items, opts, on_select)
    if not use_fzf() then
        vim.ui.select(items, {
            prompt = opts.prompt,
            format_item = function(item)
                return item.text
            end,
        }, function(item)
            if item then
                on_select(item.value, opts.where)
            end
        end)
        return
    end

    local lines = {}
    for i, item in ipairs(items) do
        table.insert(lines, i .. "\t" .. item.text)
    end

    -- The value of the selected line, or nil
    local function value_of(selected)
        local index = selected[1] and tonumber(selected[1]:match("^(%d+)\t"))
        return index and items[index] and items[index].value
    end

    local function action(where)
        return function(selected)
            local value = value_of(selected)
            if value ~= nil then
                on_select(value, where or opts.where)
            end
        end
    end

    local actions = { ["default"] = action(nil), ["ctrl-v"] = action("right"), ["ctrl-s"] = action("below") }
    for key, fn in pairs(opts.extra_actions or {}) do
        actions[key] = function(selected)
            fn(value_of(selected))
        end
    end

    require("fzf-lua").fzf_exec(lines, {
        prompt = opts.prompt .. " ",
        fzf_opts = {
            ["--delimiter"] = "\t",
            ["--with-nth"] = "2..",
            ["--header"] = opts.header and (HEADER .. "\n" .. opts.header) or HEADER,
        },
        actions = actions,
    })
end

return M
