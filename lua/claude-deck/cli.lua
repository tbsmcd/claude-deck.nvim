-- Backend of the `ct` command (bin/ct), called via `nvim --remote-expr`.
local state = require("claude-deck.state")

local M = {}

local MAX_MESSAGE_LENGTH = 2000
-- Max display width (cells) of a title given with `ct title`. Longer titles are refused, not
-- cut, so that Claude picks a shorter one.
local MAX_TITLE_WIDTH = 40

local function json_list(self_id)
    local terminals = {}
    for _, term in ipairs(state.sorted()) do
        table.insert(terminals, {
            id = term.id,
            state = term.state,
            title = term.title,
            title_source = term.title_source or vim.NIL,
            cwd = term.cwd,
            session_id = term.session_id or vim.NIL,
            transcript_path = term.transcript_path or vim.NIL,
            -- The model requested when the terminal was started (not confirmed by Claude Code)
            model = term.model or vim.NIL,
            spawned_by = term.spawned_by or vim.NIL,
        })
    end
    return vim.json.encode({
        self = (tonumber(self_id) and tonumber(self_id) > 0) and tonumber(self_id) or vim.NIL,
        terminals = #terminals > 0 and terminals or vim.empty_dict(),
    })
end

-- `ct list`; with `json`, one JSON object (internal state names, null for missing values)
function M.list(self_id, json)
    if json then
        return json_list(self_id)
    end
    local lines = {}
    for _, term in ipairs(state.sorted()) do
        table.insert(
            lines,
            string.format(
                "#%d%s\t%s\t%s\t%s",
                term.id,
                term.id == tonumber(self_id) and " (you)" or "",
                state.label(term.state),
                state.title(term),
                term.cwd
            )
        )
        table.insert(lines, "\tsession_id: " .. (term.session_id or "(not started)"))
        table.insert(lines, "\ttranscript: " .. (term.transcript_path or "(not started)"))
        table.insert(lines, "\tmodel: " .. (term.model or "(default)"))
    end
    return #lines > 0 and table.concat(lines, "\n") or "No terminals"
end

local function message_text(entry)
    local content = (entry.message or {}).content
    if type(content) == "string" then
        return content
    end
    if type(content) ~= "table" then
        return nil
    end

    local parts = {}
    for _, block in ipairs(content) do
        if block.type == "text" and type(block.text) == "string" then
            table.insert(parts, block.text)
        elseif block.type == "tool_use" then
            table.insert(parts, "(tool: " .. tostring(block.name) .. ")")
        end
    end
    return #parts > 0 and table.concat(parts, "\n") or nil
end

