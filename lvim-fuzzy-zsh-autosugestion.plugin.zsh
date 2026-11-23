# lvim-fuzzy-zsh-autosugestion: the grey rest of a command, from what you have run — and where, and whether it worked.
#
# Like zsh-autosuggestions (which it replaces: do not load both) it shows the suggestion after the cursor, accepts it with → / End (all of it) and
# Alt-→ (a word), and draws it again after every change of the line. Unlike it, the suggestion comes from atuin's history (which knows the directory
# and the exit status of every command):
#
#   next     what usually FOLLOWS the command you ran last (also on an empty line)
#   dir      what you ran in this directory (then the ones above it) — and only what worked
#   global   everything that worked, the often and the recent first
#   path     the one file or directory that the last word of the line leads to
#
#   zstyle ':lvim-fuzzy-zsh-autosugestion:' strategy next dir global path     # the order (default as listed)
#   zstyle ':lvim-fuzzy-zsh-autosugestion:' style 'fg=7'                      # how it is drawn (default: the theme's ANSI 7, a dim that reads)
#   zstyle ':lvim-fuzzy-zsh-autosugestion:' ignore '*(password|token|secret)*'   # never suggested (default as written)
#   zstyle ':lvim-fuzzy-zsh-autosugestion:' db ~/.local/share/atuin/history.db
#   zstyle ':lvim-fuzzy-zsh-autosugestion:' limit 20000                       # how many commands are read
#   zstyle ':lvim-fuzzy-zsh-autosugestion:' pick-key '^_'                     # the key of the lfz picker (default Ctrl-/, which a terminal sends as ^_)
#
# Keys: → End Ctrl-F accept all · Alt-→ Alt-F a word · Alt-↑ / Alt-↓ the next / previous suggestion · Ctrl-/ pick one in lfz (lvim-fuzzy-cli).

[[ -o interactive ]] || return 0
zmodload zsh/datetime zsh/zle 2>/dev/null
autoload -Uz add-zsh-hook add-zle-hook-widget

typeset -ga _lvsg_global _lvsg_strategy _lvsg_alts
typeset -gA _lvsg_dir _lvsg_next
typeset -g  _lvsg_style _lvsg_ignore _lvsg_cur _lvsg_seen=$'\0' _lvsg_prev _lvsg_cmd _lvsg_cmd_cwd
typeset -gi _lvsg_i=1

_lvsg_zs() { zstyle -s ':lvim-fuzzy-zsh-autosugestion:' $1 REPLY || REPLY=$2 }

# ---- the history: read once (atuin's) in the background, then kept up to date with what is run here --------------------------------------------

typeset -g _lvsg_tmp _lvsg_loaded=0

# starts the reading: sqlite3 writes what is needed to files while the first prompt is drawn (nothing waits for it)
_lvsg_spawn() {
  local db limit
  _lvsg_zs db ${XDG_DATA_HOME:-$HOME/.local/share}/atuin/history.db; db=$REPLY
  _lvsg_zs limit 20000; limit=$REPLY
  if (( ! $+commands[sqlite3] )) || [[ ! -r $db ]]; then
    print -u2 "lvim-fuzzy-zsh-autosugestion: needs sqlite3 and atuin's history ($db): not loaded"
    return 1
  fi
  _lvsg_tmp=${TMPDIR:-/tmp}/lvim-fuzzy-zsh-autosugestion.$$
  # a command that worked, one line, of a size that is a command
  local ok="deleted_at IS NULL AND exit = 0 AND length(command) BETWEEN 2 AND 400 AND instr(command, char(10)) = 0 AND command NOT LIKE ' %'"
  # often, and the more the later (a week halves it)
  local score="count(*) * 1.0 / (1.0 + (strftime('%s','now') - max(timestamp) / 1000000000) / 604800.0)"
  local t=$_lvsg_tmp
  setopt localoptions no_monitor no_notify
  {
    sqlite3 -readonly -escape off $db "SELECT command FROM history WHERE $ok GROUP BY command ORDER BY $score DESC LIMIT $limit" >| $t.g 2>/dev/null
    # per directory: its line, then its commands (best first) joined by the record separator
    sqlite3 -readonly -escape off -separator $'\n' $db "SELECT cwd, group_concat(command, char(30)) FROM (SELECT cwd, command FROM history WHERE $ok GROUP BY cwd, command ORDER BY cwd, $score DESC) GROUP BY cwd" >| $t.d 2>/dev/null
    # what followed what, in the same session
    sqlite3 -readonly -escape off -separator $'\n' $db "SELECT prev, group_concat(command, char(30)) FROM (SELECT prev, command FROM (SELECT command, exit, deleted_at, lag(command) OVER (PARTITION BY session ORDER BY timestamp) AS prev FROM history) WHERE prev IS NOT NULL AND exit = 0 AND deleted_at IS NULL AND length(command) BETWEEN 2 AND 400 AND instr(command, char(10)) = 0 AND instr(prev, char(10)) = 0 GROUP BY prev, command ORDER BY prev, count(*) DESC) GROUP BY prev" >| $t.n 2>/dev/null
    sqlite3 -readonly -escape off $db "SELECT command FROM history WHERE deleted_at IS NULL AND instr(command, char(10)) = 0 ORDER BY timestamp DESC LIMIT 1" >| $t.p 2>/dev/null
    : >| $t.done
  } &!
}

