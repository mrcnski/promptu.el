# Changelog

All notable changes to promptu are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `promptu-blocks-from-json`: read the block list from a JSON file, so it
  can be shared with other promptu frontends.  A missing file is created
  and seeded with the default blocks; an existing file is never modified.

## [1.0.0] - 2026-07-12

Initial release.

### Added

- `promptu` transient menu: compose an LLM prompt from single-key building
  blocks, with a live preview that updates as the prompt is built.
- Default block set, extensible via `promptu-blocks` (with collision warnings
  for keys reserved by the menu).
- Free-text entries alongside blocks.
- `-` to negate the next block (prefix configurable via
  `promptu-negation-prefix`).
- Point navigation (`C-p` / `C-n`) to insert, edit, or remove entries anywhere
  in the prompt, not just at the end.
- Entry editing: `M-e` edits a single entry, `M-E` edits the whole prompt
  verbatim in a dedicated buffer, `DEL` removes an entry.
- Undo/redo (`C-/` / `C-M-/`).
- Prompt history: `M-p` / `M-n` cycle, `M-r` browses via completion; optional
  persistence across sessions with `promptu-history-file`.
- `RET` finishes by copying the composed prompt to the kill ring.
- Inapplicable keys are grayed out.
- Configurable entry separator (`promptu-separator`) and history size
  (`promptu-history-max`).
- Runtime check for the minimum required transient version.

[1.0.0]: https://github.com/mrcnski/promptu/releases/tag/v1.0.0
