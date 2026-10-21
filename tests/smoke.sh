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
# The renderer tests check what the plugin passes, not what was inherited
unset CLAUDE_CODE_NO_FLICKER

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
check "classic renderer by default" "$(cat "$TEST_OUT/env.1")" "CLAUDE_CODE_NO_FLICKER=0"
check "terminal scrollback is set" "$(lua '"[" .. vim.bo.buftype .. " " .. vim.bo.scrollback .. "]"')" "[terminal 100000]"

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

# ct list: token usage from the transcript
cat >"$TEST_OUT/usage.jsonl" <<'JSONL'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"model":"claude-a","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":1000}}}
{"type":"assistant","isSidechain":true,"message":{"model":"claude-side","usage":{"input_tokens":9999,"output_tokens":9999}}}
this line is broken
{"type":"assistant","message":{"model":"claude-a","usage":{"input_tokens":20,"output_tokens":7}}}
{"type":"assistant","message":{"model":"claude-b","usage":{"input_tokens":3,"output_tokens":4,"cache_read_input_tokens":2000,"cache_creation_input_tokens":30}}}
JSONL
UJ='(function() local t = require("claude-deck.state").get(1); t.transcript_path = %s; local u = vim.json.decode(require("claude-deck.cli").list(nil, true)).terminals[1].usage; if u == vim.NIL then return "null" end; return table.concat({ u.model, u.turns, u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens, u.context_tokens }, " ") end)()'
lua "$(printf "$UJ" 'vim.env.TEST_OUT .. "/usage.jsonl"')" >"$TEST_OUT/u1"
check "ct list --json usage sums, latest model and context" "$(cat "$TEST_OUT/u1")" "claude-b 3 33 16 2100 1030 2033"
printf '{"type":"assistant","message":{"model":"claude-c","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":5000}}}\n' >>"$TEST_OUT/usage.jsonl"
lua "$(printf "$UJ" 'vim.env.TEST_OUT .. "/usage.jsonl"')" >"$TEST_OUT/u1"
check "appended assistant line is picked up" "$(cat "$TEST_OUT/u1")" "claude-c 4 34 17 7100 1030 5001"
check "usage key follows orchestration in the JSON" "$(lua 'require("claude-deck.cli").list(nil, true):match("\"orchestration\":%a+,\"usage\":{\"model\":\"claude%-c\",\"turns\":4")')" "orchestration"
check "ct list text has a usage line" "$(NVIM="$SOCK" bin/ct list)" "usage: claude-c turns=4 context=5001 in=34 out=17 cache_read=7100 cache_create=1030"
check "statusline shows the context size" "$(lua '(function() local t = require("claude-deck.state").get(1); vim.g.statusline_winid = vim.fn.bufwinid(t.buf); if vim.g.statusline_winid < 0 then return "nowin" end; return require("claude-deck.ui").statusline() end)()')" "5k ctx"
check "cli.usage = false gives null" "$(lua '(function() local c = require("claude-deck.config").options.cli; c.usage = false; local r = ('"$(printf "$UJ" 'vim.env.TEST_OUT .. "/usage.jsonl"' | sed 's/^/(/;s/$/)/')"'); c.usage = true; return r end)()')" "null"
check "no transcript gives null" "$(lua "$(printf "$UJ" 'nil')")" "null"
check "text ct list without transcript" "$(lua '(function() require("claude-deck.state").get(1).transcript_path = nil; return require("claude-deck.cli").list() end)()')" "usage: (no transcript yet)"
lua '(function() require("claude-deck.state").get(1).transcript_path = vim.env.PWD .. "/tests/fixtures/transcript.jsonl"; return "" end)()' >/dev/null

# Fork opens to the right with --resume
lua '(function() vim.cmd("wincmd k"); require("claude-deck").fork(); vim.cmd("stopinsert"); return "" end)()' >/dev/null
sleep 0.5
check "fork resumes the session" "$(tr '\n' ' ' <"$TEST_OUT/args.3")" "--resume sess-1 --fork-session"
check "fork title" "$(lua 'T_winbar()')" "↳Refactor"

# Focus mode opens a tab and returns
lua '(function() vim.cmd("wincmd h"); _G.T_calls = {}; _G.T_jobresize = vim.fn.jobresize; vim.fn.jobresize = function(j, w, h) table.insert(_G.T_calls, w .. "x" .. h); return _G.T_jobresize(j, w, h) end; require("claude-deck").focus(); return "" end)()' >/dev/null
check "focus mode resizes the pty to the terminal window" "$(lua '(function() local win = vim.fn.bufwinid(require("claude-deck.state").get(1).buf); return tostring(_G.T_calls[#_G.T_calls] == vim.api.nvim_win_get_width(win) .. "x" .. vim.api.nvim_win_get_height(win) - 1) end)()')" "true"
lua '(function() _G.T_calls = {}; local win = vim.fn.bufwinid(require("claude-deck.state").get(1).buf); vim.api.nvim_win_set_width(win, vim.api.nvim_win_get_width(win) - 5); return "" end)()' >/dev/null
sleep 0.3
check "resizing the terminal window resizes the pty" "$(lua '(function() local win = vim.fn.bufwinid(require("claude-deck.state").get(1).buf); local ok = _G.T_calls[#_G.T_calls] == vim.api.nvim_win_get_width(win) .. "x" .. vim.api.nvim_win_get_height(win) - 1; vim.fn.jobresize = _G.T_jobresize; require("claude-deck").focus(); return tostring(ok) end)()')" "true"
check "focus opens a tab in the terminal cwd" "$(lua '(function() vim.cmd("wincmd h"); require("claude-deck").focus(); return #vim.api.nvim_list_tabpages() .. " " .. vim.fn.getcwd() end)()')" "2 $ROOT"
check "focus closes and returns" "$(lua '(function() require("claude-deck").focus(); return #vim.api.nvim_list_tabpages() .. " " .. vim.b.claude_deck_id end)()')" "1 1"

# :q hides a terminal; list can bring it back below
lua '(function() vim.cmd("q"); return "" end)()' >/dev/null
check "hidden terminal still listed" "$(NVIM="$SOCK" bin/ct list)" "#1"
check "list shows hidden terminal below" "$(lua '(function() require("claude-deck").list(); T_pick("ctrl-s", 1); return vim.b.claude_deck_id end)()')" "1"

# Directory picker
check "dir picker candidates" "$(lua '(function() require("claude-deck").pick_dir(); return table.concat(_G.last_picker.lines, ";") end)()')" "fixtures/roots/project-a"
check "dir picker opens in the chosen dir" "$(lua '(function() for i, l in ipairs(_G.last_picker.lines) do if l:find("project%-a") then T_pick("ctrl-v", i) end end; vim.cmd("stopinsert"); return require("claude-deck.state").current().cwd end)()')" "fixtures/roots/project-a"
check "dir picker lists the cwd and then its subdirectories" "$(lua '(function() require("claude-deck").pick_dir(); local l = _G.last_picker.lines; return l[1] .. ";" .. l[2] end)()')" "$(printf '1\t%s;2\t%s/bin' "$ROOT_DISPLAY" "$ROOT_DISPLAY")"
check "dir picker header has the browse keys" "$(lua '_G.last_picker.opts.fzf_opts["--header"]')" "tab: go into / shift-tab: go up"
# T_pick a line by pattern; browsing opens the next picker on vim.schedule
pick_line() { # action, Lua pattern
    lua '(function() for i, l in ipairs(_G.last_picker.lines) do if l:find("'"$2"'") then T_pick("'"$1"'", i); return "" end end; return "" end)()' >/dev/null
}
picker_state() {
    lua '_G.last_picker.opts.prompt .. "|" .. table.concat(_G.last_picker.lines, ";")'
}
FIXTURES="$ROOT_DISPLAY/tests/fixtures/roots"
pick_line tab "project%-a$"
check "tab browses into a directory" "$(picker_state)" "$(printf '%s/project-a> |1\t%s/project-a;2\t%s/project-a/sub-a' "$FIXTURES" "$FIXTURES" "$FIXTURES")"
pick_line btab "project%-a$"
check "shift-tab goes up" "$(picker_state)" "$(printf '%s> |1\t%s;2\t%s/project-a;3\t%s/project-b' "$FIXTURES" "$FIXTURES" "$FIXTURES" "$FIXTURES")"
pick_line tab "project%-a$"
pick_line tab "sub%-a$"
check "tab into an empty directory lists it alone" "$(picker_state)" "$(printf '%s/project-a/sub-a> |1\t%s/project-a/sub-a' "$FIXTURES" "$FIXTURES")"
check "enter after browsing opens there" "$(lua '(function() T_pick("default", 1); vim.cmd("stopinsert"); return require("claude-deck.state").current().cwd end)()')" "fixtures/roots/project-a/sub-a"
lua '(function() vim.cmd("close"); require("claude-deck").pick_dir(); T_pick("btab", 1); return "" end)()' >/dev/null
check "shift-tab from the first list shows the cwd parent" "$(picker_state)" "$(dirname "$ROOT_DISPLAY")> |"
lua '(function() require("claude-deck").pick_dir(); return "" end)()' >/dev/null
pick_line tab "project%-a$"
lua '(function() T_pick("tab"); return "" end)()' >/dev/null
check "tab without a selection reopens the browsed list" "$(picker_state)" "$(printf '%s/project-a> |1\t%s/project-a;2\t%s/project-a/sub-a' "$FIXTURES" "$FIXTURES" "$FIXTURES")"
lua '(function() require("claude-deck").pick_dir(); _G.T_first = table.concat(_G.last_picker.lines, ";"); T_pick("tab"); return "" end)()' >/dev/null
check "tab without a selection reopens the first list" "$(lua '_G.last_picker.opts.prompt .. "|" .. tostring(table.concat(_G.last_picker.lines, ";") == _G.T_first)')" "Directory> |true"
check "dir_roots skip hidden directories" "$(lua 'table.concat(_G.last_picker.lines, ";")')" "fixtures/roots/project-b"
case "$(lua 'table.concat(_G.last_picker.lines, ";")')" in
*roots/.hidden*) echo "FAIL - dir_roots skip hidden directories (listed)"; failures=$((failures + 1)) ;;
esac
mkdir -p "$TEST_OUT/browse/gone"
lua '(function() vim.cmd.cd(vim.fn.fnameescape(vim.env.TEST_OUT .. "/browse")); require("claude-deck").pick_dir(); vim.fn.delete(vim.env.TEST_OUT .. "/browse/gone", "d"); for i, l in ipairs(_G.last_picker.lines) do if l:find("/gone$") then T_pick("tab", i) end end; return "" end)()' >/dev/null
check "browsing into a removed directory is no error" "$(lua '(function() local p = _G.last_picker; vim.cmd.cd(vim.fn.fnameescape("'"$ROOT"'")); return p.opts.prompt .. "|" .. #p.lines end)()')" "/gone> |0"
check "terminal list has no browse keys" "$(lua '(function() require("claude-deck").list(); local o = _G.last_picker.opts; return tostring(o.actions.tab) .. " " .. tostring(o.actions.btab) .. " " .. tostring(o.fzf_opts["--header"]:find("tab:", 1, true)) end)()')" "nil nil nil"

# Terminal-mode keymaps and auto insert
check "normal_mode keymap in terminals" "$(lua '(function() local m = vim.fn.maparg("<C-q>", "t", false, true); return tostring(m.buffer) .. " " .. m.rhs end)()')" "1 <C-\\><C-n>"
check "send_esc keymap in terminals" "$(lua '(function() local m = vim.fn.maparg("<C-]>", "t", false, true); return tostring(m.buffer) .. " " .. m.rhs end)()')" "1 <Esc>"
lua '(function() vim.cmd("stopinsert"); vim.cmd("wincmd w"); vim.cmd("wincmd w"); return "" end)()' >/dev/null
sleep 0.2
check "auto insert when entering a terminal" "$(lua 'vim.api.nvim_get_mode().mode .. " " .. tostring(vim.b.claude_deck_id ~= nil)')" "t true"

# Splitting a terminal keeps the editor width (even with 'equalalways')
check "split keeps other windows" "$(lua '(function() vim.cmd("stopinsert | tabnew"); vim.o.columns = 200; vim.o.equalalways = true; vim.cmd("edit " .. vim.fn.tempname()); local editor = vim.api.nvim_get_current_win(); require("claude-deck").new(); vim.cmd("stopinsert"); local before = vim.api.nvim_win_get_width(editor); require("claude-deck").new("right"); vim.cmd("stopinsert"); return before .. " " .. vim.api.nvim_win_get_width(editor) .. " " .. tostring(vim.o.equalalways) end)()')" "119 119 true"
lua '(function() vim.cmd("tabclose!"); return "" end)()' >/dev/null

# Renderer and scrollback options (each case opens a terminal below and reads what it got)
renderer_env() { # setup options as a Lua table
    id=$(lua '(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, '"$1"')); require("claude-deck").new("below"); vim.cmd("stopinsert"); local id = vim.b.claude_deck_id; vim.cmd("close"); return id end)()')
    sleep 0.5
    cat "$TEST_OUT/env.$id"
}
check "renderer = fullscreen" "$(renderer_env '{ renderer = "fullscreen" }')" "CLAUDE_CODE_NO_FLICKER=1"
check "renderer = false sets nothing" "$(renderer_env '{ renderer = false }')" "CLAUDE_CODE_NO_FLICKER=unset"
check "invalid renderer sets nothing" "$(renderer_env '{ renderer = "nope" }')" "CLAUDE_CODE_NO_FLICKER=unset"
check "invalid renderer warns once" "$(lua '(function() require("claude-deck").new("below"); vim.cmd("stopinsert | close"); local _, n = vim.api.nvim_exec2("messages", { output = true }).output:gsub("claude%-deck: invalid renderer", ""); return "[" .. n .. "]" end)()')" "[1]"
check "invalid renderer is replaced with false" "$(lua 'tostring(require("claude-deck.config").options.renderer)')" "false"
check "scrollback = false keeps the default" "$(lua '(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, { scrollback = false })); require("claude-deck").new("below"); vim.cmd("stopinsert"); local s = "[" .. vim.bo.scrollback .. "]"; vim.cmd("close"); return s end)()')" "[10000]"
check "invalid scrollback values are replaced with false" "$(lua '(function() local c = require("claude-deck.config"); local r = {}; for _, v in ipairs({ "big", -5, 1.5, 0, 100001 }) do require("claude-deck").setup(vim.tbl_extend("force", T_opts, { scrollback = v })); table.insert(r, tostring(c.options.scrollback)) end; return "[" .. table.concat(r, " ") .. "]" end)()')" "[false false false false false]"
check "invalid scrollback still opens a terminal" "$(lua '(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, { scrollback = -5 })); require("claude-deck").new("below"); vim.cmd("stopinsert"); local s = "[" .. tostring(require("claude-deck.state").get(vim.b.claude_deck_id) ~= nil) .. " " .. vim.bo.scrollback .. "] " .. vim.trim(T_winbar()); vim.cmd("close"); return s end)()')" "[true 10000] #"
lua '(function() require("claude-deck").setup(T_opts); return "" end)()' >/dev/null

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

