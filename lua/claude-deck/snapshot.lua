-- Crash-safe record of the terminals, so that `restore()` can resume their Claude Code sessions
-- after Neovim died. One file per Neovim instance; the terminals themselves live only in memory.
local config = require("claude-deck.config")

local M = {}

-- Minimum interval between two writes. A hook burst changes the state many times in a row.
local DEBOUNCE_MS = 500

local identity
local timer_pending = false
local closing = false

function M.dir()
    return vim.fn.stdpath("state") .. "/claude-deck"
end

-- Fixed for the life of this Neovim, so that every write updates the same file
local function self_identity()
    if not identity then
        local pid = vim.fn.getpid()
        identity = {
            pid = pid,
            cwd = vim.fn.getcwd(),
            name = string.format("%s-%d.json", os.date("%Y%m%d-%H%M%S"), pid),
        }
    end
    return identity
end

function M.file()
    return M.dir() .. "/" .. self_identity().name
end

-- Snapshot files, newest first. The name starts with the start time, so the name order is the
-- start order even when mtimes are touched.
function M.files()
    local names = {}
    local handle = vim.uv.fs_scandir(M.dir())
    while handle do
        local name = vim.uv.fs_scandir_next(handle)
        if not name then
            break
        end
        if name:match("^%d+%-%d+%-%d+%.json$") then
            table.insert(names, name)
        end
    end
    table.sort(names, function(a, b)
        return a > b
    end)
    return vim.tbl_map(function(name)
        return M.dir() .. "/" .. name
    end, names)
end

local function encode(clean_exit)
    local state = require("claude-deck.state")
    local object = require("claude-deck.cli").ordered_object
    local terminals = {}
    for _, term in ipairs(state.sorted()) do
        table.insert(
            terminals,
            object({
                { "id", term.id },
                { "cwd", term.cwd },
                { "title", term.title },
                { "title_source", term.title_source or vim.NIL },
                { "state", term.state },
                { "session_id", term.session_id or vim.NIL },
                { "model", term.model or vim.NIL },
                { "permission_mode", term.permission_mode or vim.NIL },
                { "orchestration", term.orchestration == true },
                { "spawned_by", term.spawned_by or vim.NIL },
                { "resumed_from", term.resumed_from or vim.NIL },
            })
        )
    end
    local id = self_identity()
    local fields = {
        { "version", 1 },
        { "saved_at", os.time() },
        { "pid", id.pid },
        { "cwd", id.cwd },
    }
    if clean_exit then
        table.insert(fields, { "clean_exit", true })
    end
    table.insert(fields, { "terminals", { raw = "[" .. table.concat(terminals, ",") .. "]" } })
    return object(fields)
end

-- 0 means no limit
local function prune()
    local options = config.options.snapshot
    local own = M.file()
    local cutoff = options.keep_days > 0 and os.time() - options.keep_days * 86400 or nil
    local kept = 0
    for _, path in ipairs(M.files()) do
        if path == own then
            kept = kept + 1
        else
            local stat = vim.uv.fs_stat(path)
            local too_old = cutoff and stat and stat.mtime.sec < cutoff
            local too_many = options.keep > 0 and kept >= options.keep
            if too_old or too_many then
                os.remove(path)
            else
                kept = kept + 1
            end
        end
    end
end

function M.write(clean_exit)
    if not config.options.snapshot.enabled then
        return
    end
    local ok = pcall(function()
        vim.fn.mkdir(M.dir(), "p")
        local path = M.file()
        local tmp = path .. ".tmp"
        local file = assert(io.open(tmp, "wb"))
        file:write(encode(clean_exit))
        file:close()
        assert(os.rename(tmp, path))
        prune()
    end)
    return ok
end

function M.schedule()
    if closing or timer_pending or not config.options.snapshot.enabled then
        return
    end
    timer_pending = true
    -- defer_fn runs its callback in the main loop, where Vim functions are allowed
    vim.defer_fn(function()
        timer_pending = false
        if not closing then
            M.write()
        end
    end, DEBOUNCE_MS)
end

-- VimLeavePre. Not written when nothing was ever recorded, so that an instance that never
-- used a terminal leaves no file.
function M.leave()
    closing = true
    if identity and vim.uv.fs_stat(M.file()) then
        M.write(true)
    end
end

return M
