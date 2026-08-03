#!/usr/bin/env bash
#
# setup-linux-user.sh -- provision a USER account, not the server.
#
# Everything here is per-user and lands under $HOME. The only step that needs
# sudo is the optional apt install of a few CLI tools; skip it with --no-apt
# and a parent server-provisioning script can own that instead.
#
#   ./setup-linux-user.sh                    # everything except the optional CLIs
#   ./setup-linux-user.sh --check            # dry run, touch nothing
#   ./setup-linux-user.sh --env ml --python 3.12
#   ./setup-linux-user.sh --claude --codex   # include the optional AI CLIs
#   ./setup-linux-user.sh --only dirs,git    # run just these steps
#
# Idempotent: safe to re-run. Existing files are backed up, never clobbered.
#
set -euo pipefail

# ============================================================================
# CONFIGURATION -- edit these, or override with the flags below.
# ============================================================================

ENV_NAME="${ENV_NAME:-llm}"          # --env      mamba environment name
PYTHON_VERSION="${PYTHON_VERSION:-3.14}"   # --python
GIT_NAME="${GIT_NAME:-prairie-guy}"        # --git-name
GIT_EMAIL="${GIT_EMAIL:-cdaniels@nandor.net}"  # --git-email
DOOM_REPO="${DOOM_REPO:-git@github.com:prairie-guy/doom-emacs_dot_file.git}"
DOOM_REPO_HTTPS="https://github.com/prairie-guy/doom-emacs_dot_file.git"

# Default mamba packages. DELETE ANY LINE YOU DO NOT WANT -- that is the
# intended way to customise this. Or override wholesale with --mamba-pkgs.
# (xclip was deliberately dropped: useless on a headless box, where the
# clipboard goes over OSC-52 instead.)
MAMBA_PACKAGES=(
  bat            # cat replacement, aliased to `b`
  tree           # directory listing, aliased via `treeacl`
  dust           # du replacement
  fd-find        # find replacement; provides the real `fd` name
  ripgrep-all    # provides `rga`, aliased to `rgac`; pulls in ripgrep
  fzf            # fuzzy finder, aliased to `fz`; wired into bash below
  zoxide         # smarter cd, wired into bash below
  zellij         # terminal multiplexer
)

# Node/npm. Installed into the mamba env to keep it out of the system.
NODE_PACKAGES=(nodejs)

# Directories created in $HOME. ~/bin is also prepended to PATH by the bashrc.
HOME_DIRS=(bin scratch stuff junk)

# ============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$SCRIPT_DIR/templates"
STAMP="$(date +%Y%m%d-%H%M%S)"

CHECK_ONLY=0
DO_CLAUDE=0
DO_CODEX=0
SKIP_APT=0
ONLY=""
MAMBA_PKGS_OVERRIDE=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '    \033[2m--  %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if (( CHECK_ONLY )); then printf '    \033[2m[would run]\033[0m %s\n' "$*"; else "$@"; fi; }

while (( $# )); do
  case "$1" in
    --check)      CHECK_ONLY=1; shift ;;
    --env)        ENV_NAME="${2:?--env needs a name}"; shift 2 ;;
    --env=*)      ENV_NAME="${1#*=}"; shift ;;
    --python)     PYTHON_VERSION="${2:?--python needs a version}"; shift 2 ;;
    --python=*)   PYTHON_VERSION="${1#*=}"; shift ;;
    --git-name)   GIT_NAME="${2:?}"; shift 2 ;;
    --git-email)  GIT_EMAIL="${2:?}"; shift 2 ;;
    --mamba-pkgs) MAMBA_PKGS_OVERRIDE="${2:?}"; shift 2 ;;
    --claude)     DO_CLAUDE=1; shift ;;
    --codex)      DO_CODEX=1; shift ;;
    --no-apt)     SKIP_APT=1; shift ;;
    --only)       ONLY="${2:?--only needs a comma-separated step list}"; shift 2 ;;
    --only=*)     ONLY="${1#*=}"; shift ;;
    -h|--help)    sed -n '2,18p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$MAMBA_PKGS_OVERRIDE" ]] && read -r -a MAMBA_PACKAGES <<<"$MAMBA_PKGS_OVERRIDE"

# A step runs unless --only was given and does not name it.
want() { [[ -z "$ONLY" ]] || [[ ",$ONLY," == *",$1,"* ]]; }

# ---------------------------------------------------------------- preflight --

[[ "$(uname -s)" == "Linux" ]] || die "this script targets Linux"
[[ $EUID -ne 0 ]] || die "do not run as root -- this provisions YOUR account, and
   under sudo \$HOME becomes /root and everything lands in the wrong place"
[[ -d "$TEMPLATES" ]] || die "templates/ not found next to the script"

(( CHECK_ONLY )) && warn "DRY RUN -- nothing will be changed."
log "user=$USER home=$HOME env=$ENV_NAME python=$PYTHON_VERSION"

