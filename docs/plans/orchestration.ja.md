# 仕様: 複数セッションの協調（オーケストレーション）

状態: 第 2 段まで実装済み。

## 実装済み（第 1 段）

- ターミナルごとのモデル
  - `new(where, opts)` / `fork(where, opts)` の `opts.model` を、`--model <model>` として別々の argv 要素で Claude Code に渡す。`cmd` に `--model X`（2 要素）または `--model=X` があるときは、明示したモデルがあれば取り除く。明示しなければ `cmd` はそのまま。
  - 要求したモデルを `term.model` に保存する（Claude Code が実際に使うモデルを確認するものではない）。`fork()` は `opts.model` がなければ元のターミナルのモデルを引き継ぎ、`new()` は何も引き継がない。`redraw()` は同じモデルで再起動する。
  - `:ClaudeDeck new|fork [right|below] [--model <model>]`（引数の順序は自由）。UI（winbar・statusline）は変えず、`ct list` に `\tmodel: <model または (default)>` の行を足した。
- `ct list --json`
  - `{"self": <id または null>, "terminals": [{"id", "state", "title", "title_source", "cwd", "session_id", "transcript_path", "model", "spawned_by"}]}` を 1 行で出力する。番号順。`state` は内部名（`idle|running|waiting|attention|exited`）。値がないものは JSON の null。`title_source` は `"claude"|"user"|"auto"|null`。
  - 許可リストに `Bash(ct list:*)` を追加した。
- `ct spawn`
  - `ct spawn [--title <名前>] [--cwd <dir>] [--model <model>] (--prompt <text> | --prompt-file <path>) [--show]`
  - プロンプトは Claude Code の位置引数として渡す（`-` で始まるときは `--` を前に置く）。入力欄には打ち込まない。`--prompt-file` は Neovim が読み、相対パスと相対 `--cwd` は Claude のシェルの `$PWD` からの相対。`--cwd` の既定は呼び出し元の cwd で、存在するディレクトリであること。
  - 既定ではフローティング window で起動してすぐ閉じる。タブ・window・カーソル・モードは変わらず、バッファは非表示のまま残る。`--show` では呼び出し元のターミナルの右に開き、フォーカスは動かさない。
  - 成功時: `{"id": <新しい番号>, "cwd": "…", "model": <文字列|null>, "title": <文字列|null>}`（終了コード 0）。
  - エラー（`ct: …`、終了コード 1）: プロンプトなし、両方指定、プロンプトファイルを読めない、`--cwd` が不正、名前が 40 セル超（何も作る前に拒否）、claude-deck のターミナルの外、`ct: spawn limit reached (N)`。
  - 上限は `cli.spawn_limit`（既定 3）。`term.spawned = true` で終了していないものを数える。`term.spawned_by` に呼び出し元の番号を記録する。
  - winbar は子に `#6›#8`、終了していない子を持つ親に `·2` を表示する。`list()` と `ct list`（テキスト）は子を親の直下に `  └ ` 付きで並べる（`state.children(id)` / `state.tree()`）。`ct list --json` は変えない。
  - `Bash(ct spawn:*)` と `Bash(ct send:*)` は既定では許可リストに入れない（そのつど Claude Code があなたに確認する）。`cli.allow_orchestration = true` のときだけ追加する。システムプロンプトには、作業を任せるよう頼まれたときだけ使うよう書いた。
  - Lua API: `require("claude-deck").spawn({ prompt, cwd, model, title, show })` が新しい番号（失敗時は nil とメッセージ）を返す。

## 実装済み（第 2 段）

- `ct send <id> (--prompt <text> | --prompt-file <path>)`
  - 既存のターミナルに作業を渡す。`--prompt-file` の相対パスは Claude のシェルの `$PWD` からの相対（`ct spawn` と同じ）。
  - 配送: プロンプト全体を 1 回のブラケットペースト（`\27[200~` … `\27[201~`）で `nvim_chan_send` し、約 50 ms 後（`vim.defer_fn`）に `\r` で送信する。複数行でも 1 回のペーストに収まる。表示中のターミナルには先に `fit_pty(win)` を呼ぶ。非表示でもそのまま送る。ペースト終端の列がテキストに含まれていれば取り除く。
  - 成功時: `{"id": 3, "request": "r1"}` を 1 行で出力する（終了コード 0）。成功は「入力を書き込んだ」ことだけを意味する。
  - エラー（`ct: …`、終了コード 1）: 自分自身（`ct: cannot send to yourself`）、存在しない番号、状態が `idle`/`waiting` 以外（`ct: terminal #3 is running (send only to idle or waiting terminals)`。attention・exited も同じ形）、ジョブが死んでいる、プロンプトなし、両方指定、読めないファイル、空（trim 後）、NUL バイトを含む。
  - `Bash(ct send:*)` は許可リストに入れない。
