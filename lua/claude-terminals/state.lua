-- Registry of terminals and their status.
local config = require("claude-terminals.config")

local M = {}

-- id -> { id, buf, job, cwd, title, state, session_id, transcript_path }
M.terminals = {}
M.next_id = 1
-- Updated by FocusGained / FocusLost
M.nvim_focused = true

function M.of_buf(buf)
    local id = vim.b[buf].claude_terminal_id
    return id and M.terminals[id] or nil
end

function M.current()
    return M.of_buf(vim.api.nvim_get_current_buf())
end

function M.get(id)
    return M.terminals[tonumber(id)]
end

function M.sorted()
    local list = vim.tbl_values(M.terminals)
    table.sort(list, function(a, b)
        return a.id < b.id
    end)
    return list
end

-- Windows in the current tab that show a terminal
function M.wins_in_tab()
    local wins = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if M.of_buf(vim.api.nvim_win_get_buf(win)) then
            table.insert(wins, win)
        end
    end
    return wins
end

function M.label(state)
    return config.options.labels[state] or state
end

function M.title(term)
    return term.title ~= "" and term.title or config.options.labels.untitled
end

function M.make_title(text)
    local s = vim.trim(text:gsub("%s+", " "))
    local width = config.options.title_width
    if vim.fn.strchars(s) > width then
        s = vim.fn.strcharpart(s, 0, width) .. "…"
    end
    return s
end

function M.add(term)
    M.terminals[term.id] = term
end

function M.remove(id)
    M.terminals[id] = nil
end

function M.set_state(term, state, message)
    term.state = state
    require("claude-terminals.ui").redraw()
    require("claude-terminals.notify").on_state(term, state, message)
end

return M
