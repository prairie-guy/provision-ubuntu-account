#!/usr/bin/env bash
#
# provision-ubuntu-account.sh -- provision a USER account, not the server.
#
# Everything here is per-user and lands under $HOME. The only step that needs
# sudo is the optional apt install of a few CLI tools; skip it with --no-apt
# and a parent server-provisioning script can own that instead.
#
#   ./provision-ubuntu-account.sh                    # everything except the optional CLIs
#   ./provision-ubuntu-account.sh --check            # dry run, touch nothing
#   ./provision-ubuntu-account.sh --env ml --python 3.12   # --env skips the prompt
#   ./provision-ubuntu-account.sh --claude --codex   # include the optional AI CLIs
#   ./provision-ubuntu-account.sh --only dirs,git    # run just these steps
#
# Idempotent: safe to re-run. Existing files are backed up, never clobbered.
#
set -euo pipefail

# ============================================================================
# CONFIGURATION -- edit these, or override with the flags below.
# ============================================================================

# Prompted for interactively unless --env is given or ENV_NAME is exported.
if [[ -n "${ENV_NAME:-}" ]]; then ENV_EXPLICIT=1; else ENV_EXPLICIT=0; fi
ENV_NAME="${ENV_NAME:-llm}"          # --env      mamba environment name
PYTHON_VERSION="${PYTHON_VERSION:-3.14}"   # --python
GIT_NAME="${GIT_NAME:-prairie-guy}"        # --git-name
# GitHub's noreply form, so a public repo carries no scrapeable address. Commits
# made with it still attribute correctly on GitHub. Override with --git-email
# if you want a real address in your commit metadata.
GIT_EMAIL="${GIT_EMAIL:-prairie-guy@users.noreply.github.com}"  # --git-email
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

# ML stack. NOT installed unless --ml is given: it is ~3GB and most servers do
# not need it. Goes into the main env, matching the "one main env plus throwaway
# envs for experiments" workflow -- for anything volatile, prefer
#   mamba create -n experiment-x python=3.14 pytorch ...
# rather than growing the env every shell activates.
#
# No GPU detection needed: conda exposes the driver as a __cuda virtual package,
# so the solver picks CUDA builds where a GPU exists and CPU builds where it
# does not, from these same names.
ML_PACKAGES=(
  pytorch        # pulls cuda-* + triton automatically when __cuda is present
  numpy
  pandas
  matplotlib
  jupyterlab
)

# Directories created in $HOME. ~/bin is also prepended to PATH by the bashrc.
HOME_DIRS=(bin scratch stuff junk)

# ============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$SCRIPT_DIR/templates"
STAMP="$(date +%Y%m%d-%H%M%S)"

CHECK_ONLY=0
DO_ML=0
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
    --env)        ENV_NAME="${2:?--env needs a name}"; ENV_EXPLICIT=1; shift 2 ;;
    --env=*)      ENV_NAME="${1#*=}"; ENV_EXPLICIT=1; shift ;;
    --python)     PYTHON_VERSION="${2:?--python needs a version}"; shift 2 ;;
    --python=*)   PYTHON_VERSION="${1#*=}"; shift ;;
    --git-name)   GIT_NAME="${2:?}"; shift 2 ;;
    --git-email)  GIT_EMAIL="${2:?}"; shift 2 ;;
    --mamba-pkgs) MAMBA_PKGS_OVERRIDE="${2:?}"; shift 2 ;;
    --ml)         DO_ML=1; shift ;;
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

# Ask a yes/no question. Without a terminal it takes the default silently, so an
# unattended run never blocks. `read` returns non-zero at EOF; tolerate it.
ask_yn() {
  local q="$1" def="${2:-n}" reply hint
  [[ "$def" == y ]] && hint="[Y/n]" || hint="[y/N]"
  if [[ ! -t 0 ]]; then [[ "$def" == y ]]; return; fi
  read -r -p "$q $hint " reply || true
  reply="${reply:-$def}"
  [[ "${reply,,}" == y* ]]
}

# Ask for the env name when it was not specified and someone is there to answer.
# `read` returns non-zero at EOF, which would abort under `set -e`.
if (( ! ENV_EXPLICIT )) && [[ -t 0 ]]; then
  read -r -p "mamba env name [$ENV_NAME]: " _reply || true
  [[ -n "${_reply:-}" ]] && ENV_NAME="$_reply"
fi