# send_location(): "path:line " typed into the prompt (stdin.<id> of the dummy), no <CR>
ESC=$(printf '\033')
sent() { # id: what the terminal received since the last call, in brackets (<paste>: bracketed paste)
    sleep 0.3
    printf '[%s]' "$(sed "s/$ESC\[200~/<paste>/g; s/$ESC\[201~/<\/paste>/g" "$TEST_OUT/stdin.$1" 2>/dev/null)"
    : >"$TEST_OUT/stdin.$1"
}
to_editor() { # leave terminal mode and go back to the editor window of focus mode
    nvim --server "$SOCK" --remote-send '<C-\><C-n>' >/dev/null 2>&1
    lua '(function() vim.api.nvim_set_current_win(_G.T_edit_win); return "" end)()' >/dev/null
}
keys() { # keys typed in the editor
    nvim --server "$SOCK" --remote-send "$1" >/dev/null 2>&1
}
lua '(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, { keymaps = { send_location = "<F5>" } })); return "" end)()' >/dev/null
check "send_location keymap in normal and visual mode" "$(lua '(function() local n, x = vim.fn.maparg("<F5>", "n", false, true), vim.fn.maparg("<F5>", "x", false, true); return n.desc .. " | " .. x.desc end)()')" "Claude: send file location | Claude: send file location"
sent 1 >/dev/null
lua '(function() vim.cmd("stopinsert"); require("claude-deck").focus(); _G.T_edit_win = vim.api.nvim_get_current_win(); vim.cmd("edit README.md"); vim.api.nvim_win_set_cursor(0, { 3, 0 }); return "" end)()' >/dev/null
check "send_location in focus mode switches to the terminal" "$(lua '(function() require("claude-deck").send_location(); return tostring(vim.b.claude_deck_id) end)()')" "1"
check "send_location sends the relative path and line" "$(sent 1)" "[<paste>README.md:3 </paste>]"
to_editor
check "send_location enters the terminal window before sending" "$(lua '(function() local orig, at = vim.api.nvim_chan_send, nil; vim.api.nvim_chan_send = function(...) at = vim.api.nvim_get_current_win(); return orig(...) end; require("claude-deck").send_location(); vim.wait(1000, function() return at ~= nil end); vim.api.nvim_chan_send = orig; return tostring(at == vim.fn.bufwinid(require("claude-deck.state").get(1).buf)) end)()')" "true"
sent 1 >/dev/null
sleep 0.2
check "send_location leaves the terminal in terminal mode" "$(lua 'vim.api.nvim_get_mode().mode')" "t"
to_editor
keys '5GVjj<F5>'
check "visual line selection sends a range" "$(sent 1)" "[<paste>README.md:5-7 </paste>]"
sleep 0.2
check "visual mode is left after sending" "$(lua '(function() local b = vim.api.nvim_win_get_buf(_G.T_edit_win); return vim.api.nvim_get_mode().mode .. " " .. vim.api.nvim_buf_get_mark(b, "<")[1] .. "-" .. vim.api.nvim_buf_get_mark(b, ">")[1] end)()')" "t 5-7"
to_editor
keys '9G<C-v>kk<F5>'
check "upward blockwise selection sends start-end" "$(sent 1)" "[<paste>README.md:7-9 </paste>]"
to_editor
keys '6Gvl<F5>'
check "selection on one line sends one line" "$(sent 1)" "[<paste>README.md:6 </paste>]"
to_editor
keys "4GVj:ClaudeDeck location<CR>"
check ":'<,'>ClaudeDeck location sends the range" "$(sent 1)" "[<paste>README.md:4-5 </paste>]"
to_editor
lua '(function() vim.cmd("noswapfile edit ~/claude-deck-test-nonexistent/a.lua"); vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x", "y" }); vim.api.nvim_win_set_cursor(0, { 2, 0 }); local b = vim.api.nvim_get_current_buf(); require("claude-deck").send_location(); vim.bo[b].modified = false; return "" end)()' >/dev/null
check "file outside the cwd is sent with ~ (unsaved is fine)" "$(sent 1)" "[<paste>~/claude-deck-test-nonexistent/a.lua:2 </paste>]"
to_editor
lua '(function() vim.cmd("edit " .. vim.fn.fnameescape(vim.env.TEST_OUT .. "/outside.txt")); require("claude-deck").send_location(); return "" end)()' >/dev/null
check "file outside the cwd and home is sent as absolute path" "$(sent 1)" "[<paste>$(cd "$TEST_OUT" && pwd -P)/outside.txt:1 </paste>]"
to_editor
check "unnamed buffer warns" "$(lua '(function() vim.cmd("enew!"); return T_notify(require("claude-deck").send_location) end)()')" "the current buffer is not a file"
check "unnamed buffer sends nothing and stays" "$(sent 1)$(lua 'tostring(vim.b.claude_deck_id)')" "[]nil"
check "inside the terminal warns" "$(lua '(function() vim.cmd("stopinsert"); require("claude-deck").show(1); return T_notify(require("claude-deck").send_location) end)()')" "the current buffer is not a file"
to_editor
check "focus mode terminal not shown warns" "$(lua '(function() vim.cmd("edit README.md"); local term_win = vim.fn.bufwinid(require("claude-deck.state").get(1).buf); vim.api.nvim_win_close(term_win, false); return T_notify(require("claude-deck").send_location) end)()')" "terminal #1 is not shown in this tab"
check "nothing sent when the terminal is not shown" "$(sent 1)" "[]"
lua '(function() require("claude-deck").focus(); return "" end)()' >/dev/null

# send_location() outside focus mode: the only terminal shown in the tab
lua '(function() vim.cmd("stopinsert | tabnew | edit README.md"); _G.T_edit_win = vim.api.nvim_get_current_win(); require("claude-deck").new(); vim.cmd("stopinsert"); _G.T_tab_term = vim.b.claude_deck_id; vim.api.nvim_set_current_win(_G.T_edit_win); return "" end)()' >/dev/null
TAB_TERM=$(lua '_G.T_tab_term')
sleep 0.3
lua '(function() vim.api.nvim_win_set_cursor(0, { 2, 0 }); require("claude-deck").send_location(); return "" end)()' >/dev/null
check "outside focus mode the only terminal in the tab gets it" "$(sent "$TAB_TERM")" "[<paste>README.md:2 </paste>]"
to_editor
check "two terminals in the tab warn" "$(lua '(function() local w = vim.api.nvim_get_current_win(); require("claude-deck").new("below"); vim.cmd("stopinsert"); _G.T_second = vim.api.nvim_get_current_win(); vim.api.nvim_set_current_win(w); return T_notify(require("claude-deck").send_location) end)()')" "more than one terminal is shown in this tab"
check "nothing sent with two terminals" "$(sent "$TAB_TERM")" "[]"
keys '3GVj<F5>'
check "visual mode is left also when only warning" "$(lua 'vim.api.nvim_get_mode().mode .. " " .. vim.fn.line("'"'"'<") .. "-" .. vim.fn.line("'"'"'>")')" "n 3-4"
check "exited terminal warns" "$(lua '(function() vim.api.nvim_win_close(_G.T_second, true); local t = require("claude-deck.state").get(_G.T_tab_term); vim.fn.jobstop(t.job); vim.fn.jobwait({ t.job }, 1000); vim.wait(1000, function() return t.state == "exited" end); return T_notify(require("claude-deck").send_location) end)()')" "terminal #$TAB_TERM has exited"
check "nothing sent to an exited terminal" "$(sent "$TAB_TERM")" "[]"
lua '(function() vim.cmd("tabclose!"); require("claude-deck").setup(T_opts); return "" end)()' >/dev/null
check "invalid keymaps.send_location warns" "$(lua 'T_notify(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, { keymaps = { send_location = true } })) end)')" "invalid keymaps.send_location true"
check "invalid keymaps.send_location is replaced with false" "$(lua 'tostring(require("claude-deck.config").options.keymaps.send_location) .. " [" .. vim.fn.maparg("<F5>", "n") .. "]"')" "false []"
lua '(function() require("claude-deck").setup(T_opts); return "" end)()' >/dev/null
check "send_location keymap is off by default" "$(lua '"[" .. vim.fn.maparg("<F5>", "n") .. vim.fn.maparg("<F5>", "x") .. "]"')" "[]"

# ct title: Claude names its own terminal
lua '(function() vim.cmd("tabnew"); require("claude-deck").new(); vim.cmd("stopinsert"); _G.T_title_term = vim.b.claude_deck_id; return "" end)()' >/dev/null
TT=$(lua '_G.T_title_term')
sleep 0.3
ct_title() { # ct title in terminal $TT; prints the output and the exit status
    out=$(NVIM="$SOCK" CLAUDE_DECK_ID="$TT" bin/ct title "$@" 2>&1)
    printf '%s exit=%s' "$out" "$?"
}
check "system prompt asks for ct title by default" "$(cat "$TEST_OUT/args.$TT")" 'ct title "<title>"'
check "permissions allow ct title" "$(lua 'require("claude-deck.hooks").settings_json()')" '"Bash(ct title:*)"'
hook "$TT" UserPromptSubmit '{"prompt":"first prompt of the task"}'
check "ct title replaces the title from the first prompt" "$(ct_title Fix   the parser)" "title: Fix the parser exit=0"
check "ct title shows in the winbar" "$(lua 'T_winbar()')" "#$TT Running │ Fix the parser"
check "ct title renames the buffer" "$(lua 'vim.api.nvim_buf_get_name(0)')" "claude:#$TT Fix the parser"
check "ct title with quotes, backslash and Japanese" "$(ct_title "It's \"パーサー\" \\ 修正")|$(lua 'T_winbar()')" "exit=0| #$TT Running │ It's \"パーサー\" \\ 修正"
check "ct title without a title shows the title" "$(ct_title)" "It's \"パーサー\" \\ 修正 exit=0"
check "ct title refuses more than 40 cells" "$(ct_title あいうえおかきくけこさしすせそたちつてとな)" "ct: title is too long (42 cells, max 40) exit=1"
check "too long title is not set" "$(ct_title)" "It's \"パーサー\" \\ 修正 exit=0"
check "ct title outside a terminal fails" "$(NVIM= bin/ct title x 2>&1; echo "exit=$?")" "exit=1"
check "ct title without an id fails" "$(NVIM="$SOCK" CLAUDE_DECK_ID= bin/ct title x 2>&1; echo "exit=$?")" "ct: run this inside a claude-deck terminal
exit=1"
hook "$TT" SessionStart '{"source":"clear"}'
check "/clear removes the title from ct title" "$(lua 'T_winbar()')" "#$TT New │ (new task)"
lua '(function() local input = vim.ui.input; vim.ui.input = function(_, cb) cb("  My   name ") end; require("claude-deck").rename(); vim.ui.input = input; return "" end)()' >/dev/null
check "ct title keeps the title from rename()" "$(ct_title Other)" "ct: the title was set by the user; run \`ct title --force <title>\` if the user asked you to rename it exit=1"
check "the user's title is unchanged" "$(lua 'T_winbar()')" "#$TT New │ My name"
hook "$TT" SessionStart '{"source":"clear"}'
check "/clear keeps the title from rename()" "$(lua 'T_winbar()')" "#$TT New │ My name"
check "ct title --force replaces the user's title" "$(ct_title --force Forced name)|$(lua 'T_winbar()')" "exit=0| #$TT New │ Forced name"
check "a forced title is Claude's" "$(ct_title Again)" "title: Again exit=0"
lua '(function() vim.cmd("tabclose!"); return "" end)()' >/dev/null
check "auto_title = false leaves out the ct title paragraph" "$(lua '(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, { cli = { auto_title = false } })); require("claude-deck").new("below"); vim.cmd("stopinsert"); local id = vim.b.claude_deck_id; vim.cmd("close"); vim.wait(500); local args = table.concat(vim.fn.readfile(vim.env.TEST_OUT .. "/args." .. id), "\n"); return tostring(args:find("ct list", 1, true) ~= nil) .. " " .. tostring(args:find([[ct title "]], 1, true) ~= nil) end)()')" "true false"
lua '(function() require("claude-deck").setup(T_opts); return "" end)()' >/dev/null

# ct open: Claude opens a file in the editor window of focus mode
lua '(function() vim.cmd("tabnew"); _G.T_open_origin = vim.api.nvim_get_current_tabpage(); require("claude-deck").new(); _G.T_open_term = vim.b.claude_deck_id; return "" end)()' >/dev/null
OT=$(lua '_G.T_open_term')
sleep 0.3
check "system prompt tells about ct open" "$(cat "$TEST_OUT/args.$OT")" 'ct open <path>[:line]'
check "permissions allow ct open" "$(lua 'require("claude-deck.hooks").settings_json()')" '"Bash(ct open:*)"'
OPEN_TABS=$(lua '#vim.api.nvim_list_tabpages()')
editor_state() { # tabs, focus mode terminal, current file, cursor line, buftype and mode
    lua '(function() return #vim.api.nvim_list_tabpages() .. " #" .. tostring(require("claude-deck.focus").term_id()) .. " " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") .. ":" .. vim.fn.line(".") .. " [" .. vim.bo.buftype .. "] " .. vim.api.nvim_get_mode().mode end)()'
}
check "cli.open opens focus mode with the file at the line" "$(lua 'require("claude-deck.cli").open('"$OT"', "tests/fixtures/open/greeter.rb:24")')|$(editor_state)" "Opened tests/fixtures/open/greeter.rb:24 in the editor|$((OPEN_TABS + 1)) #$OT greeter.rb:24 [] n"
check "the file is opened in the editor window made by focus mode (tree | editor | terminal)" "$(lua '(function() local wins = vim.api.nvim_tabpage_list_wins(0); local terms = #require("claude-deck.state").wins_in_tab(); return #wins .. " " .. terms .. " " .. vim.fn.winnr() end)()')" "3 1 2"
lua '(function() _G.T_open_edit = vim.api.nvim_get_current_win(); vim.api.nvim_set_current_tabpage(_G.T_open_origin); return "" end)()' >/dev/null
check "cli.open with focus mode open reuses its tab and editor window" "$(lua 'require("claude-deck.cli").open('"$OT"', "tests/fixtures/open/my notes.txt")')|$(editor_state)|$(lua 'tostring(vim.api.nvim_get_current_win() == _G.T_open_edit)')" "Opened tests/fixtures/open/my notes.txt in the editor|$((OPEN_TABS + 1)) #$OT my notes.txt:1 [] n|true"
check "line past the end goes to the last line" "$(lua 'require("claude-deck.cli").open('"$OT"', "tests/fixtures/open/greeter.rb:999")')|$(editor_state)" "Opened tests/fixtures/open/greeter.rb:30 in the editor|$((OPEN_TABS + 1)) #$OT greeter.rb:30 [] n"
check "path:line:col uses the line" "$(lua 'require("claude-deck.cli").open('"$OT"', "tests/fixtures/open/greeter.rb:7:3")')|$(editor_state)" "greeter.rb:7 in the editor|$((OPEN_TABS + 1)) #$OT greeter.rb:7 [] n"
check "split_line" "$(lua '(function() local cli = require("claude-deck.cli"); local a, b = cli.split_line("a/b.rb:24"); local c, d = cli.split_line("a/b.rb"); local e, f = cli.split_line("x:2:5"); return a .. " " .. b .. "|" .. c .. " " .. tostring(d) .. "|" .. e .. " " .. f end)()')" "a/b.rb 24|a/b.rb nil|x 2"
check "absolute and ~ paths" "$(lua 'require("claude-deck.cli").open('"$OT"', vim.fn.getcwd() .. "/README.md:2")')|$(lua 'require("claude-deck.cli").resolve_path("~/", "/") == vim.fs.normalize(vim.env.HOME)')" "Opened README.md:2 in the editor|true"
check "missing file fails" "$(lua 'require("claude-deck.cli").open('"$OT"', "tests/fixtures/open/nope.rb:3")')|$(editor_state)" "ct: file not found: tests/fixtures/open/nope.rb|$((OPEN_TABS + 1)) #$OT README.md:2 [] n"
check "a directory fails" "$(lua 'require("claude-deck.cli").open('"$OT"', "tests/fixtures/open")')|$(editor_state)" "ct: not a file: tests/fixtures/open|$((OPEN_TABS + 1)) #$OT README.md:2 [] n"
check "relative paths use the given cwd (the shell's \$PWD)" "$(lua 'require("claude-deck.cli").open('"$OT"', "greeter.rb:6", vim.fn.getcwd() .. "/tests/fixtures/open")')|$(editor_state)" "Opened tests/fixtures/open/greeter.rb:6 in the editor|$((OPEN_TABS + 1)) #$OT greeter.rb:6 [] n"
printf 'a\nb\nc\n' >"$TEST_OUT/foo"
printf 'x\n' >"$TEST_OUT/foo:24"
check "a file named foo:24 is opened as it is" "$(lua 'require("claude-deck.cli").open('"$OT"', "foo:24", vim.env.TEST_OUT)')|$(editor_state)" "foo:24 in the editor|$((OPEN_TABS + 1)) #$OT foo:24:1 [] n"
check "foo:3 without such a file opens foo at line 3" "$(lua 'require("claude-deck.cli").open('"$OT"', "foo:3", vim.env.TEST_OUT)')|$(editor_state)" "foo:3 in the editor|$((OPEN_TABS + 1)) #$OT foo:3 [] n"
printf 'swapped\n' >"$TEST_OUT/swapped.txt"
nvim --headless --clean "$TEST_OUT/swapped.txt" </dev/null >/dev/null 2>&1 &
SWAP_PID=$!
sleep 0.5
check "a file with a swap file opens read-only without a prompt" "$(lua '(function() local n = #vim.api.nvim_get_autocmds({ event = "SwapExists" }); local r = require("claude-deck.cli").open('"$OT"', vim.env.TEST_OUT .. "/swapped.txt"); return r .. "|" .. tostring(vim.bo.readonly) .. " " .. tostring(n == #vim.api.nvim_get_autocmds({ event = "SwapExists" })) end)()')|$(editor_state)" "swapped.txt in the editor|true true|$((OPEN_TABS + 1)) #$OT swapped.txt:1 [] n"
kill $SWAP_PID 2>/dev/null
lua '(function() vim.cmd("edit README.md | 2"); return "" end)()' >/dev/null
check "closed editor window is made again" "$(lua '(function() vim.api.nvim_win_close(_G.T_open_edit, false); local r = require("claude-deck.cli").open('"$OT"', "tests/fixtures/open/greeter.rb:5"); return r .. " " .. #vim.api.nvim_tabpage_list_wins(0) .. " " .. #require("claude-deck.state").wins_in_tab() end)()')|$(editor_state)" "greeter.rb:5 in the editor 3 1|$((OPEN_TABS + 1)) #$OT greeter.rb:5 [] n"

