-- `ct diff`: the diff of the pull request (`gh pr diff`) or of the working tree (`git diff`) in
-- a read-only diff buffer in the editor window of focus mode.
local state = require("claude-deck.state")

local M = {}

-- Seconds to wait for gh / git
local TIMEOUT = 30000

local function run(cmd, cwd)
    local ok, proc = pcall(vim.system, cmd, { cwd = cwd, text = true })
    if not ok then
        return nil, tostring(proc)
    end
    local result = proc:wait(TIMEOUT)
    if result.code ~= 0 then
        local err = vim.trim(result.stderr or "")
        if result.signal and result.signal ~= 0 and err == "" then
            err = "timed out"
        end
        return nil, err ~= "" and err or ("exit status " .. tostring(result.code))
    end
    return result.stdout or ""
end

-- Parses `ct diff` arguments: a path[:line] and `--base <ref>`. Returns a table or nil and an
-- error message.
function M.parse_args(args)
    local opts = {}
    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg == "--base" then
            local ref = args[i + 1]
            if not ref or ref == "" then
                return nil, "ct: --base needs a ref"
            end
            opts.base = ref
            i = i + 2
        elseif vim.startswith(arg, "--base=") then
            opts.base = arg:sub(8)
            if opts.base == "" then
                return nil, "ct: --base needs a ref"
            end
            i = i + 1
        elseif arg == "--" then
            i = i + 1
        elseif vim.startswith(arg, "-") and arg ~= "-" then
            return nil, "ct: unknown option " .. arg
        else
            if opts.path then
                return nil, "ct: only one path can be given"
            end
            opts.path = arg
            i = i + 1
        end
    end
    return opts
end

-- Parses unified diff lines into files:
-- { path (new side, or the old one for a deleted file), old_path, new_path, line (buffer line
--   of "diff --git"), deleted, hunks = { { line, new_start, new_count } } }
function M.parse(lines)
    local files = {}
    local file
    for lnum, line in ipairs(lines) do
        if vim.startswith(line, "diff ") then
            file = { line = lnum, hunks = {} }
            table.insert(files, file)
        elseif file then
            local path = line:match("^%-%-%- a/(.*)$") or line:match("^%-%-%- (.*)$")
            if path and #file.hunks == 0 then
                path = path:gsub("\t$", "")
                file.old_path = path ~= "/dev/null" and path or nil
            else
                path = line:match("^%+%+%+ b/(.*)$") or line:match("^%+%+%+ (.*)$")
                if path and #file.hunks == 0 then
                    path = path:gsub("\t$", "")
                    file.new_path = path ~= "/dev/null" and path or nil
                else
                    local new_start, new_count = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
                    if new_start then
                        table.insert(file.hunks, {
                            line = lnum,
                            new_start = tonumber(new_start),
                            new_count = new_count ~= "" and tonumber(new_count) or 1,
                        })
                    end
                end
            end
        end
    end
    for _, f in ipairs(files) do
        if not f.new_path and not f.old_path then
            -- A header without ---/+++ (e.g. a binary file or a mode change): take the path
            -- from "diff --git a/x b/y"
            f.new_path = lines[f.line]:match("^diff %-%-git a/.- b/(.*)$")
        end
        f.deleted = f.new_path == nil and f.old_path ~= nil
        f.path = f.new_path or f.old_path
    end
    return files
end

-- Buffer line of line `new_line` (new side) in `file`, or the nearest hunk header
local function buffer_line(lines, file, new_line)
    if not new_line or #file.hunks == 0 then
        return file.line
    end
    local nearest = file.hunks[1].line
    for _, hunk in ipairs(file.hunks) do
        if new_line >= hunk.new_start then
            nearest = hunk.line
        end
        local counter = hunk.new_start
        for lnum = hunk.line + 1, #lines do
            local c = lines[lnum]:sub(1, 1)
            if c == "@" or c == "d" or (c ~= " " and c ~= "+" and c ~= "-" and c ~= "\\" and c ~= "") then
                break
            end
            if c == " " or c == "+" or c == "" then
                if counter == new_line then
                    return lnum
                end
                counter = counter + 1
            end
        end
    end
    return nearest
end

-- Path and line (new side) at buffer line `lnum` of a parsed diff: the file whose section holds
-- the line, and the line counted from the enclosing hunk (a removed line gives the line that
-- follows it). nil when `lnum` is before the first file.
function M.location_at(lines, files, lnum)
    local file
    for _, f in ipairs(files) do
        if f.line <= lnum then
            file = f
        end
    end
    if not file then
        return nil
    end
    local hunk
    for _, h in ipairs(file.hunks) do
        if h.line <= lnum then
            hunk = h
        end
    end
    if not hunk then
        return file, nil
    end
    local counter = hunk.new_start
    for l = hunk.line + 1, lnum do
        local c = lines[l]:sub(1, 1)
        if c == " " or c == "+" or c == "" then
            if l == lnum then
                return file, counter
            end
            counter = counter + 1
        end
    end
    return file, counter
