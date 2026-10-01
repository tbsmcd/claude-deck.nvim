-- Winbar and highlights.
local state = require("claude-terminals.state")

local M = {}

M.WINBAR = "%!v:lua.require'claude-terminals.ui'.winbar()"
M.STATUSLINE = "%!v:lua.require'claude-terminals.ui'.statusline()"

M.highlights = {
    idle = "ClaudeTerminalsIdle",
    running = "ClaudeTerminalsRunning",
    waiting = "ClaudeTerminalsWaiting",
    attention = "ClaudeTerminalsAttention",
    exited = "ClaudeTerminalsExited",
}

-- Defined with `default = true` so colorschemes and user config can override them.
-- Okabe-Ito based colors that stay distinguishable with color vision deficiencies
-- (they differ in lightness as well as hue); text contrast is at least 4.5:1.
function M.set_highlights()
    local hl = vim.api.nvim_set_hl
    hl(0, "ClaudeTerminalsIdle", { default = true, fg = "#000000", bg = "#999999", bold = true })
    hl(0, "ClaudeTerminalsRunning", { default = true, fg = "#000000", bg = "#56b4e9", bold = true })
    hl(0, "ClaudeTerminalsWaiting", { default = true, fg = "#000000", bg = "#f0e442", bold = true })
    hl(0, "ClaudeTerminalsAttention", { default = true, fg = "#000000", bg = "#d55e00", bold = true })
    hl(0, "ClaudeTerminalsExited", { default = true, fg = "#c8c8c8", bg = "#3b3b3b" })
    hl(0, "ClaudeTerminalsCwd", { default = true, link = "Directory" })
end

local function escape(s)
    return (s:gsub("%%", "%%%%"))
end

local function width(s)
    return vim.fn.strdisplaywidth(s)
end

-- Cut `s` to at most `max` display cells, ending with "…" when cut
local function truncate(s, max)
    if width(s) <= max then
        return s
    end
    if max <= 1 then
        return max == 1 and "…" or ""
    end
    local out, used = {}, 0
    for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
        local w = width(ch)
        if used + w > max - 1 then
            break
        end
        table.insert(out, ch)
        used = used + w
    end
    return table.concat(out) .. "…"
end

-- True when the cwd and session id go to the window's own statusline (second line)
local function two_lines()
    return require("claude-terminals.config").options.statusline and vim.o.laststatus ~= 3
end

-- Line 1: " #2 Running │ task title". Without the statusline, the cwd is right-aligned here,
-- shortened or dropped before the title is cut.
function M.winbar()
    local win = vim.g.statusline_winid
    local term = state.of_buf(vim.api.nvim_win_get_buf(win))
    if not term then
        return ""
    end

    local prefix = string.format(" #%d %s │ ", term.id, state.label(term.state))
    local available = vim.api.nvim_win_get_width(win) - width(prefix) - 1
    local title = state.title(term)
    local cwd = ""

    if not two_lines() then
        local full = vim.fn.fnamemodify(term.cwd, ":~")
        for _, candidate in ipairs({ full, vim.fn.pathshorten(full) }) do
            if width(title) + width(candidate) + 3 <= available then
                cwd = candidate
                break
            end
        end
    end

    title = truncate(title, cwd == "" and available or available - width(cwd) - 3)
    local line = string.format("%%#%s#%s%s %%*", M.highlights[term.state], escape(prefix), escape(title))
    if cwd ~= "" then
        line = line .. "%=%#ClaudeTerminalsCwd# " .. escape(cwd) .. " %*"
    end
    return line
end

-- Line 2 (the window's statusline): " ~/path        session 1234abcd "
function M.statusline()
    local win = vim.g.statusline_winid
    local term = state.of_buf(vim.api.nvim_win_get_buf(win))
    if not term then
        return ""
    end

    local session = term.session_id and ("session " .. term.session_id:sub(1, 8)) or ""
    return string.format(
        "%%#ClaudeTerminalsCwd# %%<%s %%*%%=%s ",
        escape(vim.fn.fnamemodify(term.cwd, ":~")),
        escape(session)
    )
end

local function set_local(win, name, value)
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
end

local function get_local(win, name)
    return vim.api.nvim_get_option_value(name, { scope = "local", win = win })
end

-- Window options set for terminals (window-local only, so other windows keep the user's values)
local STYLE = { number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0" }

function M.style_window(win)
    for name, value in pairs(STYLE) do
        set_local(win, name, value)
    end
    set_local(win, "winbar", M.WINBAR)
    if require("claude-terminals.config").options.statusline then
        set_local(win, "statusline", M.STATUSLINE)
    end
end

-- Drops the terminal header and style copied from a terminal window. Without `force`, only
-- when the window still has the terminal's winbar or statusline.
function M.unstyle_window(win, force)
    local copied = false
    if get_local(win, "winbar") == M.WINBAR then
        set_local(win, "winbar", "")
        copied = true
    end
    if get_local(win, "statusline") == M.STATUSLINE then
        set_local(win, "statusline", "")
        copied = true
    end
    if copied or force then
        for name in pairs(STYLE) do
            set_local(win, name, vim.go[name])
        end
    end
end

-- Splitting a terminal window copies its winbar, statusline and style; drop them when another
-- buffer is shown.
function M.on_buf_win_enter(buf)
    local win = vim.api.nvim_get_current_win()
    if state.of_buf(buf) then
        M.style_window(win)
        return
    end
    M.unstyle_window(win)
end

function M.redraw()
    vim.cmd("redrawstatus!")
end

return M