# ENV_NAME is interpolated into a sed replacement and into a grep pattern, so
# restrict it to characters that are inert in both.
[[ "$ENV_NAME" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "invalid --env '$ENV_NAME': use only letters, digits, dot, dash, underscore"

# A step runs unless --only was given and does not name it. Unknown names are
# rejected: a typo like --only dir would otherwise run nothing and exit 0,
# looking like a successful provision.
VALID_STEPS=(dirs bashrc loginshell git dotfiles ssh apt mamba node ml emacs claude codex)
if [[ -n "$ONLY" ]]; then
  IFS=, read -r -a _requested <<<"$ONLY"
  for _s in "${_requested[@]}"; do
    [[ " ${VALID_STEPS[*]} " == *" $_s "* ]] \
      || die "unknown step '$_s'. Valid: ${VALID_STEPS[*]}"
  done
fi
want() { [[ -z "$ONLY" ]] || [[ ",$ONLY," == *",$1,"* ]]; }

# Optional installs. A flag already given is taken as the answer, so --ml and
# friends still work unattended; otherwise ask. Asked here, before any work, so
# the run does not stop for input part-way through.
if (( ! DO_ML ))     && ask_yn "install the ML stack (pytorch/numpy/pandas/jupyterlab, ~3GB)?" n; then DO_ML=1; fi
if (( ! DO_CLAUDE )) && ask_yn "install Claude Code?"                                          n; then DO_CLAUDE=1; fi
if (( ! DO_CODEX ))  && ask_yn "install OpenAI Codex CLI?"                                     n; then DO_CODEX=1; fi

# ---------------------------------------------------------------- preflight --

[[ "$(uname -s)" == "Linux" ]] || die "this script targets Linux"
[[ $EUID -ne 0 ]] || die "do not run as root -- this provisions YOUR account, and
   under sudo \$HOME becomes /root and everything lands in the wrong place"
[[ -d "$TEMPLATES" ]] || die "templates/ not found next to the script"

(( CHECK_ONLY )) && warn "DRY RUN -- nothing will be changed."
log "user=${USER:-$(id -un)} home=$HOME env=$ENV_NAME python=$PYTHON_VERSION"

# Back up a file before replacing it, once per run.
backup() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  log "backing up $f -> $f.bak-$STAMP"
  run cp -a "$f" "$f.bak-$STAMP"
}

# ------------------------------------------------------------------- 1. apt --

# Runs FIRST: it installs git, which the git, dotfiles, ssh and emacs steps all
# depend on. On a minimal image git is absent, and using it before this point
# would abort the run under `set -e`.

# A handful of things genuinely want to be system packages rather than living
# in a python env. Everything else comes from mamba.
if want apt && (( ! SKIP_APT )); then
  # Only things that must exist before/outside the mamba env. `tree`, `bat`,
  # `fd` etc. come from mamba instead -- do not duplicate them here.
  APT_PKGS=(git curl wget bc less)
  missing=()
  for p in "${APT_PKGS[@]}"; do
    [[ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" == "install ok installed" ]] || missing+=("$p")
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

# ------------------------------------------------------------------- 2. dirs

if want dirs; then
  log "creating home directories"
  for d in "${HOME_DIRS[@]}"; do
    if [[ -d "$HOME/$d" ]]; then skip "~/$d exists"; else run mkdir -p "$HOME/$d"; fi
  done
  # The same explainer goes in each of scratch/stuff/junk -- it describes all
  # three, so whichever one you land in tells you the whole scheme. ~/bin is
  # self-explanatory and gets none.
  for d in scratch stuff junk; do
    if [[ -f "$HOME/$d/README.md" ]] && cmp -s "$TEMPLATES/dirs-README.md" "$HOME/$d/README.md"; then
      skip "~/$d/README.md already current"
    else
      backup "$HOME/$d/README.md"
      run cp "$TEMPLATES/dirs-README.md" "$HOME/$d/README.md"
    fi
    # superseded by README.md
    [[ -f "$HOME/$d/README.org" ]] && { log "removing stale ~/$d/README.org"; run rm -f "$HOME/$d/README.org"; }
  done

  # Helper scripts into ~/bin, which the bashrc puts on PATH.
  if [[ -d "$TEMPLATES/bin" ]]; then
    for f in "$TEMPLATES"/bin/*; do
      [[ -f "$f" ]] || continue
      dest="$HOME/bin/$(basename "$f")"
      if [[ -f "$dest" ]] && cmp -s "$f" "$dest"; then
        skip "~/bin/$(basename "$f") already current"
      else
        backup "$dest"
        log "installing $dest"
        run cp "$f" "$dest"
        run chmod +x "$dest"
      fi
    done
  fi
fi

# ---------------------------------------------------------------- 3. bashrc

if want bashrc; then
  if [[ -f "$HOME/.bashrc" ]] && grep -q 'installed by provision-ubuntu-account.sh' "$HOME/.bashrc" 2>/dev/null \
     && grep -qxF "mamba activate $ENV_NAME 2>/dev/null" "$HOME/.bashrc" 2>/dev/null; then
    skip "~/.bashrc already installed for env '$ENV_NAME'"
  else
    backup "$HOME/.bashrc"
    log "installing ~/.bashrc (env: $ENV_NAME)"
    if (( CHECK_ONLY )); then
      printf '    \033[2m[would write]\033[0m %s from templates/bashrc\n' "$HOME/.bashrc"
    else
      # Write via a temp file: a bare `>` truncates before sed runs, so a
      # failure would leave an empty ~/.bashrc.
      _tmp="$HOME/.bashrc.tmp-$STAMP"
      sed "s/__ENV_NAME__/$ENV_NAME/g" "$TEMPLATES/bashrc" >"$_tmp"
      mv "$_tmp" "$HOME/.bashrc"
    fi
  fi
fi

# --------------------------------------------------------- 4. login shell

# A login shell (ssh, mosh) reads ONLY the first of ~/.bash_profile,
# ~/.bash_login, ~/.profile that exists -- and Ubuntu puts the `source
# ~/.bashrc` line in ~/.profile. So if anything ever drops a ~/.bash_profile
# in place, ~/.profile is silently ignored, ~/.bashrc never loads over ssh,
# and the whole environment vanishes on login while still working in a
# subshell. Verify the chain rather than assume it.
if want loginshell; then
  first=""
  for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    [[ -f "$f" ]] && { first="$f"; break; }
  done

  if [[ -z "$first" ]]; then
    warn "no ~/.bash_profile, ~/.bash_login or ~/.profile -- login shells will"
    warn "not read ~/.bashrc. Creating a minimal ~/.profile."
    if (( CHECK_ONLY )); then
      printf '    \033[2m[would write]\033[0m %s\n' "$HOME/.profile"
    else
      cat >"$HOME/.profile" <<'EOF'
# ~/.profile: read by login shells. Sourcing ~/.bashrc is what makes an
# interactive login shell pick up the same environment as a subshell.
[ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
EOF
    fi
  elif grep -q 'bashrc' "$first" 2>/dev/null; then
    skip "login shells read ~/.bashrc via $(basename "$first")"
  else
    warn "$first is the file login shells read, and it does NOT source"
    warn "~/.bashrc -- so ssh/mosh logins will not get your environment."
    warn "Add this to it:    [ -f \"\$HOME/.bashrc\" ] && . \"\$HOME/.bashrc\""
  fi
fi

# ------------------------------------------------------------------- 5. git

if want git; then
  if [[ -n "$(git config --global user.email 2>/dev/null)" ]]; then
    skip "git identity already set ($(git config --global user.email))"
  else
    log "setting global git identity: $GIT_NAME <$GIT_EMAIL>"
    run git config --global user.name  "$GIT_NAME"
    run git config --global user.email "$GIT_EMAIL"
    run git config --global init.defaultBranch main
    run git config --global pull.rebase false
  fi
fi

# -------------------------------------------------------------- 6. dotfiles

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
  # UI preferences only (theme, tui). Deliberately NOT carried from ~/.claude:
  # .credentials.json (auth tokens), settings.local.json (machine-specific
  # permissions, and already in the global gitignore), and projects/ sessions/
  # history.jsonl / cache -- transcripts and regenerable state.
  install_dotfile claude-settings.json "$HOME/.claude/settings.json"
fi

# ------------------------------------------------------------------- 7. ssh

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

# ----------------------------------------------------------------- 8. mamba

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

  # Probe before solving: without this every re-run does a full network solve
  # for the same 8 packages, so a no-op re-run takes minutes.
  _pkgs_missing=0
  for _p in "${MAMBA_PACKAGES[@]}"; do
    [[ -d "$HOME/miniforge3/envs/$ENV_NAME/conda-meta" ]] \
      && compgen -G "$HOME/miniforge3/envs/$ENV_NAME/conda-meta/${_p}-*.json" >/dev/null \
      || { _pkgs_missing=1; break; }
  done
  if (( ${#MAMBA_PACKAGES[@]} )) && (( ! _pkgs_missing )); then
    skip "mamba packages already present in '$ENV_NAME'"
  elif (( ${#MAMBA_PACKAGES[@]} )); then
    log "mamba install: ${MAMBA_PACKAGES[*]}"
    run "$MAMBA" install -n "$ENV_NAME" -y "${MAMBA_PACKAGES[@]}"
  else
    skip "no mamba packages requested"
  fi
fi

# ------------------------------------------------------------------ 9. node

if want node; then
  MAMBA="$HOME/miniforge3/bin/mamba"
  if [[ ! -x "$MAMBA" ]] && (( ! CHECK_ONLY )); then
    die "mamba not found at $MAMBA -- run the mamba step first"
  fi
  if [[ -x "$HOME/miniforge3/envs/$ENV_NAME/bin/node" ]]; then
    skip "node already in env '$ENV_NAME'"
  else
    log "installing node/npm into env '$ENV_NAME': ${NODE_PACKAGES[*]}"
    run "$MAMBA" install -n "$ENV_NAME" -y "${NODE_PACKAGES[@]}"
  fi
fi

# -------------------------------------------------------------------- 10. ml

if want ml && (( DO_ML )); then
  MAMBA="$HOME/miniforge3/bin/mamba"
  if [[ ! -x "$MAMBA" ]] && (( ! CHECK_ONLY )); then
    die "mamba not found at $MAMBA -- run the mamba step first"
  fi
  if [[ -x "$HOME/miniforge3/envs/$ENV_NAME/bin/python" ]] \
     && "$HOME/miniforge3/envs/$ENV_NAME/bin/python" -c 'import torch' 2>/dev/null; then
    skip "ML stack already present in '$ENV_NAME'"
  else
    if command -v nvidia-smi >/dev/null 2>&1; then
      log "GPU detected; the solver will select CUDA builds"
    else
      warn "no GPU detected; the solver will select CPU builds of the same packages"
    fi
    log "installing ML stack into '$ENV_NAME' (~3GB): ${ML_PACKAGES[*]}"
    run "$MAMBA" install -n "$ENV_NAME" -y "${ML_PACKAGES[@]}"
  fi
fi

# ----------------------------------------------------------------- 11. emacs

if want emacs; then
  if [[ -d "$HOME/.config/doom/.git" ]]; then
    skip "~/.config/doom already cloned"
  else
    log "cloning doom config to ~/.config/doom"
    if (( CHECK_ONLY )); then
      printf '    \033[2m[would clone]\033[0m %s\n' "$DOOM_REPO"
    else
      # Keep stderr: hiding it turns a host-key prompt or a network failure
      # into a silent, unexplained fallback. A failed clone can still leave a
      # partial directory behind, which would make the https attempt fail with
      # "destination path already exists", so clear it first.
      if ! git clone "$DOOM_REPO" "$HOME/.config/doom"; then
        rm -rf "$HOME/.config/doom"
        warn "ssh clone failed (key not registered with GitHub yet?); using https"
        git clone "$DOOM_REPO_HTTPS" "$HOME/.config/doom"
        DOOM_REMOTE_IS_HTTPS=1
      fi
    fi
  fi

  # Record the https remote whether or not this run did the cloning -- a
  # previous run may have fallen back, and the summary needs to say so.
  if [[ -d "$HOME/.config/doom/.git" ]] \
     && git -C "$HOME/.config/doom" remote get-url origin 2>/dev/null | grep -q '^https://'; then
    DOOM_REMOTE_IS_HTTPS=1
  fi

  # The doom repo carries its own installer; it handles emacs, doom, vterm deps
  # and its own idempotency. Do not duplicate that logic here.
  if [[ -x "$HOME/.config/doom/setup.sh" ]]; then
    log "delegating to ~/.config/doom/setup.sh"
    # --check must actually INVOKE the child with --check. Routing it through
    # `run` would only print the command, leaving the entire emacs half
    # uninspected by a dry run.
    doom_args=()
    (( CHECK_ONLY )) && doom_args+=(--check)
    # SKIP_APT is read from the environment by setup.sh, so it has to be
    # exported, not merely set. Without this, --no-apt is silently ignored by
    # the emacs half and it calls sudo anyway.
    # Never abort the whole provision on an emacs failure: everything above has
    # already succeeded, and the summary below prints the ssh key the user must
    # upload. Report and carry on.
    if ! SKIP_APT="$SKIP_APT" "$HOME/.config/doom/setup.sh" "${doom_args[@]}"; then
      warn "~/.config/doom/setup.sh failed (exit $?). The account is otherwise"
      warn "provisioned; re-run it directly to see the error:"
      warn "    ~/.config/doom/setup.sh"
      EMACS_FAILED=1
    fi
  elif (( CHECK_ONLY )); then
    skip "doom setup.sh will exist after the clone above; cannot dry-run it yet"
  else
    warn "~/.config/doom/setup.sh not found or not executable; skipping emacs"
  fi
fi

# -------------------------------------------------------- 12. optional CLIs

if want claude && (( DO_CLAUDE )); then
  if command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]]; then
    skip "claude already installed"
  else
    log "installing Claude Code"
    run bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
    NEED_AUTH_CLAUDE=1
  fi
fi

if want codex && (( DO_CODEX )); then
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