end

-- Repository root of `cwd`, or nil and a "ct: …" message
local function repo_root(cwd)
    local out, err = run({ "git", "rev-parse", "--show-toplevel" }, cwd)
    if not out then
        if err:find("not a git repository", 1, true) then
            return nil, "ct: not a git repository: " .. cwd
        end
        return nil, "ct: git: " .. err
    end
    return vim.trim(out)
end

-- The diff text and a description of its source. opts.base: compare the working tree with
-- this ref (git diff <ref>) instead of looking for a pull request.
-- Returns { text, title, source } or nil and a "ct: …" message.
function M.fetch(root, opts)
    if opts.base then
        local out, err = run({ "git", "diff", opts.base }, root)
        if not out then
            return nil, "ct: git diff " .. opts.base .. ": " .. err
        end
        return { text = out, title = "git diff " .. opts.base, source = "git" }
    end

    if vim.fn.executable("gh") == 1 then
        local json = run({ "gh", "pr", "view", "--json", "number,title,baseRefName" }, root)
        if json then
            local ok, pr = pcall(vim.json.decode, json)
            if ok and type(pr) == "table" and pr.number then
                local out, err = run({ "gh", "pr", "diff" }, root)
                if not out then
                    return nil, "ct: gh pr diff: " .. err
                end
                return {
                    text = out,
                    title = string.format("PR #%d %s (base: %s)", pr.number, pr.title or "", pr.baseRefName or "?"),
                    source = "pr",
                    pr = pr,
                }
            end
        end
    end

    local out, err = run({ "git", "diff", "HEAD" }, root)
    if not out then
        return nil, "ct: git diff HEAD: " .. err
    end
    return { text = out, title = "git diff HEAD (uncommitted changes)", source = "git" }
end

-- Buffer name of the diff buffer of terminal `id`
local function buffer_name(id)
    return "claude-deck://diff/" .. id
end

local function set_lines(buf, lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
end

-- Info of the diff buffer `buf` (0: current), or nil when it is not one
function M.info(buf)
    if not buf or buf == 0 then
        buf = vim.api.nvim_get_current_buf()
    end
    local ok, info = pcall(vim.api.nvim_buf_get_var, buf, "claude_deck_diff")
    return ok and info or nil
end

-- Path and line (new side) at buffer line `lnum` of the diff buffer in `win`, as an absolute
-- path (the file may not exist for a deleted file). Returns nil when the line is above the
-- first file.
function M.location_at_line(win, lnum)
    local buf = vim.api.nvim_win_get_buf(win)
    local info = M.info(buf)
    if not info then
        return nil
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local file, line = M.location_at(lines, M.parse(lines), lnum)
    if not file then
        return nil
    end
    return info.root .. "/" .. file.path, line, file
end

-- The same for the cursor line of `win` (default: the current window)
function M.location_in(win)
    win = win or vim.api.nvim_get_current_win()
    return M.location_at_line(win, vim.api.nvim_win_get_cursor(win)[1])
end

-- A window of the current tab to open a file from the diff buffer in: one already showing a
-- normal buffer other than the diff, else a new one right of the diff window.
function M.file_window(diff_win)
    local focus = require("claude-deck.focus")
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win ~= diff_win and focus.is_editor_window(win) then
            return win
        end
    end
    vim.api.nvim_set_current_win(diff_win)
    vim.cmd("rightbelow vsplit")
    return vim.api.nvim_get_current_win()
end

-- <CR> in the diff buffer: opens the file under the cursor at that line in a window right of the
-- diff (keeping the diff buffer).
function M.open_at_cursor()
    local diff_win = vim.api.nvim_get_current_win()
    local path, line, file = M.location_in(diff_win)
    if not path then
        vim.notify("claude-deck: move to a file section first", vim.log.levels.WARN)
        return
    end
    if file.deleted or not vim.uv.fs_stat(path) then
        vim.notify("claude-deck: " .. file.path .. " does not exist in the working tree", vim.log.levels.WARN)
        return
    end
    local win = M.file_window(diff_win)
    vim.api.nvim_set_current_win(win)
    local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
    if not ok then
        vim.notify("claude-deck: " .. tostring(err), vim.log.levels.ERROR)
        return
    end
    if line then
        line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(0)))
        vim.api.nvim_win_set_cursor(win, { line, 0 })
        vim.cmd("normal! zz")
    end
end

