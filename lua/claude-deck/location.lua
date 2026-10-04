-- Inserting "path:line" / "path:start-end" of the current buffer into a terminal's prompt.
local state = require("claude-deck.state")

local M = {}

local function warn(message)
    vim.notify("claude-deck: " .. message, vim.log.levels.WARN)
end

-- Terminals shown in the current tab (each once)
local function terms_in_tab()
    local terms, seen = {}, {}
    for _, win in ipairs(state.wins_in_tab()) do
        local term = state.of_buf(vim.api.nvim_win_get_buf(win))
        if not seen[term.id] then
            seen[term.id] = true
            table.insert(terms, term)
        end
    end
    return terms
end

-- The terminal to send to: the one focus mode was opened for, or the only terminal shown in
-- this tab. Returns nil and a reason otherwise.
local function target()
    local id = require("claude-deck.focus").term_id()
    if id then
        local term = state.get(id)
        if not term then
            return nil, string.format("terminal #%d of this focus mode is gone", id)
        end
        return term
    end

    local terms = terms_in_tab()
    if #terms == 0 then
        return nil, "no terminal is shown in this tab"
    elseif #terms > 1 then
        return nil, "more than one terminal is shown in this tab (use focus mode to pick one)"
    end
    return terms[1]
end

-- Absolute directory path with a trailing slash
local function as_dir(path)
    path = vim.fn.fnamemodify(path, ":p")
    return path:sub(-1) == "/" and path or path .. "/"
end

-- `file` relative to `cwd` when it is under `cwd` (also comparing resolved symlinks), otherwise
-- the absolute path with ~ for the home directory.
function M.relative_path(file, cwd)
    local files = { file, vim.uv.fs_realpath(file) }
    local dirs = { as_dir(cwd) }
    local real_cwd = vim.uv.fs_realpath(cwd)
    if real_cwd then
        table.insert(dirs, as_dir(real_cwd))
    end
    for _, f in ipairs(files) do
        for _, dir in ipairs(dirs) do
            if vim.startswith(f, dir) and #f > #dir then
                return f:sub(#dir + 1)
            end
        end
    end
    return vim.fn.fnamemodify(file, ":~")
end

-- First and last line: `range` ({ line1, line2 } from a command range), the Visual selection
-- (leaving Visual mode), or the cursor line.
local function lines(range)
    if range then
        return range[1], range[2]
    end
    local mode = vim.api.nvim_get_mode().mode
    if mode == "v" or mode == "V" or mode == "\22" then
        local first, last = vim.fn.line("v"), vim.fn.line(".")
        vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
        return first, last
    end
    local line = vim.fn.line(".")
    return line, line
end

-- Inserts the location into the target terminal's prompt (without sending it) and moves to
-- that terminal. range: optional { line1, line2 }.
function M.send(range)
    -- First, so that Visual mode is left on every path (also when only a warning is given)
    local first, last = lines(range)
    if first > last then
        first, last = last, first
    end

    local buf = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype ~= "" or name == "" then
        warn("the current buffer is not a file")
        return
    end

    local term, reason = target()
    if not term then
        warn(reason)
        return
    end
    if
        term.state == "exited"
        or not term.job
        or not vim.api.nvim_buf_is_valid(term.buf)
        or vim.fn.jobwait({ term.job }, 0)[1] ~= -1
    then
        warn(string.format("terminal #%d has exited", term.id))
        return
    end

    local term_win
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == term.buf then
            term_win = win
            break
        end
    end
    if not term_win then
        warn(string.format("terminal #%d is not shown in this tab", term.id))
        return
    end

    local text = M.relative_path(vim.fn.fnamemodify(name, ":p"), term.cwd) .. ":" .. first
    if last ~= first then
        text = text .. "-" .. last
    end

    -- As a bracketed paste, so that a path starting with "/" in an empty prompt is not taken
    -- as a slash command typed key by key
    vim.api.nvim_chan_send(vim.bo[term.buf].channel, "\27[200~" .. text .. " \27[201~")
    vim.api.nvim_set_current_win(term_win)
end

return M
