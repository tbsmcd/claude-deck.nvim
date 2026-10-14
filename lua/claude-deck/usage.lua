-- Token usage of a terminal, summed up from the Claude Code transcript (JSONL).
-- The transcript format is internal to Claude Code and may change.
local M = {}

-- terminal id -> { path, size, mtime, offset, result }
local cache = {}

local FIELDS = { "input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens" }

local function count(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0 and value or 0
end

local function new_entry(path)
    local result = { turns = 0 }
    for _, field in ipairs(FIELDS) do
        result[field] = 0
    end
    result.context_tokens = 0
    return { path = path, offset = 0, result = result }
end

local function add_line(result, line)
    local ok, entry = pcall(vim.json.decode, line)
    if not ok or type(entry) ~= "table" or entry.type ~= "assistant" or entry.isSidechain == true then
        return
    end
    local message = entry.message
    if type(message) ~= "table" then
        return
    end
    local usage = type(message.usage) == "table" and message.usage or {}
    result.turns = result.turns + 1
    for _, field in ipairs(FIELDS) do
        result[field] = result[field] + count(usage[field])
    end
    if type(message.model) == "string" then
        result.model = message.model
    end
    result.context_tokens = count(usage.input_tokens)
        + count(usage.cache_read_input_tokens)
        + count(usage.cache_creation_input_tokens)
end

local function snapshot(result)
    return {
        model = result.model,
        turns = result.turns,
        input_tokens = result.input_tokens,
        output_tokens = result.output_tokens,
        cache_read_input_tokens = result.cache_read_input_tokens,
        cache_creation_input_tokens = result.cache_creation_input_tokens,
        context_tokens = result.context_tokens,
    }
end

-- Usage of `term`, or nil when `cli.usage` is off or there is no readable transcript. Only the
-- bytes appended since the last call are read.
function M.get(term)
    if not require("claude-deck.config").options.cli.usage then
        return nil
    end
    local path = term.transcript_path
    if type(path) ~= "string" then
        cache[term.id] = nil
        return nil
    end
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
        cache[term.id] = nil
        return nil
    end
    local entry = cache[term.id]
    if not entry or entry.path ~= path or stat.size < entry.offset then
        entry = new_entry(path)
        cache[term.id] = entry
    end
    if stat.size > entry.offset then
        local file = io.open(path, "rb")
        if not file then
            cache[term.id] = nil
            return nil
        end
        file:seek("set", entry.offset)
        local data = file:read(stat.size - entry.offset) or ""
        file:close()
        -- Only complete lines; a partial last line is read again next time
        local last = data:match(".*()\n")
        if last then
            for line in data:sub(1, last):gmatch("[^\n]+") do
                add_line(entry.result, line)
            end
            entry.offset = entry.offset + last
        end
    end
    return snapshot(entry.result)
end

function M.forget(id)
    cache[id] = nil
end

return M