- リクエストの追跡
  - リクエスト番号 `r<N>` は `state.next_request` の通し番号。対象に `term.requests`（履歴）と `term.last_request`（`{id, from, text, sent_at, received, completed}`、終了時は `exited = true` も）を持つ。
  - `UserPromptSubmit` で、`last_request` が未受信かつ hook の `prompt` を trim したものが `text` を trim したものと等しければ `received = true`。`Stop` で `received` かつ未完了なら `completed = true`。ターミナルが終了したときも `completed = true`、`exited = true`。
  - `ct list --json` の各ターミナルに `"last_request": {"id", "from", "received", "completed", "sent_at"}`（なければ null）を足した。キーの順序は固定（`id` が先頭）。
- `ct wait <id>... [--timeout <seconds>]`
  - 既定のタイムアウトは 600 秒。待つループは `bin/ct`（POSIX sh）にあり、1 秒ごとに `cli.wait_status([ids])` を呼ぶので Neovim は止まらない。`pending` の行がなくなるか、タイムアウトで終わる。
  - `wait_status` の行: `3 done r1` / `3 pending r1 running` / `3 attention r1` / `3 exited`（リクエストがあれば `3 exited r1`）/ `3 missing` / `3 none`。判定の順序は、存在しない → `missing`、終了 → `exited`、最新のリクエストが完了 → `done`、状態が attention → `attention`、リクエストなし → `none`、それ以外 → `pending`。`none` は終了扱い（待ちが止まらないようにするため）。`waiting` だけでは完了にならない（受信してから `Stop` が必要）。
  - 最終出力（`cli.wait_result([ids], timed_out)`）: `{"timed_out": false, "terminals": {"3": {"status": "done", "request": "r1", "state": "waiting"}}}`。`status` は `done|attention|exited|missing|none|pending`。リクエストや状態がなければ null。
  - 終了コード: 完了で 0、タイムアウトで 2、使い方の誤り（番号なし、数字でない番号、不正なタイムアウト）で 1。
  - `Bash(ct wait:*)` を許可リストに入れた（読み取りのみ）。
- システムプロンプト: `ct send` と `ct wait` を `ct spawn` の段落に足した。終了はターンの終わりであって成功ではないので、作業者が書いた結果を読むよう書いた。
- Lua API: `require("claude-deck").send(id, prompt)` がリクエスト番号（失敗時は nil とメッセージ）を返す。`wait` は呼び出しをブロックするため、Lua API にはない。

## 修正（レビュー後）

- 長いプロンプトの照合: Claude Code は長いペースト（実測で約 40 行）を `\n\n<pasted_content id="…">\n…\n</pasted_content>` で包んで `UserPromptSubmit` に渡す。`state.normalize_prompt`（`<pasted_content …>` タグの除去、CRLF→LF、trim）を両側に適用し、等しいか、hook 側が依頼テキストを含めば `received`。依頼テキストは送信時と同じ正規化（`\27[201~` の除去、CRLF→LF）後に保存する。長いペーストは作業者に「指示ではなくデータ」と見なされることがあるため、`ct send` / `--prompt-file` のプロンプトはタスクファイルを指す 1〜2 行にする（ドキュメントとシステムプロンプトに記載）。
- `ct spawn` は最初のプロンプトを `received = false`・`from = 呼び出し元` のリクエストとして登録する。`none` は `idle|waiting|attention|exited` のときだけ終了扱いで、`running` なら `pending`。
- `start_detached` が失敗したら、ウィンドウを閉じ、`state.remove` でレコードを消し、バッファを wipe し、`next_id` を戻し、`eventignore` を復元してからエラーを再送出する。
- `ct send` の競合: 最新のリクエストが未受信（`lost` でない）なら `ct: terminal #3 has a pending request r2 (not received yet)`、`session_id` がなければ `ct: terminal #3 is still starting` で拒否する。未受信のまま `Stop` が届いたらリクエストを `lost = true` にし、`ct wait` は `lost` を終了扱いにする（再び送れる）。後から該当プロンプトが届けば `received` に戻す。`ct list --json` の `last_request` に `lost` を追加（`completed` の次）。
- `ct wait` の終了コード 0 は「待ちが終わった」だけを意味する。呼び出し側は各ターミナルの `status`（`done|attention|exited|missing|none|lost`）を読む。
- `ct spawn --show` で呼び出し元がタブに表示されていないときは `vertical botright split` でタブの右端に開く（フォーカスは動かさない。ほかの window の大きさが変わることがある）。
- claude に渡す引数では、位置引数のプロンプトの前に常に `--` を置く（`cmd` の末尾の可変長オプションに飲まれないため。Commander 標準）。

## 実装済み（ターミナルごとの orchestration）

