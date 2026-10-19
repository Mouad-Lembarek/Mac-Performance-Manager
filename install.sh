#!/bin/bash
# =============================================================================
# install.sh - install, update or remove the `mpm` command (Mac Performance Manager)
#
#   One command, no clone (run it again later to update):
#     curl -fsSL https://raw.githubusercontent.com/Mouad-Lembarek/Mac-Performance-Manager/master/install.sh | bash
#   From a clone (update later with `git pull`):
#     ./install.sh
#   Remove:
#     ./install.sh --uninstall      or      curl -fsSL .../install.sh | bash -s -- --uninstall
#
# What it touches, and nothing else:
#   ~/.local/bin/mpm                          a symlink to the script
#   ~/.local/share/mac-performance-manager/   the downloaded script (one-command install only),
#                                             plus its settings, logs and reports
# No sudo. Your shell profile is never edited (the line to add is printed instead).
# Removing moves files to the Trash; nothing is deleted permanently, and a clone is never touched.
# =============================================================================
set -u

SCRIPT_NAME=mac-performance-manager.sh
SOURCE_URL=${MPM_INSTALL_URL:-https://raw.githubusercontent.com/Mouad-Lembarek/Mac-Performance-Manager/master}
BIN_DIR=${MPM_BIN_DIR:-$HOME/.local/bin}
SHARE_DIR=${MPM_SHARE_DIR:-$HOME/.local/share/mac-performance-manager}
LINK="$BIN_DIR/mpm"

say()  { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
tilde() { case $1 in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
# A path inside a command the user may paste (bash/zsh): "$HOME/My Folder/x", special characters escaped.
qpath() {
  local p=$1 pre=""
  case $p in "$HOME"/*) pre='$HOME/'; p=${p#"$HOME"/} ;; esac
  printf '"%s%s"' "$pre" "$(printf '%s' "$p" | sed 's/[\\"`$]/\\&/g')"
}

# The folder of this installer when it runs from a file (a clone); empty when piped from curl.
clone_dir() {
  local src=${BASH_SOURCE[0]:-} dir
  [ -n "$src" ] && [ -f "$src" ] || return 1
  dir=$(cd -P "$(dirname "$src")" 2>/dev/null && pwd) || return 1
  [ -f "$dir/$SCRIPT_NAME" ] || return 1
  printf '%s' "$dir"
}

# 0 if $LINK is a symlink to some copy of this tool (so it is ours to replace or remove).
link_is_ours() { [ -L "$LINK" ] && case $(readlink "$LINK") in */"$SCRIPT_NAME") return 0 ;; esac; return 1; }

# A downloaded file is used only if it really is this tool: shebang, version line, valid syntax.
valid_script() {
  [ "$(head -n 1 "$1" 2>/dev/null)" = "#!/bin/bash" ] && grep -q '^MPM_VERSION="' "$1" && /bin/bash -n "$1" 2>/dev/null
}

download() {   # -> path of the installed script
  command -v curl >/dev/null 2>&1 || fail "curl is needed to download the script (or install from a clone)."
  mkdir -p "$SHARE_DIR" && chmod 700 "$SHARE_DIR" || fail "cannot create $(tilde "$SHARE_DIR")."
  local tmp="$SHARE_DIR/.$SCRIPT_NAME.download.$$"
  if ! curl -fsSL "$SOURCE_URL/$SCRIPT_NAME" -o "$tmp"; then
    rm -f -- "$tmp"; fail "download failed from $SOURCE_URL/$SCRIPT_NAME (nothing was changed)."
  fi
  if ! valid_script "$tmp"; then
    rm -f -- "$tmp"; fail "the downloaded file is not a valid $SCRIPT_NAME (nothing was changed)."
  fi
  chmod 700 "$tmp" && mv -f -- "$tmp" "$SHARE_DIR/$SCRIPT_NAME" || { rm -f -- "$tmp"; fail "cannot write $(tilde "$SHARE_DIR")."; }
  # The documented settings file, for reference only; never overwrites your own config.env.
  curl -fsSL "$SOURCE_URL/config.env.example" -o "$SHARE_DIR/config.env.example" 2>/dev/null || rm -f -- "$SHARE_DIR/config.env.example"
  printf '%s' "$SHARE_DIR/$SCRIPT_NAME"
}

install_mpm() {
  [ "$(uname -s 2>/dev/null)" = Darwin ] || [ "${MPM_ALLOW_NON_DARWIN:-0}" = 1 ] || fail "Mac Performance Manager runs on macOS only."
  local clone target data version
  if clone=$(clone_dir); then
    target="$clone/$SCRIPT_NAME"; chmod u+x "$target" 2>/dev/null
    data=$clone
    say "Installing from the clone at $(tilde "$clone")."
  else
    say "Downloading Mac Performance Manager..."
    target=$(download) || exit 1
    data=$SHARE_DIR
  fi

  if [ -e "$LINK" ] || [ -L "$LINK" ]; then
    link_is_ours || fail "$(tilde "$LINK") already exists and is not Mac Performance Manager; it was left alone. Remove or rename it, then run the installer again."
  fi
  mkdir -p "$BIN_DIR" || fail "cannot create $(tilde "$BIN_DIR")."
  ln -s "$target" "$LINK.tmp.$$" && mv -f -- "$LINK.tmp.$$" "$LINK" || { rm -f -- "$LINK.tmp.$$"; fail "cannot create $(tilde "$LINK")."; }

  version=$("$LINK" --version 2>/dev/null) || fail "installed, but $(tilde "$LINK") --version did not run."
  say "Installed: $version"
  say "  command   $(tilde "$LINK") -> $(tilde "$target")"
  say "  data      $(tilde "$data") (logs/, reports/, state/ are created on first run)"
  say "  settings  optional:  cp $(qpath "$data/config.env.example") $(qpath "$data/config.env")"

  local found; found=$(command -v mpm 2>/dev/null)
  case ":$PATH:" in
    *":$BIN_DIR:"*)
      if [ -n "$found" ] && [ "$found" != "$LINK" ]; then
        say ""; say "Note: another 'mpm' comes first in your PATH ($found). Run $(tilde "$LINK") directly, or reorder PATH."
      fi ;;
    *)
      say ""
      say "$(tilde "$BIN_DIR") is not in your PATH yet. Add it once (zsh is the macOS default shell):"
      say "  echo 'export PATH=$(qpath "$BIN_DIR" | sed 's/"$//'):\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
      say "Until then, run it as $(tilde "$LINK")." ;;
  esac
  say ""
  say "Try:  mpm --once    (one overview)     mpm    (menu)     mpm --work    (all-day monitor)"
  if [ -n "${clone:-}" ]; then say "Update: git pull in $(tilde "$clone")."
  else say "Update: run the same install command again."; fi
}