-- Recent user / assistant messages from the session transcript (JSONL).
-- The transcript format is internal to Claude Code and may change.
function M.read(id, count)
    local term = state.get(id)
    if not term then
        return "ct: no terminal #" .. tostring(id)
    end
    if not term.transcript_path or vim.fn.filereadable(term.transcript_path) == 0 then
        return "ct: terminal #" .. term.id .. " has no conversation yet"
    end

    local messages = {}
    for _, line in ipairs(vim.fn.readfile(term.transcript_path)) do
        local ok, entry = pcall(vim.json.decode, line)
        if ok and type(entry) == "table" and not entry.isSidechain and not entry.isMeta then
            local role = entry.type == "user" and "User" or entry.type == "assistant" and "Claude" or nil
            local text = role and message_text(entry)
            if text and vim.trim(text) ~= "" then
                if #text > MAX_MESSAGE_LENGTH then
                    text = text:sub(1, MAX_MESSAGE_LENGTH) .. "… (truncated)"
                end
                table.insert(messages, "## " .. role .. "\n" .. text)
            end
        end
    end

    local first = math.max(1, #messages - (tonumber(count) or 20) + 1)
    local header = string.format(
        "# Terminal #%d [%s] %s (%s)",
        term.id,
        state.label(term.state),
        state.title(term),
        term.cwd
    )
    return header .. "\n\n" .. table.concat(vim.list_slice(messages, first), "\n\n")
end

-- `ct title`: without `text`, the current title of terminal `id`; otherwise sets it. A title
-- set by the user (rename()) is changed only with `force` (`ct title --force`).
function M.title(id, text, force)
    local term = state.get(id)
    if not term then
        return "ct: no terminal #" .. tostring(id)
    end
    if text == nil then
        return state.title(term)
    end

    local title = state.normalize_title(text)
    if title == "" then
        return "ct: the title is empty"
    end
    local width = vim.fn.strdisplaywidth(title)
    if width > MAX_TITLE_WIDTH then
        return string.format("ct: title is too long (%d cells, max %d)", width, MAX_TITLE_WIDTH)
    end
    if term.title_source == "user" and not force then
        return "ct: the title was set by the user; run `ct title --force <title>` if the user asked you to rename it"
    end

    state.set_title(term, title, "claude")
    return string.format("Terminal #%d title: %s", term.id, title)
end

-- "path:line" (also "path:line:col") -> path, line; just a path -> path, nil
function M.split_line(text)
    local path, line = text:match("^(.-):(%d+):%d+$")
    if not path then
        path, line = text:match("^(.-):(%d+)$")
    end
    if not path or path == "" then
        return text, nil
    end
    return path, tonumber(line)
end

-- Absolute path of `path` (absolute, "~/…" or relative to `cwd`), or nil when it does not exist
function M.resolve_path(path, cwd)
    if path == "~" or vim.startswith(path, "~/") then
        path = vim.env.HOME .. path:sub(2)
    elseif not vim.startswith(path, "/") then
        path = cwd .. "/" .. path
    end
    path = vim.fs.normalize(vim.fn.simplify(path))
    return vim.uv.fs_stat(path) and path or nil
end

-- `ct open <path>[:line]`: opens the file in the editor window of the focus mode of terminal
-- `id` (opening focus mode when needed). Relative paths are relative to `cwd` (the shell's
-- current directory; empty or nil: the terminal's cwd). A file whose whole name matches (e.g.
-- "foo:24") is opened as it is; otherwise a trailing ":line" is the line.
function M.open(id, text, cwd)
    local term = state.get(id)
    if not term then
        return "ct: no terminal #" .. tostring(id)
    end
    text = vim.trim(text or "")
    if text == "" then
        return "ct: no path given"
    end
    local base = (cwd and cwd ~= "") and cwd or term.cwd

    local path, line = text, nil
    local resolved = M.resolve_path(path, base)
    if not resolved then
        path, line = M.split_line(text)
        resolved = M.resolve_path(path, base)
    end
    if not resolved then
        return "ct: file not found: " .. path
    end
    if vim.fn.isdirectory(resolved) == 1 then
        return "ct: not a file: " .. path
    end

    local ok, result = pcall(require("claude-deck.focus").open_file, term, resolved, line)
    if not ok then
        pcall(vim.cmd, "stopinsert")
        return "ct: " .. tostring(result)
    end
    return result
end

-- `ct diff [<path>[:line]] [--base <ref>]`: opens the diff of the pull request (or of the
-- working tree) in the editor window of the focus mode of terminal `id`. `args`: the
-- arguments as a list; relative paths are relative to `cwd` (the shell's current directory;
-- empty or nil: the terminal's cwd).
function M.diff(id, args, cwd)
    local term = state.get(id)
    if not term then
        return "ct: no terminal #" .. tostring(id)
    end
    local diff = require("claude-deck.diff")
    local opts, err = diff.parse_args(args or {})
    if not opts then
        return err
    end
    local base = (cwd and cwd ~= "") and cwd or term.cwd
    if opts.path then
        opts.path = vim.trim(opts.path)
        if opts.path == "" then
            opts.path = nil
        elseif not M.resolve_path(opts.path, base) then
            opts.path, opts.line = M.split_line(opts.path)
        end
    end
    local ok, result = pcall(diff.open, term, base, opts)
    if not ok then
        pcall(vim.cmd, "stopinsert")
        return "ct: " .. tostring(result)
    end
    return result
end

local function title_error(title)
    if title == "" then
        return "ct: the title is empty"
    end
    local width = vim.fn.strdisplaywidth(title)
    if width > MAX_TITLE_WIDTH then
        return string.format("ct: title is too long (%d cells, max %d)", width, MAX_TITLE_WIDTH)
    end
end

-- Starts a new terminal for `ct spawn` / spawn(). `caller`: the terminal that asks (or nil).
-- opts: { prompt, cwd (relative to opts.base, default: the caller's cwd), base, model, title,
-- show }. Returns the terminal, or nil and a "ct: …" message. Nothing is created on an error.
function M.spawn_term(caller, opts)
    local prompt = opts.prompt
    if type(prompt) ~= "string" or vim.trim(prompt) == "" then
        return nil, "ct: no prompt given (use --prompt or --prompt-file)"
    end
    if prompt:find("\0", 1, true) then
        return nil, "ct: the prompt contains a NUL byte"
    end

    local model = opts.model
    if model ~= nil and (type(model) ~= "string" or model == "" or vim.startswith(model, "-")) then
        return nil, "ct: invalid model: " .. tostring(model)
    end

    local title
    if opts.title ~= nil then
        title = state.normalize_title(opts.title)
        local err = title_error(title)
        if err then
            return nil, err
        end
    end

    local default_cwd = caller and caller.cwd or vim.fn.getcwd()
    local base = (opts.base and opts.base ~= "") and opts.base or default_cwd
    local cwd = default_cwd
    if opts.cwd ~= nil then
        cwd = opts.cwd
        if cwd == "~" or vim.startswith(cwd, "~/") then
            cwd = vim.env.HOME .. cwd:sub(2)
        elseif not vim.startswith(cwd, "/") then
            cwd = base .. "/" .. cwd
        end
        cwd = vim.fs.normalize(vim.fn.simplify(cwd))
        if vim.fn.isdirectory(cwd) == 0 then
            return nil, "ct: not a directory: " .. opts.cwd
        end
    end

    local limit = require("claude-deck.config").options.cli.spawn_limit
    local running = 0
    for _, term in ipairs(state.sorted()) do
        if term.spawned and term.state ~= "exited" then
            running = running + 1
        end
    end
    if running >= limit then
        return nil, string.format("ct: spawn limit reached (%d)", limit)
    end

    local caller_win = caller and vim.fn.bufwinid(caller.buf)
    local ok, term = pcall(require("claude-deck.terminal").start_detached, cwd, {
        model = model,
        prompt = prompt,
        show = opts.show,
        caller_win = (caller_win and caller_win > 0) and caller_win or nil,
    })
    if not ok then
        return nil, "ct: " .. tostring(term)
    end
    term.spawned = true
    term.spawned_by = caller and caller.id or nil
    if title then
        state.set_title(term, title, "claude")
    end
    return term
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local SPAWN_VALUE_OPTIONS = { "--title", "--cwd", "--model", "--prompt", "--prompt-file" }

-- `ct spawn [--title <title>] [--cwd <dir>] [--model <model>] (--prompt <text> | --prompt-file
-- <path>) [--show]`: starts a new terminal without changing what the user sees (with --show:
-- next to terminal `id`) and returns its id etc. as one line of JSON. `args`: the arguments as
-- a list; relative paths are relative to `pwd` (the shell's current directory).
function M.spawn(id, args, pwd)
    local caller = state.get(id)
    if not caller then
        return "ct: no terminal #" .. tostring(id)
    end

    local opts, i = {}, 1
    while i <= #args do
        local arg = args[i]
        local name, value = arg:match("^(%-%-[%w-]+)=(.*)$")
        name = name or arg
        if name == "--show" and value == nil then
            opts.show = true
        elseif vim.tbl_contains(SPAWN_VALUE_OPTIONS, name) then
            if value == nil then
                i = i + 1
                value = args[i]
            end
            if value == nil then
                return "ct: " .. name .. " needs a value"
            end
            opts[name:sub(3):gsub("-", "_")] = value
        else
            return "ct: unknown argument " .. arg
        end
        i = i + 1
    end

    if opts.prompt and opts.prompt_file then
        return "ct: use either --prompt or --prompt-file, not both"
    end
    local prompt = opts.prompt
    if opts.prompt_file then
        local path = opts.prompt_file
        if path == "~" or vim.startswith(path, "~/") then
            path = vim.env.HOME .. path:sub(2)
        elseif not vim.startswith(path, "/") then
            path = ((pwd and pwd ~= "") and pwd or caller.cwd) .. "/" .. path
        end
        prompt = read_file(path)
        if not prompt or vim.fn.isdirectory(path) == 1 then
            return "ct: cannot read the prompt file: " .. opts.prompt_file
        end
        prompt = prompt:gsub("\n+$", "")
    end
    if prompt == nil then
        return "ct: no prompt given (use --prompt or --prompt-file)"
    end

    local term, err = M.spawn_term(caller, {
        prompt = prompt,
        cwd = opts.cwd,
        base = pwd,
        model = opts.model,
        title = opts.title,
        show = opts.show,
    })
    if not term then
        return err
    end
    return vim.json.encode({
        id = term.id,
        cwd = term.cwd,
        model = term.model or vim.NIL,
        title = term.title ~= "" and term.title or vim.NIL,
    })
end

return M