# bin/ct open from the terminal in Terminal mode
ct_open() { # ct open in terminal $OT; prints the output and the exit status
    out=$(NVIM="$SOCK" CLAUDE_DECK_ID="$OT" bin/ct open "$@" 2>&1)
    printf '%s exit=%s' "$out" "$?"
}
lua '(function() vim.cmd("tabclose"); vim.api.nvim_set_current_tabpage(_G.T_open_origin); require("claude-deck").show('"$OT"'); return "" end)()' >/dev/null
sleep 0.2
check "the terminal is in Terminal mode before ct open" "$(lua 'vim.api.nvim_get_mode().mode')" "t"
check "ct open opens focus mode from Terminal mode" "$(ct_open "tests/fixtures/open/greeter.rb:24")" "Opened tests/fixtures/open/greeter.rb:24 in the editor exit=0"
sleep 0.2
check "ct open leaves the editor window current in Normal mode" "$(editor_state)" "$((OPEN_TABS + 1)) #$OT greeter.rb:24 [] n"
check "ct open with a space in the path" "$(ct_open "tests/fixtures/open/my notes.txt")|$(editor_state)" "Opened tests/fixtures/open/my notes.txt in the editor exit=0|$((OPEN_TABS + 1)) #$OT my notes.txt:1 [] n"
check "ct open missing file fails" "$(ct_open nope.txt)" "ct: file not found: nope.txt exit=1"
check "ct open resolves relative paths from the shell's current directory" "$(cd tests/fixtures/open && NVIM="$SOCK" CLAUDE_DECK_ID="$OT" "$ROOT/bin/ct" open greeter.rb:2; echo "exit=$?")|$(editor_state)" "Opened tests/fixtures/open/greeter.rb:2 in the editor
exit=0|$((OPEN_TABS + 1)) #$OT greeter.rb:2 [] n"
check "ct open without a path fails" "$(ct_open; echo)" "ct open <path>[:line]"
check "ct open without an id fails" "$(NVIM="$SOCK" CLAUDE_DECK_ID= bin/ct open README.md 2>&1; echo "exit=$?")" "ct: run this inside a claude-deck terminal
exit=1"

# A hidden terminal is shown first; the API and the user command
lua '(function() vim.cmd("tabclose"); vim.api.nvim_set_current_tabpage(_G.T_open_origin); vim.cmd("stopinsert | vnew"); local t = require("claude-deck.state").get('"$OT"'); for _, w in ipairs(vim.fn.win_findbuf(t.buf)) do vim.api.nvim_win_close(w, false) end; return "" end)()' >/dev/null
check "ct open shows a hidden terminal and opens focus mode" "$(ct_open README.md:3)|$(editor_state)|$(lua '#require("claude-deck.state").wins_in_tab()')" "Opened README.md:3 in the editor exit=0|$((OPEN_TABS + 1)) #$OT README.md:3 [] n|1"
check "open_file() uses the terminal of the focus mode tab" "$(lua '(function() require("claude-deck").open_file("tests/fixtures/open/greeter.rb", 12); return "" end)()')$(editor_state)" "$((OPEN_TABS + 1)) #$OT greeter.rb:12 [] n"
check ":ClaudeDeck open path:line (relative to Neovim's cwd)" "$(lua '(function() local cwd = vim.fn.getcwd(); vim.cmd("tcd tests/fixtures/open"); vim.cmd("ClaudeDeck open greeter.rb:20"); vim.cmd("tcd " .. vim.fn.fnameescape(cwd)); return "" end)()')$(editor_state)" "$((OPEN_TABS + 1)) #$OT greeter.rb:20 [] n"
check ":ClaudeDeck open missing file warns" "$(lua 'T_notify(function() vim.cmd("ClaudeDeck open nope.txt") end)')" "/nope.txt"
check "open_file() outside a terminal warns" "$(lua '(function() vim.cmd("tabclose"); vim.api.nvim_set_current_tabpage(_G.T_open_origin); vim.cmd("stopinsert | 1wincmd w"); return T_notify(function() require("claude-deck").open_file("README.md") end) end)()')" "run this inside a terminal or its focus mode"
lua '(function() vim.cmd("tabclose!"); return "" end)()' >/dev/null

# Notification methods
notify_methods='(function() local fn, n = vim.fn, require("claude-deck.notify"); local has, ex = fn.has, fn.executable; local r = {}; fn.has = function(f) return f == "mac" and 1 or has(f) end; for _, tn in ipairs({ 1, 0 }) do fn.executable = function(c) return c == "terminal-notifier" and tn or 1 end; table.insert(r, n.method()) end; fn.has = function() return 0 end; table.insert(r, n.method()); fn.has, fn.executable = has, ex; return table.concat(r, " ") end)()'
check "auto method: terminal-notifier, osascript, notify-send" "$(lua "$notify_methods")" "terminal-notifier osascript notify-send"
mkdir -p "$TEST_OUT/bin"
printf '#!/bin/sh\nprintf "[%%s]" "$@" > "%s/tn.args"\n' "$TEST_OUT" >"$TEST_OUT/bin/terminal-notifier"
chmod +x "$TEST_OUT/bin/terminal-notifier"
tn_args() { # bundle id ("nil" for none), desktop_notify arguments
    rm -f "$TEST_OUT/tn.args"
    lua '(function() local path = vim.env.PATH; vim.env.PATH = vim.env.TEST_OUT .. "/bin:" .. path; require("claude-deck").setup(vim.tbl_deep_extend("force", T_opts, { notify = { method = "terminal-notifier", notifier = false } })); local n = require("claude-deck.notify"); local saved = n.bundle_id; n.bundle_id = '"$1"'; n.desktop_notify('"$2"'); n.bundle_id = saved; vim.env.PATH = path; return "" end)()' >/dev/null
    i=0
    while [ ! -s "$TEST_OUT/tn.args" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
    cat "$TEST_OUT/tn.args" 2>/dev/null
}
check "terminal-notifier gets title, subtitle, body, -activate and -group" "$(tn_args '"com.example.term"' '"Claude: Waiting", "Fix tests", "~/src", 7')" "[-title][Claude: Waiting][-subtitle][Fix tests][-message][~/src][-activate][com.example.term][-group][claude-deck-7]"
check "terminal-notifier without a bundle id has no -activate" "$(tn_args nil '"Claude: Waiting", "Fix tests", "~/src", 7')" "[-message][~/src][-group][claude-deck-7]"
check "terminal-notifier escapes values read as non-strings" "$(tn_args nil '"-x", "[y]", "(a, b)", 7')" "[-title][\\-x][-subtitle][\\[y]][-message][\\(a, b)][-group]"
check "terminal-notifier escapes a leading brace" "$(tn_args nil '"T", "S", "{z}", 7')" "[-message][\\{z}][-group]"
check "terminal-notifier leaves out an empty subtitle and body" "$(tn_args nil '"T", "", "", 7')" "[-title][T][-group][claude-deck-7]"
# A failing terminal-notifier is reported once per session
printf '#!/bin/sh\necho "Notifications are turned off for this application." >&2\nexit 3\n' >"$TEST_OUT/bin/terminal-notifier"
fail_msgs=$(lua '(function() local path = vim.env.PATH; vim.env.PATH = vim.env.TEST_OUT .. "/bin:" .. path; require("claude-deck").setup(vim.tbl_deep_extend("force", T_opts, { notify = { method = "terminal-notifier", notifier = false } })); local n = require("claude-deck.notify"); n.desktop_notify("T", "S", "B", 7); vim.wait(2000, function() return vim.api.nvim_exec2("messages", { output = true }).output:find("exit 3", 1, true) ~= nil end); n.desktop_notify("T", "S", "B", 7); vim.wait(500); vim.env.PATH = path; return vim.api.nvim_exec2("messages", { output = true }).output end)()')
check "failing terminal-notifier warns with the reason" "$fail_msgs" "claude-deck: terminal-notifier failed (exit 3): Notifications are turned off for this application."
check "failing terminal-notifier warns only once" "$(printf '%s' "$fail_msgs" | grep -c 'terminal-notifier failed (exit 3)')" "1"
osc_out() { # ui list, desktop_notify arguments, expression of the output `out`
    lua '(function() local parts = {}; local api = vim.api; local uis, send, chan_send = api.nvim_list_uis, api.nvim_ui_send, api.nvim_chan_send; api.nvim_list_uis = function() return '"$1"' end; api.nvim_ui_send = function(s) table.insert(parts, s) end; api.nvim_chan_send = function(_, s) table.insert(parts, s) end; require("claude-deck").setup(vim.tbl_deep_extend("force", T_opts, { notify = { method = "osc", notifier = false } })); require("claude-deck.notify").desktop_notify('"$2"'); api.nvim_list_uis, api.nvim_ui_send, api.nvim_chan_send = uis, send, chan_send; local out = table.concat(parts); return '"$3"' end)()'
}
osc_shown='"[" .. out:gsub("\27", "<ESC>"):gsub("\7", "<BEL>") .. "]"'
check "osc writes OSC 9 without control characters" "$(osc_out '{ { stdout_tty = true } }' '"Claude: Waiting", "Fix\27 tests", "line 1\nline 2\194\156\7", 7' "$osc_shown")" "[<ESC>]9;Claude: Waiting: Fix tests — line 1 line 2<BEL>]"
check "osc cuts a long text at a character boundary" "$(osc_out '{ { stdout_tty = true } }' '"T", "S", string.rep("あ", 300), 7' '#out .. " " .. tostring(out:sub(-4) == "あ\7")')" "503 true"
check "osc writes nothing without a terminal UI" "$(osc_out '{}' '"T", "S", "B", 7' "$osc_shown")" "[]"
check "invalid notify.method warns" "$(lua 'T_notify(function() require("claude-deck").setup(vim.tbl_deep_extend("force", T_opts, { notify = { method = "nope", notifier = false } })) end) .. " " .. require("claude-deck.config").options.notify.method')" 'invalid notify.method "nope" (use "auto"'
check "invalid notify.method falls back to auto" "$(lua 'require("claude-deck.config").options.notify.method')" "auto"
check "missing notify.method command warns" "$(lua '(function() local ex = vim.fn.executable; vim.fn.executable = function() return 0 end; local m = T_notify(function() require("claude-deck").setup(vim.tbl_deep_extend("force", T_opts, { notify = { method = "notify-send", notifier = false } })) end); vim.fn.executable = ex; return m .. " " .. require("claude-deck.config").options.notify.method end)()')" '`notify-send` was not found); using "auto" auto'
check "notifier function: no notify.method check" "$(lua 'T_notify(function() require("claude-deck").setup(vim.tbl_deep_extend("force", T_opts, { notify = { method = "nope" } })) end) .. " " .. require("claude-deck.config").options.notify.method')" "none nope"
check "notifier function takes precedence over notify.method" "$(lua '(function() _G.notifications = {}; local c = require("claude-deck.config"); c.options.notify.skip_when_watching = false; require("claude-deck.notify").on_state(require("claude-deck.state").sorted()[1], "waiting"); return table.concat(_G.notifications, ";") end)()')" "Claude: Waiting |"
lua '(function() require("claude-deck").setup(T_opts); return "" end)()' >/dev/null

# Delayed notifications
delay_case() { # delay, Lua statements run after setup (terminal #1, unwatched); prints the notifications
    lua '(function() _G.notifications = {}; require("claude-deck").setup(vim.tbl_deep_extend("force", T_opts, { notify = { delay = '"$1"', skip_when_watching = false } })); local s = require("claude-deck.state"); local t = s.get(1); '"$2"'; return "[" .. table.concat(_G.notifications, ";") .. "]" end)()'
}
check "notification is dropped when Claude resumes within the delay" "$(delay_case 300 'local o = t.state; s.set_state(t, "waiting"); s.set_state(t, "running"); vim.wait(400); s.set_state(t, o)')" "[]"
check "notification is sent after the delay" "$(delay_case 300 'local o = t.state; s.set_state(t, "waiting"); local early = #_G.notifications; vim.wait(400); s.set_state(t, o); _G.notifications[#_G.notifications + 1] = "early=" .. early')" "[Claude: Waiting | "
check "nothing is sent before the delay has passed" "$(lua '_G.notifications[#_G.notifications]')" "early=0"
check "attention replaces a pending waiting notification" "$(delay_case 300 'local o = t.state; s.set_state(t, "waiting"); s.set_state(t, "attention"); vim.wait(400); s.set_state(t, o)')" "[Claude: Needs you | "
check "only the attention notification is sent" "$(lua '#_G.notifications')" "1"
check "removed terminal gets no delayed notification" "$(delay_case 300 'local o = t.state; s.set_state(t, "waiting"); s.terminals[t.id] = nil; vim.wait(400); s.terminals[t.id] = t; s.set_state(t, o)')" "[]"
check "invalid notify.delay warns" "$(lua 'T_notify(function() require("claude-deck").setup(vim.tbl_deep_extend("force", T_opts, { notify = { delay = -1 } })) end)')" "invalid notify.delay -1"
check "invalid notify.delay falls back to 2000" "$(lua '(function() local r = {}; for _, v in ipairs({ "x", -5 }) do T_notify(function() require("claude-deck").setup(vim.tbl_deep_extend("force", T_opts, { notify = { delay = v } })) end); table.insert(r, require("claude-deck.config").options.notify.delay) end; return table.concat(r, " ") end)()')" "2000 2000"
lua '(function() require("claude-deck").setup(T_opts); return "" end)()' >/dev/null

# redraw(): the job is stopped and the same session resumed with the same id in a new buffer
redraw_term() { # opens a terminal in a new tab; prints its id
    lua '(function() vim.cmd("tabnew"); require("claude-deck").new(); vim.cmd("stopinsert"); return vim.b.claude_deck_id end)()'
}
wait_resumed() { # id: waits until the dummy of terminal $1 got --resume
    i=0
    while ! grep -q -- "--resume" "$TEST_OUT/args.$1" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    sleep 0.3
}
capture_notify='_G.T_msgs = {}; _G.T_orig_notify = vim.notify; vim.notify = function(m) table.insert(_G.T_msgs, m) end'
captured='(function() vim.notify = _G.T_orig_notify; vim.cmd("stopinsert"); return table.concat(_G.T_msgs, ";") end)()'
RT=$(redraw_term)
sleep 0.3
check "redraw without a session id warns" "$(lua 'T_notify(require("claude-deck").redraw)')" "session id is known"
hook "$RT" SessionStart '{"session_id":"sess-redraw"}'
hook "$RT" UserPromptSubmit '{"prompt":"Redraw me"}'
check "redraw while running warns" "$(lua 'T_notify(require("claude-deck").redraw)')" "claude-deck: wait until Claude finishes (state: running)"
check "redraw while running does not resume" "$(tr '\n' ' ' <"$TEST_OUT/args.$RT")" "--append-system-prompt"
case "$(cat "$TEST_OUT/args.$RT")" in
*--resume*) echo "FAIL - redraw while running starts nothing"; failures=$((failures + 1)) ;;
*) echo "ok   - redraw while running starts nothing" ;;
esac
hook "$RT" Notification '{"message":"Allow?"}'
check "redraw while attention warns" "$(lua 'T_notify(require("claude-deck").redraw)')" "(state: attention)"
hook "$RT" Stop '{}'
sent "$RT" >/dev/null
rm -f "$TEST_OUT/env.$RT"
lua '(function() _G.T_old_buf = vim.api.nvim_get_current_buf(); '"$capture_notify"'; vim.cmd("ClaudeDeck redraw"); require("claude-deck").redraw(); return "" end)()' >/dev/null
wait_resumed "$RT"
check "redraw types nothing into the prompt" "$(sent "$RT")" "[]"
check "redraw resumes the session" "$(tr '\n' ' ' <"$TEST_OUT/args.$RT")" "--resume sess-redraw"
check "redraw keeps --settings" "$(cat "$TEST_OUT/args.$RT")" "claude-deck-hook"
check "redraw keeps the system prompt with the same id" "$(cat "$TEST_OUT/args.$RT")" "terminal #$RT of claude-deck"
check "redraw reports when done (and once while redrawing)" "$(lua "$captured")" "claude-deck: #$RT is being redrawn;claude-deck: redrew #$RT"
check "redraw keeps the id in a new buffer in the same window" "$(lua 'tostring(vim.b.claude_deck_id) .. " " .. tostring(vim.api.nvim_get_current_buf() ~= _G.T_old_buf) .. " " .. tostring(vim.api.nvim_buf_is_valid(_G.T_old_buf)) .. " " .. #vim.api.nvim_tabpage_list_wins(0)')" "$RT true false 1"
check "redraw keeps the winbar number and title" "$(lua 'T_winbar()')" "#$RT New │ Redraw me"
check "redrawn terminal is registered with the new buffer" "$(lua '(function() local s = require("claude-deck.state").get(_G.T_redraw_term or vim.b.claude_deck_id); return tostring(s.buf == vim.api.nvim_get_current_buf()) .. " " .. s.state .. " " .. vim.api.nvim_buf_get_name(0):match("claude:#.*") end)()')" "true idle claude:#$RT Redraw me"
check "redrawn terminal has scrollback and keymaps" "$(lua 'vim.bo.buftype .. " " .. vim.bo.scrollback .. " " .. vim.fn.maparg("<C-]>", "t", false, true).desc')" "terminal 100000 Send <Esc> to Claude"
check "redrawn terminal gets the renderer" "$(cat "$TEST_OUT/env.$RT" 2>/dev/null)" "CLAUDE_CODE_NO_FLICKER=0"
hook "$RT" SessionStart '{"source":"resume","session_id":"sess-redraw"}'
check "SessionStart from resume keeps the title" "$(lua 'T_winbar()')" "#$RT New │ Redraw me"
# idle (resumed, no prompt yet) can be redrawn
lua '(function() '"$capture_notify"'; require("claude-deck").redraw(); return "" end)()' >/dev/null
sleep 1
check "redraw while idle" "$(lua "$captured")" "claude-deck: redrew #$RT"
# exited: started again directly
lua '(function() local t = require("claude-deck.state").get('"$RT"'); vim.fn.jobstop(t.job); vim.wait(3000, function() return t.state == "exited" end); return "" end)()' >/dev/null
rm -f "$TEST_OUT/args.$RT"
check "redraw of an exited terminal starts it at once" "$(lua '(function() local s = require("claude-deck.state"); local old = vim.api.nvim_get_current_buf(); '"$capture_notify"'; require("claude-deck").redraw(); return tostring(s.get('"$RT"').buf ~= old) .. " " .. s.get('"$RT"').state .. " " .. '"$captured"' end)()')" "true idle claude-deck: redrew #$RT"
wait_resumed "$RT"
check "exited terminal resumes the session" "$(tr '\n' ' ' <"$TEST_OUT/args.$RT")" "--resume sess-redraw"
# The old buffer is wiped while waiting: the terminal is gone and nothing is started
lua '(function() _G.T_rtab = vim.api.nvim_get_current_tabpage(); local cd = require("claude-deck"); cd._redraw_timeout = 3000; local s = require("claude-deck.state"); local t = s.get('"$RT"'); local saved = vim.fn.jobstop; vim.fn.jobstop = function() return 1 end; cd.redraw(); vim.fn.jobstop = saved; vim.cmd("bwipe! " .. t.buf); return "" end)()' >/dev/null
rm -f "$TEST_OUT/args.$RT"
sleep 0.5
check "wiping the buffer while waiting removes the terminal" "$(lua 'tostring(require("claude-deck.state").get('"$RT"'))')" "nil"
check "wiping the buffer while waiting starts nothing" "[$(cat "$TEST_OUT/args.$RT" 2>/dev/null)]" "[]"
lua '(function() require("claude-deck")._redraw_timeout = 5000; if vim.api.nvim_tabpage_is_valid(_G.T_rtab) then vim.cmd(vim.api.nvim_tabpage_get_number(_G.T_rtab) .. "tabclose!") end; return "" end)()' >/dev/null
# A job that ignores SIGTERM / SIGHUP: give up after the timeout
lua '(function() local o = vim.deepcopy(T_opts); o.cmd = { "sh", "-c", "trap \"\" TERM HUP; while :; do sleep 0.1; done" }; require("claude-deck").setup(o); return "" end)()' >/dev/null
RT=$(redraw_term)
lua '(function() require("claude-deck").setup(T_opts); return "" end)()' >/dev/null
sleep 0.3
hook "$RT" SessionStart '{"session_id":"sess-stuck"}'
check "redraw gives up when the job does not exit" "$(lua '(function() local cd = require("claude-deck"); cd._redraw_timeout = 300; '"$capture_notify"'; cd.redraw(); vim.wait(1000, function() return #_G.T_msgs > 0 end); cd._redraw_timeout = 5000; return '"$captured"' end)()')" "claude-deck: #$RT did not exit; not redrawn"
check "redraw can be retried after giving up" "$(lua 'tostring(require("claude-deck.state").get('"$RT"').redrawing)')" "nil"
lua '(function() local t = require("claude-deck.state").get('"$RT"'); vim.wait(4000, function() return t.state == "exited" end); vim.cmd("tabclose!"); return "" end)()' >/dev/null
# The window is closed while waiting: no window is opened, the terminal is dropped
RT=$(redraw_term)
sleep 0.3
hook "$RT" SessionStart '{"session_id":"sess-closed"}'
lua '(function() vim.cmd("vsplit | enew"); local edit = vim.api.nvim_get_current_win(); vim.cmd("wincmd p"); '"$capture_notify"'; require("claude-deck").redraw(); vim.api.nvim_win_close(0, true); return "" end)()' >/dev/null
sleep 1
check "closed window: redraw warns and stops" "$(lua "$captured")|$(lua '#vim.api.nvim_tabpage_list_wins(0) .. " " .. tostring(require("claude-deck.state").get('"$RT"'))')" "claude-deck: window for #$RT was closed; not redrawn|1 nil"
lua '(function() vim.cmd("tabclose!"); return "" end)()' >/dev/null

