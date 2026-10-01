-- Backend of the `ct` command (bin/ct), called via `nvim --remote-expr`.
local state = require("claude-terminals.state")

local M = {}

local MAX_MESSAGE_LENGTH = 2000

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

return M
