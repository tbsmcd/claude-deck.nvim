local M = {}

-- Root directory of the plugin (…/claude-deck.nvim)
M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
M.bin_dir = M.root .. "/bin"

M.defaults = {
    -- Command used to start Claude Code. Extra arguments are appended by the plugin.
    cmd = { "claude" },
    -- Pass the hooks (status, notifications, task titles, session ids) and the `ct` permissions
    -- with `claude --settings`. Set to false to start claude without --settings; then register
    -- the hooks in your own Claude Code settings (`:ClaudeDeck settings` shows them) or
    -- go without status tracking.
    claude_settings = true,
    -- Max characters kept for a task title taken from the first prompt or given to rename().
    -- The winbar cuts it further to fit the window.
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
        -- Built-in notifier:
        -- "auto": terminal-notifier if installed, otherwise osascript on macOS; notify-send elsewhere.
        -- "terminal-notifier": macOS; clicking the notification brings back the terminal app.
        -- "osc": the terminal emulator's own notification (OSC 9, e.g. iTerm2).
        -- "osascript": macOS; clicking the notification does not bring back the terminal app.
        -- "notify-send": Linux.
        method = "auto",
        -- function({ title, subtitle, body, state, terminal }) to replace the built-in
        -- notifier. Takes precedence over `method`.
        notifier = nil,
    },
    -- Keys mapped by the plugin. Set an entry to false to disable it.
    keymaps = {
        -- The entries below are terminal-mode keys mapped only in claude-deck terminals.
        -- Leave terminal mode. Claude Code does not use <C-q>; <C-\><C-n> always works too.
        normal_mode = "<C-q>",
        -- Prefix for window commands straight from terminal mode, e.g. "<C-w>" makes
        -- <C-w>h / <C-w>l / <C-w>> work without leaving terminal mode first.
        -- Claude Code's <C-w> (delete word) is then unavailable.
        window = false,
        -- Send <Esc> to Claude (interrupt, close dialogs; twice = <Esc><Esc> for the rewind menu).
        -- For users who map <Esc> themselves to leave terminal mode.
        send_esc = "<C-]>",
        -- Global normal / Visual mode key for send_location() (insert "path:line" of the current
        -- file into the Claude prompt). Off by default, e.g. "<leader>cp".
        send_location = false,
    },
    -- How Claude Code draws its screen, set with CLAUDE_CODE_NO_FLICKER.
    -- "classic": normal screen; the whole conversation stays in the terminal buffer's
    --   scrollback, so Neovim's j/k, / and y work on it in normal mode.
    -- "fullscreen": alternate screen; Claude Code keeps the history itself and the buffer
    --   only holds the current screen (scroll with PageUp/PageDown or Ctrl+O).
    -- false: do not set it; CLAUDE_CODE_NO_FLICKER from Neovim's environment is used if set,
    --   otherwise Claude Code's `tui` setting decides.
    renderer = "classic",
    -- 'scrollback' of claude-deck terminal buffers (lines kept by Neovim; Neovim's default
    -- is 10000, the maximum 100000). false leaves it unchanged.
    scrollback = 100000,
    -- Enter terminal mode when you move into a claude-deck terminal window.
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
        -- Also tell Claude (in that system prompt) to name its terminal with `ct title`.
        -- `ct title` works either way.
        auto_title = true,
    },
}

M.options = vim.deepcopy(M.defaults)

-- Options that were invalid in the last setup(), as given (for :checkhealth).
M.invalid = {}

local function warn_invalid(name, value, hint, fallback)
    M.invalid[name] = value
    vim.notify(
        string.format(
            "claude-deck: invalid %s %s (%s); using %s",
            name,
            vim.inspect(value),
            hint,
            vim.inspect(fallback or false)
        ),
        vim.log.levels.WARN
    )
end

-- Command run by each notify.method (false: needs no command).
local notify_commands = {
    auto = false,
    ["terminal-notifier"] = "terminal-notifier",
    osc = false,
    osascript = "osascript",
    ["notify-send"] = "notify-send",
}

-- Replaces invalid values with false (notify.method: "auto"), warning once per setup().
local function validate(options)
    local renderer = options.renderer
    if renderer ~= false and renderer ~= "classic" and renderer ~= "fullscreen" then
        warn_invalid("renderer", renderer, 'use "classic", "fullscreen" or false')
        options.renderer = false
    end
    local scrollback = options.scrollback
    if
        scrollback ~= false
        and not (type(scrollback) == "number" and scrollback % 1 == 0 and scrollback >= 1 and scrollback <= 100000)
    then
        warn_invalid("scrollback", scrollback, "use an integer from 1 to 100000 or false")
        options.scrollback = false
    end
    local send_location = options.keymaps.send_location
    if send_location ~= false and type(send_location) ~= "string" then
        warn_invalid("keymaps.send_location", send_location, "use a key such as \"<leader>cp\" or false")
        options.keymaps.send_location = false
    end
    -- A notifier function replaces the built-in methods, so the method is not used
    if type(options.notify.notifier) == "function" then
        return
    end
    local method = options.notify.method
    local command = notify_commands[method]
    if command == nil then
        warn_invalid(
            "notify.method",
            method,
            'use "auto", "terminal-notifier", "osc", "osascript" or "notify-send"',
            "auto"
        )
        options.notify.method = "auto"
    elseif command and vim.fn.executable(command) == 0 then
        warn_invalid("notify.method", method, "`" .. command .. "` was not found", "auto")
        options.notify.method = "auto"
    end
end

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    M.invalid = {}
    validate(M.options)
end

return M