# User command
check "user command completion" "$(lua 'table.concat(vim.fn.getcompletion("ClaudeDeck f", "cmdline"), ",")')" "focus,fork"
check "user command completion has redraw" "$(lua 'table.concat(vim.fn.getcompletion("ClaudeDeck re", "cmdline"), ",")')" "redraw,rename"
check "user command completion has location" "$(lua 'table.concat(vim.fn.getcompletion("ClaudeDeck l", "cmdline"), ",")')" "list,location"
check "user command completion has open" "$(lua 'table.concat(vim.fn.getcompletion("ClaudeDeck o", "cmdline"), ",")')" "open"
check "ClaudeDeck open completes files" "$(lua 'table.concat(vim.fn.getcompletion("ClaudeDeck open tests/fixtures/open/g", "cmdline"), ",")')" "tests/fixtures/open/greeter.rb"

# ct diff: a repository in $TEST_OUT with a commit and uncommitted changes
REPO="$TEST_OUT/repo"
mkdir -p "$REPO/app"
(
    cd "$REPO" || exit 1
    git init -q -b main
    git config user.email t@example.com
    git config user.name t
    printf 'line 1\nline 2\nline 3\nline 4\nline 5\n' >app/one.txt
    printf 'gone\n' >app/gone.txt
    printf 'same\n' >same.txt
    git add . && git commit -q -m init
    printf 'line 1\nline 2 changed\nline 3\nline 4\nline 5\nline 6 new\n' >app/one.txt
    printf 'brand new\n' >'app/new file.txt'
    git add 'app/new file.txt'
    rm app/gone.txt
)
lua '(function() vim.cmd("tabnew"); _G.T_diff_origin = vim.api.nvim_get_current_tabpage(); require("claude-deck.terminal").open_new("'"$REPO"'"); _G.T_diff_term = vim.b.claude_deck_id; return "" end)()' >/dev/null
DT=$(lua '_G.T_diff_term')
sleep 0.3
check "system prompt tells about ct diff" "$(cat "$TEST_OUT/args.$DT")" 'ct diff [<path>[:line]] [--pr <number>] [--base <ref>]'
check "permissions allow ct diff" "$(lua 'require("claude-deck.hooks").settings_json()')" '"Bash(ct diff)","Bash(ct diff:*)"'
DIFF_TABS=$(lua '#vim.api.nvim_list_tabpages()')
diff_state() { # tabs, focus terminal, buffer name tail, cursor line text, filetype, modifiable, mode
    lua '(function() return #vim.api.nvim_list_tabpages() .. " #" .. tostring(require("claude-deck.focus").term_id()) .. " " .. (vim.api.nvim_buf_get_name(0):gsub("^claude%-deck://", "")) .. " [" .. vim.fn.getline(".") .. "] " .. vim.bo.filetype .. " " .. tostring(vim.bo.modifiable) .. " " .. vim.api.nvim_get_mode().mode end)()'
}
ct_diff() { # ct diff in terminal $DT from $REPO; prints the output and the exit status
    out=$(cd "$REPO" && NVIM="$SOCK" CLAUDE_DECK_ID="$DT" "$ROOT/bin/ct" diff "$@" 2>&1)
    echo "$out exit=$?"
}
# Without gh on PATH: the uncommitted changes
NOGH="$TEST_OUT/nogh"
mkdir -p "$NOGH"
lua '(function() _G.T_path = vim.env.PATH; vim.env.PATH = vim.env.TEST_OUT .. "/nogh:" .. vim.fn.join(vim.tbl_filter(function(d) return vim.fn.executable(d .. "/gh") == 0 end, vim.split(_G.T_path, ":")), ":"); return vim.fn.executable("gh") end)()' >/dev/null
check "ct diff without a pull request opens git diff HEAD in focus mode" "$(ct_diff)|$(diff_state)" "Opened the diff in the editor (git diff HEAD (uncommitted changes), 3 files) exit=0|$((DIFF_TABS + 1)) #$DT diff/$DT [# git diff HEAD (uncommitted changes)] diff false n"
check "the diff buffer lists the changed files" "$(lua '(function() local l = vim.api.nvim_buf_get_lines(0, 0, -1, false); local r = {}; for _, x in ipairs(l) do if x:find("^diff ") then table.insert(r, x) end end; return table.concat(r, ";") end)()')" "diff --git a/app/gone.txt b/app/gone.txt;diff --git a/app/new file.txt b/app/new file.txt;diff --git a/app/one.txt b/app/one.txt"
check "ct diff path:line goes to that line of the new side" "$(ct_diff app/one.txt:6)|$(diff_state)" "3 files, at app/one.txt:6) exit=0|$((DIFF_TABS + 1)) #$DT diff/$DT [+line 6 new] diff false n"
check "ct diff path goes to the file header" "$(ct_diff app/one.txt)|$(diff_state)" "at app/one.txt) exit=0|$((DIFF_TABS + 1)) #$DT diff/$DT [diff --git a/app/one.txt b/app/one.txt] diff false n"
check "a path relative to a subdirectory" "$(cd "$REPO/app" && NVIM="$SOCK" CLAUDE_DECK_ID="$DT" "$ROOT/bin/ct" diff one.txt:2; echo "exit=$?")|$(diff_state)" "at app/one.txt:2)
exit=0|$((DIFF_TABS + 1)) #$DT diff/$DT [+line 2 changed] diff false n"
check "a line outside the hunks goes to the nearest hunk header" "$(ct_diff app/one.txt:99; diff_state)" "[@@ -1,5 +1,6 @@]"
check "a staged new file with a space" "$(ct_diff 'app/new file.txt:1'; diff_state)" "[+brand new]"
check "a deleted file" "$(ct_diff app/gone.txt; diff_state)" "[diff --git a/app/gone.txt b/app/gone.txt]"
check "an unchanged file fails" "$(ct_diff same.txt)" "ct: no changes in same.txt (git diff HEAD (uncommitted changes)) exit=1"
check "a path outside the repository fails" "$(ct_diff /tmp/x.txt)" "ct: not in the repository: /tmp/x.txt exit=1"
check "an unknown option fails" "$(ct_diff --nope)" "ct: unknown option --nope exit=1"
check "--base without a ref fails" "$(ct_diff --base)" "ct: --base needs a ref exit=1"
check "--pr without gh fails" "$(ct_diff --pr 34)" "ct: --pr needs the GitHub CLI (gh) exit=1"
check "--base compares the working tree with the ref" "$(ct_diff --base HEAD app/one.txt:6; diff_state)" "Opened the diff in the editor (git diff HEAD, 3 files, at app/one.txt:6) exit=0
$((DIFF_TABS + 1)) #$DT diff/$DT [+line 6 new] diff false n"
check "--base with a bad ref fails" "$(ct_diff --base nope)" "ct: git diff nope: fatal: "
check "outside a repository fails" "$(cd "$TEST_OUT" && NVIM="$SOCK" CLAUDE_DECK_ID="$DT" "$ROOT/bin/ct" diff; echo "exit=$?")" "ct: not a git repository: $TEST_OUT
exit=1"
# Keys in the diff buffer
ct_diff app/one.txt >/dev/null
check "]c and [c move between hunks" "$(lua '(function() vim.cmd("normal ]c"); local a = vim.fn.getline("."); vim.cmd("normal [c"); return a .. "|" .. vim.fn.getline(".") end)()')" "@@ -1,5 +1,6 @@|@@ -0,0 +1 @@"
check "]f and [f move between files" "$(lua '(function() vim.cmd("normal [f"); local a = vim.fn.getline("."); vim.cmd("normal ]f"); return a .. "|" .. vim.fn.getline(".") end)()')" "diff --git a/app/new file.txt b/app/new file.txt|diff --git a/app/one.txt b/app/one.txt"
check "<CR> opens the file at the line right of the diff, keeping the diff" "$(lua '(function() vim.fn.search("^+line 6 new"); _G.T_diff_win = vim.api.nvim_get_current_win(); vim.cmd("normal \r"); local wins = vim.api.nvim_tabpage_list_wins(0); return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") .. ":" .. vim.fn.line(".") .. " " .. #wins .. " " .. tostring(vim.api.nvim_win_is_valid(_G.T_diff_win) and (vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(_G.T_diff_win)):gsub("^claude%-deck://", ""))) .. " " .. tostring(vim.api.nvim_win_get_position(0)[2] > vim.api.nvim_win_get_position(_G.T_diff_win)[2] and vim.api.nvim_win_get_position(0)[1] == vim.api.nvim_win_get_position(_G.T_diff_win)[1]) end)()')" "one.txt:6 4 diff/$DT true"
check "<CR> on a removed line opens the line that follows" "$(lua '(function() vim.api.nvim_set_current_win(_G.T_diff_win); vim.fn.search("^-line 2"); vim.cmd("normal \r"); return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") .. ":" .. vim.fn.line(".") .. " " .. #vim.api.nvim_tabpage_list_wins(0) end)()')" "one.txt:2 4"
check "<CR> on a deleted file warns" "$(lua '(function() vim.api.nvim_set_current_win(_G.T_diff_win); vim.fn.search("^-gone"); return T_notify(function() vim.cmd("normal \r") end) end)()')" "app/gone.txt does not exist in the working tree"
check "<CR> above the first file warns" "$(lua '(function() vim.api.nvim_win_set_cursor(0, { 1, 0 }); return T_notify(function() vim.cmd("normal \r") end) end)()')" "move to a file section first"
check "ct open beside a shown diff keeps the diff" "$(ct_diff app/one.txt:6 >/dev/null; lua '(function() local r = require("claude-deck.cli").open('"$DT"', "same.txt", "'"$REPO"'"); return r .. " " .. #vim.api.nvim_tabpage_list_wins(0) .. " " .. tostring(vim.api.nvim_win_is_valid(_G.T_diff_win)) end)()')" "Opened same.txt in the editor 4 true"
# send_location from the diff buffer
check "send_location in the diff sends the file and line of the new side" "$(lua '(function() vim.api.nvim_set_current_win(_G.T_diff_win); vim.fn.search("^+line 6 new"); local before = #vim.fn.readfile(vim.env.TEST_OUT .. "/stdin.'"$DT"'", "b"); require("claude-deck").send_location(); vim.wait(500, function() return #vim.fn.readfile(vim.env.TEST_OUT .. "/stdin.'"$DT"'", "b") > before end); vim.cmd("stopinsert"); return vim.fn.readfile(vim.env.TEST_OUT .. "/stdin.'"$DT"'", "b")[#vim.fn.readfile(vim.env.TEST_OUT .. "/stdin.'"$DT"'", "b")] end)()')" "app/one.txt:6 "
check "send_location on the header warns" "$(lua '(function() vim.api.nvim_set_current_win(_G.T_diff_win); vim.api.nvim_win_set_cursor(0, { 1, 0 }); return T_notify(function() require("claude-deck").send_location() end) end)()')" "move to a changed line of the diff first"
check "q closes the diff window" "$(lua '(function() vim.api.nvim_set_current_win(_G.T_diff_win); vim.cmd("normal q"); return #vim.api.nvim_tabpage_list_wins(0) .. " " .. tostring(vim.api.nvim_win_is_valid(_G.T_diff_win)) end)()')" "3 false"
# With a pull request: a fake gh
mkdir -p "$TEST_OUT/ghbin"
cat >"$TEST_OUT/ghbin/gh" <<'GH'
#!/bin/sh
case "$*" in
"pr view --json number,title,baseRefName") printf '{"number":12,"title":"Greet twice","baseRefName":"main"}\n' ;;
"pr diff") printf 'diff --git a/app/one.txt b/app/one.txt\nindex 1..2 100644\n--- a/app/one.txt\n+++ b/app/one.txt\n@@ -1,3 +1,3 @@\n line 1\n-line 2\n+line 2 from the PR\n line 3\n' ;;
"pr view 34 --json number,title,baseRefName") printf '{"number":34,"title":"Other PR","baseRefName":"develop"}\n' ;;
"pr diff 34") printf 'diff --git a/same.txt b/same.txt\nindex 1..2 100644\n--- a/same.txt\n+++ b/same.txt\n@@ -1 +1 @@\n-same\n+same, from PR 34\n' ;;
"pr view 99 --json number,title,baseRefName") echo "GraphQL: Could not resolve to a PullRequest with the number of 99." >&2; exit 1 ;;
*) echo "gh: unexpected $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TEST_OUT/ghbin/gh"
lua '(function() vim.env.PATH = vim.env.TEST_OUT .. "/ghbin:" .. vim.env.PATH; return "" end)()' >/dev/null
check "ct diff with a pull request opens gh pr diff" "$(ct_diff app/one.txt:2; diff_state)" "Opened the diff in the editor (PR #12 Greet twice (base: main), 1 file, at app/one.txt:2) exit=0
$((DIFF_TABS + 1)) #$DT diff/$DT [+line 2 from the PR] diff false n"
check "the header line names the PR" "$(lua 'vim.fn.getline(1)')" "# PR #12 Greet twice (base: main)"
check "--base skips the pull request" "$(ct_diff --base HEAD)" "git diff HEAD, 3 files) exit=0"
check "--pr opens another pull request" "$(ct_diff --pr 34 same.txt:1; diff_state)" "Opened the diff in the editor (PR #34 Other PR (base: develop), 1 file, at same.txt:1) exit=0
$((DIFF_TABS + 1)) #$DT diff/$DT [+same, from PR 34] diff false n"
check "--pr with an unknown pull request fails" "$(ct_diff --pr 99)" "ct: pull request 99: GraphQL: Could not resolve to a PullRequest with the number of 99. exit=1"
check "--pr without a value fails" "$(ct_diff --pr)" "ct: --pr needs a pull request number, URL or branch exit=1"
check "the diff buffer is reused" "$(lua '(function() local n = 0; for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_get_name(b):find("claude%-deck://diff/") then n = n + 1 end end; return n end)()')" "1"
check "open_diff() uses the terminal of the focus mode tab" "$(lua '(function() require("claude-deck").open_diff({ path = "app/one.txt", line = 2 }); return "" end)()')$(diff_state)" "[+line 2 from the PR] diff false n"
check ":ClaudeDeck diff --base ref path:line" "$(lua '(function() local cwd = vim.fn.getcwd(); vim.cmd("tcd '"$REPO"'"); vim.cmd("ClaudeDeck diff --base HEAD app/one.txt:6"); vim.cmd("tcd " .. vim.fn.fnameescape(cwd)); return "" end)()')$(diff_state)" "[+line 6 new] diff false n"
check ":ClaudeDeck diff with an unknown option warns" "$(lua 'T_notify(function() vim.cmd("ClaudeDeck diff --nope") end)')" "unknown option --nope"
check "open_diff() outside a terminal warns" "$(lua '(function() vim.cmd("tabclose"); vim.api.nvim_set_current_tabpage(_G.T_diff_origin); vim.cmd("stopinsert | vnew"); return T_notify(function() require("claude-deck").open_diff() end) end)()')" "run this inside a terminal or its focus mode"
lua '(function() vim.env.PATH = _G.T_path; vim.cmd("tabclose!"); return "" end)()' >/dev/null
check "ClaudeDeck diff completes files" "$(lua 'table.concat(vim.fn.getcompletion("ClaudeDeck diff tests/fixtures/open/g", "cmdline"), ",")')" "tests/fixtures/open/greeter.rb"

