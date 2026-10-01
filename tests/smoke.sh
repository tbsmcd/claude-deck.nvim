#!/bin/sh
# Headless smoke test. Starts Neovim with tests/minimal_init.lua and drives it over RPC.
#   sh tests/smoke.sh
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)

TEST_OUT=$(mktemp -d)
export TEST_OUT
SOCK="$TEST_OUT/nvim.sock"
# Make notification behaviour deterministic (no frontmost-app check)
unset __CFBundleIdentifier

nvim --headless --clean -u tests/minimal_init.lua --listen "$SOCK" >/dev/null 2>&1 &
NVIM_PID=$!
trap 'kill $NVIM_PID 2>/dev/null; rm -rf "$TEST_OUT"' EXIT

i=0
while [ ! -S "$SOCK" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done

failures=0
lua() {
    # Evaluate a Lua expression in the test Neovim and print the result
    printf 'return %s' "$1" >"$TEST_OUT/expr.lua"
    nvim --server "$SOCK" --remote-expr "v:lua.T_run('$TEST_OUT/expr.lua')"
}
check() { # name, actual, expected substring
    case "$2" in
    *"$3"*) echo "ok   - $1" ;;
    *)
        echo "FAIL - $1"
        echo "       expected to contain: $3"
        echo "       actual: $2"
        failures=$((failures + 1))
        ;;
    esac
}
hook() { # id, event, json
    printf '%s' "$3" | NVIM="$SOCK" CLAUDE_TERMINALS_ID="$1" bin/claude-terminals-hook "$2"
    sleep 0.3
}

# Opening in an empty buffer reuses the window
check "toggle opens in place" "$(lua '(function() require("claude-terminals").toggle(); vim.cmd("stopinsert"); return #vim.api.nvim_list_wins() .. " " .. vim.b.claude_terminal_id end)()')" "1 1"
sleep 0.5
check "claude gets --settings with hooks" "$(cat "$TEST_OUT/args.1")" "claude-terminals-hook"
check "claude gets the system prompt" "$(cat "$TEST_OUT/args.1")" "ct list"

# Hook events update the winbar
hook 1 SessionStart '{"cwd":"'"$ROOT"'","session_id":"sess-1","transcript_path":"'"$ROOT"'/tests/fixtures/transcript.jsonl"}'
hook 1 UserPromptSubmit '{"prompt":"Refactor   the parser module and add tests for it"}'
check "running state in winbar" "$(lua 'T_winbar()')" "#1 Running │ Refactor the parser modu…"
hook 1 Notification '{"notification_type":"permission_prompt","message":"Claude needs your permission"}'
check "attention state in winbar" "$(lua 'T_winbar()')" "Needs you"
check "no notification for the watched terminal" "$(lua '#_G.notifications')" "0"
hook 1 Notification '{"notification_type":"idle_prompt"}'
check "idle_prompt keeps the state" "$(lua 'T_winbar()')" "Needs you"

# A second terminal below; terminal #1 is no longer watched
lua '(function() require("claude-terminals").new("below"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
check "new below splits" "$(lua 'vim.json.encode(vim.fn.winlayout()[1])')" "col"
hook 1 Stop '{}'
check "notification for an unwatched terminal" "$(lua 'table.concat(_G.notifications, ";")')" "Claude: Waiting | Refactor the parser"

# ct list / ct read
check "ct list" "$(NVIM="$SOCK" CLAUDE_TERMINALS_ID=2 bin/ct list)" "#2 (you)"
check "ct read" "$(NVIM="$SOCK" bin/ct read '#1' 2)" "## Claude"
check "ct read unknown id fails" "$(NVIM="$SOCK" bin/ct read 9; echo "exit=$?")" "exit=1"

# Fork opens to the right with --resume
lua '(function() vim.cmd("wincmd k"); require("claude-terminals").fork(); vim.cmd("stopinsert"); return "" end)()' >/dev/null
sleep 0.5
check "fork resumes the session" "$(tr '\n' ' ' <"$TEST_OUT/args.3")" "--resume sess-1 --fork-session"
check "fork title" "$(lua 'T_winbar()')" "↳Refactor"

# Focus mode opens a tab and returns
check "focus opens a tab in the terminal cwd" "$(lua '(function() vim.cmd("wincmd h"); require("claude-terminals").focus(); return #vim.api.nvim_list_tabpages() .. " " .. vim.fn.getcwd() end)()')" "2 $ROOT"
check "focus closes and returns" "$(lua '(function() require("claude-terminals").focus(); return #vim.api.nvim_list_tabpages() .. " " .. vim.b.claude_terminal_id end)()')" "1 1"

# :q hides a terminal; list can bring it back below
lua '(function() vim.cmd("q"); return "" end)()' >/dev/null
check "hidden terminal still listed" "$(NVIM="$SOCK" bin/ct list)" "#1"
check "list shows hidden terminal below" "$(lua '(function() require("claude-terminals").list(); T_pick("ctrl-s", 1); return vim.b.claude_terminal_id end)()')" "1"

# Directory picker
check "dir picker candidates" "$(lua '(function() require("claude-terminals").pick_dir(); return table.concat(_G.last_picker.lines, ";") end)()')" "fixtures/roots/project-a"
check "dir picker opens in the chosen dir" "$(lua '(function() for i, l in ipairs(_G.last_picker.lines) do if l:find("project%-a") then T_pick("ctrl-v", i) end end; vim.cmd("stopinsert"); return require("claude-terminals.state").current().cwd end)()')" "fixtures/roots/project-a"

# Without --settings
lua '(function() require("claude-terminals").setup(vim.tbl_extend("force", T_opts, { claude_settings = false })); require("claude-terminals").new("below"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
sleep 0.5
args=$(cat "$TEST_OUT/args.$(lua 'vim.b.claude_terminal_id')")
case "$args" in
*--settings*) echo "FAIL - claude_settings = false omits --settings"; failures=$((failures + 1)) ;;
*) echo "ok   - claude_settings = false omits --settings" ;;
esac
check "claude_settings = false keeps the system prompt" "$args" "ct list"
check "settings command shows the hooks" "$(lua '(function() require("claude-terminals").show_settings(); return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end)()')" "claude-terminals-hook"

# User command
check "user command completion" "$(lua 'table.concat(vim.fn.getcompletion("ClaudeTerminals f", "cmdline"), ",")')" "focus,fork"

messages=$(lua 'vim.api.nvim_exec2("messages", { output = true }).output')
case "$messages" in
*rror* | *E[0-9]*) echo "FAIL - no errors in :messages"; echo "$messages"; failures=$((failures + 1)) ;;
*) echo "ok   - no errors in :messages" ;;
esac

if [ "$failures" -gt 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "all tests passed"