# Back up a file before replacing it, once per run.
backup() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  log "backing up $f -> $f.bak-$STAMP"
  run cp -a "$f" "$f.bak-$STAMP"
}

# ------------------------------------------------------------------- 1. dirs --

if want dirs; then
  log "creating home directories"
  for d in "${HOME_DIRS[@]}"; do
    if [[ -d "$HOME/$d" ]]; then skip "~/$d exists"; else run mkdir -p "$HOME/$d"; fi
  done
  # The same explainer goes in each of scratch/stuff/junk -- it describes all
  # three, so whichever one you land in tells you the whole scheme. ~/bin is
  # self-explanatory and gets none.
  for d in scratch stuff junk; do
    if [[ -f "$HOME/$d/README.org" ]]; then
      skip "~/$d/README.org exists"
    else
      run cp "$TEMPLATES/dirs-README.org" "$HOME/$d/README.org"
    fi
  done
fi

# ---------------------------------------------------------------- 2. bashrc --

if want bashrc; then
  if [[ -f "$HOME/.bashrc" ]] && grep -q 'installed by setup-linux-user.sh' "$HOME/.bashrc" 2>/dev/null \
     && grep -q "mamba activate $ENV_NAME" "$HOME/.bashrc" 2>/dev/null; then
    skip "~/.bashrc already installed for env '$ENV_NAME'"
  else
    backup "$HOME/.bashrc"
    log "installing ~/.bashrc (env: $ENV_NAME)"
    if (( CHECK_ONLY )); then
      printf '    \033[2m[would write]\033[0m %s from templates/bashrc\n' "$HOME/.bashrc"
    else
      sed "s/__ENV_NAME__/$ENV_NAME/g" "$TEMPLATES/bashrc" >"$HOME/.bashrc"
    fi
  fi
fi

# ------------------------------------------------------------------- 3. git --

if want git; then
  if [[ -n "$(git config --global user.email 2>/dev/null)" ]]; then
    skip "git identity already set ($(git config --global user.email))"
  else
    log "setting global git identity: $GIT_NAME <$GIT_EMAIL>"
    run git config --global user.name  "$GIT_NAME"
    run git config --global user.email "$GIT_EMAIL"
    run git config --global init.defaultBranch master
    run git config --global pull.rebase false
  fi
fi

# -------------------------------------------------------------- 4. dotfiles --

# XDG-located config files that are not covered by any other repo. Without
# these they exist on exactly one machine and are lost with it.
if want dotfiles; then
  # git reads $XDG_CONFIG_HOME/git/ignore as core.excludesFile by default, so
  # placing the file is enough -- no git config needed.
  install_dotfile() {
    local src="$1" dst="$2"
    if [[ -f "$dst" ]] && cmp -s "$TEMPLATES/$src" "$dst"; then
      skip "$(basename "$dst") already current"
      return
    fi
    backup "$dst"
    log "installing $dst"
    run mkdir -p "$(dirname "$dst")"
    run cp "$TEMPLATES/$src" "$dst"
  }
  install_dotfile git-ignore        "$HOME/.config/git/ignore"
  install_dotfile zellij-config.kdl "$HOME/.config/zellij/config.kdl"
fi

# ------------------------------------------------------------------- 5. ssh --

if want ssh; then
  if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    skip "ssh key already exists"
  else
    log "generating ed25519 ssh key (no passphrase, for unattended git)"
    run mkdir -p "$HOME/.ssh"
    run chmod 700 "$HOME/.ssh"
    run ssh-keygen -t ed25519 -N "" -C "$GIT_EMAIL" -f "$HOME/.ssh/id_ed25519"
    NEED_KEY_UPLOAD=1
  fi
fi

# ------------------------------------------------------------------- 5. apt --

