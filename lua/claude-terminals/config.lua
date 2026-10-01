local M = {}

-- Root directory of the plugin (…/claude-terminals.nvim)
M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
M.bin_dir = M.root .. "/bin"

M.defaults = {
    -- Command used to start Claude Code. Extra arguments are appended by the plugin.
    cmd = { "claude" },
    -- Max characters of the task title (taken from the first prompt).
    title_width = 24,
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
