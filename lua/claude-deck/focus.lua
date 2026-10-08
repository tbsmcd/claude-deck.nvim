-- Focus mode: a new tab with tree | editor | terminal in the terminal's cwd.
local config = require("claude-deck.config")
local state = require("claude-deck.state")

local M = {}

-- tabpage -> { origin_tab, origin_win, term_id, edit_win }
local focus_tabs = {}

-- Filetypes of file tree windows, which are never used as the editor window
local TREE_FILETYPES = { NvimTree = true, netrw = true, ["neo-tree"] = true }

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

-- Opens focus mode for `term` from the current window, which shows the terminal. origin:
-- optional { tab, win } to return to on closing (default: the current tab and window).
function M.open(term, origin)
    local tab = origin and origin.tab or vim.api.nvim_get_current_tabpage()
    local origin_win = origin and origin.win or vim.api.nvim_get_current_win()
    vim.cmd("tab split")
    local focus = { origin_tab = tab, origin_win = origin_win, term_id = term.id }
    focus_tabs[vim.api.nvim_get_current_tabpage()] = focus
    vim.cmd("tcd " .. vim.fn.fnameescape(term.cwd))

    local term_win = vim.api.nvim_get_current_win()
    vim.cmd("leftabove vnew")
    local edit_win = vim.api.nvim_get_current_win()
    focus.edit_win = edit_win
    vim.api.nvim_win_set_width(term_win, math.floor(vim.o.columns * config.options.width_ratio))

    open_tree(term.cwd)
    vim.api.nvim_set_current_win(edit_win)
    require("claude-deck.terminal").fit_pty(term_win)
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
    M.open(term)
end

-- The focus mode tab of `term` (the current tab first), or nil
local function focus_tab_of(term)
    local current = vim.api.nvim_get_current_tabpage()
    local found
    for tab, focus in pairs(focus_tabs) do
        if focus.term_id == term.id and vim.api.nvim_tabpage_is_valid(tab) then
            if tab == current then
                return tab
            end
            if not found or tab < found then
                found = tab
            end
        end
    end
    return found
end

-- A window in `tab` showing `buf` (the current window first), or nil
local function win_with_buf(tab, buf)
    local current = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_tabpage(current) == tab and vim.api.nvim_win_get_buf(current) == buf then
        return current
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_win_get_buf(win) == buf then
            return win
        end
    end
end

local function is_float(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
end

local function is_tree_or_terminal(win)
    local buf = vim.api.nvim_win_get_buf(win)
    return vim.bo[buf].buftype == "terminal" or TREE_FILETYPES[vim.bo[buf].filetype] ~= nil
end

-- The editor window of focus mode in the current tab: the one made on opening, another window
-- with a normal buffer, or a new one left of the terminal
local function editor_win(focus, term)
    local tab = vim.api.nvim_get_current_tabpage()
    local win = focus.edit_win
    if
        win
        and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_tabpage(win) == tab
        and not is_float(win)
        and not is_tree_or_terminal(win)
    then
        return win
    end

    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if M.is_editor_window(w) then
            focus.edit_win = w
            return w
        end
    end

    local term_win = win_with_buf(tab, term.buf)
    if term_win then
        vim.api.nvim_set_current_win(term_win)
        vim.cmd("leftabove vnew")
    else
        vim.cmd("vnew")
    end
    focus.edit_win = vim.api.nvim_get_current_win()
    if term_win then
        vim.api.nvim_win_set_width(term_win, math.floor(vim.o.columns * config.options.width_ratio))
        require("claude-deck.terminal").fit_pty(term_win)
    end
    return focus.edit_win
end

local function same_file(a, b)
    if a == "" then
        return false
    end
    return (vim.uv.fs_realpath(a) or a) == (vim.uv.fs_realpath(b) or b)
end

-- True when `win` can show a file for focus mode: not floating, not a tree or terminal, and
-- holding a normal buffer or a claude-deck diff buffer
function M.is_editor_window(win)
    if is_float(win) or is_tree_or_terminal(win) then
        return false
    end
    local buf = vim.api.nvim_win_get_buf(win)
    return vim.bo[buf].buftype == "" or require("claude-deck.diff").info(buf) ~= nil
end

-- The editor window of the focus mode of `term`, opening focus mode when there is none (showing
-- the terminal first if it is hidden). Makes that tab current and returns the window.
function M.editor_window(term)
    local tab = focus_tab_of(term)
    if tab then
        vim.api.nvim_set_current_tabpage(tab)
    else
        local origin = { tab = vim.api.nvim_get_current_tabpage(), win = vim.api.nvim_get_current_win() }
        local term_win = win_with_buf(origin.tab, term.buf)
        if not term_win then
            for _, t in ipairs(vim.api.nvim_list_tabpages()) do
                term_win = win_with_buf(t, term.buf)
                if term_win then
                    origin = { tab = t, win = term_win }
                    break
                end
            end
        end
        if term_win then
            vim.api.nvim_set_current_win(term_win)
        else
            require("claude-deck.terminal").show(term)
        end
        M.open(term, origin)
        tab = vim.api.nvim_get_current_tabpage()
    end
    return editor_win(focus_tabs[tab], term)
end

-- Opens `path` (absolute, an existing file) in the editor window of the focus mode of `term`, opening
-- focus mode when there is none, and moves the cursor to `line` (optional; past the end: the
-- last line). The editor window becomes the current window in Normal mode. Returns a one-line
-- report for `ct open` ("ct: …" on failure).
function M.open_file(term, path, line)
    local win = M.editor_window(term)
    -- Keep a diff buffer shown there: open the file beside it, as <CR> in the diff does
    if require("claude-deck.diff").info(vim.api.nvim_win_get_buf(win)) then
        win = require("claude-deck.diff").file_window(win)
    end
    vim.api.nvim_set_current_win(win)
    -- Not when the file is already shown: `:edit` would fail on unsaved changes
    if not same_file(vim.api.nvim_buf_get_name(0), path) then
        -- With a swap file, open read-only instead of asking: nobody can answer the prompt
        -- while `ct open` waits for --remote-expr
        local swap = vim.api.nvim_create_autocmd("SwapExists", {
            callback = function()
                vim.v.swapchoice = "o"
            end,
        })
        local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
        vim.api.nvim_del_autocmd(swap)
        if not ok then
            vim.cmd("stopinsert")
            return "ct: " .. (tostring(err):match("E%d+:.*") or tostring(err))
        end
    end

    local shown = require("claude-deck.location").relative_path(path, term.cwd)
    if line then
        line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(0)))
        vim.api.nvim_win_set_cursor(win, { line, 0 })
        vim.cmd("normal! zz")
        shown = shown .. ":" .. line
    end
    -- terminal.show() and leaving the terminal may have asked for Insert / Terminal mode
    vim.cmd("stopinsert")
    return "Opened " .. shown .. " in the editor"
end

return M
