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
check "system prompt tells about ct diff" "$(cat "$TEST_OUT/args.$DT")" 'ct diff [<path>[:line]] [--base <ref>]'
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
*) echo "gh: unexpected $*" >&2; exit 1 ;;
esac
GH
chmod +x "$TEST_OUT/ghbin/gh"
lua '(function() vim.env.PATH = vim.env.TEST_OUT .. "/ghbin:" .. vim.env.PATH; return "" end)()' >/dev/null
check "ct diff with a pull request opens gh pr diff" "$(ct_diff app/one.txt:2; diff_state)" "Opened the diff in the editor (PR #12 Greet twice (base: main), 1 file, at app/one.txt:2) exit=0
$((DIFF_TABS + 1)) #$DT diff/$DT [+line 2 from the PR] diff false n"
check "the header line names the PR" "$(lua 'vim.fn.getline(1)')" "# PR #12 Greet twice (base: main)"
check "--base skips the pull request" "$(ct_diff --base HEAD)" "git diff HEAD, 3 files) exit=0"
check "the diff buffer is reused" "$(lua '(function() local n = 0; for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_get_name(b):find("claude%-deck://diff/") then n = n + 1 end end; return n end)()')" "1"
check "open_diff() uses the terminal of the focus mode tab" "$(lua '(function() require("claude-deck").open_diff({ path = "app/one.txt", line = 2 }); return "" end)()')$(diff_state)" "[+line 2 from the PR] diff false n"
check ":ClaudeDeck diff --base ref path:line" "$(lua '(function() local cwd = vim.fn.getcwd(); vim.cmd("tcd '"$REPO"'"); vim.cmd("ClaudeDeck diff --base HEAD app/one.txt:6"); vim.cmd("tcd " .. vim.fn.fnameescape(cwd)); return "" end)()')$(diff_state)" "[+line 6 new] diff false n"
check ":ClaudeDeck diff with an unknown option warns" "$(lua 'T_notify(function() vim.cmd("ClaudeDeck diff --nope") end)')" "unknown option --nope"
check "open_diff() outside a terminal warns" "$(lua '(function() vim.cmd("tabclose"); vim.api.nvim_set_current_tabpage(_G.T_diff_origin); vim.cmd("stopinsert | vnew"); return T_notify(function() require("claude-deck").open_diff() end) end)()')" "run this inside a terminal or its focus mode"
lua '(function() vim.env.PATH = _G.T_path; vim.cmd("tabclose!"); return "" end)()' >/dev/null
check "ClaudeDeck diff completes files" "$(lua 'table.concat(vim.fn.getcompletion("ClaudeDeck diff tests/fixtures/open/g", "cmdline"), ",")')" "tests/fixtures/open/greeter.rb"

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
