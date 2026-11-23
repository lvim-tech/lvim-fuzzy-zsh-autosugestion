# lvim-fuzzy-zsh-autosugestion

The grey rest of a command in zsh, suggested from what you have already run: where you ran it, whether it worked, and what usually came next.
It replaces [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) (do not load both) and reads [atuin](https://github.com/atuinsh/atuin)'s history.

## Suggestions

Tried in this order (`strategy`):

- `next`: what usually follows the command you ran last (also on an empty line)
- `dir`: what you ran in this directory, then in the directories above it. Only commands that succeeded
- `global`: every command that worked, the often and the recent first
- `path`: the one file or directory the last word of the line leads to

A suggestion whose last word is a path that does not exist from here (a `cd` that worked in another directory) is dropped.
A command that fails is not learned. A command that matches `ignore` (passwords, tokens) is never suggested.
The history is read once in the background, so the first prompt does not wait.

## Keys

| Key | Action |
| --- | --- |
| `→` `End` `Ctrl-F` | accept all of it |
| `Alt-→` `Alt-F` | accept one word |
| `Alt-↑` `Alt-↓` | the previous / next suggestion |
| `Ctrl-/` | pick from all suggestions in [lfz](https://github.com/lvim-tech/lvim-fuzzy-cli) |

In the picker every row shows the icon (and, with `Ctrl-P`, the preview) of the path its command ends with. A path that is missing shows a red
folder with an error, a command that is not a path shows the icon of a shell script.

## Install

```zsh
source /path/to/lvim-fuzzy-zsh-autosugestion/lvim-fuzzy-zsh-autosugestion.plugin.zsh
```

Load it after `compinit` and before zsh-syntax-highlighting. It needs `sqlite3` and atuin's database; the picker needs `lfz`.

## Settings

```zsh
zstyle ':lvim-fuzzy-zsh-autosugestion:' strategy next dir global path
zstyle ':lvim-fuzzy-zsh-autosugestion:' style 'fg=7'          # default: the theme's ANSI 7
zstyle ':lvim-fuzzy-zsh-autosugestion:' ignore '*(password|passwd|token|secret|api_key|apikey)*'
zstyle ':lvim-fuzzy-zsh-autosugestion:' db ~/.local/share/atuin/history.db
zstyle ':lvim-fuzzy-zsh-autosugestion:' limit 20000           # how many commands are read
zstyle ':lvim-fuzzy-zsh-autosugestion:' pick-key '^_'         # Ctrl-/
```

## License

BSD 3-Clause
