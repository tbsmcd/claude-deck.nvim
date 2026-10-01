-- Winbar and highlights.
local state = require("claude-terminals.state")

local M = {}

M.WINBAR = "%!v:lua.require'claude-terminals.ui'.winbar()"

M.highlights = {
    idle = "ClaudeTerminalsIdle",
    running = "ClaudeTerminalsRunning",
    waiting = "ClaudeTerminalsWaiting",
    attention = "ClaudeTerminalsAttention",
    exited = "ClaudeTerminalsExited",
}

-- Defined with `default = true` so colorschemes and user config can override them.
function M.set_highlights()
    local hl = vim.api.nvim_set_hl
    hl(0, "ClaudeTerminalsIdle", { default = true, fg = "#192330", bg = "#8b98a8", bold = true })
    hl(0, "ClaudeTerminalsRunning", { default = true, fg = "#192330", bg = "#719cd6", bold = true })
    hl(0, "ClaudeTerminalsWaiting", { default = true, fg = "#192330", bg = "#81b29a", bold = true })
    hl(0, "ClaudeTerminalsAttention", { default = true, fg = "#192330", bg = "#f4a261", bold = true })
    hl(0, "ClaudeTerminalsExited", { default = true, fg = "#aeafb0", bg = "#39506d" })
    hl(0, "ClaudeTerminalsCwd", { default = true, link = "Directory" })
end

local function escape(s)
    return (s:gsub("%%", "%%%%"))
end

-- " #2 Running │ task title  ~/path "
function M.winbar()
    local win = vim.g.statusline_winid
    local term = state.of_buf(vim.api.nvim_win_get_buf(win))
    if not term then
        return ""
    end

    return string.format(
        "%%#%s# #%d %s │ %s %%#ClaudeTerminalsCwd# %%<%s %%*",
        M.highlights[term.state],
        term.id,
        escape(state.label(term.state)),
        escape(state.title(term)),
        escape(vim.fn.fnamemodify(term.cwd, ":~"))
    )
end

function M.style_window(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.api.nvim_set_option_value("winbar", M.WINBAR, { scope = "local", win = win })
end

-- Splitting a terminal window copies its winbar; drop it when another buffer is shown.
function M.on_buf_win_enter(buf)
    local win = vim.api.nvim_get_current_win()
    if state.of_buf(buf) then
        M.style_window(win)
    elseif vim.api.nvim_get_option_value("winbar", { scope = "local", win = win }) == M.WINBAR then
        vim.api.nvim_set_option_value("winbar", "", { scope = "local", win = win })
    end
end

function M.redraw()
    vim.cmd("redrawstatus!")
end

return M
