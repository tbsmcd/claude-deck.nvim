# claude-deck.nvim

## Documentation rules

- Every user-facing change (new feature, changed behavior, changed default, removed feature, new option or command) must be reflected in both READMEs: `README.md` (English) and `README.ja.md` (Japanese). Keep the two in sync: the same sections, the same facts.
- Keep the help files in sync with the READMEs as well: `doc/claude-deck.txt` (English) and `doc/claude-deck.jax` (Japanese) must have the same set of tags.
- Release notes (GitHub releases) must not contradict the READMEs.

## Development

- Run `sh tests/smoke.sh` before committing; all tests must pass.
- Run `nvim --headless --clean -c "helptags doc" -c "qa"` to check the help files, then delete the generated `doc/tags` and `doc/tags-ja` (they are not committed).
- Do not add attribution trailers (e.g. `Co-Authored-By`) to commits.