- `--settings` で渡した権限は起動後に変えられないため、ターミナルごとのフラグ `term.orchestration`（既定は false。`cli.allow_orchestration = true` なら作成時に true）を PreToolUse hook で効かせる。`new` / `fork` / `spawn` は `orchestration = true|false` を受け取り、fork は元の値を引き継ぐ。`:ClaudeDeck new|fork … --orchestrate`、`:ClaudeDeck orchestrate on|off`、Lua の `set_orchestration(id, enabled)` で設定できる。
- `ct orchestrate on|off|status` は呼び出し元のターミナルのフラグを変更・表示し、`orchestration: on` / `orchestration: off` を出力する。許可リストには入れない（一度の承認がそのセッションの同意になる）。システムプロンプトには、ユーザーが求めたとき以外は自分で有効にしないよう書いた。
- `ct list --json` の各要素に `"orchestration": true|false`、`ct list` に `\torchestration: on|off` の行を足した。
- `settings_json()` に matcher `Bash` の `PreToolUse` hook を登録する。`bin/claude-deck-hook` は PreToolUse のときだけ `--remote-expr` の結果を標準出力に出す。`hooks.on_hook` は `tool_name == "Bash"` で、コマンド（前後の空白を除き、先頭の `command ` は許す）が `ct spawn` または `ct send` で始まり、フラグが true のときだけ `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",…}}` を返し、それ以外は空文字列（判断なし）を返す。PreToolUse は状態遷移に関与せず、`term.state` は変わらない。

## 実装済み（usage）

- `ct list --json` に `usage`（transcript がなければ null）を追加しました。`{"model", "turns", "input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "context_tokens"}` の順で、キー `model` は従来どおり要求したモデル、`usage.model` は transcript が報告する実際のモデルです。`ct list` のテキストにも `usage:` の行が出ます。
- 集計は `lua/claude-deck/usage.lua` が transcript（JSONL）の assistant の行から行います。`isSidechain` の行とデコードできない行は無視し、`context_tokens` は最新の assistant の行の `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` です。
- ターミナルごとにパス・読み込み済みのバイト位置・集計値をキャッシュし、追記された分だけを読みます（ファイルが縮んだ、またはパスが変わったら最初から）。`ct list --json` は大きな transcript でも軽いままです。
- ステータスライン（2 行目）に ` · ` 区切りで `<n>k ctx` を出します。ステータスラインの再描画（`Stop` などの hook）のたびに差分だけを読みます。
- transcript の形式は Claude Code の内部仕様で、変わる可能性があります。数値は transcript の記録で、請求額ではありません。`cli.usage = false` で無効にできます（usage は null、transcript は読みません）。

## 実装済み（ターミナルごとの権限モード）

- worker は親の権限を引き継がないため、既定モードの親から起動した worker は権限の確認で止まり（状態は `attention`）、親は承認できません。そこで、モデルと同じ形でターミナルごとの権限モードを持てるようにしました。
- `start_opts.permission_mode` を `--permission-mode <mode>`（別々の argv 要素）として渡します。値は `default`・`acceptEdits`・`plan`・`auto`・`bypassPermissions` で、一覧は `config.lua` の 1 つの表に置き、検証します。`cmd` に `--permission-mode X` / `--permission-mode=X` があるときは、明示的に指定した場合だけ取り除きます。
- `term.permission_mode` に保存します（指定がなければ nil）。`fork()` は指定がなければ元のターミナルのモードを引き継ぎ、`redraw()` は保持し、`new()` は何も引き継ぎません。
- `new(where, { permission_mode })`、`fork(where, { permission_mode })`、`spawn({ permission_mode })`、`:ClaudeDeck new|fork [right|below] [--model m] [--orchestrate] [--permission-mode mode]`、`ct spawn [--permission-mode <mode>]`。不正な値は `ct: invalid permission mode: <x> (use default, acceptEdits, plan, auto or bypassPermissions)` で拒否します（`:ClaudeDeck` では警告）。
- 設定 `cli.spawn_permission_mode`（既定 nil）は、`--permission-mode` なしの `ct spawn` / `spawn()` に使うモードです。nil なら何も渡さず、Claude Code 自身の既定になります。不正な値は警告して nil に戻します。
- `ct list --json` の各要素に `model` の次の `permission_mode`（文字列または null）を、`ct list` に `\tpermission_mode: <mode または (default)>` の行を追加しました。`ct spawn` の出力にも `permission_mode` を含めます。
- `bypassPermissions` は受け付けますが、コードでは特別扱いしません。ドキュメントで、その worker の権限確認をすべて無効にするのでサンドボックスの中でだけ使うよう明記しています。
- システムプロンプトの `ct spawn` の説明に、`--permission-mode acceptEdits`（または `auto`）で worker が確認で止まらずに進められること、モードはユーザーが決めること（指示やスキルに従い、`bypassPermissions` を自分では選ばない）を追記しました。
- `ct spawn --resume <session_id>`（Lua は `spawn({ resume })`）は、`--resume <id>` を `--model` / `--permission-mode` の前に渡し（`--fork-session` なし）、以前の Neovim のセッションを新しいターミナルで続けます。`resume` があればプロンプトは省略でき、省くと位置引数もリクエストも作らず `idle` で起動します。
- `term.resumed_from` に記録し、`ct list --json` の `spawned_by` の次と `ct spawn` の出力に `resumed_from`（文字列または null）を含めます。
