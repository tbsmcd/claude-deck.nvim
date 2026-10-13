-- Backend of the `ct` command (bin/ct), called via `nvim --remote-expr`.
local state = require("claude-deck.state")

local M = {}

local MAX_MESSAGE_LENGTH = 2000
-- Max display width (cells) of a title given with `ct title`. Longer titles are refused, not
-- cut, so that Claude picks a shorter one.
local MAX_TITLE_WIDTH = 40

-- JSON object with the keys in the given order: { { key, value }, … } (vim.json.encode()
-- orders keys arbitrarily, which makes the output of `ct` hard to match with grep)
local function ordered_object(pairs_list)
    local parts = {}
    for _, pair in ipairs(pairs_list) do
        local value = pair[2]
        -- { raw = "<json>" }: already encoded
        value = type(value) == "table" and value.raw or vim.json.encode(value)
        table.insert(parts, vim.json.encode(pair[1]) .. ":" .. value)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function json_list(self_id)
    local terminals = {}
    for _, term in ipairs(state.sorted()) do
        local request = term.last_request
        table.insert(
            terminals,
            ordered_object({
                { "id", term.id },
                { "state", term.state },
                { "title", term.title },
                { "title_source", term.title_source or vim.NIL },
                { "cwd", term.cwd },
                { "session_id", term.session_id or vim.NIL },
                { "transcript_path", term.transcript_path or vim.NIL },
                -- The model requested when the terminal was started (not confirmed by Claude Code)
                { "model", term.model or vim.NIL },
                { "spawned_by", term.spawned_by or vim.NIL },
                { "orchestration", term.orchestration == true },
                {
                    "last_request",
                    request
                            and {
                                raw = ordered_object({
                                    { "id", request.id },
                                    { "from", request.from or vim.NIL },
                                    { "received", request.received },
                                    { "completed", request.completed },
                                    { "lost", request.lost or false },
                                    { "sent_at", request.sent_at },
                                }),
                            }
                        or vim.NIL,
                },
            })
        )
    end
    local self = tonumber(self_id)
    return '{"self":'
        .. vim.json.encode((self and self > 0) and self or vim.NIL)
        .. ',"terminals":['
        .. table.concat(terminals, ",")
        .. "]}"
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
        table.insert(lines, "\torchestration: " .. (term.orchestration and "on" or "off"))
    end
    return #lines > 0 and table.concat(lines, "\n") or "No terminals"
end

-- `ct orchestrate on|off|status`: sets or shows the orchestration flag of terminal `id`
function M.orchestrate(id, mode)
    local term = state.get(id)
    if not term then
        return "ct: no terminal #" .. tostring(id)
    end
    if mode == "on" then
        term.orchestration = true
    elseif mode == "off" then
        term.orchestration = false
    elseif mode ~= "status" then
        return "ct: usage: ct orchestrate on|off|status"
    end
    return "orchestration: " .. (term.orchestration and "on" or "off")
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

local function new_request(term, caller, text)
    local request = {
        id = "r" .. state.next_request,
        from = caller and caller.id or nil,
        text = text,
        sent_at = os.time(),
        received = false,
        completed = false,
        lost = false,
    }
    state.next_request = state.next_request + 1
    term.requests = term.requests or {}
    table.insert(term.requests, request)
    term.last_request = request
    return request
end

-- Starts a new terminal for `ct spawn` / spawn(). `caller`: the terminal that asks (or nil).
-- opts: { prompt, cwd (relative to opts.base, default: the caller's cwd), base, model, title,
-- show, orchestration }. Returns the terminal, or nil and a "ct: …" message. Nothing is created on an error.
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

    -- CRLF (e.g. a prompt file) becomes LF, as for `ct send`
    prompt = prompt:gsub("\r\n", "\n")

    local caller_win = caller and vim.fn.bufwinid(caller.buf)
    local ok, term = pcall(require("claude-deck.terminal").start_detached, cwd, {
        model = model,
        prompt = prompt,
        show = opts.show,
        caller_win = (caller_win and caller_win > 0) and caller_win or nil,
        orchestration = opts.orchestration,
    })
    if not ok then
        return nil, "ct: " .. tostring(term)
    end
    term.spawned = true
    term.spawned_by = caller and caller.id or nil
    -- The first prompt is a request too, so that `ct wait` can follow the first turn
    new_request(term, caller, prompt)
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
        prompt = prompt:gsub("[\r\n]+$", "")
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

-- Delivers a task to terminal `id` for `ct send` / send(): one bracketed paste, then (after the
-- TUI has processed it) a carriage return to submit. `caller`: the terminal that asks (or nil).
-- Returns the request id, or nil and a "ct: …" message. Success means only that the input was
-- written; whether Claude took it up is seen from the hooks (term.last_request.received).
function M.send_term(caller, id, prompt)
    local term = state.get(id)
    if not term then
        return nil, "ct: no terminal #" .. tostring(id)
    end
    if caller and caller.id == term.id then
        return nil, "ct: cannot send to yourself"
    end
    if term.state ~= "idle" and term.state ~= "waiting" then
        return nil,
            string.format(
                "ct: terminal #%d is %s (send only to idle or waiting terminals)",
                term.id,
                term.state
            )
    end
    local running = term.job and vim.fn.jobwait({ term.job }, 0)[1] == -1
    if not running or not vim.api.nvim_buf_is_valid(term.buf) then
        return nil, string.format("ct: terminal #%d is not running", term.id)
    end
    -- The TUI may not be ready before the SessionStart hook has arrived
    if not term.session_id then
        return nil, string.format("ct: terminal #%d is still starting", term.id)
    end
    -- Two pastes must not land in one input
    local last = term.last_request
    if last and not last.received and not last.lost then
        return nil, string.format("ct: terminal #%d has a pending request %s (not received yet)", term.id, last.id)
    end
    if type(prompt) ~= "string" or vim.trim(prompt) == "" then
        return nil, "ct: no prompt given (use --prompt or --prompt-file)"
    end
    if prompt:find("\0", 1, true) then
        return nil, "ct: the prompt contains a NUL byte"
    end

    -- The end marker of a paste inside the text would end the paste early; CRLF becomes LF
    local text = prompt:gsub("\27%[201~", "")
    text = text:gsub("\r\n", "\n")
    local request = new_request(term, caller, text)

    local win = vim.fn.bufwinid(term.buf)
    if win > 0 then
        require("claude-deck.terminal").fit_pty(win)
    end
    local buf = term.buf
    -- Scheduled so that the pty size is updated first (as in location.lua)
    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local channel = vim.bo[buf].channel
        if not pcall(vim.api.nvim_chan_send, channel, "\27[200~" .. text .. "\27[201~") then
            return
        end
        vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(buf) then
                pcall(vim.api.nvim_chan_send, vim.bo[buf].channel, "\r")
            end
        end, 50)
    end)
    return request.id
