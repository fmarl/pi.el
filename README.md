# pi.el

Talks to the Pi coding agent running next to Emacs: sends it prompts,
the location at point, diagnostics and review comments, and shows in
the mode line what it is doing. Pi in turn sees what Emacs shows and
can open files in it.

## Installation

Requires Emacs 29.1 or later. To install with `use-package` (Emacs 30
or later):

```elisp
(use-package pi
  :vc (:url "https://github.com/fmarl/pi.el")
  :bind-keymap ("C-c a" . pi-command-map)
  :config (pi-mode))
```

Pi needs the extension in `emacs-bridge/`. This repository is a Pi
package, so Pi installs it with

```sh
pi install git:github.com/fmarl/pi.el
```

or, to load it from a checkout, `pi install /path/to/pi.el`.

Its tools reach Emacs through `emacsclient`, so Emacs must run a
server (`server-start`).

### Installing system-wide

```sh
make install PREFIX=/usr/local
```

installs the Emacs package to `$PREFIX/share/emacs/site-lisp/pi` and
the extension to `$PREFIX/share/pi/extensions/emacs-bridge`.

Pi does not look in `$PREFIX`, so tell it where the extension is:

```sh
pi install /usr/local/share/pi/extensions/emacs-bridge
```

## Usage

The bridge serves each Pi's working directory. Every command talks to
the Pi serving the current buffer's directory or one of its parents.

Pi and Emacs meet in `$XDG_RUNTIME_DIR/pi/emacs`, or in
`~/.cache/pi/emacs` without a runtime directory. Both must see the same
`XDG_RUNTIME_DIR`, which matters when Emacs runs as a service. A Pi
without a UI, as with `pi -p`, does not serve its directory.

| Key | Command              | Effect                                       |
|-----|----------------------|----------------------------------------------|
| `a` | `pi-prompt`          | Send a prompt                                |
| `l` | `pi-send-location`   | Send a prompt starting with `@file#L4-6`     |
| `d` | `pi-send-diagnostic` | Ask Pi to fix the diagnostics at point       |
| `c` | `pi-add-comment`     | Note a review comment on the lines at point  |
| `s` | `pi-send-comments`   | Send the noted comments as one prompt        |
| `p` | `pi-run-command`     | Run one of Pi's slash commands               |
| `k` | `pi-abort`           | Abort what Pi is doing                       |
| `n` | `pi-new-session`     | Start a new session                          |
| `m` | `pi-last`            | Show Pi's last answer                        |
| `r` | `pi-review`          | Open Magit, or VC, on the project            |

Pi takes up a prompt once it is done. With a prefix argument, it takes
it up right after its current tool step.

In a Magit diff, locations point to the lines of the file, not of the
diff.

## Customization

```elisp
(use-package pi
  :bind (:map pi-command-map ("x" . pi-abort))
  :custom
  (pi-mode-line-lighter " Pi")
  (pi-timeout 10))
```

## What Pi sees

The extension gives Pi two tools:

- `emacs_context` returns the file, line and column of the selected
  window, the region, the Flymake diagnostics, the files in the other
  windows and the place in a Magit hunk.
- `emacs_show` opens a project file at a line.

## Development

```sh
guix shell -m manifest.scm
eldev compile
eldev test
eldev lint
npm install
npm run check
npm test
```

`npm run check` type-checks and lints the extension and checks its
formatting; `npm run format` formats it with Prettier.

## License

GPL-3.0-or-later
