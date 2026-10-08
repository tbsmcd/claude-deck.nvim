-- Focus mode: a new tab with tree | editor | terminal in the terminal's cwd.
local config = require("claude-deck.config")
local state = require("claude-deck.state")

local M = {}

-- tabpage -> { origin_tab, origin_win, term_id }
local focus_tabs = {}

local function open_tree(cwd)
    local tree = config.options.focus.tree
    if tree == false then
        return
    end
    if type(tree) == "function" then
        tree(cwd)
        return
    end

    local ok, api = pcall(require, "nvim-tree.api")
    if ok then
        api.tree.open({ path = cwd })
        return
    end
    pcall(vim.cmd, "Lexplore " .. vim.fn.fnameescape(cwd))
end

local function close(tab, focus)
    focus_tabs[tab] = nil
    local ok, err = pcall(vim.cmd, "tabclose")
    if not ok then
        focus_tabs[tab] = focus
        vim.notify(err, vim.log.levels.ERROR)
        return
    end
    if vim.api.nvim_tabpage_is_valid(focus.origin_tab) then
        vim.api.nvim_set_current_tabpage(focus.origin_tab)
    end
    if vim.api.nvim_win_is_valid(focus.origin_win) then
        vim.api.nvim_set_current_win(focus.origin_win)
    end
end

-- Id of the terminal that focus mode was opened for in `tab` (0: current), or nil
function M.term_id(tab)
    if not tab or tab == 0 then
        tab = vim.api.nvim_get_current_tabpage()
    end
    local focus = focus_tabs[tab]
    return focus and focus.term_id
end

function M.toggle()
    local tab = vim.api.nvim_get_current_tabpage()
    if focus_tabs[tab] then
        close(tab, focus_tabs[tab])
        return
    end

    local term = state.current()
    if not term then
        vim.notify("claude-deck: run this inside a terminal", vim.log.levels.WARN)
        return
    end

    local origin_win = vim.api.nvim_get_current_win()
    vim.cmd("tab split")
    focus_tabs[vim.api.nvim_get_current_tabpage()] = { origin_tab = tab, origin_win = origin_win, term_id = term.id }
    vim.cmd("tcd " .. vim.fn.fnameescape(term.cwd))

    local term_win = vim.api.nvim_get_current_win()
    vim.cmd("leftabove vnew")
    local edit_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(term_win, math.floor(vim.o.columns * config.options.width_ratio))

    open_tree(term.cwd)
    vim.api.nvim_set_current_win(edit_win)
    require("claude-deck.terminal").fit_pty(term_win)
end

return M
