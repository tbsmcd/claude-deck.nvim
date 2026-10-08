-- Backend of the `ct` command (bin/ct), called via `nvim --remote-expr`.
local state = require("claude-deck.state")

local M = {}

local MAX_MESSAGE_LENGTH = 2000
-- Max display width (cells) of a title given with `ct title`. Longer titles are refused, not
-- cut, so that Claude picks a shorter one.
local MAX_TITLE_WIDTH = 40

function M.list(self_id)
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

return M
