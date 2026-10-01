-- claude-terminals.nvim: run multiple Claude Code sessions in Neovim terminals,
-- with status in the winbar, desktop notifications and cross-session inspection.
local config = require("claude-terminals.config")
local state = require("claude-terminals.state")
local terminal = require("claude-terminals.terminal")

local M = {}

local did_setup = false

function M.setup(opts)
    config.setup(opts)
    did_setup = true

    local ui = require("claude-terminals.ui")
    ui.set_highlights()

    local group = vim.api.nvim_create_augroup("ClaudeTerminals", { clear = true })
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
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function(args)
            ui.on_buf_win_enter(args.buf)
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
        vim.notify("claude-terminals: no terminals", vim.log.levels.INFO)
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
                state.title(term),
                vim.fn.fnamemodify(term.cwd, ":~"),
                term.session_id and term.session_id:sub(1, 8) or ""
            ),
        })
    end

    require("claude-terminals.picker").pick(items, { prompt = "Terminals>", where = (opts or {}).where }, M.show)
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
    require("claude-terminals.picker").pick(
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
        vim.notify("claude-terminals: run this inside a terminal with a started session", vim.log.levels.WARN)
        return
    end

    local term = terminal.open_new(parent.cwd, where or "right", { "--resume", parent.session_id, "--fork-session" })
    term.title = "↳" .. (parent.title ~= "" and parent.title or ("#" .. parent.id))
    require("claude-terminals.ui").redraw()
end

-- Rename the current terminal's task.
function M.rename()
    ensure_setup()
    local term = state.current()
    if not term then
        vim.notify("claude-terminals: run this inside a terminal", vim.log.levels.WARN)
        return
    end

    vim.ui.input({ prompt = "Task title: ", default = term.title }, function(input)
        if input then
            term.title = state.make_title(input)
            require("claude-terminals.ui").redraw()
        end
    end)
end

-- Toggle focus mode (tree | editor | terminal in a new tab).
function M.focus()
    ensure_setup()
    require("claude-terminals.focus").toggle()
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
        vim.notify("claude-terminals: unknown subcommand " .. name, vim.log.levels.ERROR)
        return
    end
    sub(vim.list_slice(fargs, 2))
end

return M
