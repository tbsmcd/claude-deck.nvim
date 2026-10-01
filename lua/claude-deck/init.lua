-- claude-deck.nvim: run multiple Claude Code sessions in Neovim terminals,
-- with status in the winbar, desktop notifications and cross-session inspection.
local config = require("claude-deck.config")
local state = require("claude-deck.state")
local terminal = require("claude-deck.terminal")

local M = {}

local did_setup = false

local function is_float(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
end

-- Same as Neovim's only_one_window(): another tab page always counts; help windows (unless
-- the current window shows help), floating windows and the preview window do not.
local function is_last_window(win)
    if #vim.api.nvim_list_tabpages() > 1 then
        return false
    end
    local in_help = vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "help"
    local count = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local skip = (vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "help" and not in_help)
            or is_float(w)
            or vim.wo[w].previewwindow
        if w == win or not skip then
            count = count + 1
        end
    end
    return count <= 1
end

-- An existing empty, unmodified, unnamed buffer (e.g. left by an earlier quit), or a new one
local function empty_buffer()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].buflisted and vim.api.nvim_buf_is_loaded(buf) and terminal.is_empty_buffer(buf) then
            return buf
        end
    end
    return vim.api.nvim_create_buf(true, false)
end

-- QuitPre: when `:q` is about to close the last window and it shows a running terminal,
-- open an empty window first so that `:q` only hides the terminal and Neovim keeps running.
-- (`:q` cannot be cancelled from QuitPre.)
local function keep_alive_on_quit()
    local win = vim.api.nvim_get_current_win()
    local term = state.of_buf(vim.api.nvim_win_get_buf(win))
    if not term or term.state == "exited" or is_float(win) or not is_last_window(win) then
        return
    end

    local empty = vim.api.nvim_open_win(empty_buffer(), false, { split = "left" })
    -- Do not carry over the terminal's header and window style
    require("claude-deck.ui").unstyle_window(empty, true)

    vim.schedule(function()
        -- The quit failed (e.g. `:xa` with E948): remove the empty window again
        if vim.api.nvim_win_is_valid(win) then
            if vim.api.nvim_win_is_valid(empty) then
                local buf = vim.api.nvim_win_get_buf(empty)
                vim.api.nvim_win_close(empty, false)
                if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
                    pcall(vim.api.nvim_buf_delete, buf, {})
                end
            end
            return
        end

        local running = #vim.tbl_filter(function(t)
            return t.state ~= "exited"
        end, state.sorted())
        if running > 0 then
            vim.notify(
                string.format(
                    "claude-deck: %d terminal%s still running (:qa to quit Neovim)",
                    running,
                    running == 1 and "" or "s"
                ),
                vim.log.levels.INFO
            )
        end
    end)
end

function M.setup(opts)
    config.setup(opts)
    did_setup = true

    local ui = require("claude-deck.ui")
    ui.set_highlights()

    local group = vim.api.nvim_create_augroup("ClaudeDeck", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = ui.set_highlights })
    vim.api.nvim_create_autocmd("FocusGained", {
        group = group,
        callback = function()
            state.nvim_focused = true
        end,
    })
    vim.api.nvim_create_autocmd("FocusLost", {
        group = group,
        callback = function()
            state.nvim_focused = false
        end,
    })
    vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
        group = group,
        callback = function(args)
            if not config.options.auto_insert or not state.of_buf(args.buf) then
                return
            end
            vim.schedule(function()
                local term = state.current()
                if term and term.state ~= "exited" and vim.api.nvim_get_mode().mode ~= "t" then
                    vim.cmd("startinsert")
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function(args)
            ui.on_buf_win_enter(args.buf)
        end,
    })
    vim.api.nvim_create_autocmd("QuitPre", {
        group = group,
        callback = function()
            if config.options.keep_alive_on_quit then
                keep_alive_on_quit()
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = group,
        callback = function(args)
            local term = state.of_buf(args.buf)
            if term then
                state.remove(term.id)
            end
        end,
    })
end

local function ensure_setup()
    if not did_setup then
        M.setup()
    end
end

local function default_cwd()
    local term = state.current()
    return term and term.cwd or vim.fn.getcwd()
end