# the reading is done: take it (a key-and-value list is an associative array as it is). Tried at every redraw of the line until it is there.
_lvsg_take() {
  (( _lvsg_loaded )) && return
  [[ -e $_lvsg_tmp.done ]] || return
  _lvsg_loaded=1
  local t=$_lvsg_tmp
  _lvsg_global=( ${(f)"$(<$t.g)"} )
  _lvsg_dir=( ${(f)"$(<$t.d)"} )
  _lvsg_next=( ${(f)"$(<$t.n)"} )
  # (what was run here since the start is already in them: the new ones go in front)
  [[ -z $_lvsg_prev ]] && _lvsg_prev=$(<$t.p)
  command rm -f $t.g $t.d $t.n $t.p $t.done
}

# what is run now: only what worked is learned (the exit status is read first of all the prompt's functions)
_lvsg_preexec() { _lvsg_cmd=$1; _lvsg_cmd_cwd=$PWD }
_lvsg_precmd() {
  local rc=$?
  _lvsg_hook
  local c=$_lvsg_cmd
  _lvsg_cmd=
  [[ -n $c && $c != ' '* && $c != *$'\n'* && ${#c} -ge 2 && ${#c} -le 400 ]] || return $rc
  _lvsg_take
  local sep=$'\x1e'
  if (( rc == 0 )) && [[ $c != ${~_lvsg_ignore} ]]; then
    _lvsg_global=( $c ${_lvsg_global:#"$c"} )
    _lvsg_dir[$_lvsg_cmd_cwd]=$c$sep${_lvsg_dir[$_lvsg_cmd_cwd]}
    [[ -n $_lvsg_prev ]] && _lvsg_next[$_lvsg_prev]=$c$sep${_lvsg_next[$_lvsg_prev]}
  fi
  _lvsg_prev=$c
  return $rc
}

# ---- what to suggest -----------------------------------------------------------------------------------------------------------------------------

# the line completed with the one file or directory the last word leads to (REPLY; empty when there is none, or more than one)
_lvsg_path() {
  REPLY=
  local b=$BUFFER
  [[ -n $b && $b != *[[:space:]] ]] || return
  local last=${b##*[[:space:]]}
  [[ $last == */* || $last == '~'* || $last == .* ]] || return
  local exp=$last
  [[ $exp == '~/'* ]] && exp=$HOME/${exp#\~/}
  [[ $exp == '~' ]] && exp=$HOME
  local dir=${exp:h} base=${exp:t}
  [[ $exp == */ ]] && { dir=${exp%/}; base= }
  [[ -d ${dir:-/} ]] || return
  setopt localoptions nullglob
  local -a m=( ${dir%/}/${base}*(N) )
  (( $#m == 1 )) || return
  local rest=${m[1]:t}
  rest=${rest#$base}
  [[ -d ${m[1]} ]] && rest+=/
  [[ -n $rest ]] || return
  REPLY=$b${(q)rest}
}

# A command whose last word is a path that is not there from here (a `cd lvim-ls/lua/lvim-ls` that worked in another directory) is not suggested.
# Words that are not plainly a path (an option, a URL, a variable, a glob, quotes) are not judged.
_lvsg_valid() {
  local c=$1 last=${1##*[[:space:]]}
  case $last in
    '' | -* | *://* | *[=\*\$\`\"\'\;\&\|\<\>\(\)]*) return 0 ;;
  esac
  [[ $last == */* || ${c%% *} == (cd|pushd) ]] || return 0
  local p=${last//\\ / }
  [[ $p == '~/'* ]] && p=$HOME/${p#\~/}
  [[ $p == '~' ]] && p=$HOME
  [[ -e $p ]]
}

# the suggestions for the line, the best first (reply): at most $1
_lvsg_collect() {
  local -i max=$1
  reply=()
  local b=$BUFFER
  [[ $b != *$'\n'* && ${#b} -le 300 ]] || return
  local s c d
  local -a hit l
  local -i g
  for s in $_lvsg_strategy; do
    hit=()
    case $s in
      next)
        [[ -n $_lvsg_prev ]] && { l=( ${(ps:\x1e:)_lvsg_next[$_lvsg_prev]} ); hit=( ${(M)l:#"$b"*} ) } ;;
      dir)
        [[ -n $b ]] && {
          d=$PWD g=0
          while (( g++ < 8 )) && [[ -n $d ]]; do
            (( $+_lvsg_dir[$d] )) && { l=( ${(ps:\x1e:)_lvsg_dir[$d]} ); hit+=( ${(M)l:#"$b"*} ) }
            [[ $d == / || $d == $HOME ]] && break
            d=${d:h}
          done
        } ;;
      global)
        [[ -n $b ]] && hit=( ${(M)_lvsg_global:#"$b"*} ) ;;
      path)
        _lvsg_path; [[ -n $REPLY ]] && hit=( $REPLY ) ;;
    esac
    for c in $hit; do
      [[ $c == $b || $c == ${~_lvsg_ignore} ]] && continue
      [[ $s == path ]] || _lvsg_valid $c || continue
      (( ${reply[(Ie)$c]} )) && continue
      reply+=$c
      (( $#reply >= max )) && return
    done
  done
}

# ---- showing it ----------------------------------------------------------------------------------------------------------------------------------

typeset -gi _lvsg_in_pre=0 _lvsg_in_acc=0 _lvsg_hooked_pre=0 _lvsg_hooked_acc=0
_lvsg_clear() {
  region_highlight=( ${region_highlight:#*memo=lvim-fuzzy-suggest} )
  POSTDISPLAY=
}

_lvsg_show() {
  _lvsg_clear
  [[ -n $_lvsg_cur && ${#_lvsg_cur} -gt $#BUFFER && ${_lvsg_cur[1,$#BUFFER]} == "$BUFFER" ]] || return
  POSTDISPLAY=${_lvsg_cur[$(( $#BUFFER + 1 )),-1]}
  region_highlight+=("$#BUFFER $(( $#BUFFER + $#POSTDISPLAY )) ${_lvsg_style},memo=lvim-fuzzy-suggest")
}

# before every redraw of the line: the suggestion follows what is typed (so it never stays behind a change another widget made)
_lvsg_redraw() {
  _lvsg_take
  if (( CURSOR != $#BUFFER )); then
    _lvsg_clear
    _lvsg_seen=$'\0'
    return
  fi
  if [[ $BUFFER != $_lvsg_seen ]]; then
    _lvsg_seen=$BUFFER
    _lvsg_collect 8
    _lvsg_alts=( $reply )
    _lvsg_i=1
    _lvsg_cur=${_lvsg_alts[1]}
  fi
  _lvsg_show
}

# ---- taking it ------------------------------------------------------------------------------------------------------------------------------------

_lvsg_accept() {
  [[ -n $POSTDISPLAY ]] && (( CURSOR == $#BUFFER )) || return 1
  BUFFER+=$POSTDISPLAY
  CURSOR=$#BUFFER
  _lvsg_clear
  return 0
}

_lvsg_accept_word() {
  [[ -n $POSTDISPLAY ]] && (( CURSOR == $#BUFFER )) || return 1
  local rest=$POSTDISPLAY lead word
  lead=${rest%%[^[:space:]]*}
  rest=${rest#$lead}
  word=${rest%%[[:space:]]*}
  BUFFER+=$lead$word
  CURSOR=$#BUFFER
  return 0
}

# a key that, with a suggestion shown, takes it; else does what it did (widgets of the same names, so every key bound to them follows)
_lvsg_wrap() {
  local w=$1 fn=_lvsg_w_${1//-/_}
  eval "$fn() { _lvsg_$2 || zle .$w }"
  zle -N $w $fn
}

_lvsg_step() {
  (( $#_lvsg_alts > 1 )) || return
  _lvsg_i=$(( (_lvsg_i - 1 + $1) % $#_lvsg_alts + 1 ))
  (( _lvsg_i < 1 )) && _lvsg_i=$#_lvsg_alts
  _lvsg_cur=${_lvsg_alts[_lvsg_i]}
  _lvsg_show
}
_lvsg_next_alt() { _lvsg_step 1 }
_lvsg_prev_alt() { _lvsg_step -1 }

# Ctrl-/: every suggestion in lfz; the chosen one is the line
_lvsg_pick() {
  local fz=${commands[lfz]:-$commands[lvim-fuzzy-cli]}
  [[ -n $fz ]] || { zle -M "lvim-fuzzy-zsh-autosugestion: lfz (lvim-fuzzy-cli) is not installed"; return }
  local -a save=( $_lvsg_alts ) cs
  _lvsg_collect 300
  cs=( $reply )
  (( $#cs )) || { zle -M "no suggestion for this line"; return }
  local out
  echoti civis >/dev/tty 2>/dev/null
  print -n '\n' >/dev/tty
  # a row is the whole command, and the path it ends with is the target: lfz draws its icon and (Ctrl-P) its preview
  local -a rows; local c w t
  for c in $cs; do
    w=${${(z)c}[-1]}; w=${(Q)w}; t=${w/#\~/$HOME}
    [[ $t == /* ]] || t=$PWD/$t
    [[ $w == *[\$\`\(\&\|\;\<\>*?]* || $w == -* || $c != *\ * ]] && t=!
    rows+=( "$c"$'\t'"$t" )
  done
  out=$(print -rl -- $rows | $fz --minimal --height='~40%' --exit-cursor=hidden --preview-window=right --delimiter=$'\t' --with-nth=1 --accept-nth=1 --target='{2}' --no-multi 2>/dev/null) || true
  echoti cuu1 >/dev/tty 2>/dev/null
  echoti cnorm >/dev/tty 2>/dev/null
  # lfz gave the cursor back as the terminal's default: the shell's own shape (zsh-vi-mode's bar in insert mode) comes back
  (( $+functions[zvm_update_cursor] )) && zvm_update_cursor
  if [[ -n $out ]]; then
    BUFFER=$out
    CURSOR=$#BUFFER
  fi
  zle .redisplay
}

# ---- on ------------------------------------------------------------------------------------------------------------------------------------------

_lvsg_bind() {
  local w km pk
  _lvsg_zs pick-key '^_'; pk=$REPLY
  for w in forward-char end-of-line vi-forward-char vi-end-of-line; do _lvsg_wrap $w accept; done
  for w in forward-word emacs-forward-word vi-forward-word vi-forward-word-end; do _lvsg_wrap $w accept_word; done
  zle -N _lvsg_next_alt
  zle -N _lvsg_prev_alt
  zle -N _lvsg_pick
  for km in emacs viins main; do
    bindkey -M $km '^[[1;3A' _lvsg_prev_alt 2>/dev/null
    bindkey -M $km '^[[1;3B' _lvsg_next_alt 2>/dev/null
    bindkey -M $km $pk _lvsg_pick 2>/dev/null
  done
}

# The line editor's own widgets, put over zle-line-pre-redraw and accept-line with the ones that were there called first — and again at every prompt: zsh-vi-mode (and
# others) set theirs at the first prompt, and a hook added before that is no longer called. (The widget table says whose a widget is: nothing is forked.)
# (a guard against re-entry: when another plugin wraps ours again, the chain would come back here)
_lvsg_pre_redraw() {
  if (( ! _lvsg_in_pre )); then
    _lvsg_in_pre=1
    (( $+widgets[_lvsg_orig_pre_redraw] )) && zle _lvsg_orig_pre_redraw "$@"
    _lvsg_in_pre=0
  fi
  _lvsg_redraw
}
_lvsg_accept_line() {
  _lvsg_clear
  if (( _lvsg_in_acc )); then zle .accept-line; return; fi
  _lvsg_in_acc=1
  if (( $+widgets[_lvsg_orig_accept_line] )); then zle _lvsg_orig_accept_line "$@"; else zle .accept-line; fi
  _lvsg_in_acc=0
}
# taken once: the widget that was there is kept, whoever wraps ours later
_lvsg_hook() {
  if (( ! _lvsg_hooked_pre )) && [[ ${widgets[zle-line-pre-redraw]} != user:_lvsg_pre_redraw ]]; then
    (( $+widgets[zle-line-pre-redraw] )) && zle -A zle-line-pre-redraw _lvsg_orig_pre_redraw
    zle -N zle-line-pre-redraw _lvsg_pre_redraw
    _lvsg_hooked_pre=1
  fi
  if (( ! _lvsg_hooked_acc )) && [[ ${widgets[accept-line]} != user:_lvsg_accept_line ]]; then
    zle -A accept-line _lvsg_orig_accept_line
    zle -N accept-line _lvsg_accept_line
    _lvsg_hooked_acc=1
  fi
}

_lvsg_late() {
  add-zsh-hook -d precmd _lvsg_late
  _lvsg_bind
}

_lvsg_start() {
  _lvsg_zs style 'fg=7'; _lvsg_style=$REPLY
  _lvsg_zs ignore '*(password|passwd|token|secret|api_key|apikey)*'; _lvsg_ignore=$REPLY
  zstyle -a ':lvim-fuzzy-zsh-autosugestion:' strategy _lvsg_strategy || _lvsg_strategy=(next dir global path)
  _lvsg_spawn || return 1
  _lvsg_bind
  _lvsg_hook
  add-zsh-hook preexec _lvsg_preexec
  # first of the prompt's functions: it reads the exit status of the command
  precmd_functions=( _lvsg_precmd ${precmd_functions:#_lvsg_precmd} )
  add-zsh-hook precmd _lvsg_late
}
_lvsg_start