# Per-terminal model, ct list --json, ct spawn
model_args() { # id: the arguments of terminal $1 on one line
    sleep 0.4
    tr '\n' ' ' <"$TEST_OUT/args.$1"
}
lua '(function() vim.cmd("tabnew"); return "" end)()' >/dev/null
MT=$(lua '(function() require("claude-deck").new(nil, { model = "haiku" }); vim.cmd("stopinsert"); return vim.b.claude_deck_id end)()')
check "new(opts.model) passes --model as separate arguments" "$(sleep 0.4; grep -x -A1 -e '--model' "$TEST_OUT/args.$MT" | tr '\n' ' ')" "--model haiku"
check "new() without a model passes no --model" "$(lua '(function() require("claude-deck").new("below"); vim.cmd("stopinsert"); local id = vim.b.claude_deck_id; vim.wait(500); local n = #vim.tbl_filter(function(l) return l == "--model" end, vim.fn.readfile(vim.env.TEST_OUT .. "/args." .. id)); vim.cmd("close"); return "models=" .. n end)()')" "models=0"
check "the requested model is recorded" "$(lua 'tostring(require("claude-deck.state").get('"$MT"').model)')" "haiku"
hook "$MT" SessionStart '{"cwd":"'"$ROOT"'","session_id":"sess-model"}'
lua '(function() require("claude-deck").fork(); vim.cmd("stopinsert"); return "" end)()' >/dev/null
MF=$(lua 'vim.b.claude_deck_id')
check "fork inherits the model" "$(model_args "$MF")" "--fork-session --model haiku"
lua '(function() vim.cmd("close"); require("claude-deck").fork("below", { model = "sonnet" }); vim.cmd("stopinsert"); return "" end)()' >/dev/null
MF2=$(lua 'vim.b.claude_deck_id')
check "fork with an explicit model overrides" "$(model_args "$MF2")" "--fork-session --model sonnet"
lua '(function() vim.cmd("close"); vim.cmd("ClaudeDeck new below --model sonnet"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
check ":ClaudeDeck new below --model sonnet" "$(model_args "$(lua 'vim.b.claude_deck_id')")" "--model sonnet"
lua '(function() vim.cmd("close"); vim.cmd("ClaudeDeck new --model=opus below"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
check ":ClaudeDeck new accepts the arguments in any order" "$(lua 'require("claude-deck.state").get(vim.b.claude_deck_id).model .. " " .. #vim.api.nvim_tabpage_list_wins(0)')" "opus 2"
lua '(function() vim.cmd("close"); vim.cmd("ClaudeDeck fork below --model haiku"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
check ":ClaudeDeck fork --model" "$(model_args "$(lua 'vim.b.claude_deck_id')")" "--fork-session --model haiku"
check ":ClaudeDeck new with a bad argument warns" "$(lua 'T_notify(function() vim.cmd("ClaudeDeck new right below") end)')" "usage: ClaudeDeck new|fork"
lua '(function() vim.cmd("close"); return "" end)()' >/dev/null
# redraw keeps the model
lua '(function() vim.cmd("only"); vim.api.nvim_set_current_buf(require("claude-deck.state").get('"$MT"').buf); return "" end)()' >/dev/null
hook "$MT" Stop '{}'
lua '(function() require("claude-deck").redraw(); return "" end)()' >/dev/null
sleep 1.5
check "redraw keeps the model" "$(model_args "$MT")" "--resume sess-model --model haiku"
lua '(function() vim.cmd("stopinsert"); return "" end)()' >/dev/null
# An explicit model replaces --model in cmd; otherwise cmd is untouched
lua '(function() local o = vim.deepcopy(T_opts); vim.list_extend(o.cmd, { "--model", "opus" }); require("claude-deck").setup(o); require("claude-deck").new("below"); vim.cmd("stopinsert"); _G.T_id1 = vim.b.claude_deck_id; vim.cmd("close"); require("claude-deck").new("below", { model = "haiku" }); vim.cmd("stopinsert"); _G.T_id2 = vim.b.claude_deck_id; vim.cmd("close"); local o2 = vim.deepcopy(T_opts); vim.list_extend(o2.cmd, { "--model=opus" }); require("claude-deck").setup(o2); require("claude-deck").new("below", { model = "haiku" }); vim.cmd("stopinsert"); _G.T_id3 = vim.b.claude_deck_id; vim.cmd("close"); require("claude-deck").setup(T_opts); return "" end)()' >/dev/null
sleep 0.5
M1=$(lua '_G.T_id1') M2=$(lua '_G.T_id2') M3=$(lua '_G.T_id3')
check "cmd with --model is kept without an explicit model" "$(model_args "$M1")" "--model opus"
check "an explicit model replaces --model in cmd" "$(model_args "$M2")" "--model haiku"
check "the replaced --model is not duplicated" "$(grep -c -x -e '--model' "$TEST_OUT/args.$M2")|$(grep -c opus "$TEST_OUT/args.$M2")" "1|0"
check "an explicit model replaces --model=X in cmd" "$(grep -c -x -e '--model' "$TEST_OUT/args.$M3")|$(grep -c -x -e '--model=opus' "$TEST_OUT/args.$M3")" "1|0"

# Per-terminal permission mode
lua '(function() vim.cmd("only"); require("claude-deck").new("below", { permission_mode = "acceptEdits" }); vim.cmd("stopinsert"); return "" end)()' >/dev/null
PT=$(lua 'vim.b.claude_deck_id')
check "new(opts.permission_mode) passes --permission-mode and the value" "$(model_args "$PT")" "--permission-mode acceptEdits"
check "the requested permission mode is recorded" "$(lua 'tostring(require("claude-deck.state").get('"$PT"').permission_mode)')" "acceptEdits"
check "new() inherits no permission mode" "$(lua 'tostring(require("claude-deck.state").get('"$MT"').permission_mode)')" "nil"
hook "$PT" SessionStart '{"cwd":"'"$ROOT"'","session_id":"sess-perm"}'
lua '(function() require("claude-deck").fork(); vim.cmd("stopinsert"); return "" end)()' >/dev/null
PF=$(lua 'vim.b.claude_deck_id')
check "fork inherits the permission mode" "$(model_args "$PF")" "--resume sess-perm --fork-session --permission-mode acceptEdits"
lua '(function() vim.cmd("close"); require("claude-deck").fork("below", { permission_mode = "plan" }); vim.cmd("stopinsert"); return "" end)()' >/dev/null
check "fork with an explicit permission mode overrides" "$(model_args "$(lua 'vim.b.claude_deck_id')")" "--resume sess-perm --fork-session --permission-mode plan"
lua '(function() vim.cmd("close"); vim.cmd("ClaudeDeck new below --permission-mode acceptEdits"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
check ":ClaudeDeck new below --permission-mode acceptEdits" "$(model_args "$(lua 'vim.b.claude_deck_id')")" "--permission-mode acceptEdits"
lua '(function() vim.cmd("close"); vim.cmd("ClaudeDeck fork below --permission-mode=auto"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
check ":ClaudeDeck fork --permission-mode=auto" "$(model_args "$(lua 'vim.b.claude_deck_id')")" "--permission-mode auto"
lua '(function() vim.cmd("close"); return "" end)()' >/dev/null
check ":ClaudeDeck new with an invalid permission mode warns" "$(lua 'T_notify(function() vim.cmd("ClaudeDeck new below --permission-mode nope") end)')" "invalid permission mode: nope (use default, acceptEdits, plan, auto or bypassPermissions)"
# redraw keeps the permission mode
lua '(function() vim.api.nvim_set_current_buf(require("claude-deck.state").get('"$PT"').buf); return "" end)()' >/dev/null
hook "$PT" Stop '{}'
lua '(function() require("claude-deck").redraw(); return "" end)()' >/dev/null
sleep 1.5
check "redraw keeps the permission mode" "$(model_args "$PT")" "--resume sess-perm --permission-mode acceptEdits"
lua '(function() vim.cmd("stopinsert"); return "" end)()' >/dev/null
# An explicit mode replaces --permission-mode in cmd
lua '(function() local o = vim.deepcopy(T_opts); vim.list_extend(o.cmd, { "--permission-mode", "plan" }); require("claude-deck").setup(o); require("claude-deck").new("below"); vim.cmd("stopinsert"); _G.T_id1 = vim.b.claude_deck_id; vim.cmd("close"); require("claude-deck").new("below", { permission_mode = "acceptEdits" }); vim.cmd("stopinsert"); _G.T_id2 = vim.b.claude_deck_id; vim.cmd("close"); local o2 = vim.deepcopy(T_opts); vim.list_extend(o2.cmd, { "--permission-mode=plan" }); require("claude-deck").setup(o2); require("claude-deck").new("below", { permission_mode = "acceptEdits" }); vim.cmd("stopinsert"); _G.T_id3 = vim.b.claude_deck_id; vim.cmd("close"); require("claude-deck").setup(T_opts); return "" end)()' >/dev/null
sleep 0.5
P1=$(lua '_G.T_id1') P2=$(lua '_G.T_id2') P3=$(lua '_G.T_id3')
check "cmd with --permission-mode is kept without an explicit mode" "$(model_args "$P1")" "--permission-mode plan"
check "an explicit mode replaces --permission-mode in cmd" "$(grep -c -x -e '--permission-mode' "$TEST_OUT/args.$P2")|$(grep -c -x plan "$TEST_OUT/args.$P2")|$(grep -c -x acceptEdits "$TEST_OUT/args.$P2")" "1|0|1"
check "an explicit mode replaces --permission-mode=X in cmd" "$(grep -c -x -e '--permission-mode' "$TEST_OUT/args.$P3")|$(grep -c -x -e '--permission-mode=plan' "$TEST_OUT/args.$P3")" "1|0"
check "ct list shows the permission mode" "$(NVIM="$SOCK" bin/ct list)" "permission_mode: acceptEdits"
check "ct list shows (default) without a permission mode" "$(NVIM="$SOCK" bin/ct list)" "permission_mode: (default)"
JP=$(NVIM="$SOCK" CLAUDE_DECK_ID="$MT" bin/ct list --json)
check "ct list --json: permission_mode follows model" "$JP" '"model":"haiku","permission_mode":null'
check "ct list --json: permission_mode value" "$JP" '"permission_mode":"acceptEdits"'
lua '(function() vim.cmd("only"); vim.api.nvim_set_current_buf(require("claude-deck.state").get('"$MT"').buf); return "" end)()' >/dev/null