-- Focus a visible terminal when outside one; otherwise open a new terminal.
function M.toggle()
    ensure_setup()
    local wins = state.wins_in_tab()
    if not state.current() and #wins > 0 then
        vim.api.nvim_set_current_win(wins[#wins])
        vim.cmd("startinsert")
        return
    end
    terminal.open_new(default_cwd())
end

-- Open a new terminal. where: "right" or "below" (split the current window), or nil.
function M.new(where)
    ensure_setup()
    terminal.open_new(default_cwd(), where)
end

-- Show a terminal by id (works for hidden terminals too).
function M.show(id, where)
    ensure_setup()
    local term = state.get(id)
    if term then
        terminal.show(term, where)
    end
end

-- Pick a terminal to show. opts.where applies when the picker has no split keys.
function M.list(opts)
    ensure_setup()
    local list = state.sorted()
    if #list == 0 then
        vim.notify("claude-deck: no terminals", vim.log.levels.INFO)
        return
    end

    local items = {}
    for _, term in ipairs(list) do
        table.insert(items, {
            value = term.id,
            text = string.format(
                "#%d [%s]\t%s\t%s\t%s",
                term.id,
                state.label(term.state),
                vim.fn.fnamemodify(term.cwd, ":~"),
                state.title(term),
                term.session_id and term.session_id:sub(1, 8) or ""
            ),
        })
    end

    require("claude-deck.picker").pick(items, { prompt = "Terminals>", where = (opts or {}).where }, M.show)
end

local function dir_candidates()
    local dirs, seen = {}, {}
    local function add(dir)
        dir = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
        if not seen[dir] and vim.fn.isdirectory(dir) == 1 then
            seen[dir] = true
            table.insert(dirs, { value = dir, text = vim.fn.fnamemodify(dir, ":~") })
        end
    end

    add(vim.fn.getcwd())
    for _, term in ipairs(state.sorted()) do
        add(term.cwd)
    end
    for _, root in ipairs(config.options.dir_roots) do
        for _, dir in ipairs(vim.fn.glob(vim.fn.expand(root) .. "/*/", false, true)) do
            add(dir)
        end
    end
    if config.options.zoxide and vim.fn.executable("zoxide") == 1 then
        for _, dir in ipairs(vim.fn.systemlist({ "zoxide", "query", "--list" })) do
            add(dir)
        end
    end
    return dirs
end

-- Pick a directory and open a new terminal there.
function M.pick_dir(opts)
    ensure_setup()
    require("claude-deck.picker").pick(
        dir_candidates(),
        { prompt = "Directory>", where = (opts or {}).where },
        function(dir, where)
            terminal.open_new(dir, where)
        end
    )
end

-- Open a terminal that forks the current terminal's session.
function M.fork(where)
    ensure_setup()
    local parent = state.current()
    if not parent or not parent.session_id then
        vim.notify(
            "claude-deck: run this inside a terminal whose session id is known (needs the hooks)",
            vim.log.levels.WARN
        )
        return
    end

    local term = terminal.open_new(parent.cwd, where or "right", { "--resume", parent.session_id, "--fork-session" })
    state.set_title(term, "↳" .. (parent.title ~= "" and parent.title or ("#" .. parent.id)))
end

-- Show the Claude Code settings JSON (hooks and `ct` permissions) in a scratch buffer,
-- for adding to your own settings when `claude_settings` is false.
function M.show_settings()
    ensure_setup()
    local json = require("claude-deck.hooks").settings_json()
    local lines = vim.fn.systemlist({ "jq", "." }, json)
    if vim.v.shell_error ~= 0 then
        lines = { json }
    end

    vim.cmd("new")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "json"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

-- Rename the current terminal's task.
function M.rename()
    ensure_setup()
    local term = state.current()
    if not term then
        vim.notify("claude-deck: run this inside a terminal", vim.log.levels.WARN)
        return
    end

    vim.ui.input({ prompt = "Task title: ", default = term.title }, function(input)
        if input then
            state.set_title(term, state.make_title(input))
        end
    end)
end

-- Toggle focus mode (tree | editor | terminal in a new tab).
function M.focus()
    ensure_setup()
    require("claude-deck.focus").toggle()
end

local SUBCOMMANDS = {
    toggle = function()
        M.toggle()
    end,
    new = function(args)
        M.new(args[1])
    end,
    list = function(args)
        M.list({ where = args[1] })
    end,
    dir = function(args)
        M.pick_dir({ where = args[1] })
    end,
    fork = function(args)
        M.fork(args[1])
    end,
    rename = function()
        M.rename()
    end,
    focus = function()
        M.focus()
    end,
    settings = function()
        M.show_settings()
    end,
    show = function(args)
        M.show(tonumber(args[1]), args[2])
    end,
}

M.subcommands = vim.tbl_keys(SUBCOMMANDS)
table.sort(M.subcommands)

function M.command(fargs)
    local name = fargs[1] or "toggle"
    local sub = SUBCOMMANDS[name]
    if not sub then
        vim.notify("claude-deck: unknown subcommand " .. name, vim.log.levels.ERROR)
        return
    end
    sub(vim.list_slice(fargs, 2))
end

return M
