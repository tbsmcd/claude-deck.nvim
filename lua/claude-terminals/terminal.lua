-- Starting terminals and placing their windows.
local config = require("claude-terminals.config")
local state = require("claude-terminals.state")
local ui = require("claude-terminals.ui")

local M = {}

local function system_prompt(id)
    return table.concat({
        string.format("You are running inside claude-terminals terminal #%d in Neovim.", id),
        "Other terminals in the same Neovim run their own Claude Code sessions. You can inspect them with:",
        "- `ct list`: list terminals (id, status, task title, cwd, session_id, transcript path)",
        "- `ct read <id> [count]`: recent conversation of a terminal (default 20 messages)",
        "Use these when the user refers to another terminal or task, or when you need to check consistency with parallel work.",
    }, "\n")
end

local function set_keymaps(buf)
    local keymaps = config.options.keymaps
    if keymaps.normal_mode then
        vim.keymap.set("t", keymaps.normal_mode, [[<C-\><C-n>]], { buffer = buf, desc = "Leave terminal mode" })
    end
    if keymaps.window then
        vim.keymap.set("t", keymaps.window, [[<C-\><C-n><C-w>]], { buffer = buf, desc = "Window command" })
    end
    if keymaps.send_esc then
        vim.keymap.set("t", keymaps.send_esc, "<Esc>", { buffer = buf, desc = "Send <Esc> to Claude" })
    end
end

-- Starts Claude Code in `win`. `extra_args` are appended to the command.
function M.start(win, cwd, extra_args)
    local opts = config.options
    local id = state.next_id
    state.next_id = state.next_id + 1

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].bufhidden = "hide"
    vim.b[buf].claude_terminal_id = id
    set_keymaps(buf)

    local term = { id = id, buf = buf, cwd = cwd, title = "", state = "idle" }
    state.add(term)

    local cmd = vim.deepcopy(opts.cmd)
    if opts.claude_settings then
        vim.list_extend(cmd, { "--settings", require("claude-terminals.hooks").settings_json() })
    end
    if opts.cli.enabled and opts.cli.system_prompt then
        vim.list_extend(cmd, { "--append-system-prompt", system_prompt(id) })
    end
    vim.list_extend(cmd, extra_args or {})

    local env = { CLAUDE_TERMINALS_ID = tostring(id) }
    if opts.cli.enabled then
        env.PATH = config.bin_dir .. ":" .. vim.env.PATH
    end

    term.job = vim.fn.jobstart(cmd, {
        term = true,
        cwd = cwd,
        env = env,
        on_exit = function()
            vim.schedule(function()
                if state.get(id) then
                    term.state = "exited"
                    ui.redraw()
                end
            end)
        end,
    })

    -- jobstart() names the buffer "term://…"; use a readable name instead
    state.set_title(term, "")
    ui.style_window(win)
    vim.cmd("startinsert")
    return term
end

-- Runs `fn` with the size of every window in the tab except the current one fixed, so that
-- splitting with 'equalalways' does not resize the other windows. (Toggling 'equalalways'
-- itself does not work: turning it back on equalizes all windows.)
local function with_other_windows_fixed(fn)
    local current = vim.api.nvim_get_current_win()
    local saved = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win ~= current then
            saved[win] = { vim.wo[win].winfixwidth, vim.wo[win].winfixheight }
            vim.wo[win].winfixwidth = true
            vim.wo[win].winfixheight = true
        end
    end

    local ok, err = pcall(fn)

    for win, fixed in pairs(saved) do
        if vim.api.nvim_win_is_valid(win) then
            vim.wo[win].winfixwidth = fixed[1]
            vim.wo[win].winfixheight = fixed[2]
        end
    end
    if not ok then
        error(err)
    end
end

-- where: "right" / "below" split the current window, "far_right" opens at the far right.
-- Other windows keep their size.
function M.open_window(where)
    with_other_windows_fixed(function()
        if where == "right" then
            vim.cmd("rightbelow vsplit")
        elseif where == "below" then
            vim.cmd("rightbelow split")
        else
            vim.cmd("botright vsplit")
            vim.api.nvim_win_set_width(0, math.floor(vim.o.columns * config.options.width_ratio))
        end
    end)
    return vim.api.nvim_get_current_win()
end

local function is_empty_buffer(buf)
    return vim.api.nvim_buf_get_name(buf) == ""
        and vim.bo[buf].buftype == ""
        and not vim.bo[buf].modified
        and vim.api.nvim_buf_line_count(buf) == 1
        and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

-- Opens a new terminal in `cwd`. Without `where`: to the right when inside a terminal,
-- in place when the current buffer is empty (e.g. right after startup), otherwise at the far right.
function M.open_new(cwd, where, extra_args)
    if where or state.current() then
        return M.start(M.open_window(where or "right"), cwd, extra_args)
    end

    local buf = vim.api.nvim_get_current_buf()
    if is_empty_buffer(buf) then
        local term = M.start(vim.api.nvim_get_current_win(), cwd, extra_args)
        if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
            vim.api.nvim_buf_delete(buf, {})
        end
        return term
    end

    return M.start(M.open_window("far_right"), cwd, extra_args)
end

-- Shows a terminal (including hidden ones). Focuses it if already visible in this tab.
function M.show(term, where)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == term.buf then
            vim.api.nvim_set_current_win(win)
            vim.cmd("startinsert")
            return
        end
    end

    local win = M.open_window(where or (state.current() and "right" or "far_right"))
    vim.api.nvim_win_set_buf(win, term.buf)
    ui.style_window(win)
    vim.cmd("startinsert")
end

return M