# ct list shows the model; ct list --json
check "ct list shows the model" "$(NVIM="$SOCK" bin/ct list)" "model: haiku"
check "ct list shows (default) without a model" "$(NVIM="$SOCK" bin/ct list)" "model: (default)"
hook "$MT" Stop '{}'
JS=$(NVIM="$SOCK" CLAUDE_DECK_ID="$MT" bin/ct list --json)
rec() { echo "$JS" | sed 's/},{"id"/}\n{"id"/g' | grep '^{"id":'"$1"',\|"terminals":\[{"id":'"$1"',' | head -1; }
check "ct list --json: self" "$JS" '"self":'"$MT"
check "ct list --json: internal state" "$(rec "$MT")" '"state":"waiting"'
check "ct list --json: model" "$(rec "$MT")" '"model":"haiku"'
check "ct list --json: session_id" "$(rec "$MT")" '"session_id":"sess-model"'
check "ct list --json: missing values are null" "$(rec 1)" '"model":null'
check "ct list --json: missing spawned_by is null" "$(rec 1)" '"spawned_by":null'
check "ct list --json outside a terminal has a null self" "$(NVIM="$SOCK" CLAUDE_DECK_ID= bin/ct list --json)" '"self":null'
check "ct list --json is sorted by id" "$(ids=$(echo "$JS" | grep -o '"id":[0-9]*' | cut -d: -f2); [ "$ids" = "$(echo "$ids" | sort -n)" ] && echo sorted)" "sorted"
check "permissions allow ct list with arguments" "$(lua 'require("claude-deck.hooks").settings_json()')" '"Bash(ct list:*)"'
check "permissions do not allow ct spawn" "$(lua 'tostring(require("claude-deck.hooks").settings_json():find("ct spawn", 1, true))')" "nil"
check "system prompt tells about ct spawn" "$(cat "$TEST_OUT/args.$MT")" '`ct spawn --title <title>'

# Per-terminal orchestration flag, ct orchestrate, PreToolUse hook
ct_as() { NVIM="$SOCK" CLAUDE_DECK_ID="$1" bin/ct "${@:2}" 2>&1; }
pre() { # id, command: the stdout of the PreToolUse hook
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$2" | NVIM="$SOCK" CLAUDE_DECK_ID="$1" bin/claude-deck-hook PreToolUse
}
check "orchestration is off by default" "$(ct_as "$MT" orchestrate status)" "orchestration: off"
check "ct list shows orchestration off" "$(NVIM="$SOCK" bin/ct list)" "orchestration: off"
check "ct list --json: orchestration false" "$(NVIM="$SOCK" bin/ct list --json | grep -o '"id":'"$MT"',.*' | grep -o '"orchestration":[a-z]*' | head -1)" '"orchestration":false'
check "PreToolUse: flag off gives no decision (spawn)" "[$(pre "$MT" 'ct spawn --prompt x')]" "[]"
check "PreToolUse: flag off gives no decision (send)" "[$(pre "$MT" 'ct send 3 --prompt x')]" "[]"
STATE_BEFORE=$(lua 'require("claude-deck.state").get('"$MT"').state')
check "ct orchestrate on" "$(ct_as "$MT" orchestrate on)" "orchestration: on"
check "ct orchestrate status after on" "$(ct_as "$MT" orchestrate status)" "orchestration: on"
check "ct list --json: orchestration true" "$(NVIM="$SOCK" bin/ct list --json | grep -o '"id":'"$MT"',.*' | grep -o '"orchestration":[a-z]*' | head -1)" '"orchestration":true'
check "ct list shows orchestration on" "$(NVIM="$SOCK" bin/ct list)" "orchestration: on"
check "PreToolUse: flag on allows ct spawn" "$(pre "$MT" 'ct spawn --prompt x')" '"permissionDecision":"allow"'
check "PreToolUse: the decision names the hook event" "$(pre "$MT" 'ct spawn --prompt x')" '"hookEventName":"PreToolUse"'
check "PreToolUse: flag on allows ct send" "$(pre "$MT" 'ct send 3 --prompt x')" '"permissionDecision":"allow"'
check "PreToolUse: command ct spawn is allowed" "$(pre "$MT" '  command ct spawn --prompt x')" '"permissionDecision":"allow"'
check "PreToolUse: ct list gives no decision" "[$(pre "$MT" 'ct list')]" "[]"
check "PreToolUse: ct spawnx gives no decision" "[$(pre "$MT" 'ct spawnx')]" "[]"
check "PreToolUse: another command gives no decision" "[$(pre "$MT" 'rm -rf x; ct spawn')]" "[]"
check "PreToolUse: ct orchestrate gives no decision" "[$(pre "$MT" 'ct orchestrate on')]" "[]"
check "PreToolUse: other tools give no decision" "[$(printf '{"tool_name":"Read","tool_input":{"command":"ct spawn x"}}' | NVIM="$SOCK" CLAUDE_DECK_ID="$MT" bin/claude-deck-hook PreToolUse)]" "[]"
check "PreToolUse: unknown terminal gives no decision" "[$(pre 99999 'ct spawn --prompt x')]" "[]"
check "PreToolUse: bad JSON gives no decision" "[$(echo '{' | NVIM="$SOCK" CLAUDE_DECK_ID="$MT" bin/claude-deck-hook PreToolUse)]" "[]"
check "other events print nothing" "[$(echo '{}' | NVIM="$SOCK" CLAUDE_DECK_ID="$MT" bin/claude-deck-hook Stop)]" "[]"
sleep 0.2
check "PreToolUse does not change the state" "$(lua 'require("claude-deck.state").get('"$MT"').state')" "$STATE_BEFORE"
check "ct orchestrate off" "$(ct_as "$MT" orchestrate off)" "orchestration: off"
check "PreToolUse: flag off again gives no decision" "[$(pre "$MT" 'ct spawn --prompt x')]" "[]"
check "ct orchestrate without an argument shows usage" "$(ct_as "$MT" orchestrate; true)" "ct orchestrate on|off|status"
check "permissions do not allow ct orchestrate" "$(lua 'tostring(require("claude-deck.hooks").settings_json():find("ct orchestrate", 1, true))')" "nil"
check "settings has a PreToolUse hook with the Bash matcher" "$(lua '(function() local h = vim.json.decode(require("claude-deck.hooks").settings_json()).hooks.PreToolUse[1]; return h.matcher .. " " .. h.hooks[1].command:match("claude%-deck%-hook. PreToolUse$") end)()')" "Bash claude-deck-hook' PreToolUse"
check "settings PreToolUse matcher" "$(lua 'require("claude-deck.hooks").settings_json()')" '"matcher":"Bash"'
check "system prompt tells about ct orchestrate" "$(cat "$TEST_OUT/args.$MT")" 'ct orchestrate on'
check "set_orchestration(id, true)" "$(lua '(function() require("claude-deck").set_orchestration('"$MT"', true); return tostring(require("claude-deck.state").get('"$MT"').orchestration) end)()')" "true"
check ":ClaudeDeck orchestrate off" "$(lua '(function() vim.cmd("ClaudeDeck orchestrate off"); return tostring(require("claude-deck.state").get('"$MT"').orchestration) end)()')" "false"
check ":ClaudeDeck orchestrate with a bad argument warns" "$(lua 'T_notify(function() vim.cmd("ClaudeDeck orchestrate maybe") end)')" "usage: ClaudeDeck orchestrate on|off"
lua '(function() vim.cmd("ClaudeDeck new below --orchestrate"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
check ":ClaudeDeck new --orchestrate sets the flag" "$(lua 'tostring(require("claude-deck.state").get(vim.b.claude_deck_id).orchestration)')" "true"
lua 'vim.cmd("close")' >/dev/null
lua '(function() vim.api.nvim_set_current_buf(require("claude-deck.state").get('"$MT"').buf); require("claude-deck.state").get('"$MT"').orchestration = true; vim.cmd("ClaudeDeck fork below"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
check "fork inherits the flag" "$(lua 'tostring(require("claude-deck.state").get(vim.b.claude_deck_id).orchestration)')" "true"
lua 'vim.cmd("close")' >/dev/null
lua '(function() vim.api.nvim_set_current_buf(require("claude-deck.state").get('"$MT"').buf); vim.cmd("ClaudeDeck fork below --orchestrate"); vim.cmd("stopinsert"); require("claude-deck.state").get(vim.b.claude_deck_id).orchestration = false; vim.cmd("close"); require("claude-deck.state").get('"$MT"').orchestration = false; return "" end)()' >/dev/null
check "new(opts.orchestration = false) is off" "$(lua '(function() require("claude-deck").new("below", { orchestration = false }); vim.cmd("stopinsert"); local v = tostring(require("claude-deck.state").get(vim.b.claude_deck_id).orchestration); vim.cmd("close"); return v end)()')" "false"
check "spawn({ orchestration = true }) sets the flag" "$(lua '(function() local id = require("claude-deck").spawn({ prompt = "x", orchestration = true }); local t = require("claude-deck.state").get(id); local v = tostring(t.orchestration); require("claude-deck.state").remove(id); pcall(vim.api.nvim_buf_delete, t.buf, { force = true }); return v end)()')" "true"
check "cli.allow_orchestration makes new terminals default on" "$(lua '(function() local o = vim.deepcopy(T_opts); o.cli = vim.tbl_extend("force", o.cli or {}, { allow_orchestration = true }); require("claude-deck").setup(o); require("claude-deck").new("below"); vim.cmd("stopinsert"); local v = tostring(require("claude-deck.state").get(vim.b.claude_deck_id).orchestration); vim.cmd("close"); require("claude-deck").new("below", { orchestration = false }); vim.cmd("stopinsert"); v = v .. " " .. tostring(require("claude-deck.state").get(vim.b.claude_deck_id).orchestration); vim.cmd("close"); require("claude-deck").setup(T_opts); return v end)()')" "true false"

