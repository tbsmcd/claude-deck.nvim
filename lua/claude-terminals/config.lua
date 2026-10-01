local M = {}

-- Root directory of the plugin (…/claude-terminals.nvim)
M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
M.bin_dir = M.root .. "/bin"

M.defaults = {
    -- Command used to start Claude Code. Extra arguments are appended by the plugin.
    cmd = { "claude" },
    -- Pass the hooks (status, notifications, task titles, session ids) and the `ct` permissions
    -- with `claude --settings`. Set to false to start claude without --settings; then register
    -- the hooks in your own Claude Code settings (`:ClaudeTerminals settings` shows them) or
    -- go without status tracking.
    claude_settings = true,
    -- Max characters kept for the task title (taken from the first prompt). The winbar
    -- cuts it further to fit the window.
    title_width = 60,
    -- Two-line header: status and task title in the winbar, cwd and session id in the
    -- window's statusline. When false (or with 'laststatus' = 3), the cwd goes into the winbar.
    statusline = true,
    -- Width of a terminal opened at the far right, relative to the editor width.
    width_ratio = 0.4,
    -- Directories whose direct children are offered by `pick_dir()`.
    dir_roots = {},
    -- Also offer directories from `zoxide query --list` in `pick_dir()`.
    zoxide = true,
    -- Text shown in the winbar, pickers and notifications.
    labels = {
        idle = "New",
        running = "Running",
        waiting = "Waiting",
        attention = "Needs you",
        exited = "Exited",
        untitled = "(new task)",
    },
    notify = {
        enabled = true,
        -- States that trigger a desktop notification.
        states = { "waiting", "attention" },
        -- Skip the notification when you are looking at that terminal.
        skip_when_watching = true,
        -- function({ title, subtitle, body, state, terminal }) to replace the built-in
        -- notifier (osascript on macOS, notify-send elsewhere).
        notifier = nil,
    },
    -- Terminal-mode keys mapped only in claude terminals. Set an entry to false to disable it.
    keymaps = {
        -- Leave terminal mode. Claude Code does not use <C-q>; <C-\><C-n> always works too.
        normal_mode = "<C-q>",
        -- Prefix for window commands straight from terminal mode, e.g. "<C-w>" makes
        -- <C-w>h / <C-w>l / <C-w>> work without leaving terminal mode first.
        -- Claude Code's <C-w> (delete word) is then unavailable.
        window = false,
        -- Send <Esc> to Claude (interrupt, close dialogs; twice = <Esc><Esc> for the rewind menu).
        -- For users who map <Esc> themselves to leave terminal mode.
        send_esc = "<C-]>",
    },
    -- Enter terminal mode when you move into a claude terminal window.
    auto_insert = true,
    -- Keep Neovim (and Claude) running when `:q` closes the last window and it shows a running
    -- terminal: an empty window is opened first, so `:q` only hides the terminal.
    -- `:qa` still quits Neovim.
    keep_alive_on_quit = true,
    -- "auto" (fzf-lua if installed), "fzf-lua" or "select" (vim.ui.select).
    picker = "auto",
    focus = {
        -- How to open the file tree in focus mode: "auto" (nvim-tree, then netrw),
        -- false to skip, or function(cwd).
        tree = "auto",
    },
    cli = {
        -- Put the `ct` command on PATH inside terminals and let Claude run `ct list` / `ct read`
        -- without a permission prompt.
        enabled = true,
        -- Tell Claude about the `ct` command via --append-system-prompt.
        system_prompt = true,
    },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
