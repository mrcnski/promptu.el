# promptu

<p align="center">
  <img src="mascot.svg" alt="promptu mascot — a friendly creature built from stacked prompt blocks" width="180">
</p>

Compose LLM prompts from building blocks. A small Emacs package with a
[transient](https://github.com/magit/transient) menu that builds a prompt
incrementally.

*promptu: the opposite of 'impromptu': composed, not off-the-cuff.*

## Usage

```
M-x promptu
```

<p align="center">
  <img src="screenshot.png" alt="promptu transient menu showing blocks, controls, and a live preview" width="300">
</p>

Pick building blocks one at a time. The menu stays open and shows a live
preview as blocks accumulate. Blocks can prompt for runtime values and can be
negated. Press `RET` to copy the composed prompt to the kill ring, then paste
it into your agent (e.g. `agent-shell`) or anywhere else.

### Keys

| Key       | Action                                              |
|-----------|-----------------------------------------------------|
| _block_   | Add that block to the prompt                         |
| `-`       | Arm "negate next" — the next block added is negated  |
| `DEL`     | Remove the most recently added block                |
| `M-e`     | Edit the most recently added block in the minibuffer |
| `M-p`     | Recall an older prompt from history                 |
| `M-n`     | Recall a newer prompt (or return to your draft)     |
| `M-r`     | Browse history and load a past prompt               |
| `RET`     | Finish: copy the composed prompt to the kill ring   |
| `q` / `C-g` | Abort with no output and no kill-ring change      |

Negation emits a block's explicit negative text when it defines one, otherwise
its affirmative text prefixed with `promptu-negation-prefix` (default `don't `).

### History

Every finished prompt is remembered. Inside the menu, step back through past
prompts with `M-p` / `M-n` like shell history, or browse them with `M-r`. A
recalled prompt becomes the live session: you can keep editing it, or step
forward with `M-n` to return to the draft you were building.

To grab a past prompt without opening the menu:

```
M-x promptu-recall
```

It picks a past prompt and copies it straight to the kill ring.

## Example

Adding `review`, `commit`, then arming `-` and adding `push` composes (with the
default separator) a bulleted list:

```
- review your changes
- commit
- don't push
```

## Customization

```elisp
(setq promptu-blocks
      '((:key "r" :desc "review"      :text "review your changes")
        (:key "c" :desc "commit"      :text "commit")
        (:key "t" :desc "add tests"   :text "add tests" :negative "skip the tests")
        (:key "p" :desc "push"        :text "push when done")
        (:key "i" :desc "investigate" :text "investigate {link}" :placeholders ("link"))))
```

Each block is a plist:

- `:key`: the transient trigger key (avoid the reserved keys `-`, `RET`, `DEL`, `q`).
- `:desc`: the short menu description.
- `:text`: the affirmative text; may contain named placeholders as `{name}`.
- `:negative`: optional text emitted when the block is negated.
- `:placeholders`: optional list of placeholder names prompted for on add.

Other options:

- `promptu-separator` (default `"\n- "`): placed between blocks. When it
  contains a newline, its trailing line prefix is also applied to the first
  block, so the default produces a fully bulleted list.
- `promptu-negation-prefix` (default `"don't "`): used for negated blocks
  with no explicit `:negative` text.
- `promptu-history-max` (default `50`): how many past prompts to keep. Set to
  `nil` for unbounded history.
- `promptu-history-file` (default `nil`): where to persist history. When `nil`,
  history lives only in the current Emacs session, like the kill ring.

### Persisting history across sessions

History is in-memory by default. To keep it across Emacs restarts, point
`promptu-history-file` at a file:

```elisp
(setq promptu-history-file
      (expand-file-name "promptu-history.el" user-emacs-directory))
```

It is loaded on first use and saved after each finished prompt. Note that
composed prompts can include values you typed for placeholders, so enabling
this writes those values to the file in plain text.

## Installation

Clone and load:

```elisp
(use-package promptu
  :load-path "~/.emacs.d/packages/promptu"
  :bind ("s-;" . promptu))
```

## Dependencies

Emacs 28.1+ and `transient`. Nothing else.

## Related

- [context-clues](https://github.com/mrcnski/context-clues): a sibling
  transient menu for copying file, buffer, and code context to the kill ring.

## License

GPL-3.0-or-later.