# ct spawn
SP="$TEST_OUT/prompt.txt"
printf 'Fix the bug\nin "parser" $HOME\n' >"$SP"
lua '(function() vim.cmd("only"); vim.api.nvim_set_current_buf(require("claude-deck.state").get('"$MT"').buf); vim.cmd("startinsert"); return "" end)()' >/dev/null
sleep 0.3
spawn_state() { # current tab, number of windows, terminal id, mode
    lua 'vim.api.nvim_get_current_tabpage() .. " " .. #vim.api.nvim_tabpage_list_wins(0) .. " #" .. vim.b.claude_deck_id .. " " .. vim.api.nvim_get_mode().mode'
}
ct_spawn() { # runs ct spawn in terminal $MT; prints output and exit status
    out=$(NVIM="$SOCK" CLAUDE_DECK_ID="$MT" bin/ct spawn "$@" 2>&1)
    echo "$out exit=$?"
}
BEFORE=$(spawn_state)
TABS_BEFORE=$(lua '#vim.api.nvim_list_tabpages()')
OUT=$(NVIM="$SOCK" CLAUDE_DECK_ID="$MT" bin/ct spawn --title "Worker one" --cwd tests/fixtures --model haiku --prompt-file "$SP" 2>&1; echo "exit=$?")
SID=$(echo "$OUT" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
check "ct spawn prints JSON with cwd" "$OUT" '"cwd":"'"$ROOT"'/tests/fixtures"'
check "ct spawn prints the title" "$OUT" '"title":"Worker one"'
check "ct spawn prints the model" "$OUT" '"model":"haiku"'
check "ct spawn: exit status 0" "$OUT" "exit=0"
check "ct spawn leaves tab, window, buffer and mode alone" "$(spawn_state)" "$BEFORE"
check "ct spawn creates no tab" "$(lua '#vim.api.nvim_list_tabpages()')" "$TABS_BEFORE"
check "ct spawn: the terminal is hidden" "$(lua '#vim.fn.win_findbuf(require("claude-deck.state").get('"$SID"').buf)')" "0"
check "ct spawn creates no floating window" "$(lua '#vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())')" "0"
sleep 0.5
check "ct spawn: the prompt is the last argument" "$(tail -n 2 "$TEST_OUT/args.$SID" | tr '\n' '|')" 'in "parser" $HOME|'
check "ct spawn: the prompt follows the model and --" "$(tail -n 5 "$TEST_OUT/args.$SID" | head -3 | tr '\n' '|')" '--model|haiku|--|'
check "ct spawn: record" "$(lua '(function() local t = require("claude-deck.state").get('"$SID"'); return t.cwd .. "|" .. t.model .. "|" .. t.title .. "|" .. t.title_source .. "|" .. tostring(t.spawned) .. "|" .. t.spawned_by .. "|" .. t.state end)()')" "$ROOT/tests/fixtures|haiku|Worker one|claude|true|$MT|idle"
check "ct spawn: ct list --json has spawned_by" "$(NVIM="$SOCK" bin/ct list --json | grep -o '"id":'"$SID"',[^}]*')" '"spawned_by":'"$MT"
check "ct spawn registers the prompt as a request" "$(lua '(function() local r = require("claude-deck.state").get('"$SID"').last_request; return tostring(r.received) .. " " .. r.from .. " " .. r.text end)()')" "false $MT Fix the bug"
check "ct spawn: the system prompt belongs to the new id" "$(cat "$TEST_OUT/args.$SID")" "terminal #$SID of claude-deck"
check "ct spawn: a later show displays it and fits the pty" "$(lua '(function() local calls = {}; local jr = vim.fn.jobresize; vim.fn.jobresize = function(j, w, h) table.insert(calls, w .. "x" .. h); return jr(j, w, h) end; require("claude-deck").show('"$SID"'); vim.cmd("stopinsert"); vim.fn.jobresize = jr; local w = vim.api.nvim_get_current_win(); return vim.b.claude_deck_id .. " " .. tostring(calls[#calls] == vim.api.nvim_win_get_width(w) .. "x" .. vim.api.nvim_win_get_height(w) - 1) end)()')" "$SID true"
lua '(function() vim.cmd("close"); vim.api.nvim_set_current_buf(require("claude-deck.state").get('"$MT"').buf); vim.cmd("startinsert"); return "" end)()' >/dev/null
# A prompt starting with "-" goes after --; relative --cwd is relative to the shell's $PWD
OUT=$(cd tests/fixtures && NVIM="$SOCK" CLAUDE_DECK_ID="$MT" "$ROOT/bin/ct" spawn --prompt "-x: a dash" --cwd open 2>&1; echo "exit=$?")
SID2=$(echo "$OUT" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
sleep 0.5
check "ct spawn --prompt with a leading dash uses --" "$(tail -n 3 "$TEST_OUT/args.$SID2" | tr '\n' '|')" '--|-x: a dash|'
check "ct spawn: relative --cwd is relative to \$PWD" "$OUT" '"cwd":"'"$ROOT"'/tests/fixtures/open"'
check "ct spawn without a title or model has nulls" "$OUT" '"model":null'
check "ct spawn without a title has a null title" "$OUT" '"title":null'
OUT=$(cd tests/fixtures && NVIM="$SOCK" CLAUDE_DECK_ID="$MT" "$ROOT/bin/ct" spawn --prompt-file ../../tests/minimal_init.lua 2>&1; echo "exit=$?")
SID4=$(echo "$OUT" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
sleep 0.5
check "ct spawn: relative --prompt-file is relative to \$PWD" "$(grep -c '^-- Minimal config for tests/smoke.sh' "$TEST_OUT/args.$SID4")|$OUT" "1|{"
# errors
check "ct spawn without a prompt fails" "$(ct_spawn --title x)" "ct: no prompt given (use --prompt or --prompt-file) exit=1"
check "ct spawn with both prompts fails" "$(ct_spawn --prompt a --prompt-file "$SP")" "ct: use either --prompt or --prompt-file, not both exit=1"
check "ct spawn with a missing prompt file fails" "$(ct_spawn --prompt-file /nonexistent/x.md)" "ct: cannot read the prompt file: /nonexistent/x.md exit=1"
check "ct spawn with a bad cwd fails" "$(ct_spawn --prompt a --cwd /nonexistent)" "ct: not a directory: /nonexistent exit=1"
check "ct spawn with a file as cwd fails" "$(ct_spawn --prompt a --cwd "$SP")" "ct: not a directory"
check "ct spawn refuses a title over 40 cells" "$(ct_spawn --prompt a --title あいうえおかきくけこさしすせそたちつてとな)" "ct: title is too long (42 cells, max 40) exit=1"
check "ct spawn with an unknown argument fails" "$(ct_spawn --prompt a --nope)" "ct: unknown argument --nope exit=1"
check "ct spawn with an option without a value fails" "$(ct_spawn --prompt)" "ct: --prompt needs a value exit=1"
check "ct spawn outside a terminal fails" "$(NVIM="$SOCK" CLAUDE_DECK_ID= bin/ct spawn --prompt a 2>&1; echo "exit=$?")" "ct: run this inside a claude-deck terminal"
check "failed spawns created no terminals" "$(lua '#vim.tbl_filter(function(t) return t.spawned end, require("claude-deck.state").sorted())')" "3"
# The limit (3) is reached by the three spawned terminals so far
check "ct spawn stops at the limit" "$(ct_spawn --prompt a)" "ct: spawn limit reached (3) exit=1"
lua '(function() local t = require("claude-deck.state").get('"$SID2"'); vim.fn.jobstop(t.job); vim.wait(3000, function() return t.state == "exited" end); return "" end)()' >/dev/null
check "an exited spawned terminal frees a slot" "$(ct_spawn --prompt a)" '"id":'
# --show: to the right of the caller, the focus stays
lua '(function() local o = vim.deepcopy(T_opts); o.cli = { spawn_limit = 10 }; require("claude-deck").setup(o); return "" end)()' >/dev/null
BEFORE=$(spawn_state)
OUT=$(NVIM="$SOCK" CLAUDE_DECK_ID="$MT" bin/ct spawn --show --prompt "shown" --model sonnet 2>&1; echo "exit=$?")
SID3=$(echo "$OUT" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
check "ct spawn --show succeeds" "$OUT" "exit=0"
check "ct spawn --show opens a window to the right and keeps the focus" "$(spawn_state)|$(lua '(function() local b = require("claude-deck.state").get('"$SID3"').buf; local w = vim.fn.win_findbuf(b)[1]; return tostring(w ~= nil and vim.api.nvim_win_get_position(w)[2] > vim.api.nvim_win_get_position(0)[2]) end)()')" "$(echo "$BEFORE" | sed 's/ [0-9]* #/ 2 #/')|true"
sleep 0.5
check "ct spawn --show passes the model and prompt" "$(tail -n 4 "$TEST_OUT/args.$SID3" | tr '\n' ' ')" "--model sonnet -- shown"
lua '(function() local b = require("claude-deck.state").get('"$SID3"').buf; vim.api.nvim_win_close(vim.fn.win_findbuf(b)[1], true); return "" end)()' >/dev/null
# --show without a window of the caller in the tab: at the far right, the focus stays
lua '(function() vim.cmd("tabnew"); _G.T_tabw = vim.api.nvim_get_current_win(); return "" end)()' >/dev/null
OUT=$(ct_spawn --show --prompt "far right")
check "ct spawn --show without a caller window succeeds" "$OUT" "exit=0"
check "ct spawn --show without a caller window opens at the far right" "$(lua '(function() local wins = vim.api.nvim_tabpage_list_wins(0); local other = vim.tbl_filter(function(w) return w ~= _G.T_tabw end, wins)[1]; return #wins .. " " .. tostring(vim.api.nvim_get_current_win() == _G.T_tabw) .. " " .. tostring(other ~= nil and vim.api.nvim_win_get_position(other)[2] > vim.api.nvim_win_get_position(_G.T_tabw)[2]) end)()')" "2 true true"
lua '(function() vim.cmd("tabclose!"); return "" end)()' >/dev/null
# A failing start leaves nothing behind
FAIL_TERMS=$(NVIM="$SOCK" bin/ct list --json | grep -o '"spawned_by"' | wc -l | tr -d ' ')
FAIL_WINS=$(lua '#vim.api.nvim_list_wins()')
FAIL_EI=$(lua 'vim.o.eventignore')
lua '(function() local o = vim.deepcopy(T_opts); o.cmd = { "/nonexistent/claude" }; o.cli = { spawn_limit = 10 }; require("claude-deck").setup(o); return "" end)()' >/dev/null
OUT=$(ct_spawn --prompt "will fail")
lua '(function() local o = vim.deepcopy(T_opts); o.cli = { spawn_limit = 10 }; require("claude-deck").setup(o); return "" end)()' >/dev/null
check "ct spawn with a bad cmd returns an error" "$OUT" "ct: "
check "ct spawn with a bad cmd names the command" "$OUT" "nonexistent"
check "ct spawn with a bad cmd opens no window" "$(lua '#vim.api.nvim_list_wins()')" "$FAIL_WINS"
check "ct spawn with a bad cmd adds no terminal" "$(NVIM="$SOCK" bin/ct list --json | grep -o '"spawned_by"' | wc -l | tr -d ' ')" "$FAIL_TERMS"
check "ct spawn with a bad cmd restores eventignore" "$(lua 'vim.o.eventignore')" "$FAIL_EI"
# ct spawn --permission-mode and cli.spawn_permission_mode
OUT=$(ct_spawn --prompt "pm" --permission-mode auto)
SIDP=$(echo "$OUT" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
sleep 0.5
check "ct spawn --permission-mode auto prints the mode" "$OUT" '"permission_mode":"auto"'
check "ct spawn --permission-mode passes the mode before --" "$(tail -n 4 "$TEST_OUT/args.$SIDP" | head -2 | tr '\n' ' ')" "--permission-mode auto "
check "ct spawn: permission mode is recorded" "$(lua 'require("claude-deck.state").get('"$SIDP"').permission_mode')" "auto"
check "ct spawn --permission-mode=plan form" "$(ct_spawn --prompt pm --permission-mode=plan)" '"permission_mode":"plan"'
check "ct spawn without a mode passes none" "$(ct_spawn --prompt pm)" '"permission_mode":null'
check "ct spawn refuses an invalid permission mode" "$(ct_spawn --prompt pm --permission-mode nope)" "ct: invalid permission mode: nope (use default, acceptEdits, plan, auto or bypassPermissions) exit=1"
check "ct spawn --permission-mode needs a value" "$(ct_spawn --prompt pm --permission-mode)" "ct: --permission-mode needs a value exit=1"
lua '(function() local o = vim.deepcopy(T_opts); o.cli = { spawn_limit = 20, spawn_permission_mode = "acceptEdits" }; require("claude-deck").setup(o); return "" end)()' >/dev/null
check "cli.spawn_permission_mode applies without the flag" "$(ct_spawn --prompt pm)" '"permission_mode":"acceptEdits"'
# ct spawn --resume
OUT=$(ct_spawn --resume abc-123 --title T)
SIDR=$(echo "$OUT" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
sleep 0.5
check "ct spawn --resume without a prompt succeeds" "$OUT" '"resumed_from":"abc-123"'
check "ct spawn --resume passes --resume and the id before --model/--permission-mode" "$(grep -A3 -x -e '--resume' "$TEST_OUT/args.$SIDR" | tr '\n' ' ')" "--resume abc-123 --permission-mode acceptEdits "
check "ct spawn --resume without a prompt passes no prompt" "$(tail -n 1 "$TEST_OUT/args.$SIDR")" "acceptEdits"
check "ct spawn --resume: no fork-session" "$(grep -c -x -e '--fork-session' "$TEST_OUT/args.$SIDR")" "0"
check "ct list --json shows resumed_from and no request" "$(NVIM="$SOCK" bin/ct list --json | grep -o '"id":'"$SIDR"',[^}]*' | grep -o '"resumed_from":"abc-123"')|$(lua 'tostring(require("claude-deck.state").get('"$SIDR"').last_request)')" '"resumed_from":"abc-123"|nil'
check "ct list --json: resumed_from is null otherwise" "$(NVIM="$SOCK" bin/ct list --json | grep -o '"id":'"$SIDP"',[^}]*')" '"resumed_from":null'
OUT=$(ct_spawn --resume def-456 --prompt hi)
SIDR2=$(echo "$OUT" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
sleep 0.5
check "ct spawn --resume with a prompt: the prompt is the last argument" "$(tail -n 2 "$TEST_OUT/args.$SIDR2" | tr '\n' '|')" '--|hi|'
check "ct spawn --resume with a prompt: the id is passed" "$(grep -A1 -x -e '--resume' "$TEST_OUT/args.$SIDR2" | tr '\n' ' ')" "--resume def-456 "
check "ct spawn --resume with a prompt registers a request" "$(lua 'require("claude-deck.state").get('"$SIDR2"').last_request.text')" "hi"
check "ct spawn --resume without a value fails" "$(ct_spawn --resume)" "ct: --resume needs a session id exit=1"
check "ct spawn --resume with an empty value fails" "$(ct_spawn --resume= --prompt a)" "ct: --resume needs a session id exit=1"
check "ct spawn --resume with whitespace fails" "$(ct_spawn --resume "a b" --prompt a)" "ct: --resume needs a session id exit=1"
check "spawn({ resume }) works without a prompt" "$(lua '(function() local id = require("claude-deck").spawn({ resume = "lua-1" }); local t = require("claude-deck.state").get(id); return t.resumed_from .. " " .. tostring(t.last_request) end)()')" "lua-1 nil"
check "--permission-mode overrides cli.spawn_permission_mode" "$(ct_spawn --prompt pm --permission-mode plan)" '"permission_mode":"plan"'
check "spawn() uses cli.spawn_permission_mode" "$(lua '(function() local id = require("claude-deck").spawn({ prompt = "api" }); return require("claude-deck.state").get(id).permission_mode end)()')" "acceptEdits"
check "spawn() with an invalid permission mode returns a message" "$(lua '(function() local id, err = require("claude-deck").spawn({ prompt = "api", permission_mode = "x" }); return tostring(id) .. " " .. err end)()')" "nil invalid permission mode: x"
check "an invalid cli.spawn_permission_mode warns and falls back to nil" "$(lua '(function() local o = vim.deepcopy(T_opts); o.cli = { spawn_permission_mode = "nope" }; local w = T_notify(function() require("claude-deck").setup(o) end); return w .. "|" .. tostring(require("claude-deck.config").options.cli.spawn_permission_mode) end)()')" "cli.spawn_permission_mode"
check "the fallback of an invalid cli.spawn_permission_mode is nil" "$(lua 'tostring(require("claude-deck.config").options.cli.spawn_permission_mode)')" "nil"
lua '(function() local o = vim.deepcopy(T_opts); o.cli = { spawn_limit = 20 }; require("claude-deck").setup(o); return "" end)()' >/dev/null
# Lua API
check "spawn() returns the id" "$(lua '(function() local id = require("claude-deck").spawn({ prompt = "api", title = "Api", model = "haiku" }); local t = require("claude-deck.state").get(id); return t.title .. " " .. t.model .. " " .. t.spawned_by end)()')" "Api haiku $MT"
check "spawn() without a prompt returns nil and a message" "$(lua '(function() local id, err = require("claude-deck").spawn({}); return tostring(id) .. " " .. err end)()')" "nil no prompt given"
# Spawn tree: winbar, picker and ct list
lua '(function() vim.cmd("only"); require("claude-deck").new("below"); vim.cmd("stopinsert"); _G.T_P = vim.b.claude_deck_id; return "" end)()' >/dev/null
PT=$(lua '_G.T_P')
C1=$(NVIM="$SOCK" CLAUDE_DECK_ID="$PT" bin/ct spawn --title "Kid one" --prompt a | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
C2=$(NVIM="$SOCK" CLAUDE_DECK_ID="$PT" bin/ct spawn --title "Kid two" --prompt b | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
winbar_of() { lua '(function() vim.api.nvim_set_current_buf(require("claude-deck.state").get('"$1"').buf); vim.cmd("stopinsert"); return T_winbar() end)()'; }
picker_line() { # offset from the parent's line
    lua '(function() local p; for i, l in ipairs(_G.last_picker.lines) do if l:find("#'"$PT"' %[") then p = i end end; return _G.last_picker.lines[p + '"$1"'] end)()'
}
check "winbar: a spawned terminal shows its parent" "$(winbar_of "$C1")" "#$PT›#$C1 "
check "winbar: a parent shows the count of live children" "$(winbar_of "$PT")" "#$PT "
check "winbar: the count follows the status" "$(winbar_of "$PT")" "·2 │ "
check "winbar: a terminal without a parent is unchanged" "$(winbar_of 1)" " #1 "
lua '(function() vim.fn.jobstop(require("claude-deck.state").get('"$C2"').job); return "" end)()' >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(lua 'require("claude-deck.state").get('"$C2"').state')" = exited ] && break
    sleep 0.3
done
check "winbar: the count drops when a child exits" "$(winbar_of "$PT")" "·1 │ "
check "state.children(alive_only)" "$(lua '#require("claude-deck.state").children('"$PT"') .. "/" .. #require("claude-deck.state").children('"$PT"', true)')" "2/1"
lua '(function() require("claude-deck").list(); return "" end)()' >/dev/null
check "picker: the first child follows the parent, with the marker" "$(picker_line 1)" "	  └ #$C1 ["
check "picker: the second child follows the first" "$(picker_line 2)" "	  └ #$C2 ["
check "picker: top-level lines are padded when children exist" "$(picker_line 0)" "	    #$PT ["
LT=$(NVIM="$SOCK" bin/ct list | grep -v '^	' | sed 's/	.*//' | tr '\n' ' ')
case "$LT" in
*"#$PT   └ #$C1   └ #$C2 "*) echo "ok   - ct list: tree order with the marker" ;;
*) echo "FAIL - ct list: tree order with the marker"; echo "       actual: $LT"; failures=$((failures + 1)) ;;
esac
check "ct list --json: sorted by id" "$(NVIM="$SOCK" bin/ct list --json | grep -o '"id":[0-9]*,"state"' | sed 's/,"state"//' | tr '\n' ' ')" "\"id\":$PT \"id\":$C1 \"id\":$C2 "
check "ct list --json: no marker" "$(NVIM="$SOCK" bin/ct list --json | grep -c '└')" "0"

lua '(function() require("claude-deck").setup(T_opts); vim.cmd("only"); return "" end)()' >/dev/null

# ct send / ct wait
ct_as() { # id, args...: runs bin/ct as terminal $1; prints output and exit status
    cid=$1
    shift
    out=$(NVIM="$SOCK" CLAUDE_DECK_ID="$cid" bin/ct "$@" 2>&1)
    echo "$out exit=$?"
}
stdin_of() { # id: what has been typed into terminal $1, escapes visible
    lua 'vim.inspect(table.concat(vim.fn.readfile(vim.env.TEST_OUT .. "/stdin.'"$1"'", "b"), "\n"))' | sed 's/\\\\/\\/g'
}
lua '(function() vim.cmd("only"); vim.api.nvim_set_current_buf(require("claude-deck.state").get('"$MT"').buf); return "" end)()' >/dev/null
# ct wait right after ct spawn follows the first prompt
check "ct wait right after ct spawn is pending" "$(ct_as "$MT" wait "$SID" --timeout 0)" '"status":"pending"'
hook "$SID" SessionStart '{"cwd":"'"$ROOT"'","session_id":"sess-send"}'
hook "$SID" UserPromptSubmit "$(lua 'vim.json.encode({ prompt = require("claude-deck.state").get('"$SID"').last_request.text })')"
check "the spawn prompt marks its request received" "$(lua 'tostring(require("claude-deck.state").get('"$SID"').last_request.received)')" "true"
hook "$SID" Stop '{}'
check "ct wait after ct spawn: done" "$(ct_as "$MT" wait "$SID" --timeout 5)" '"status":"done"'
lua '(function() local t = require("claude-deck.state").get('"$SID"'); t.requests, t.last_request = {}, nil; require("claude-deck.state").next_request = 1; return "" end)()' >/dev/null
check "send: target is waiting" "$(lua 'require("claude-deck.state").get('"$SID"').state')" "waiting"
check "permissions do not allow ct send" "$(lua 'tostring(require("claude-deck.hooks").settings_json():find("ct send", 1, true))')" "nil"
check "permissions allow ct wait" "$(lua 'require("claude-deck.hooks").settings_json()')" '"Bash(ct wait:*)"'
# cli.allow_orchestration
lua '(function() require("claude-deck").setup(vim.tbl_deep_extend("force", T_opts, { cli = { allow_orchestration = true } })); return "" end)()' >/dev/null
check "allow_orchestration allows ct spawn" "$(lua 'require("claude-deck.hooks").settings_json()')" '"Bash(ct spawn:*)"'
check "allow_orchestration allows ct send" "$(lua 'require("claude-deck.hooks").settings_json()')" '"Bash(ct send:*)"'
AO=$(lua '(function() require("claude-deck").new("below"); vim.cmd("stopinsert"); local id = vim.b.claude_deck_id; vim.wait(500); vim.cmd("close"); return id end)()')
check "allow_orchestration: the system prompt says no permission prompt" "$(cat "$TEST_OUT/args.$AO")" "without a permission prompt"
check "invalid cli.allow_orchestration warns" "$(lua 'T_notify(function() require("claude-deck").setup(vim.tbl_deep_extend("force", T_opts, { cli = { allow_orchestration = "yes" } })) end)')" 'invalid cli.allow_orchestration "yes"'
check "invalid cli.allow_orchestration falls back to false" "$(lua 'tostring(require("claude-deck.config").options.cli.allow_orchestration)')" "false"
lua '(function() require("claude-deck").setup(T_opts); return "" end)()' >/dev/null
check "permissions do not allow ct send after restoring the options" "$(lua 'tostring(require("claude-deck.hooks").settings_json():find("ct send", 1, true))')" "nil"
check "system prompt tells about ct send and ct wait" "$(cat "$TEST_OUT/args.$MT")" '`ct wait <id>... [--timeout s]`'
OUT=$(ct_as "$MT" send "$SID" --prompt "Do the thing")
check "ct send prints JSON" "$OUT" '{"id":'"$SID"',"request":"r1"} exit=0'
sleep 0.4
check "ct send: bracketed paste, then a carriage return" "$(lua 'vim.inspect(table.concat(vim.fn.readfile(vim.env.TEST_OUT .. "/stdin.'"$SID"'", "b"), "\n"))')" '\27[200~Do the thing\27[201~'
check "ct send: the paste is followed by a CR" "$(printf '%s' "$(od -An -c "$TEST_OUT/stdin.$SID" | tr -d ' \n')")" '201~\r'
LR() { NVIM="$SOCK" CLAUDE_DECK_ID="$MT" bin/ct list --json | sed 's/},{"id"/}\n{"id"/g' | grep '^{"id":'"$1"','; }
check "ct list --json: request not received yet" "$(LR "$SID")" '"last_request":{"id":"r1","from":'"$MT"',"received":false,"completed":false,'
check "ct list --json: no request is null" "$(LR "$MT")" '"last_request":null'
check "ct wait times out while pending" "$(ct_as "$MT" wait "$SID" --timeout 1)" '"timed_out":true'
check "ct wait: exit 2 on timeout" "$(ct_as "$MT" wait "$SID" --timeout 1)" 'exit=2'
check "ct wait: pending status" "$(ct_as "$MT" wait "$SID" --timeout 0)" '"status":"pending","request":"r1"'
hook "$SID" Stop '{}'
check "a Stop before the prompt arrived does not complete" "$(LR "$SID")" '"received":false,"completed":false,"lost":true'
check "ct wait: a lost request is finished" "$(ct_as "$MT" wait "$SID" --timeout 5)" '"status":"lost","request":"r1","state":"waiting"}}} exit=0'
hook "$SID" UserPromptSubmit '{"prompt":"something else"}'
check "another prompt is not the request" "$(LR "$SID")" '"received":false'
hook "$SID" UserPromptSubmit '{"prompt":"  Do the thing\n"}'
check "the submitted prompt marks the request received" "$(LR "$SID")" '"received":true,"completed":false,"lost":false'
check "ct wait: still pending while running" "$(ct_as "$MT" wait "$SID" --timeout 0)" 'exit=2'
(sleep 1.5; hook "$SID" Stop '{}') &
STOP_PID=$!
WAIT_OUT=$(ct_as "$MT" wait "$SID" --timeout 20)
wait $STOP_PID
check "ct wait returns after the Stop hook" "$WAIT_OUT" '"timed_out":false,"terminals":{"'"$SID"'":{"status":"done","request":"r1","state":"waiting"}}} exit=0'
check "request is completed" "$(LR "$SID")" '"received":true,"completed":true'
check "send: the request is recorded on the target" "$(lua '(function() local t = require("claude-deck.state").get('"$SID"'); return #t.requests .. " " .. t.requests[1].text .. " " .. t.last_request.from end)()')" "1 Do the thing $MT"
# Refusals
check "ct send to yourself fails" "$(ct_as "$MT" send "$MT" --prompt x)" "ct: cannot send to yourself exit=1"
check "ct send to a missing terminal fails" "$(ct_as "$MT" send 999 --prompt x)" "ct: no terminal #999 exit=1"
hook "$SID" UserPromptSubmit '{"prompt":"busy"}'
check "ct send to a running terminal fails" "$(ct_as "$MT" send "$SID" --prompt x)" "ct: terminal #$SID is running (send only to idle or waiting terminals) exit=1"
hook "$SID" Notification '{"notification_type":"permission_prompt","message":"m"}'
check "ct send to an attention terminal fails" "$(ct_as "$MT" send "$SID" --prompt x)" "is attention (send only to idle or waiting terminals)"
check "ct wait: a completed request is done even in attention" "$(ct_as "$MT" wait "$SID" --timeout 20)" '"status":"done"'
hook "$SID" Stop '{}'
check "ct send to an exited terminal fails" "$(ct_as "$MT" send "$SID2" --prompt x)" "ct: terminal #$SID2 is exited (send only to idle or waiting terminals)"
check "ct send without a prompt fails" "$(ct_as "$MT" send "$SID")" "ct: no prompt given (use --prompt or --prompt-file) exit=1"
check "ct send with an empty prompt fails" "$(ct_as "$MT" send "$SID" --prompt "  ")" "ct: no prompt given"
check "ct send with both prompts fails" "$(ct_as "$MT" send "$SID" --prompt a --prompt-file "$SP")" "ct: use either --prompt or --prompt-file, not both exit=1"
check "ct send with a missing prompt file fails" "$(ct_as "$MT" send "$SID" --prompt-file /nonexistent/x.md)" "ct: cannot read the prompt file: /nonexistent/x.md exit=1"
check "ct send with a non-numeric id shows the usage" "$(ct_as "$MT" send abc --prompt x)" "exit=1"
check "ct send with an unknown argument fails" "$(ct_as "$MT" send "$SID" --nope)" "ct: unknown argument --nope exit=1"
check "ct send outside a terminal fails" "$(NVIM="$SOCK" CLAUDE_DECK_ID= bin/ct send "$SID" --prompt a 2>&1; echo "exit=$?")" "ct: run this inside a claude-deck terminal"
check "ct send to a terminal with a dead job fails" "$(lua '(function() local t = require("claude-deck.state").get('"$SID"'); local job = t.job; vim.fn.jobstop(job); vim.fn.jobwait({ job }, 2000); local r, e = require("claude-deck.cli").send_term(nil, t.id, "x"); return tostring(r) .. " " .. e end)()')" "nil ct: terminal #$SID is not running"
check "the exited terminal completes its request with exited" "$(lua '(function() local t = require("claude-deck.state").get('"$SID"'); vim.wait(3000, function() return t.state == "exited" end); return t.state .. " " .. tostring(t.last_request.completed) .. " " .. tostring(t.last_request.exited) end)()')" "exited true true"
# Multi-line prompts, a prompt file relative to $PWD, a visible target
lua '(function() require("claude-deck").new("below"); vim.cmd("stopinsert"); _G.T_vis = vim.b.claude_deck_id; return "" end)()' >/dev/null
VT=$(lua '_G.T_vis')
sleep 0.4
check "ct send before SessionStart is refused" "$(ct_as "$MT" send "$VT" --prompt x)" "ct: terminal #$VT is still starting exit=1"
hook "$VT" SessionStart '{"cwd":"'"$ROOT"'","session_id":"sess-vis"}'
printf 'line one\n\nline "three" $HOME\n\n' >"$TEST_OUT/multi.md"
OUT=$(cd "$TEST_OUT" && NVIM="$SOCK" CLAUDE_DECK_ID="$MT" "$ROOT/bin/ct" send "$VT" --prompt-file multi.md 2>&1; echo "exit=$?")
check "ct send --prompt-file relative to \$PWD" "$OUT" '"request":"r2"}'
sleep 0.4
check "ct send while a request is not received is refused" "$(ct_as "$MT" send "$VT" --prompt dup)" "ct: terminal #$VT has a pending request r2 (not received yet) exit=1"
check "the refused send typed nothing" "$(lua '(function() local s = table.concat(vim.fn.readfile(vim.env.TEST_OUT .. "/stdin.'"$VT"'", "b"), "\n"); return tostring(s:find("dup", 1, true)) end)()')" "nil"
check "multi-line prompt is one paste" "$(lua '(function() local s = table.concat(vim.fn.readfile(vim.env.TEST_OUT .. "/stdin.'"$VT"'", "b"), "\n"); return s == "\27[200~line one\n\nline \"three\" $HOME\27[201~\r" end)()')" "true"
check "multi-line prompt: only one CR, at the end" "$(od -An -c "$TEST_OUT/stdin.$VT" | tr -d ' \n' | grep -o '\\r' | wc -l | tr -d ' ')|$(od -An -c "$TEST_OUT/stdin.$VT" | tr -d ' \n' | tail -c 2)" '1|\r'
hook "$VT" UserPromptSubmit '{"prompt":"line one\n\nline \"three\" $HOME"}'
check "multi-line request is received" "$(LR "$VT")" '"id":"r2"'
check "multi-line request is received (flag)" "$(LR "$VT")" '"received":true'
# ct wait: attention, missing, several ids, usage
hook "$VT" Notification '{"notification_type":"permission_prompt","message":"m"}'
check "ct wait returns early on attention" "$(ct_as "$MT" wait "$VT" --timeout 20)" '"status":"attention","request":"r2","state":"attention"}}} exit=0'
check "ct wait: missing terminal" "$(ct_as "$MT" wait 999 --timeout 5)" '"999":{"status":"missing","request":null,"state":null}}} exit=0'
check "ct wait: exited terminal" "$(ct_as "$MT" wait "$SID" --timeout 5)" '"status":"exited"'
check "ct wait: no request counts as finished" "$(ct_as "$MT" wait "$MT" --timeout 5)" '"status":"none","request":null,"state":"waiting"'
hook "$MT" UserPromptSubmit '{"prompt":"busy work"}'
check "ct wait: no request but running is pending" "$(ct_as "$MT" wait "$MT" --timeout 0)" '"status":"pending","request":null,"state":"running"}}} exit=2'
hook "$MT" Stop '{}'
check "ct wait: several ids" "$(ct_as "$MT" wait "$VT" "$SID" 999 --timeout 5)" '"timed_out":false'
check "ct wait without ids shows the usage" "$(ct_as "$MT" wait)" "exit=1"
check "ct wait with a non-numeric id shows the usage" "$(ct_as "$MT" wait abc)" "exit=1"
check "ct wait with a bad timeout shows the usage" "$(ct_as "$MT" wait "$VT" --timeout soon)" "exit=1"
check "ct wait with --timeout without a value shows the usage" "$(ct_as "$MT" wait "$VT" --timeout)" "exit=1"
check "ct wait does not block Neovim" "$( (NVIM="$SOCK" CLAUDE_DECK_ID="$MT" bin/ct wait "$VT" 999 --timeout 3 >/dev/null 2>&1 &) ; hook "$VT" Stop '{}'; lua '"alive"')" "alive"
# Lua API
check "send() returns the request id" "$(lua '(function() vim.api.nvim_set_current_buf(require("claude-deck.state").get('"$MT"').buf); local r, e = require("claude-deck").send('"$VT"', "api task"); return tostring(r) .. tostring(e) end)()')" "r3"
check "send() to yourself returns nil and a message" "$(lua '(function() local r, e = require("claude-deck").send('"$MT"', "x"); return tostring(r) .. " " .. e end)()')" "nil cannot send to yourself"
# A Stop without the prompt marks the request lost; sending is allowed again
hook "$VT" Stop '{}'
check "a Stop without the prompt marks the request lost" "$(LR "$VT")" '"id":"r3"'
check "a lost request has lost true" "$(LR "$VT")" '"received":false,"completed":false,"lost":true'
check "ct wait: lost" "$(ct_as "$MT" wait "$VT" --timeout 5)" '"status":"lost","request":"r3"'
# A long prompt arrives wrapped in <pasted_content>; the draft case; CRLF
sendrecv() { # text, hook prompt (JSON string body): sends, submits, prints the request flags
    out=$(ct_as "$MT" send "$VT" --prompt "$1")
    sleep 0.3
    hook "$VT" UserPromptSubmit '{"prompt":"'"$2"'"}'
    LR "$VT" | grep -o '"id":"r[0-9]*"\|"received":[a-z]*'| tr '\n' ' '
    hook "$VT" Stop '{}'
}
check "ct send after a lost request is allowed" "$(sendrecv "long text" "\n\n<pasted_content id=\\\"6343\\\">\nlong text\n</pasted_content>")" '"id":"r4" "received":true'
check "a draft in the input before the request still matches" "$(sendrecv "needle" "my draft needle")" '"id":"r5" "received":true'
check "a different prompt does not match a wrapped request" "$(sendrecv "alpha" "\n\n<pasted_content id=\\\"1\\\">\nbeta\n</pasted_content>")" '"id":"r6" "received":false'
hook "$VT" UserPromptSubmit '{"prompt":"alpha"}'
hook "$VT" Stop '{}'
printf 'a\r\nb\r\n' >"$TEST_OUT/crlf.md"
OUT=$(NVIM="$SOCK" CLAUDE_DECK_ID="$MT" bin/ct send "$VT" --prompt-file "$TEST_OUT/crlf.md" 2>&1)
sleep 0.4
check "a CRLF prompt file is sent with LF" "$(lua '(function() local s = table.concat(vim.fn.readfile(vim.env.TEST_OUT .. "/stdin.'"$VT"'", "b"), "\n"); return tostring(s:sub(-16) == "\27[200~a\nb\27[201~\r") end)()')" "true"
hook "$VT" UserPromptSubmit '{"prompt":"a\r\nb"}'
check "a CRLF prompt in the hook matches" "$(LR "$VT")" '"received":true'
hook "$VT" Stop '{}'
check "the request text is stored normalized" "$(lua 'vim.inspect(require("claude-deck.state").get('"$VT"').last_request.text)')" '"a\nb"'
lua '(function() vim.cmd("only"); return "" end)()' >/dev/null

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
