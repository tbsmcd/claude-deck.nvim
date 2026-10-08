# 仕様: PR レビュー中の差分を Claude からエディタに開く（`ct diff`）

状態: v0.8.0 で実装済み（2026-10-09）。`ct open`（ファイルを集中モードのエディタに開く）の差分版。

## 決めたこと（2026-10-09）

- 差分は `gh pr diff` で取る。プルリクエストがないときや `gh` がないときは `git diff HEAD`（未コミットの変更）。`--base <ref>` で `git diff <ref>` にもできる。
- 表示は統合 diff のバッファ 1 つ（左右比較の `:diffthis` 方式はやめた）。
- 分割が必要なとき（`<CR>` でファイルを開くとき）は左右に分割し、差分のバッファは残す。

## 目的

PR のレビューを Claude と一緒に進めているとき、「この PR の差分を見せて」「`app/foo.rb` の変更を見せて」と頼むだけで、集中モードのエディタにその差分が開くようにする。`ct open` と同じ流れで、Claude が `ct diff` を実行し、Neovim 側が集中モードを開いて表示する。

## コマンド

```
ct diff                         # 差分全体を開く
ct diff <path>                  # そのファイルの箇所にカーソルを置く
ct diff <path>:<line>           # 新しい側の <line> 行にカーソルを置く
ct diff --base <ref> ...        # 作業ツリーと <ref> の差分（git diff <ref>）。プルリクエストは探さない
```

- 引数のパスは `ct open` と同じ規則（絶対 / `~/` / Claude のシェルの cwd からの相対）。リポジトリの外のパスは拒否する。
- 許可は `Bash(ct diff)` と `Bash(ct diff:*)` を確認なしで通す（読むだけ）。
- Lua API: `require("claude-deck").open_diff({ path?, line?, base?, id? })`。コマンド: `:ClaudeDeck diff [path[:line]] [--base ref]`（相対パスは Neovim の今のディレクトリからの相対）。

## 差分の出どころ

1. `--base <ref>` があれば `git diff <ref>`。
2. `gh` があり、`gh pr view --json number,title,baseRefName` が成功すれば（今のブランチにプルリクエストがあれば）`gh pr diff`。
3. それ以外は `git diff HEAD`。

バッファの 1 行目に出どころを表示する（例: `# PR #12 Greet twice (base: main)`、`# git diff HEAD (uncommitted changes)`）。`ct diff` の結果にも同じ内容とファイル数を返す（例: `Opened the diff in the editor (PR #12 Greet twice (base: main), 3 files, at app/one.txt:6)`）。

## 表示

- 集中モードのエディタのウィンドウ（`ct open` と同じ探し方・開き方）に、読み取り専用のバッファ（`claude-deck://diff/<ターミナル番号>`、`buftype=nofile`、`filetype=diff`）で開く。ターミナルごとに 1 つで、`ct diff` のたびに中身を入れ替える。
- パスがあればそのファイルの `diff --git` 行へ。行もあれば、ハンクの中の新しい側のその行へ（どのハンクにもなければ、いちばん近いハンクの見出し）。変更のないファイルは `ct: no changes in <path> (...)` で拒否する。
- バッファ内のキー（バッファローカル）:
  - `<CR>`: カーソル位置のファイルを、新しい側の行で、差分の右のウィンドウに開く（差分のウィンドウは残す）。すでに別の通常のウィンドウがあればそこを使う。削除されたファイルや見出しの上では警告する。
  - `]f` / `[f`: 次 / 前のファイルの見出しへ。
  - `]c` / `[c`: 次 / 前のハンク（`@@`）へ。
  - `q`: ウィンドウを閉じる。
- 差分を表示中に `ct open` すると、差分は残してその隣にファイルを開く。

## `send_location` との連携

差分のバッファで `send_location` を呼ぶと、ハンクの見出しからファイルと新しい側の行番号を計算して `path:line` を送る（削除行の上では、その次の行）。ビジュアル選択なら範囲を送る。見出しの上では警告して送らない。

## Claude への指示（システムプロンプト）

`ct open` の段落に続けて、`ct diff [<path>[:line]] [--base <ref>]` の説明を加えている。差分・変更・PR のレビューを頼まれたとき、または説明している変更を見せたいときに使う。

## エラー

- git リポジトリでない: `ct: not a git repository: <cwd>`
- リポジトリの外のパス: `ct: not in the repository: <path>`
- 変更がない: `ct: no changes (<出どころ>)` / `ct: no changes in <path> (<出どころ>)`
- `--base` の ref が不正: `ct: git diff <ref>: fatal: ...`
- `gh pr diff` の失敗: `ct: gh pr diff: ...`（`gh pr view` の失敗はプルリクエストなしとみなして `git diff HEAD` へ）

## 後回し

- `--staged`。
- PR のコメント（`gh pr view --comments`）の表示。
- ファイル単位の折りたたみ。