-- Moves to the next (`forward`) or previous file header or hunk (`what`: "file" | "hunk")
function M.jump(what, forward)
    local pattern = what == "file" and "^diff " or "^@@ "
    local lnum = vim.fn.line(".")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local from, to, step = lnum + 1, #lines, 1
    if not forward then
        from, to, step = lnum - 1, 1, -1
    end
    for l = from, to, step do
        if lines[l]:find(pattern) then
            vim.api.nvim_win_set_cursor(0, { l, 0 })
            vim.cmd("normal! zt")
            return
        end
    end
end

function M.close()
    local ok = pcall(vim.cmd, "close")
    if not ok then
        vim.cmd("enew")
    end
end

local function set_keymaps(buf)
    local function map(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = "claude-deck diff: " .. desc })
    end
    map("<CR>", M.open_at_cursor, "open the file at this line")
    map("]f", function()
        M.jump("file", true)
    end, "next file")
    map("[f", function()
        M.jump("file", false)
    end, "previous file")
    map("]c", function()
        M.jump("hunk", true)
    end, "next hunk")
    map("[c", function()
        M.jump("hunk", false)
    end, "previous hunk")
    map("q", M.close, "close")
end

-- The diff buffer of terminal `term` (made when needed), filled with `lines`
local function diff_buffer(term, lines, root)
    local name = buffer_name(term.id)
    local buf = vim.fn.bufnr(name)
    if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, name)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "hide"
        vim.bo[buf].swapfile = false
        vim.bo[buf].filetype = "diff"
        set_keymaps(buf)
    end
    set_lines(buf, lines)
    vim.b[buf].claude_deck_diff = { term_id = term.id, root = root }
    return buf
end

-- `path` (absolute, "~/…" or relative to `cwd`) relative to the repository `root`; nil when it
-- is outside the repository
local function repo_relative(path, cwd, root)
    if path == "~" or vim.startswith(path, "~/") then
        path = vim.env.HOME .. path:sub(2)
    elseif not vim.startswith(path, "/") then
        path = cwd .. "/" .. path
    end
    path = vim.fs.normalize(vim.fn.simplify(path))
    -- Also with symlinks resolved (a deleted file: those of its directory)
    local real = vim.uv.fs_realpath(path)
    if not real then
        local dir = vim.uv.fs_realpath(vim.fs.dirname(path))
        real = dir and (dir .. "/" .. vim.fs.basename(path)) or nil
    end
    local real_root = vim.uv.fs_realpath(root) or root
    for _, r in ipairs({ root, real_root }) do
        for _, candidate in ipairs({ path, real }) do
            if vim.startswith(candidate, r .. "/") then
                return candidate:sub(#r + 2)
            end
        end
    end
    return nil
end

-- Opens the diff for terminal `term` in the editor window of its focus mode (opening focus mode
-- when needed). opts: { path, line, base }; relative paths are relative to `cwd`. Returns a
-- one-line report ("ct: …" on failure).
function M.open(term, cwd, opts)
    opts = opts or {}
    local root, err = repo_root(cwd)
    if not root then
        return err
    end

    local rel
    if opts.path then
        rel = repo_relative(opts.path, cwd, root)
        if not rel then
            return "ct: not in the repository: " .. opts.path
        end
    end

    local result
    result, err = M.fetch(root, opts)
    if not result then
        return err
    end
    local lines = vim.split(result.text, "\n", { plain = true })
    if lines[#lines] == "" then
        table.remove(lines)
    end
    local files = M.parse(lines)
    if #files == 0 then
        return "ct: no changes (" .. result.title .. ")"
    end

    local target
    if rel then
        for _, f in ipairs(files) do
            if f.new_path == rel or f.old_path == rel then
                target = f
                break
            end
        end
        if not target then
            return string.format("ct: no changes in %s (%s)", rel, result.title)
        end
    end

    -- The header line shifts the parsed line numbers by one
    table.insert(lines, 1, "# " .. result.title)
    for _, f in ipairs(files) do
        f.line = f.line + 1
        for _, h in ipairs(f.hunks) do
            h.line = h.line + 1
        end
    end

    local focus = require("claude-deck.focus")
    local ok, win = pcall(focus.editor_window, term)
    if not ok then
        pcall(vim.cmd, "stopinsert")
        return "ct: " .. tostring(win)
    end
    local buf = diff_buffer(term, lines, root)
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_set_current_win(win)

    local lnum = target and buffer_line(lines, target, opts.line) or 1
    vim.api.nvim_win_set_cursor(win, { lnum, 0 })
    vim.cmd(target and "normal! zz" or "normal! zt")
    vim.cmd("stopinsert")

    local shown = string.format("%s, %d file%s", result.title, #files, #files == 1 and "" or "s")
    if target then
        shown = shown .. ", at " .. rel .. (opts.line and (":" .. opts.line) or "")
    end
    return "Opened the diff in the editor (" .. shown .. ")"
end

return M