to_trash() {   # path -> moves it into ~/.Trash under a unique name
  local name; name="$(basename "$1")-removed-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$HOME/.Trash" && mv -- "$1" "$HOME/.Trash/$name" && say "Moved $(tilde "$1") to the Trash (as $name)."
}

uninstall_mpm() {
  local did=0 clone="" pid
  pid=$(head -n 1 "$SHARE_DIR/state/work.pid" 2>/dev/null | tr -cd '0-9')
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    fail "a work mode may still be running from $(tilde "$SHARE_DIR") (PID $pid). Stop it first with: mpm --stop"
  fi
  if [ -L "$LINK" ]; then
    if link_is_ours; then
      case $(readlink "$LINK") in "$SHARE_DIR/$SCRIPT_NAME") ;; *) clone=$(dirname "$(readlink "$LINK")") ;; esac
      rm -f -- "$LINK" && say "Removed the command $(tilde "$LINK") (a symlink)." && did=1
    else
      say "$(tilde "$LINK") is not Mac Performance Manager; left alone."
    fi
  elif [ -e "$LINK" ]; then
    say "$(tilde "$LINK") is not Mac Performance Manager; left alone."
  fi
  if [ -f "$SHARE_DIR/$SCRIPT_NAME" ]; then
    to_trash "$SHARE_DIR" && did=1   # the downloaded script with its settings, logs and reports
  elif [ -e "$SHARE_DIR" ]; then
    say "$(tilde "$SHARE_DIR") does not contain $SCRIPT_NAME; left alone."
  fi
  [ -n "$clone" ] && say "Your clone at $(tilde "$clone") was not touched; delete that folder yourself if you no longer need it."
  [ "$did" = 1 ] || say "Nothing to remove: Mac Performance Manager is not installed."
  return 0
}

main() {
  case ${1:-} in
    "") install_mpm ;;
    --uninstall) uninstall_mpm ;;
    -h|--help)
      if [ -f "${BASH_SOURCE[0]:-}" ]; then sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      else say "Usage: install.sh [--uninstall | --help]"; fi ;;
    *) fail "unknown option '$1' (use --uninstall or --help)" ;;
  esac
}

# Everything above only defines functions: a download cut off halfway runs nothing.
main "$@"
