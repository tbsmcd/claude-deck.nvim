-- claude-deck.nvim: run multiple Claude Code sessions in Neovim terminals,
-- with status in the winbar, desktop notifications and cross-session inspection.
local config = require("claude-deck.config")
local state = require("claude-deck.state")
local terminal = require("claude-deck.terminal")

local M = {}

local did_setup = false
-- Key of the global send_location() mapping made by the last setup()
local location_key

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

local function set_location_keymap()
    if location_key then
        pcall(vim.keymap.del, { "n", "x" }, location_key)
        location_key = nil
    end
    local key = config.options.keymaps.send_location
    if type(key) == "string" and key ~= "" then
        vim.keymap.set({ "n", "x" }, key, function()
            M.send_location()
        end, { desc = "Claude: send file location" })
        location_key = key
    end
end

function M.setup(opts)
    config.setup(opts)
    did_setup = true
    set_location_keymap()

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
    vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "WinResized", "VimResized" }, {
        group = group,
        callback = function(args)
            local terminal = require("claude-deck.terminal")
            if args.event == "WinResized" then
                for _, win in ipairs(vim.v.event.windows or {}) do
                    terminal.fit_pty(win)
                end
            elseif args.event == "VimResized" then
                for _, win in ipairs(state.wins_in_tab()) do
                    terminal.fit_pty(win)
                end
            else
                terminal.fit_pty(vim.api.nvim_get_current_win())
            end
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
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            require("claude-deck.snapshot").leave()
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
-- opts.model: model for Claude Code (`--model`, any alias or full id); without it the model
-- comes from `cmd` / the Claude Code settings. opts.orchestration: allow `ct spawn` / `ct send` without
-- a prompt in this terminal (default: `cli.allow_orchestration`). opts.permission_mode:
-- `--permission-mode` (default, acceptEdits, plan, auto or bypassPermissions; the last one
-- disables all permission prompts); without it Claude Code's own default applies.
function M.new(where, opts)
    ensure_setup()
    opts = opts or {}
    if opts.permission_mode ~= nil and not require("claude-deck.config").is_permission_mode(opts.permission_mode) then
        vim.notify(
            "claude-deck: invalid permission mode: "
                .. tostring(opts.permission_mode)
                .. " (use default, acceptEdits, plan, auto or bypassPermissions)",
            vim.log.levels.WARN
        )
        return
    end
    terminal.open_new(default_cwd(), where, nil, {
        model = opts.model,
        permission_mode = opts.permission_mode,
        orchestration = opts.orchestration,
    })
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
    local list = state.tree()
    if #list == 0 then
        vim.notify("claude-deck: no terminals", vim.log.levels.INFO)
        return
    end

    -- The id column is widened by the child marker for all lines when any terminal has a parent
    local nested = false
    for _, entry in ipairs(list) do
        nested = nested or entry.depth > 0
    end

    local items = {}
    for _, entry in ipairs(list) do
        local term = entry.term
        table.insert(items, {
            value = term.id,
            text = string.format(
                "%s#%d [%s]\t%s\t%s\t%s",
                entry.depth > 0 and "  └ " or (nested and "    " or ""),
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

-- Absolute path without a trailing slash ("/" stays "/")
local function normalize_dir(dir)
    dir = vim.fn.fnamemodify(dir, ":p")
    return dir == "/" and dir or (dir:gsub("/$", ""))
end

-- Directories directly under `dir` (including symlinks to directories), by name, without
-- hidden ones. Empty when `dir` cannot be read.
local function subdirs(dir)
    local dirs = {}
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
        return dirs
    end
    while true do
        local name, type = vim.uv.fs_scandir_next(handle)
        if not name then
            break
        end
        local path = (dir == "/" and "" or dir) .. "/" .. name
        if not name:match("^%.") then
            -- stat only when the entry type does not tell (symlinks, some file systems)
            if type == nil or type == "link" or type == "unknown" then
                local stat = vim.uv.fs_stat(path)
                type = stat and stat.type
            end
            if type == "directory" then
                table.insert(dirs, path)
            end
        end
    end
    table.sort(dirs)
    return dirs
end

local function dir_list()
    local dirs, seen = {}, {}
    local function add(dir)
        dir = normalize_dir(dir)
        if not seen[dir] and vim.fn.isdirectory(dir) == 1 then
            seen[dir] = true
            table.insert(dirs, { value = dir, text = vim.fn.fnamemodify(dir, ":~") })
        end
    end
    return dirs, add
end

local function dir_candidates()
    local dirs, add = dir_list()
    local cwd = vim.fn.getcwd()
    add(cwd)
    for _, dir in ipairs(subdirs(normalize_dir(cwd))) do
        add(dir)
    end
    for _, term in ipairs(state.sorted()) do
        add(term.cwd)
    end
    for _, root in ipairs(config.options.dir_roots) do
        for _, dir in ipairs(subdirs(normalize_dir(vim.fn.expand(root)))) do
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

-- `dir` itself (to open there) and the directories directly under it
local function dir_browse_candidates(dir)
    local dirs, add = dir_list()
    add(dir)
    for _, sub in ipairs(subdirs(dir)) do
        add(sub)
    end
    return dirs
end

-- dir: the directory being browsed, or nil for the first list
local function open_dir_picker(dir, where)
    -- Open the next picker (target nil: the first list) after the current one has closed
    local function browse(target)
        vim.schedule(function()
            open_dir_picker(target and normalize_dir(target), where)
        end)
    end

    require("claude-deck.picker").pick(dir and dir_browse_candidates(dir) or dir_candidates(), {
        prompt = dir and (vim.fn.fnamemodify(dir, ":~") .. ">") or "Directory>",
        where = where,
        header = "tab: go into / shift-tab: go up",
        extra_actions = {
            -- Without a selection (nothing matches), open the same list again
            ["tab"] = function(target)
                browse(target or dir)
            end,
            ["btab"] = function()
                browse(vim.fn.fnamemodify(dir or normalize_dir(vim.fn.getcwd()), ":h"))
            end,
        },
    }, function(target, w)
        terminal.open_new(target, w)
    end)
end

-- Pick a directory and open a new terminal there. With fzf-lua, tab / shift-tab browse into a
-- directory / up to the parent.
function M.pick_dir(opts)
    ensure_setup()
    open_dir_picker(nil, (opts or {}).where)
end

-- Open a terminal that forks the current terminal's session. opts.model: as in new(); by
-- default the model of the forked terminal is used (the conversation continues).
-- opts.orchestration: as in new(); by default the flag of the forked terminal is inherited.
-- opts.permission_mode: as in new(); by default the mode of the forked terminal is inherited.
function M.fork(where, opts)
    ensure_setup()
    local parent = state.current()
    if not parent or not parent.session_id then
        vim.notify(
            "claude-deck: run this inside a terminal whose session id is known (needs the hooks)",
            vim.log.levels.WARN
        )
        return
    end

    opts = opts or {}
    if opts.permission_mode ~= nil and not require("claude-deck.config").is_permission_mode(opts.permission_mode) then
        vim.notify(
            "claude-deck: invalid permission mode: "
                .. tostring(opts.permission_mode)
                .. " (use default, acceptEdits, plan, auto or bypassPermissions)",
            vim.log.levels.WARN
        )
        return
    end
    local orchestration = opts.orchestration
    if orchestration == nil then
        orchestration = parent.orchestration
    end
    local term = terminal.open_new(
        parent.cwd,
        where or "right",
        { "--resume", parent.session_id, "--fork-session" },
        {
            model = opts.model or parent.model,
            permission_mode = opts.permission_mode or parent.permission_mode,
            orchestration = orchestration,
        }
    )
    state.set_title(term, "↳" .. (parent.title ~= "" and parent.title or ("#" .. parent.id)), "auto")
end

-- Text of a restore() picker line: "2026-10-28 09:12  pid 75871  3 terminals  ~/a, ~/b (clean exit)"
local function snapshot_line(data)
    local cwds, seen = {}, {}
    for _, term in ipairs(data.terminals) do
        if type(term.cwd) == "string" and not seen[term.cwd] then
            seen[term.cwd] = true
            table.insert(cwds, vim.fn.fnamemodify(term.cwd, ":~"))
        end
    end
    return string.format(
        "%s  pid %s  %d terminal%s  %s%s",
        os.date("%Y-%m-%d %H:%M", data.saved_at),
        tostring(data.pid),
        #data.terminals,
        #data.terminals == 1 and "" or "s",
        table.concat(cwds, ", "),
        data.clean_exit and " (clean exit)" or ""
    )
end

-- nil for a missing or broken file, or one that is not a snapshot
local function read_snapshot(path)
    local ok, data = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"), { luanil = { object = true, array = true } })
    end)
    if ok and type(data) == "table" and type(data.terminals) == "table" and type(data.saved_at) == "number" then
        return data
    end
end

local function restore_file(path)
    local data = read_snapshot(path)
    if not data then
        vim.notify("claude-deck: cannot read snapshot " .. path, vim.log.levels.WARN)
        return
    end

    local ids, new_id, no_session, no_dir = {}, {}, 0, 0
    local restored = {}
    for _, saved in ipairs(data.terminals) do
        if saved.state ~= "exited" then
            if type(saved.session_id) ~= "string" or saved.session_id == "" then
                no_session = no_session + 1
            elseif type(saved.cwd) ~= "string" or vim.fn.isdirectory(saved.cwd) == 0 then
                no_dir = no_dir + 1
                vim.notify("claude-deck: skipped #" .. tostring(saved.id) .. ": directory is gone: " .. tostring(saved.cwd), vim.log.levels.WARN)
            else
                local ok, term = pcall(terminal.start_detached, saved.cwd, {
                    extra_args = { "--resume", saved.session_id },
                    model = saved.model,
                    permission_mode = config.is_permission_mode(saved.permission_mode) and saved.permission_mode or nil,
                    orchestration = saved.orchestration == true,
                })
                if ok then
                    if type(saved.title) == "string" and saved.title ~= "" then
                        state.set_title(term, saved.title, saved.title_source or "auto")
                    end
                    term.resumed_from = saved.session_id
                    term.spawned = saved.spawned_by ~= nil or nil
                    new_id[saved.id] = term.id
                    table.insert(restored, { term = term, saved = saved })
                    table.insert(ids, term.id)
                else
                    vim.notify("claude-deck: cannot restore #" .. tostring(saved.id) .. ": " .. tostring(term), vim.log.levels.WARN)
                end
            end
        end
    end
    -- The parent may be restored after its child, so the ids are mapped at the end
    for _, item in ipairs(restored) do
        item.term.spawned_by = item.saved.spawned_by and new_id[item.saved.spawned_by] or nil
    end
    state.changed()

    local skipped = {}
    if no_session > 0 then
        table.insert(skipped, no_session .. " skipped: no session")
    end
    if no_dir > 0 then
        table.insert(skipped, no_dir .. " skipped: directory is gone")
    end
    vim.notify(
        string.format(
            "claude-deck: restored %d terminal%s%s",
            #ids,
            #ids == 1 and "" or "s",
            #skipped > 0 and " (" .. table.concat(skipped, ", ") .. ")" or ""
        ),
        vim.log.levels.INFO
    )
    if #ids > 0 then
        M.list()
    end
    return ids
end

-- Resume the Claude Code sessions recorded in a snapshot of an earlier Neovim (after a crash),
-- as hidden terminals. opts.file: a snapshot file (no picker); opts.latest: the newest snapshot
-- of another instance. Otherwise pick one. Returns the new terminal ids, or nil when the
-- picker is used (the restore then runs after the selection) or nothing was restored.
function M.restore(opts)
    ensure_setup()
    opts = opts or {}
    if opts.file then
        return restore_file(vim.fn.fnamemodify(vim.fn.expand(opts.file), ":p"))
    end

    local snapshot = require("claude-deck.snapshot")
    local own = snapshot.file()
    local items = {}
    for _, path in ipairs(snapshot.files()) do
        local data = path ~= own and read_snapshot(path)
        if data then
            if opts.latest then
                return restore_file(path)
            end
            table.insert(items, { value = path, text = snapshot_line(data) })
        end
    end
    if #items == 0 then
        vim.notify("claude-deck: no snapshots to restore", vim.log.levels.INFO)
        return
    end
    require("claude-deck.picker").pick(items, { prompt = "Restore>" }, function(path)
        restore_file(path)
    end)
end

-- Give the terminal windows of the current tab the same size, leaving the other windows alone:
-- terminals side by side (same row) get the same width, stacked ones (same column) the same
-- height. Windows with 'winfixwidth' / 'winfixheight' are left as they are. Returns the number
-- of windows resized.
function M.equal()
    local state = require("claude-deck.state")
    local api = vim.api
    local wins = vim.tbl_filter(function(win)
        return api.nvim_win_get_config(win).relative == ""
    end, state.wins_in_tab())
    if #wins < 2 then
        vim.notify("claude-deck: fewer than two terminals in this tab", vim.log.levels.INFO)
        return 0
    end

    local resized = {}
    -- axis: position index (1 = row, 2 = column) shared by a group
    local function equalize(axis, fixed_opt, get, set)
        local groups, keys = {}, {}
        for _, win in ipairs(wins) do
            if not vim.wo[win][fixed_opt] then
                local pos = api.nvim_win_get_position(win)
                local key = pos[axis]
                if not groups[key] then
                    groups[key] = {}
                    table.insert(keys, key)
                end
                table.insert(groups[key], win)
            end
        end
        for _, key in ipairs(keys) do
            local group = groups[key]
            if #group >= 2 then
                local other = 3 - axis
                table.sort(group, function(a, b)
                    return api.nvim_win_get_position(a)[other] < api.nvim_win_get_position(b)[other]
                end)
                local sum = 0
                for _, win in ipairs(group) do
                    sum = sum + get(win)
                end
                local size = math.floor(sum / #group)
                -- Fix the windows outside the group, so that the space is only exchanged inside it
                local in_group, saved = {}, {}
                for _, win in ipairs(group) do
                    in_group[win] = true
                end
                for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
                    if not in_group[win] then
                        saved[win] = { vim.wo[win].winfixwidth, vim.wo[win].winfixheight }
                        vim.wo[win].winfixwidth = true
                        vim.wo[win].winfixheight = true
                    end
                end
                local set_ok, set_err = pcall(function()
                    for _, win in ipairs(group) do
                        set(win, size)
                        resized[win] = true
                    end
                    -- Neovim passes the rounding on to the neighbours; set the last one again
                    set(group[#group], size)
                end)
                for win, fixed in pairs(saved) do
                    if api.nvim_win_is_valid(win) then
                        vim.wo[win].winfixwidth = fixed[1]
                        vim.wo[win].winfixheight = fixed[2]
                    end
                end
                if not set_ok then
                    error(set_err)
                end
            end
        end
    end

    -- 'equalalways' is not toggled (turning it back on equalizes every window); the windows
    -- outside each group are fixed while it is resized instead.
    equalize(1, "winfixwidth", api.nvim_win_get_width, api.nvim_win_set_width)
    equalize(2, "winfixheight", api.nvim_win_get_height, api.nvim_win_set_height)

    local count = 0
    for win in pairs(resized) do
        require("claude-deck.terminal").fit_pty(win)
        count = count + 1
    end
    return count
end

-- How long redraw() waits for Claude Code to exit after jobstop() (ms). Changed by the tests.
M._redraw_timeout = 5000

-- Redraw the current terminal: stop Claude Code and resume the same session in a new buffer
-- in the same window, so that the whole conversation is drawn again at the current width.
-- Only while Claude is idle, waiting for input or has exited. Returns at once; reports when done.
function M.redraw()
    ensure_setup()
    local term = state.current()
    if not term then
        vim.notify("claude-deck: run this inside a terminal", vim.log.levels.WARN)
        return
    end
    if term.redrawing then
        vim.notify(string.format("claude-deck: #%d is being redrawn", term.id), vim.log.levels.INFO)
        return
    end
    if not term.session_id then
        vim.notify(
            "claude-deck: run this inside a terminal whose session id is known (needs the hooks)",
            vim.log.levels.WARN
        )
        return
    end
    if term.state ~= "waiting" and term.state ~= "idle" and term.state ~= "exited" then
        vim.notify(
            string.format("claude-deck: wait until Claude finishes (state: %s)", term.state),
            vim.log.levels.WARN
        )
        return
    end

    local win = vim.api.nvim_get_current_win()
    local session_id = term.session_id

    local function restart()
        term.redrawing = nil
        -- The terminal was removed (its buffer deleted) while Claude Code was exiting
        if state.get(term.id) ~= term then
            return
        end
        -- Do not open a window the user did not ask for: give up and drop the exited terminal
        if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= term.buf then
            vim.notify(
                string.format("claude-deck: window for #%d was closed; not redrawn", term.id),
                vim.log.levels.WARN
            )
            if vim.api.nvim_buf_is_valid(term.buf) then
                pcall(vim.api.nvim_buf_delete, term.buf, { force = true })
            end
            state.remove(term.id)
            return
        end
        terminal.start(win, term.cwd, { "--resume", session_id }, { reuse = term, model = term.model, permission_mode = term.permission_mode })
        vim.notify(string.format("claude-deck: redrew #%d", term.id), vim.log.levels.INFO)
    end

    if term.state == "exited" then
        restart()
        return
    end

    -- Stop the job instead of typing `/exit`, which would be appended to an unsent prompt.
    -- on_exit (in terminal.start()) sets "exited" for this job.
    term.redrawing = true
    local job = term.job
    pcall(vim.fn.jobstop, job)
    local timer = assert(vim.uv.new_timer())
    local waited, timeout = 0, M._redraw_timeout
    timer:start(50, 50, vim.schedule_wrap(function()
        if timer:is_closing() then
            return
        end
        waited = waited + 50
        if (term.state == "exited" and term.job == job) or state.get(term.id) ~= term then
            timer:close()
            restart()
        elseif waited >= timeout then
            timer:close()
            term.redrawing = nil
            vim.notify(string.format("claude-deck: #%d did not exit; not redrawn", term.id), vim.log.levels.WARN)
        end
    end))
end

-- Start a new Claude Code session in another terminal without changing the current tab, window
-- or mode (what `ct spawn` does). opts: { prompt (required unless resume), resume (a session id to continue), cwd (default: the cwd of the current
-- terminal, else Neovim's), model, permission_mode (default: `cli.spawn_permission_mode`), title (at most 40 cells), show }. The terminal stays hidden
-- (see show()) unless opts.show: then it opens to the right of the current terminal. Returns
-- the terminal id, or nil and a message.
function M.spawn(opts)
    ensure_setup()
    opts = opts or {}
    local term, err = require("claude-deck.cli").spawn_term(state.current(), opts)
    if not term then
        return nil, (err:gsub("^ct: ", ""))
    end
    return term.id
end

-- Types a task into the prompt of terminal `id` (an idle or waiting terminal other than the
-- current one), as `ct send` does. Returns the request id ("r1"), or nil and a message.
-- Success means only that the input was written, not that Claude accepted it.
function M.send(id, prompt)
    ensure_setup()
    local request, err = require("claude-deck.cli").send_term(state.current(), id, prompt)
    return request, err and (err:gsub("^ct: ", ""))
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

-- Rename the current terminal's task. The title takes precedence over `ct title`.
function M.rename()
    ensure_setup()
    local term = state.current()
    if not term then
        vim.notify("claude-deck: run this inside a terminal", vim.log.levels.WARN)
        return
    end

    vim.ui.input({ prompt = "Task title: ", default = term.title }, function(input)
        if input then
            state.set_title(term, state.make_title(input), "user")
        end
    end)
end

-- Toggle focus mode (tree | editor | terminal in a new tab).
function M.focus()
    ensure_setup()
    require("claude-deck.focus").toggle()
end

-- Insert "path:line" (Visual mode: "path:start-end") of the current file into the prompt of
-- the focus mode terminal (or the only terminal in this tab) and move there. Not submitted.
function M.send_location()
    ensure_setup()
    require("claude-deck.location").send()
end

-- Terminal `term_id`, the current terminal, or the one of this focus mode tab; nil with a warning
local function target_term(term_id)
    local term
    if term_id then
        term = state.get(term_id)
    else
        term = state.current() or state.get(require("claude-deck.focus").term_id())
    end
    if not term then
        vim.notify(
            term_id and ("claude-deck: no terminal #" .. tostring(term_id))
                or "claude-deck: run this inside a terminal or its focus mode",
            vim.log.levels.WARN
        )
    end
    return term
end

-- Open `path` (absolute, "~/…" or relative to the terminal's cwd) in the editor window of the
-- focus mode of terminal `term_id` (default: the current terminal, or the one of this focus
-- mode tab), opening focus mode when needed, and go to `line` (optional).
function M.open_file(path, line, term_id)
    ensure_setup()
    local term = target_term(term_id)
    if not term then
        return
    end

    local result = require("claude-deck.cli").open(term.id, line and (path .. ":" .. line) or path)
    if vim.startswith(result, "ct: ") then
        vim.notify("claude-deck: " .. result:sub(5), vim.log.levels.WARN)
    end
end

-- Turns `ct spawn` / `ct send` without a permission prompt on or off for terminal `id` (default: the
-- current terminal, or the one of this focus mode tab). Needs the PreToolUse hook (`claude_settings`).
function M.set_orchestration(id, enabled)
    ensure_setup()
    local term = target_term(id)
    if not term then
        return
    end
    term.orchestration = enabled and true or false
    state.changed()
    vim.notify("claude-deck: orchestration " .. (term.orchestration and "on" or "off") .. " for #" .. term.id)
end

-- Open the diff of the pull request of the current branch (`gh pr diff`), or of the uncommitted
-- changes, in the editor window of the focus mode of terminal `opts.id` (default: the current
-- terminal, or the one of this focus mode tab). opts: { path, line, base, pr, id }; `path` is
-- absolute, "~/…" or relative to the terminal's cwd; `base`: compare the working tree with
-- this ref instead; `pr`: this pull request (number, URL or branch) instead.
function M.open_diff(opts)
    ensure_setup()
    opts = opts or {}
    local term = target_term(opts.id)
    if not term then
        return
    end
    local result = require("claude-deck.diff")
        .open(term, term.cwd, { path = opts.path, line = opts.line, base = opts.base, pr = opts.pr })
    if vim.startswith(result, "ct: ") then
        vim.notify("claude-deck: " .. result:sub(5), vim.log.levels.WARN)
    end
end

-- `[right|below] [--model <model>] [--permission-mode <mode>]` (any order) -> where, { model, ... }; false (after a warning)
-- when the arguments are wrong
local function parse_where_model(args)
    local where, opts, i = nil, {}, 1
    while i <= #args do
        local arg = args[i]
        if arg == "--model" then
            i = i + 1
            opts.model = args[i] or ""
        elseif vim.startswith(arg, "--model=") then
            opts.model = arg:sub(9)
        elseif arg == "--permission-mode" then
            i = i + 1
            opts.permission_mode = args[i] or ""
        elseif vim.startswith(arg, "--permission-mode=") then
            opts.permission_mode = arg:sub(19)
        elseif arg == "--orchestrate" then
            opts.orchestration = true
        elseif not where then
            where = arg
        else
            where = false
        end
        if opts.model ~= nil and (opts.model == "" or vim.startswith(opts.model, "-")) then
            where = false
        end
        if where == false then
            vim.notify("claude-deck: usage: ClaudeDeck new|fork [right|below] [--model <model>] [--orchestrate] [--permission-mode <mode>]", vim.log.levels.WARN)
            return false
        end
        i = i + 1
    end
    return where, opts
end

local SUBCOMMANDS = {
    toggle = function()
        M.toggle()
    end,
    new = function(args)
        local where, opts = parse_where_model(args)
        if where ~= false then
            M.new(where, opts)
        end
    end,
    list = function(args)
        M.list({ where = args[1] })
    end,
    dir = function(args)
        M.pick_dir({ where = args[1] })
    end,
    fork = function(args)
        local where, opts = parse_where_model(args)
        if where ~= false then
            M.fork(where, opts)
        end
    end,
    orchestrate = function(args)
        if args[1] ~= "on" and args[1] ~= "off" then
            vim.notify("claude-deck: usage: ClaudeDeck orchestrate on|off", vim.log.levels.WARN)
            return
        end
        M.set_orchestration(nil, args[1] == "on")
    end,
    rename = function()
        M.rename()
    end,
    redraw = function()
        M.redraw()
    end,
    equal = function()
        M.equal()
    end,
    restore = function(args)
        M.restore({ file = args[1] })
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
    -- `:ClaudeDeck open path[:line]`
    open = function(args)
        if #args == 0 then
            vim.notify("claude-deck: usage: ClaudeDeck open <path>[:line]", vim.log.levels.WARN)
            return
        end
        -- Relative to Neovim's cwd (as completed); `%` etc. are expanded
        local function absolute(path)
            return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
        end
        local text = table.concat(args, " ")
        local whole = absolute(text)
        if vim.uv.fs_stat(whole) then
            M.open_file(whole)
            return
        end
        local path, line = require("claude-deck.cli").split_line(text)
        M.open_file(absolute(path), line)
    end,
    -- `:ClaudeDeck diff [path[:line]] [--base ref] [--pr pr]` (paths relative to Neovim's cwd)
    diff = function(args)
        local opts, err = require("claude-deck.diff").parse_args(args)
        if not opts then
            vim.notify("claude-deck: " .. err:sub(5), vim.log.levels.WARN)
            return
        end
        if opts.path then
            local whole = vim.fn.fnamemodify(vim.fn.expand(opts.path), ":p")
            if not vim.uv.fs_stat(whole) then
                local path, line = require("claude-deck.cli").split_line(opts.path)
                whole, opts.line = vim.fn.fnamemodify(vim.fn.expand(path), ":p"), line
            end
            opts.path = whole
        end
        M.open_diff(opts)
    end,
    -- With a range (e.g. `:'<,'>ClaudeDeck location`), the range is sent
    location = function(_, range)
        ensure_setup()
        require("claude-deck.location").send(range)
    end,
}

M.subcommands = vim.tbl_keys(SUBCOMMANDS)
table.sort(M.subcommands)

-- range: { line1, line2 } when the command was given a range
function M.command(fargs, range)
    local name = fargs[1] or "toggle"
    local sub = SUBCOMMANDS[name]
    if not sub then
        vim.notify("claude-deck: unknown subcommand " .. name, vim.log.levels.ERROR)
        return
    end
    sub(vim.list_slice(fargs, 2), range)
end

return M
