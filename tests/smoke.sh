#!/bin/sh
# Headless smoke test. Starts Neovim with tests/minimal_init.lua and drives it over RPC.
#   sh tests/smoke.sh
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd -P) # resolved like getcwd() (e.g. /var -> /private/var on macOS)
# The checkout directory name and its path as shown in the winbar (~ for $HOME)
ROOT_NAME=$(basename "$ROOT")
case "$ROOT" in
"$HOME"/*) ROOT_DISPLAY="~${ROOT#"$HOME"}" ;;
*) ROOT_DISPLAY=$ROOT ;;
esac

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
    printf '%s' "$3" | NVIM="$SOCK" CLAUDE_DECK_ID="$1" bin/claude-deck-hook "$2"
    sleep 0.3
}

# Opening in an empty buffer reuses the window
check "toggle opens in place" "$(lua '(function() require("claude-deck").toggle(); vim.cmd("stopinsert"); return #vim.api.nvim_list_wins() .. " " .. vim.b.claude_deck_id end)()')" "1 1"
sleep 0.5
check "claude gets --settings with hooks" "$(cat "$TEST_OUT/args.1")" "claude-deck-hook"
check "claude gets the system prompt" "$(cat "$TEST_OUT/args.1")" "ct list"

# Hook events update the winbar
hook 1 SessionStart '{"cwd":"'"$ROOT"'","session_id":"sess-1","transcript_path":"'"$ROOT"'/tests/fixtures/transcript.jsonl"}'
hook 1 UserPromptSubmit '{"prompt":"Refactor   the parser module and add tests for it"}'
check "running state in winbar" "$(lua 'T_winbar()')" "#1 Running │ Refactor the parser module and add tests for it"
check "statusline shows cwd and session" "$(lua 'T_statusline()')" "$ROOT_NAME"
check "statusline shows session id" "$(lua 'T_statusline()')" "session sess-1"
check "buffer is renamed" "$(lua 'vim.api.nvim_buf_get_name(0)')" "claude:#1 Refactor the parser"
check "no leftover term:// buffers" "$(lua '#vim.tbl_filter(function(b) return vim.api.nvim_buf_get_name(b):match("^term://") ~= nil end, vim.api.nvim_list_bufs())')" "0"
check "narrow window cuts the title" "$(lua '(function() vim.cmd("vsplit"); vim.api.nvim_win_set_width(0, 30); local s = T_winbar(); vim.cmd("close"); return s end)()')" "#1 Running │ Refactor the p…"
check "one-line mode right-aligns the cwd" "$(lua '(function() vim.o.columns = 200; vim.o.laststatus = 3; local s = T_winbar(); vim.o.laststatus = 2; vim.o.columns = 80; return s end)()')" "tests for it   "
check "one-line mode shows the full cwd" "$(lua '(function() vim.o.columns = 200; vim.o.laststatus = 3; local s = T_winbar(); vim.o.laststatus = 2; vim.o.columns = 80; return s end)()')" "$ROOT_DISPLAY"
check "one-line mode drops the cwd when narrow" "$(lua '(function() vim.o.laststatus = 3; local s = T_winbar(); vim.o.laststatus = 2; return s:find("repos", 1, true) and s or "no cwd" end)()')" "no cwd"
hook 1 Notification '{"notification_type":"permission_prompt","message":"Claude needs your permission"}'
check "attention state in winbar" "$(lua 'T_winbar()')" "Needs you"
check "no notification for the watched terminal" "$(lua '#_G.notifications')" "0"
hook 1 Notification '{"notification_type":"idle_prompt"}'
check "idle_prompt keeps the state" "$(lua 'T_winbar()')" "Needs you"

# A second terminal below; terminal #1 is no longer watched
lua '(function() require("claude-deck").new("below"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
check "new below splits" "$(lua 'vim.json.encode(vim.fn.winlayout()[1])')" "col"
hook 1 Stop '{}'
check "notification for an unwatched terminal" "$(lua 'table.concat(_G.notifications, ";")')" "Claude: Waiting | Refactor the parser"

# ct list / ct read
check "ct list" "$(NVIM="$SOCK" CLAUDE_DECK_ID=2 bin/ct list)" "#2 (you)"
check "ct read" "$(NVIM="$SOCK" bin/ct read '#1' 2)" "## Claude"
check "ct read unknown id fails" "$(NVIM="$SOCK" bin/ct read 9; echo "exit=$?")" "exit=1"

# Fork opens to the right with --resume
lua '(function() vim.cmd("wincmd k"); require("claude-deck").fork(); vim.cmd("stopinsert"); return "" end)()' >/dev/null
sleep 0.5
check "fork resumes the session" "$(tr '\n' ' ' <"$TEST_OUT/args.3")" "--resume sess-1 --fork-session"
check "fork title" "$(lua 'T_winbar()')" "↳Refactor"

# Focus mode opens a tab and returns
check "focus opens a tab in the terminal cwd" "$(lua '(function() vim.cmd("wincmd h"); require("claude-deck").focus(); return #vim.api.nvim_list_tabpages() .. " " .. vim.fn.getcwd() end)()')" "2 $ROOT"
check "focus closes and returns" "$(lua '(function() require("claude-deck").focus(); return #vim.api.nvim_list_tabpages() .. " " .. vim.b.claude_deck_id end)()')" "1 1"

# :q hides a terminal; list can bring it back below
lua '(function() vim.cmd("q"); return "" end)()' >/dev/null
check "hidden terminal still listed" "$(NVIM="$SOCK" bin/ct list)" "#1"
check "list shows hidden terminal below" "$(lua '(function() require("claude-deck").list(); T_pick("ctrl-s", 1); return vim.b.claude_deck_id end)()')" "1"

# Directory picker
check "dir picker candidates" "$(lua '(function() require("claude-deck").pick_dir(); return table.concat(_G.last_picker.lines, ";") end)()')" "fixtures/roots/project-a"
check "dir picker opens in the chosen dir" "$(lua '(function() for i, l in ipairs(_G.last_picker.lines) do if l:find("project%-a") then T_pick("ctrl-v", i) end end; vim.cmd("stopinsert"); return require("claude-deck.state").current().cwd end)()')" "fixtures/roots/project-a"

# Terminal-mode keymaps and auto insert
check "normal_mode keymap in terminals" "$(lua '(function() local m = vim.fn.maparg("<C-q>", "t", false, true); return tostring(m.buffer) .. " " .. m.rhs end)()')" "1 <C-\\><C-n>"
check "send_esc keymap in terminals" "$(lua '(function() local m = vim.fn.maparg("<C-]>", "t", false, true); return tostring(m.buffer) .. " " .. m.rhs end)()')" "1 <Esc>"
lua '(function() vim.cmd("stopinsert"); vim.cmd("wincmd w"); vim.cmd("wincmd w"); return "" end)()' >/dev/null
sleep 0.2
check "auto insert when entering a terminal" "$(lua 'vim.api.nvim_get_mode().mode .. " " .. tostring(vim.b.claude_deck_id ~= nil)')" "t true"

# Splitting a terminal keeps the editor width (even with 'equalalways')
check "split keeps other windows" "$(lua '(function() vim.cmd("stopinsert | tabnew"); vim.o.columns = 200; vim.o.equalalways = true; vim.cmd("edit " .. vim.fn.tempname()); local editor = vim.api.nvim_get_current_win(); require("claude-deck").new(); vim.cmd("stopinsert"); local before = vim.api.nvim_win_get_width(editor); require("claude-deck").new("right"); vim.cmd("stopinsert"); return before .. " " .. vim.api.nvim_win_get_width(editor) .. " " .. tostring(vim.o.equalalways) end)()')" "119 119 true"
lua '(function() vim.cmd("tabclose!"); return "" end)()' >/dev/null

# Without --settings
lua '(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, { claude_settings = false })); require("claude-deck").new("below"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
sleep 0.5
args=$(cat "$TEST_OUT/args.$(lua 'vim.b.claude_deck_id')")
case "$args" in
*--settings*) echo "FAIL - claude_settings = false omits --settings"; failures=$((failures + 1)) ;;
*) echo "ok   - claude_settings = false omits --settings" ;;
esac
check "claude_settings = false keeps the system prompt" "$args" "ct list"
check "settings command shows the hooks" "$(lua '(function() require("claude-deck").show_settings(); return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end)()')" "claude-deck-hook"

# Terminal window style is window-local; windows split from a terminal get the user's values back
check "terminal style keeps the global options" "$(lua '(function() local origin = vim.api.nvim_get_current_win(); vim.go.number = true; require("claude-deck").new("below"); vim.cmd("stopinsert"); local term, global = vim.wo.number, vim.go.number; vim.cmd("new"); local split = vim.wo.number; vim.cmd("close | close"); vim.api.nvim_set_current_win(origin); vim.go.number = false; return tostring(term) .. " " .. tostring(global) .. " " .. tostring(split) end)()')" "false true true"

# :q on the last window hides a running terminal instead of quitting Neovim
check ":q with other windows only closes the terminal window" "$(lua '(function() vim.cmd("only"); require("claude-deck").show(1); vim.cmd("stopinsert"); local before = #vim.api.nvim_list_wins(); vim.cmd("q"); return before .. " " .. #vim.api.nvim_list_wins() .. " " .. tostring(vim.b.claude_deck_id) end)()')" "2 1 nil"
check ":q on the last window keeps Neovim running" "$(lua '(function() require("claude-deck").show(1); vim.cmd("stopinsert | only"); vim.cmd("q"); local t = require("claude-deck.state").get(1); return #vim.api.nvim_list_wins() .. " [" .. vim.api.nvim_buf_get_name(0) .. "] [" .. vim.wo.winbar .. "] " .. vim.fn.jobwait({ t.job }, 0)[1] end)()')" "1 [] [] -1"
sleep 0.2
check ":q on the last window tells how many are running" "$(lua 'vim.api.nvim_exec2("messages", { output = true }).output')" "terminals still running (:qa to quit Neovim)"

check ":q next to a help window keeps Neovim running" "$(lua '(function() require("claude-deck").show(1); vim.cmd("stopinsert | only | help | wincmd p"); vim.cmd("q"); local s = #vim.api.nvim_list_wins() .. " [" .. vim.api.nvim_buf_get_name(0) .. "]"; vim.cmd("helpclose"); return s end)()')" "2 []"
check "empty buffers are reused" "$(lua '(function() local before = #vim.api.nvim_list_bufs(); require("claude-deck").show(1); vim.cmd("stopinsert | only"); vim.cmd("q"); return tostring(before == #vim.api.nvim_list_bufs()) end)()')" "true"
check "keep_alive_on_quit = false opens no window" "$(lua '(function() local o = require("claude-deck.config").options; require("claude-deck").show(1); vim.cmd("stopinsert | only"); o.keep_alive_on_quit = false; vim.api.nvim_exec_autocmds("QuitPre", {}); local off = #vim.api.nvim_list_wins(); o.keep_alive_on_quit = true; vim.api.nvim_exec_autocmds("QuitPre", {}); return off .. " " .. #vim.api.nvim_list_wins() end)()')" "1 2"
sleep 0.2
check "a failed quit removes the empty window" "$(lua '#vim.api.nvim_list_wins() .. " " .. tostring(vim.b.claude_deck_id)')" "1 1"

# User command
check "user command completion" "$(lua 'table.concat(vim.fn.getcompletion("ClaudeDeck f", "cmdline"), ",")')" "focus,fork"

messages=$(lua 'vim.api.nvim_exec2("messages", { output = true }).output')
case "$messages" in
*rror* | *E[0-9]*) echo "FAIL - no errors in :messages"; echo "$messages"; failures=$((failures + 1)) ;;
*) echo "ok   - no errors in :messages" ;;
esac

# :qa still quits Neovim (last: the test Neovim exits here)
nvim --server "$SOCK" --remote-send '<C-\><C-n>:qa<CR>' >/dev/null 2>&1
i=0
while kill -0 $NVIM_PID 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 $NVIM_PID 2>/dev/null; then
    echo "FAIL - :qa quits Neovim"
    failures=$((failures + 1))
else
    echo "ok   - :qa quits Neovim"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "all tests passed"