# A handful of things genuinely want to be system packages rather than living
# in a python env. Everything else comes from mamba.
if want apt && (( ! SKIP_APT )); then
  # Only things that must exist before/outside the mamba env. `tree`, `bat`,
  # `fd` etc. come from mamba instead -- do not duplicate them here.
  APT_PKGS=(git curl wget bc less)
  missing=()
  for p in "${APT_PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed$" || missing+=("$p")
  done
  if (( ${#missing[@]} )); then
    log "apt install: ${missing[*]}"
    run sudo apt-get update -qq
    run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  else
    skip "system CLI packages already present"
  fi
elif want apt; then
  skip "--no-apt given; parent script owns system packages"
fi

# ----------------------------------------------------------------- 6. mamba --

if want mamba; then
  if [[ -d "$HOME/miniforge3" ]]; then
    skip "miniforge3 already installed"
  else
    log "installing miniforge3"
    inst="/tmp/miniforge-$STAMP.sh"
    run curl -fsSL -o "$inst" \
      "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-$(uname -m).sh"
    run bash "$inst" -b -p "$HOME/miniforge3"   # -b = batch, no prompts, no bashrc edit
    run rm -f "$inst"
  fi

  MAMBA="$HOME/miniforge3/bin/mamba"
  if [[ ! -x "$MAMBA" ]] && (( ! CHECK_ONLY )); then
    die "mamba not found at $MAMBA after install"
  fi

  if [[ -d "$HOME/miniforge3/envs/$ENV_NAME" ]]; then
    skip "env '$ENV_NAME' exists"
  else
    log "creating env '$ENV_NAME' with python=$PYTHON_VERSION"
    run "$MAMBA" create -n "$ENV_NAME" -y "python=$PYTHON_VERSION"
  fi

  if (( ${#MAMBA_PACKAGES[@]} )); then
    log "mamba install: ${MAMBA_PACKAGES[*]}"
    run "$MAMBA" install -n "$ENV_NAME" -y "${MAMBA_PACKAGES[@]}"
  else
    skip "no mamba packages requested"
  fi
fi

# ------------------------------------------------------------------ 7. node --

if want node; then
  MAMBA="$HOME/miniforge3/bin/mamba"
  if [[ -x "$HOME/miniforge3/envs/$ENV_NAME/bin/node" ]]; then
    skip "node already in env '$ENV_NAME'"
  else
    log "installing node/npm into env '$ENV_NAME': ${NODE_PACKAGES[*]}"
    run "$MAMBA" install -n "$ENV_NAME" -y "${NODE_PACKAGES[@]}"
  fi
fi

# ----------------------------------------------------------------- 8. emacs --

if want emacs; then
  if [[ -d "$HOME/.config/doom/.git" ]]; then
    skip "~/.config/doom already cloned"
  else
    log "cloning doom config to ~/.config/doom"
    if (( CHECK_ONLY )); then
      printf '    \033[2m[would clone]\033[0m %s\n' "$DOOM_REPO"
    elif ! git clone "$DOOM_REPO" "$HOME/.config/doom" 2>/dev/null; then
      warn "ssh clone failed (key not registered with GitHub yet?); using https"
      warn "to push later: git -C ~/.config/doom remote set-url origin $DOOM_REPO"
      git clone "$DOOM_REPO_HTTPS" "$HOME/.config/doom"
    fi
  fi

  # The doom repo carries its own installer; it handles emacs, doom, vterm deps
  # and its own idempotency. Do not duplicate that logic here.
  if [[ -x "$HOME/.config/doom/setup.sh" ]]; then
    log "delegating to ~/.config/doom/setup.sh"
    if (( CHECK_ONLY )); then
      run "$HOME/.config/doom/setup.sh" --check
    else
      "$HOME/.config/doom/setup.sh"
    fi
  else
    warn "~/.config/doom/setup.sh not found or not executable; skipping emacs"
  fi
fi

# -------------------------------------------------------- 9. optional CLIs --

if (( DO_CLAUDE )); then
  if command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]]; then
    skip "claude already installed"
  else
    log "installing Claude Code"
    run bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
    NEED_AUTH_CLAUDE=1
  fi
fi

if (( DO_CODEX )); then
  NPM="$HOME/miniforge3/envs/$ENV_NAME/bin/npm"
  if [[ -x "$HOME/miniforge3/envs/$ENV_NAME/bin/codex" ]]; then
    skip "codex already installed"
  elif [[ -x "$NPM" ]] || (( CHECK_ONLY )); then
    log "installing OpenAI Codex CLI via npm (into the '$ENV_NAME' env)"
    run "$NPM" install -g @openai/codex
    NEED_AUTH_CODEX=1
  else
    warn "npm not found in env '$ENV_NAME'; run the node step first"
  fi
fi

# --------------------------------------------------------------- next steps --

echo
if (( CHECK_ONLY )); then
  log "dry run complete, nothing changed."
  exit 0
fi

log "done. Open a new shell (or 'source ~/.bashrc') to pick everything up."
echo

if [[ -n "${NEED_KEY_UPLOAD:-}" ]]; then
  warn "ADD THIS SSH KEY TO GITHUB (https://github.com/settings/keys):"
  echo
  cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true
  echo
  warn "until you do, ~/.config/doom is on an https remote and cannot push."
  warn "then: git -C ~/.config/doom remote set-url origin $DOOM_REPO"
  echo
fi

# These are interactive browser/device logins. They cannot be scripted, and
# deliberately are not -- credentials should not flow through a setup script.
[[ -n "${NEED_AUTH_CLAUDE:-}" ]] && warn "AUTHORIZE (offline, interactive): run 'claude' and follow the login prompt"
[[ -n "${NEED_AUTH_CODEX:-}" ]]  && warn "AUTHORIZE (offline, interactive): run 'codex' and follow the login prompt"
exit 0
