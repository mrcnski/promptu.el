# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

promptu: a single-file Emacs package (~980 lines) providing a transient menu
that composes an LLM prompt from single-key building blocks, with a live
preview, and copies the result to the kill ring. GPL-3, released as 1.0.0,
prepped for MELPA. Requires Emacs 28.1+ and transient 0.5.0+.

The repo is also a git submodule of the author's Emacs config
(`.emacs.d/packages/promptu.el`), loaded there via `use-package :load-path` in
`init/init-packages-ai.el` and bound to `s-"`. That config's CLAUDE.md applies
too, and its rule matters here: **feature work and fixes belong in this repo**;
the `init/*.el` files only hold toggles, keybindings, and glue.

There is a sibling macOS menubar app, [promptu](https://github.com/mrcnski/promptu),
that shares this package's block file — see "Shared blocks" below.

## Verifying changes

```sh
emacs -batch -L . -l promptu-test.el -f ert-run-tests-batch-and-exit
```

`promptu-test.el` holds 109 ERT tests, covering the pure compose core, the
session mutators, the point, history, and finalize. Most of the package's
behavior is reachable from batch tests — prefer adding one over manual
checking. Transient rendering and the editing buffer are the parts that still
need `M-x promptu` in a real frame.

Also worth running before a release: byte-compilation (`emacs -batch -L . -f
batch-byte-compile promptu.el`, `.elc` is gitignored) and `M-x checkdoc`, which
MELPA expects to be clean.

## Architecture

One file, ordered by `;;;` section headings — read them as the map:

| section | holds |
| --- | --- |
| Config helpers | `promptu-blocks-from-json` and the JSON seed/serialize helpers |
| Pure compose core | side-effect-free: resolve, substitute, entries, separators, `promptu--compose` |
| Session state | the dynamic variables (`promptu--session`, negate flag, undo/redo stacks) and their snapshot/restore |
| Point | the insertion cursor the preview marks, and the entry that remove/edit act on |
| History | in-memory ring, optional file persistence, prev/next/browse |
| Editing in a dedicated buffer | `M-e` / `M-E`, the temporary buffer and window-config restore |
| Finalize and abort | copy to the kill ring, reset |
| Transient menu | the `promptu` prefix, block suffix generation, reserved keys |

Facts that aren't obvious from the code alone:

- The prefix uses transient's `:refresh-suffixes`, so **suffix construction runs
  after every command**. Anything expensive or noisy must not live there — that
  is why `promptu--warn-key-collisions` is called once from the `promptu`
  command instead of from `promptu--block-suffixes`, which would warn on every
  keystroke.
- The load-time probe for the `refresh-suffixes` slot exists because there is no
  reliable `transient-version` that far back; without it an old transient fails
  with an opaque EIEIO slot error.
- `promptu--reserved-keys` lists the keys the menu itself binds. A block whose
  `:key` collides is skipped with a warning, not silently shadowed. Adding a new
  menu binding means adding it to that list.
- Entries carry a "free text" flag. Free text comes from a whole-prompt edit
  (`M-E`) and is deliberately kept verbatim: it is exempt from the separator's
  line prefix, and it is faced distinctly in the preview, because after that
  edit the individual blocks are no longer reconstructable.
- History can be persisted to a file, and composed prompts may contain typed
  placeholder values — the `promptu-history-file` docstring warns about that in
  plain text. Keep that warning if the code around it changes.

## Shared blocks (and the Mac app)

`promptu-blocks-from-json` reads the block list from a JSON file so it can be
shared with non-Emacs frontends:

```elisp
(setq promptu-blocks (promptu-blocks-from-json "~/.config/promptu/blocks.json"))
```

The JSON object keys map 1:1 to the plist keys minus the leading colon (`key`,
`desc`, `text`, `negative`, `placeholders`). A missing file is created and
seeded with `promptu-default-blocks`; an existing one is **never** modified.
The file is read once, when the `setq` runs.

The Mac app reads and writes the same file, so **a schema change has to land in
both repos.** Elisp remains the native configuration route — the JSON path is
only for sharing.

## Conventions

- The standard elisp skeleton: `-*- lexical-binding: t; -*-` header, the MELPA
  header block (including `Assisted-by:` lines, per MELPA's AI-attribution
  policy), `;;; Commentary:` / `;;; Code:`, `(provide 'promptu)` and a
  `;;; promptu.el ends here` footer.
- Docstrings are checkdoc-clean and full sentences, with two spaces between
  them. Public functions and every `defcustom` document the *why* and the
  trade-off, not just the type.
- Internal names are `promptu--`; only what users call or set is `promptu-`.
- Commit subjects are conventional-commit style, lowercase, imperative
  (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`). Trailer:
  `Co-Authored-By: Claude <model> <noreply@anthropic.com>`.
- Releasing: bump the `Version:` header, move `CHANGELOG.md`'s `[Unreleased]`
  entries under the new version (Keep a Changelog + semver), commit as
  `chore: release X.Y.Z`, tag `vX.Y.Z`.