end

-- `ct send <id> (--prompt <text> | --prompt-file <path>)`: `args` after the id, as a list;
-- relative paths are relative to `pwd`. Returns {"id": 3, "request": "r1"} as one line.
function M.send(self_id, target, args, pwd)
    local caller = state.get(self_id)
    if not caller then
        return "ct: no terminal #" .. tostring(self_id)
    end

    local opts, i = {}, 1
    while i <= #args do
        local arg = args[i]
        local name, value = arg:match("^(%-%-[%w-]+)=(.*)$")
        name = name or arg
        if name == "--prompt" or name == "--prompt-file" then
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
        prompt = vim.fn.isdirectory(path) == 0 and read_file(path) or nil
        if not prompt then
            return "ct: cannot read the prompt file: " .. opts.prompt_file
        end
        prompt = prompt:gsub("[\r\n]+$", "")
    end

    local request, err = M.send_term(caller, target, prompt)
    if not request then
        return err
    end
    return ordered_object({ { "id", state.get(target).id }, { "request", request } })
end

-- One entry per distinct id: { id, status, request, state }. status: "missing", "exited",
-- "done" (the last request has been received and its turn has ended), "lost" (a turn ended
-- without the request having been received), "attention", "none" (no request, and the terminal
-- is not running: counts as finished) or "pending".
local function wait_entries(ids)
    local entries, seen = {}, {}
    for _, id in ipairs(ids) do
        id = tonumber(id)
        if id and not seen[id] then
            seen[id] = true
            local term = state.get(id)
            local request = term and term.last_request
            local status
            if not term then
                status = "missing"
            elseif term.state == "exited" then
                status = "exited"
            elseif request and request.completed then
                status = "done"
            elseif request and request.lost then
                status = "lost"
            elseif term.state == "attention" then
                status = "attention"
            elseif not request then
                -- Finished only when not working (a running terminal without a request is busy)
                status = term.state == "running" and "pending" or "none"
            else
                status = "pending"
            end
            table.insert(entries, {
                id = id,
                status = status,
                request = request and request.id or nil,
                state = term and term.state or nil,
            })
        end
    end
    return entries
end

-- `ct wait`, polled by bin/ct: one line per id, "<id> <status> [<request>] [<state>]"
-- (pending lines end with the state; the status words are those of wait_entries()). The wait
-- itself is a loop in the shell so that Neovim is never blocked.
function M.wait_status(ids)
    local lines = {}
    for _, entry in ipairs(wait_entries(ids)) do
        local parts = { entry.id, entry.status }
        if entry.request then
            table.insert(parts, entry.request)
        end
        if entry.status == "pending" then
            table.insert(parts, entry.state)
        end
        table.insert(lines, table.concat(parts, " "))
    end
    return table.concat(lines, "\n")
end

-- The final output of `ct wait`: {"timed_out": false, "terminals": {"3": {"status", "request", "state"}}}
function M.wait_result(ids, timed_out)
    local terminals = {}
    for _, entry in ipairs(wait_entries(ids)) do
        table.insert(terminals, {
            tostring(entry.id),
            {
                raw = ordered_object({
                    { "status", entry.status },
                    { "request", entry.request or vim.NIL },
                    { "state", entry.state or vim.NIL },
                }),
            },
        })
    end
    return ordered_object({
        { "timed_out", timed_out and true or false },
        { "terminals", { raw = ordered_object(terminals) } },
    })
end

return M
