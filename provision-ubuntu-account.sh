#!/usr/bin/env bash
#
# provision-ubuntu-account.sh -- provision a USER account, not the server.
#
# Everything here is per-user and lands under $HOME. On a box already set up by
# provision-ubuntu-server.sh it needs no sudo at all.
#
# THERE ARE THREE COMMANDS. That is the whole interface:
#
#   ./provision-ubuntu-account.sh             ask, then do it
#   ./provision-ubuntu-account.sh --dry-run   ask, then print what it would do
#   ./provision-ubuntu-account.sh doctor      check this account, offer fixes
#
# It asks about each component individually, phrased by what it actually found
# ("install X?" when absent, "update X?" when present), and asks ALL of them
# before doing any work. Then it runs to completion without stopping. Press
# Enter through everything for the conservative answer. On an account that is
# already provisioned and has not drifted, it asks nothing at all.
#
# There are no other options, deliberately. Anything consequential enough to
# want a flag is consequential enough to be asked about, and anything that is a
# VALUE rather than a decision -- the python version, the package lists, your
# git identity -- lives in the CONFIGURATION block below, edited once.
#
# Idempotent: safe to re-run. Nothing is deleted without naming the file first;
# replaced files are backed up; your ssh key is never regenerated.
#
set -euo pipefail

# ============================================================================
# CONFIGURATION -- edit these. This is the only place values are set.
# ============================================================================

# The env name is the one value you are ASKED for, because it differs per
# account and per box. The prompt defaults to whatever ~/.bashrc already
# activates, so pressing Enter on a re-run keeps the env you have.
if [[ -n "${ENV_NAME:-}" ]]; then ENV_EXPLICIT=1; else ENV_EXPLICIT=0; fi
ENV_NAME="${ENV_NAME:-llm}"                # mamba environment name
PYTHON_VERSION="${PYTHON_VERSION:-3.14}"   # python for that env
GIT_NAME="${GIT_NAME:-prairie-guy}"        # git user.name
# GitHub's noreply form, so a public repo carries no scrapeable address. Commits
# made with it still attribute correctly on GitHub. Put a real address here if
# you want one in your commit metadata.
GIT_EMAIL="${GIT_EMAIL:-prairie-guy@users.noreply.github.com}"  # git user.email
DOOM_REPO="${DOOM_REPO:-git@github.com:prairie-guy/doom-emacs_dot_file.git}"
DOOM_REPO_HTTPS="https://github.com/prairie-guy/doom-emacs_dot_file.git"

# Default mamba packages. DELETE ANY LINE YOU DO NOT WANT -- that is the
# intended way to customise this.
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
  ipython        # doom's python module uses it for the REPL (C-c C-b); config.el
                 # tunes +python-ipython-repl-args, which is inert without it
)

# Node/npm. Installed into the mamba env to keep it out of the system.
NODE_PACKAGES=(nodejs)

# ML stack. You are asked about this, and the default is NO: it is ~3GB and most
# servers do not need it. Goes into the main env, matching the "one main env plus throwaway
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
  matplotlib
  jupyterlab

  # polars, with the optional dependencies that pip ships as polars[all].
  # conda-forge splits it into a thin wrapper plus a runtime; the default
  # runtime-32 indexes up to ~4.2e9 rows. Swap in polars-runtime-64 if you ever
  # exceed that -- it is a drop-in replacement, just a larger index type.
  polars
  pyarrow        # arrow interop, and polars' parquet/IPC backend
  connectorx     # read straight from SQL databases into polars
  deltalake      # delta lake tables (~180MB)
  fsspec         # remote filesystems: s3, gcs, http
  xlsx2csv       # polars' xlsx read path
  openpyxl       # xlsx write path

  pandas         # kept for interop only -- plenty of libraries hand back a
                 # DataFrame, and polars.from_pandas needs it
)

# Rootless Docker. An agent account should NOT be in the `docker` group -- that
# grants root, since you can bind-mount / into a container. Rootless gives the
# account its own daemon in its own user namespace instead: containers run as
# the account, so mounting / shows only what the account could already see.
# GPUs still work via CDI; the no-cgroups setting below is what makes that
# possible, because a rootless daemon cannot manage cgroups.
DOCKER_ROOTLESS_PKGS=(uidmap docker-ce-rootless-extras)   # must already be installed

# Directories created in $HOME. ~/bin is also prepended to PATH by the bashrc.
HOME_DIRS=(bin scratch stuff junk)

# ============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$SCRIPT_DIR/templates"
STAMP="$(date +%Y%m%d-%H%M%S)"

CHECK_ONLY=0
DO_ML=0
DO_ROOTLESS=0
DO_CLAUDE=0
DO_CODEX=0
SKIP_APT=0
FORCE=0
ONLY=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '    \033[2m--  %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
# Never remove the directory this script lives in, an ancestor of it, $HOME, or
# /. The clone-failure cleanup below is the only rm -rf here, but DOOMDIR is an
# overridable env var, so bound it explicitly rather than trusting the caller.
# Beyond the hard refusals, always show exactly what is about to go and ask.
safe_rmdir() {
  local target="$1" confirmed="${2:-}" resolved reply
  resolved="$(cd "$target" 2>/dev/null && pwd -P)" || return 0   # absent: nothing to do
  [[ "$resolved" != "/" ]]        || die "refusing to remove /"
  [[ "$resolved" != "$HOME" ]]    || die "refusing to remove \$HOME"
  [[ "$SCRIPT_DIR" != "$resolved" && "$SCRIPT_DIR" != "$resolved"/* ]] \
    || die "refusing to remove $resolved -- this script lives inside it"

  printf '\033[1;31m'
  printf '=========================================================\n'
  printf ' ABOUT TO DELETE A DIRECTORY AND EVERYTHING BELOW IT\n'
  printf '=========================================================\033[0m\n'
  printf '  path:    %s\n' "$resolved"
  printf '  size:    %s\n' "$(du -sh "$resolved" 2>/dev/null | cut -f1)"
  printf '  entries: %s\n' "$(find "$resolved" -mindepth 1 2>/dev/null | wc -l)"
  if [[ -d "$resolved/.git" ]]; then
    printf '  git:     %s commit(s), remote %s\n' \
      "$(git -C "$resolved" rev-list --count HEAD 2>/dev/null || echo 0)" \
      "$(git -C "$resolved" remote get-url origin 2>/dev/null || echo none)"
    if ! git -C "$resolved" diff --quiet 2>/dev/null || [[ -n "$(git -C "$resolved" status --porcelain 2>/dev/null)" ]]; then
      printf '  \033[1;33mWARNING: this repo has uncommitted changes\033[0m\n'
    fi
  fi
  printf '  contents:\n'
  ls -A "$resolved" 2>/dev/null | head -10 | sed 's/^/    /'
  [[ "$(ls -A "$resolved" 2>/dev/null | wc -l)" -gt 10 ]] && printf '    ...\n'

  # "confirmed" means the user already agreed to this specific removal in the
  # up-front questions, so do not ask a second time for the same decision.
  if [[ "$confirmed" != confirmed ]]; then
    if [[ ! -t 0 ]]; then
      die "not deleting without confirmation, and there is no terminal to ask on.
   Remove it yourself and re-run:  rm -rf $resolved"
    fi
    read -r -p "type DELETE to remove it, anything else to abort: " reply || true
    [[ "$reply" == "DELETE" ]] || die "aborted; nothing was removed"
  fi
  rm -rf "$resolved"
  log "removed $resolved"
}

run()  { if (( CHECK_ONLY )); then printf '    \033[2m[would run]\033[0m %s\n' "$*"; else "$@"; fi; }

# A subcommand, not a flag: doctor reports on the account and offers fixes,
# which is a different job from provisioning it.
DOCTOR=0; HELP=0
if [[ "${1:-}" == doctor ]]; then DOCTOR=1; shift; fi

# Three things only. Every OTHER decision this script makes is a question it
# asks you, and every value it uses is in the CONFIGURATION block above -- so
# there is nothing left for a flag to do that is not either asked or edited.
#
# The deleted flags were not neutral conveniences. --only ran a partial
# provision, which produced accounts that looked finished and were not.
# --reinstall answered yes to everything at once, including the doom rebuild
# that deletes ~/.config/emacs. --env and --python silently created a second
# environment. Each was a way to do something consequential without being asked
# about it, which is the opposite of what this script is for.
while (( $# )); do
  case "$1" in
    --dry-run)    CHECK_ONLY=1; shift ;;
    -h|--help)    HELP=1; shift ;;
    *) die "unknown argument: $1

   This script takes no options beyond --dry-run and --help.
   To choose what happens, run it and answer the questions:
       ./provision-ubuntu-account.sh
   To change a value (python version, package lists, git identity),
   edit the CONFIGURATION block at the top of the script.
   To see the current state of this account and what would change:
       ./provision-ubuntu-account.sh --help
       ./provision-ubuntu-account.sh doctor" ;;
  esac
done

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

# Default to whatever ~/.bashrc already activates, so re-running and pressing
# Enter keeps the existing environment instead of quietly creating a second one.
BASHRC_ENV=""
if (( ! ENV_EXPLICIT )) && [[ -f "$HOME/.bashrc" ]]; then
  BASHRC_ENV="$(sed -n 's/^mamba activate \([A-Za-z0-9._-]\{1,\}\).*/\1/p' "$HOME/.bashrc" 2>/dev/null | tail -1)"
  [[ -n "$BASHRC_ENV" ]] && ENV_NAME="$BASHRC_ENV"
fi

# Ask for the env name when it was not specified and someone is there to answer.
# `read` returns non-zero at EOF, which would abort under `set -e`.
if (( ! ENV_EXPLICIT )) && [[ -t 0 ]]; then
  read -r -p "mamba env name [$ENV_NAME]: " _reply || true
  [[ -n "${_reply:-}" ]] && ENV_NAME="$_reply"
fi

# ENV_NAME is interpolated into a sed replacement and into a grep pattern, so
# restrict it to characters that are inert in both.
[[ "$ENV_NAME" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "invalid env name '$ENV_NAME': use only letters, digits, dot, dash, underscore"

# The steps, in the order they run. Used by --help to describe what a run would
# ask about; every one of them is always reached.
VALID_STEPS=(dirs bashrc loginshell git dotfiles ssh apt mamba node ml emacs dockerrootless claude codex)
want() { [[ -z "$ONLY" ]] || [[ ",$ONLY," == *",$1,"* ]]; }

# Optional installs. Asked here, before any work, so the run does not stop for
# input part-way through.
# One question per component, phrased by what is actually there: "install X?"
# when it is absent, "update X?" when it is not. A single blanket question
# cannot distinguish updating mamba packages from reinstalling Codex.
ENVDIR="$HOME/miniforge3/envs/$ENV_NAME"
FORCE_MAMBA=$FORCE; FORCE_NODE=$FORCE; FORCE_ML=$FORCE
FORCE_CLAUDE=$FORCE; FORCE_CODEX=$FORCE

have_mamba_pkgs() {
  [[ -d "$ENVDIR/conda-meta" ]] || return 1
  local pkg
  for pkg in "${MAMBA_PACKAGES[@]}"; do
    compgen -G "$ENVDIR/conda-meta/${pkg}-*.json" >/dev/null || return 1
  done
}
have_node()   { [[ -x "$ENVDIR/bin/node" ]]; }
have_ml()     { [[ -x "$ENVDIR/bin/python" ]] && "$ENVDIR/bin/python" -c 'import torch' 2>/dev/null; }
have_claude() { command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]]; }
have_codex()  { [[ -x "$ENVDIR/bin/codex" ]]; }
have_doom()   { [[ -d "$HOME/.config/emacs" ]]; }
have_rootless_docker() { [[ -S "/run/user/$(id -u)/docker.sock" ]] || systemctl --user is-enabled docker >/dev/null 2>&1; }

# "differs" = the file exists but no longer matches the template. A file that is
# absent is simply installed; one that matches is left alone. Only drift is
# worth a question, so a steady-state re-run asks nothing here.
RENDERED_BASHRC="$(mktemp)"
# Single EXIT handler: a second `trap ... EXIT` would silently replace the first.
cleanup() { rm -f "${RENDERED_BASHRC:-}"; [[ -n "${SUDO_KEEPALIVE:-}" ]] && kill "$SUDO_KEEPALIVE" 2>/dev/null; return 0; }
trap cleanup EXIT
sed "s/__ENV_NAME__/$ENV_NAME/g" "$TEMPLATES/bashrc" >"$RENDERED_BASHRC"
bashrc_differs() { [[ -f "$HOME/.bashrc" ]] && ! cmp -s "$RENDERED_BASHRC" "$HOME/.bashrc"; }
# These collect the exact paths that have drifted, not just whether any have, so
# the question can NAME the files it is about to replace. Answering "yes" to
# "the directory READMEs differ" means trusting the script about which files it
# means; answering it to a list of three named paths does not.
DIRS_DRIFT=(); DIRS_STALE=()
dirs_differ() {
  local d f dest
  DIRS_DRIFT=(); DIRS_STALE=()
  for d in scratch stuff junk; do
    if [[ -f "$HOME/$d/README.md" ]] && ! cmp -s "$TEMPLATES/dirs-README.md" "$HOME/$d/README.md"; then
      DIRS_DRIFT+=("$HOME/$d/README.md")
    fi
    # Superseded by README.md. This is the only deletion in the step, so it gets
    # listed with the rest rather than happening quietly mid-run.
    [[ -f "$HOME/$d/README.org" ]] && DIRS_STALE+=("$HOME/$d/README.org")
  done
  for f in "$TEMPLATES"/bin/*; do
    [[ -f "$f" ]] || continue
    dest="$HOME/bin/$(basename "$f")"
    if [[ -f "$dest" ]] && ! cmp -s "$f" "$dest"; then
      DIRS_DRIFT+=("$dest")
    fi
  done
  (( ${#DIRS_DRIFT[@]} + ${#DIRS_STALE[@]} ))
}
DOTFILES_DRIFT=()
dotfiles_differ() {
  local pair src dst
  DOTFILES_DRIFT=()
  for pair in "git-ignore:$HOME/.config/git/ignore" \
              "zellij-config.kdl:$HOME/.config/zellij/config.kdl" \
              "claude-settings.json:$HOME/.claude/settings.json"; do
    src="${pair%%:*}"; dst="${pair#*:}"
    if [[ -f "$dst" ]] && ! cmp -s "$TEMPLATES/$src" "$dst"; then
      DOTFILES_DRIFT+=("$dst")
    fi
  done
  (( ${#DOTFILES_DRIFT[@]} ))
}

# Print exactly what a question is about to do to existing files, and where the
# backup will go. Only drifted files appear: a file that already matches its
# template is never mentioned, because nothing is going to happen to it.
list_replace() {
  local f
  for f in "$@"; do
    printf '      \033[1mREPLACE\033[0m %-40s backup: %s\n' \
      "${f/#$HOME/\~}" "$(basename "$f").bak-$STAMP"
  done
}
list_delete() {
  local f
  for f in "$@"; do
    printf '      \033[1;31mDELETE\033[0m  %-40s %s\n' \
      "${f/#$HOME/\~}" "(superseded by README.md)"
  done
}

# ------------------------------------------------------------- help / doctor --

# --help is deliberately verbose and reports LIVE state: what is installed, what
# has an update waiting, and what is missing. You should be able to decide
# whether to run anything at all without running anything.
if (( HELP )); then
  sed -n '2,27p' "$0" | sed 's/^# \?//'
  printf '\033[1mSTATE OF THIS ACCOUNT\033[0m  (%s)\n\n' "$(id -un)"
  printf '  mamba env:     %s\n' \
    "$([[ -d "$ENVDIR" ]] && printf '%s (python %s)' "$ENV_NAME" \
       "$("$ENVDIR/bin/python" -V 2>/dev/null | awk '{print $2}')" || printf 'not created')"
  printf '  components:\n'
  _row() { printf '    %-22s %s\n' "$1" "$2"; }
  _row miniforge3 "$([[ -d "$HOME/miniforge3" ]] && echo present || echo MISSING)"
  _row node       "$(have_node   && "$ENVDIR/bin/node" -v 2>/dev/null || echo 'not installed')"
  _row "ML stack" "$(have_ml     && echo present || echo 'not installed')"
  _row "Claude Code" "$(have_claude && echo present || echo 'not installed')"
  _row "Codex CLI"   "$(have_codex  && echo present || echo 'not installed')"
  _row "doom emacs"  "$(have_doom   && echo present || echo 'not installed')"
  _row "rootless docker" "$(have_rootless_docker && echo present || echo 'not set up')"
  _row "ssh key"    "$([[ -f "$HOME/.ssh/id_ed25519" ]] && echo present || echo 'not generated')"

  printf '\n  \033[1mdrifted from template\033[0m (a run would offer to restore these):\n'
  _drift=0
  if bashrc_differs; then printf '    ~/.bashrc\n'; _drift=1; fi
  if dirs_differ;    then printf '    %s\n' "${DIRS_DRIFT[@]/#$HOME/\~}"; _drift=1; fi
  if dotfiles_differ; then printf '    %s\n' "${DOTFILES_DRIFT[@]/#$HOME/\~}"; _drift=1; fi
  (( _drift )) || printf '    nothing -- every managed file matches its template\n'

  printf '\n\033[1mWHAT A RUN WOULD ASK ABOUT\033[0m\n\n'
  printf '  It walks these in order, asking one question each. A component that is\n'
  printf '  absent is offered for install; one already present is offered for update;\n'
  printf '  a managed file is only mentioned when it has actually drifted.\n\n'
  printf '    %-16s %s\n' \
    dirs        "~/bin ~/scratch ~/stuff ~/junk, and their README" \
    bashrc      "~/.bashrc from templates/bashrc" \
    loginshell  "makes sure a login shell reaches ~/.bashrc" \
    git         "global user.name / user.email / init.defaultBranch" \
    dotfiles    "gitignore, zellij config, Claude UI settings" \
    ssh         "an ed25519 key, if this account has none" \
    apt         "git curl wget bc less -- the only step that can use sudo" \
    mamba       "miniforge3 + the $ENV_NAME env + ${#MAMBA_PACKAGES[@]} packages" \
    node        "node + npm, inside that env" \
    ml          "pytorch, polars, jupyterlab (~3GB) -- asked, default no" \
    emacs       "clones the doom config, runs its own setup.sh" \
    dockerrootless "a docker daemon this account owns, no docker group" \
    claude      "Claude Code -- asked, default no" \
    codex       "OpenAI Codex CLI -- asked, default no"

  printf '\n\033[1mWHAT YOU CAN CHANGE, AND WHERE\033[0m\n\n'
  printf '  There are no options for these. Edit the CONFIGURATION block at the top\n'
  printf '  of %s -- each entry has a comment saying why it is\n' "$(basename "$0")"
  printf '  what it is. They are properties of how you like an account built, not\n'
  printf '  per-run decisions, so they live in the file and not on the command line.\n\n'
  printf '    %-22s %s\n' \
    "ENV_NAME"       "$ENV_NAME   (also asked at the prompt, per account)" \
    "PYTHON_VERSION" "$PYTHON_VERSION" \
    "GIT_NAME"       "$GIT_NAME" \
    "GIT_EMAIL"      "$GIT_EMAIL" \
    "MAMBA_PACKAGES" "${#MAMBA_PACKAGES[@]} packages -- delete any line you do not want" \
    "ML_PACKAGES"    "${#ML_PACKAGES[@]} packages, only with the ML stack" \
    "NODE_PACKAGES"  "${NODE_PACKAGES[*]}" \
    "HOME_DIRS"      "${HOME_DIRS[*]}" \
    "DOOM_REPO"      "$DOOM_REPO"
  printf '\n  Templates it installs live in templates/ -- edit those to change the\n'
  printf '  content of ~/.bashrc, the dotfiles, or ~/bin scripts.\n'

  printf '\n\033[1mWHAT IT WILL NOT DO\033[0m\n\n'
  printf '  replace or delete a file without naming it first, and showing the backup\n'
  printf '  regenerate your ssh key -- it is registered with GitHub and other hosts\n'
  printf '  delete a mamba env -- a new name creates a second one, and says so\n'
  printf '  remove a directory without printing its size and contents, and\n'
  printf '    requiring you to type DELETE\n'
  printf '  escalate to sudo, once provision-ubuntu-server.sh has run\n'
  printf '  carry credentials between machines -- dotfiles are UI settings only\n\n'
  exit 0
fi

# Reports on the account, then offers each fix. Read-only until you say yes.
DOC_OK=0; DOC_WARN=0; DOC_FAIL=0
DOC_FIX_DESC=(); DOC_FIX_CMD=()
doc_ok()   { printf '  \033[1;32mOK\033[0m    %s\n' "$*"; DOC_OK=$((DOC_OK+1)); }
doc_warn() { printf '  \033[1;33mWARN\033[0m  %s\n' "$*"; DOC_WARN=$((DOC_WARN+1)); }
doc_fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; DOC_FAIL=$((DOC_FAIL+1)); }
doc_note() { printf '        \033[2m%s\033[0m\n' "$*"; }
doc_fix()  { DOC_FIX_DESC+=("$1"); DOC_FIX_CMD+=("$2"); }

if (( DOCTOR )); then
  printf '\n'
  log "doctor: account $(id -un) on $(hostname)"
  printf '\n'

  # --- the env everything else lives in
  if [[ -d "$HOME/miniforge3" ]]; then doc_ok "miniforge3 installed"
  else doc_fail "miniforge3 is missing -- nothing in the env can work"
       doc_fix "install miniforge3 and the env" "$SCRIPT_DIR/provision-ubuntu-account.sh"; fi
  if [[ -d "$ENVDIR" ]]; then
    doc_ok "env '$ENV_NAME' exists (python $("$ENVDIR/bin/python" -V 2>/dev/null | awk '{print $2}'))"
  else
    doc_fail "env '$ENV_NAME' does not exist"
    doc_fix "create the env" "$SCRIPT_DIR/provision-ubuntu-account.sh"
  fi
  # ~/.bashrc activating an env that is not there leaves every new shell broken.
  if [[ -f "$HOME/.bashrc" ]]; then
    _act="$(sed -n 's/^mamba activate \([A-Za-z0-9._-]\{1,\}\).*/\1/p' "$HOME/.bashrc" 2>/dev/null | tail -1)"
    if [[ -n "$_act" && ! -d "$HOME/miniforge3/envs/$_act" ]]; then
      doc_fail "~/.bashrc activates env '$_act', which does not exist"
      doc_note "every new shell will fail to activate it"
      doc_fix "point ~/.bashrc at an env that exists" "$SCRIPT_DIR/provision-ubuntu-account.sh"
    elif [[ -n "$_act" ]]; then
      doc_ok "~/.bashrc activates env '$_act'"
    fi
  fi

  # --- login shell chain: without it a login shell never reads ~/.bashrc, so
  # --- ssh sessions silently get a different environment from local ones.
  _first=""
  for _f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    [[ -f "$_f" ]] && { _first="$_f"; break; }
  done
  if [[ -z "$_first" ]]; then
    doc_fail "no ~/.bash_profile, ~/.bash_login or ~/.profile -- login shells never read ~/.bashrc"
    doc_fix "create a minimal ~/.profile" "$SCRIPT_DIR/provision-ubuntu-account.sh"
  elif grep -q 'bashrc' "$_first" 2>/dev/null; then
    doc_ok "$(basename "$_first") sources ~/.bashrc"
  else
    doc_fail "$_first does not source ~/.bashrc -- login shells get a different environment"
    doc_fix "fix the login shell chain" "$SCRIPT_DIR/provision-ubuntu-account.sh"
  fi

  # --- drift. Only real differences, and never auto-fixed without listing them.
  if bashrc_differs; then
    doc_warn "~/.bashrc differs from the template"
    doc_fix "review and replace ~/.bashrc (backup kept)" "$SCRIPT_DIR/provision-ubuntu-account.sh"
  else
    doc_ok "~/.bashrc matches the template"
  fi
  if dirs_differ || dotfiles_differ; then
    doc_warn "$(( ${#DIRS_DRIFT[@]} + ${#DIRS_STALE[@]} + ${#DOTFILES_DRIFT[@]} )) managed file(s) differ from their templates"
    for _f in "${DIRS_DRIFT[@]}" "${DOTFILES_DRIFT[@]}"; do doc_note "${_f/#$HOME/\~}"; done
    for _f in "${DIRS_STALE[@]}"; do doc_note "${_f/#$HOME/\~}  (stale, superseded by README.md)"; done
    doc_fix "review and restore them (backups kept)" "$SCRIPT_DIR/provision-ubuntu-account.sh"
  else
    doc_ok "managed dotfiles match their templates"
  fi

  [[ -f "$HOME/.ssh/id_ed25519" ]] \
    && doc_ok "ssh key present" \
    || { doc_warn "no ssh key -- git pushes over ssh will fail"
         doc_fix "generate one" "$SCRIPT_DIR/provision-ubuntu-account.sh"; }

  # --- rootless docker: several separately-breakable pieces, each invisible
  # --- until a container fails to start.
  if have_rootless_docker; then
    doc_ok "rootless docker daemon configured"
    if [[ -S "/run/user/$(id -u)/docker.sock" ]]; then doc_ok "its socket is live"
    else doc_fail "the rootless socket is not there -- the daemon is not running"
         doc_fix "start it" "systemctl --user start docker"; fi
    [[ -f "$HOME/.config/docker/daemon.json" ]] \
      && doc_ok "own daemon.json (log rotation, shm, memlock)" \
      || { doc_fail "no ~/.config/docker/daemon.json"
           doc_note "a rootless daemon reads NOTHING from /etc/docker: no log rotation"
           doc_note "(fills \$HOME), 64M shm, default memlock"
           doc_fix "install it" "$SCRIPT_DIR/provision-ubuntu-account.sh"; }
    if [[ -f "$HOME/.config/nvidia-container-runtime/config.toml" ]] \
       && grep -Eq '^[[:space:]]*no-cgroups[[:space:]]*=[[:space:]]*true' "$HOME/.config/nvidia-container-runtime/config.toml"; then
      doc_ok "nvidia no-cgroups set -- GPU containers can start"
    elif command -v nvidia-ctk >/dev/null; then
      doc_fail "no-cgroups is NOT set -- GPU containers will not start under rootless"
      doc_fix "write the account's nvidia config" "$SCRIPT_DIR/provision-ubuntu-account.sh"
    fi
    if [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" == yes ]]; then
      doc_ok "linger enabled -- the daemon survives logout"
    else
      doc_fail "NO linger -- the daemon and every container die at your last logout"
      doc_note "this one needs root, so it cannot be fixed from here"
      doc_fix "" "sudo loginctl enable-linger $(id -un)"
    fi
    if [[ " $(id -nG) " == *" docker "* ]]; then
      doc_fail "this account is in the docker group, which is ROOT-EQUIVALENT"
      doc_note "rootless buys nothing while the rootful socket stays reachable"
      doc_fix "" "sudo gpasswd -d $(id -un) docker"
    fi
  fi

  printf '\n'
  log "$DOC_OK ok, $DOC_WARN warning(s), $DOC_FAIL failure(s)"
  if (( ${#DOC_FIX_CMD[@]} )); then
    printf '\n'
    for _i in "${!DOC_FIX_CMD[@]}"; do
      if [[ -z "${DOC_FIX_DESC[$_i]}" ]]; then
        warn "not fixable from here:  ${DOC_FIX_CMD[$_i]}"
        continue
      fi
      printf '\n  %s\n      \033[2m%s\033[0m\n' "${DOC_FIX_DESC[$_i]}" "${DOC_FIX_CMD[$_i]}"
      if (( CHECK_ONLY )); then
        printf '    \033[2m[dry run -- would offer this fix]\033[0m\n'
      elif ask_yn "  run it?" n; then
        eval "${DOC_FIX_CMD[$_i]}" || warn "that fix failed; the rest of the report still stands"
      fi
    done
  fi
  printf '\n'
  (( DOC_FAIL )) && exit 1
  exit 0
fi

# Default y: replacing a drifted file is what the script is for, so an
# unattended run still does it. The question is an opt-OUT, not an opt-in.
KEEP_BASHRC=0; KEEP_DIRS=0; KEEP_DOTFILES=0
if bashrc_differs; then
  printf '\n'
  list_replace "$HOME/.bashrc"
  ask_yn "~/.bashrc differs from the template -- replace it?" y || KEEP_BASHRC=1
fi
if dirs_differ; then
  printf '\n'
  if (( ${#DIRS_DRIFT[@]} )); then list_replace "${DIRS_DRIFT[@]}"; fi
  if (( ${#DIRS_STALE[@]} )); then list_delete  "${DIRS_STALE[@]}"; fi
  ask_yn "apply the $(( ${#DIRS_DRIFT[@]} + ${#DIRS_STALE[@]} )) change(s) above?" y || KEEP_DIRS=1
fi
if dotfiles_differ; then
  printf '\n'
  list_replace "${DOTFILES_DRIFT[@]}"
  ask_yn "apply the ${#DOTFILES_DRIFT[@]} change(s) above?" y || KEEP_DOTFILES=1
fi

# Always-installed components: only worth a question when already present.
if (( ! FORCE_MAMBA )) && have_mamba_pkgs \
   && ask_yn "mamba packages (${MAMBA_PACKAGES[0]}, ${MAMBA_PACKAGES[1]}, ... ${#MAMBA_PACKAGES[@]} total) are installed -- update them?" n; then
  FORCE_MAMBA=1
fi
if (( ! FORCE_NODE )) && have_node \
   && ask_yn "node/npm is installed -- update it?" n; then
  FORCE_NODE=1
fi

# Opt-in components: install if absent, update if present.
if (( ! DO_ML )); then
  if have_ml; then
    if ask_yn "the ML stack is installed -- update it?" n; then DO_ML=1; FORCE_ML=1; fi
  elif ask_yn "install the ML stack (pytorch, polars, jupyterlab, ~3GB)?" n; then
    DO_ML=1
  fi
fi
if (( ! DO_CLAUDE )); then
  if have_claude; then
    if ask_yn "Claude Code is installed -- reinstall it?" n; then DO_CLAUDE=1; FORCE_CLAUDE=1; fi
  elif ask_yn "install Claude Code?" n; then
    DO_CLAUDE=1
  fi
fi
FORCE_ROOTLESS=$FORCE
if (( ! DO_ROOTLESS )); then
  if have_rootless_docker; then
    if ask_yn "rootless Docker is set up -- refresh its config?" n; then DO_ROOTLESS=1; FORCE_ROOTLESS=1; fi
  # Gated on the docker CLI, not on the setup tool: when docker is installed but
  # docker-ce-rootless-extras is not, the step below names the package an admin
  # has to add. Gating on the tool itself would make that case ask nothing and
  # say nothing, which reads as "this box cannot do it".
  elif command -v docker >/dev/null \
       && ask_yn "set up rootless Docker for this account (containers without the root-equivalent docker group)?" n; then
    DO_ROOTLESS=1
  fi
fi

FORCE_EMACS=$FORCE
if (( ! FORCE_EMACS )) && have_doom \
   && ask_yn "doom emacs is installed -- reinstall it (deletes ~/.config/emacs and rebuilds, several minutes)?" n; then
  FORCE_EMACS=1
fi

if (( ! DO_CODEX )); then
  if have_codex; then
    if ask_yn "Codex CLI is installed -- reinstall it?" n; then DO_CODEX=1; FORCE_CODEX=1; fi
  elif ask_yn "install OpenAI Codex CLI?" n; then
    DO_CODEX=1
  fi
fi

# If anything will need root, ask for it NOW, alongside the other questions, and
# keep the credential warm. sudo's cache is 15 minutes by default and a full run
# (miniforge download, doom install) comfortably outlasts it -- without this the
# emacs step can stop for a password long after you have walked away.
if want apt && (( ! SKIP_APT )) && [[ $EUID -ne 0 ]] && (( ! CHECK_ONLY )); then
  _need_root=0
  for _p in git curl wget bc less; do
    [[ "$(dpkg-query -W -f='${Status}' "$_p" 2>/dev/null)" == "install ok installed" ]] || _need_root=1
  done
  command -v emacs >/dev/null || _need_root=1     # the doom step would install it
  if (( _need_root )); then
    log "some system packages are missing; sudo is needed once"
    sudo -v
    # Refresh every 60s until this script exits.
    while sudo -n true 2>/dev/null; do sleep 60; kill -0 "$$" 2>/dev/null || exit; done &
    SUDO_KEEPALIVE=$!
  fi
fi

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
  skip "system packages are the server script's job"
fi

# ------------------------------------------------------------------- 2. dirs

if want dirs; then
  (( KEEP_DIRS )) && skip "keeping existing ~/bin files and directory READMEs"
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
    elif [[ -f "$HOME/$d/README.md" ]] && (( KEEP_DIRS )); then
      # Say KEPT, not "already current". It differs -- you asked to keep it, and
      # reporting it as identical would hide that your version is still there.
      skip "keeping your ~/$d/README.md (differs from the template)"
    else
      backup "$HOME/$d/README.md"
      run cp "$TEMPLATES/dirs-README.md" "$HOME/$d/README.md"
    fi
    # Superseded by README.md. Listed in the question above and skipped along
    # with the rest when you decline -- "keep my files" has to mean this one too.
    if [[ -f "$HOME/$d/README.org" ]] && (( ! KEEP_DIRS )); then
      log "removing stale ~/$d/README.org"
      run rm -f "$HOME/$d/README.org"
    fi
  done

  # Helper scripts into ~/bin, which the bashrc puts on PATH.
  if [[ -d "$TEMPLATES/bin" ]]; then
    for f in "$TEMPLATES"/bin/*; do
      [[ -f "$f" ]] || continue
      dest="$HOME/bin/$(basename "$f")"
      if [[ -f "$dest" ]] && cmp -s "$f" "$dest"; then
        skip "~/bin/$(basename "$f") already current"
      elif [[ -f "$dest" ]] && (( KEEP_DIRS )); then
        skip "keeping your ~/bin/$(basename "$f") (differs from the template)"
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

if want bashrc && (( ! KEEP_BASHRC )); then
  _rendered="$RENDERED_BASHRC"
  if [[ -f "$HOME/.bashrc" ]] && cmp -s "$_rendered" "$HOME/.bashrc"; then
    skip "~/.bashrc already current for env '$ENV_NAME'"
  else
    backup "$HOME/.bashrc"
    log "installing ~/.bashrc (env: $ENV_NAME)"
    if (( CHECK_ONLY )); then
      printf '    \033[2m[would write]\033[0m %s from templates/bashrc\n' "$HOME/.bashrc"
    else
      # Move the already-rendered file into place: atomic, so a failure cannot
      # leave a truncated ~/.bashrc.
      cp "$_rendered" "$HOME/.bashrc"
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
    if [[ -f "$dst" ]] && (( KEEP_DOTFILES )); then
      skip "keeping your ${dst/#$HOME/~} (differs from the template)"
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
    # Nothing is ever deleted here, so a renamed env leaves the old one behind:
    # still on disk, no longer activated by ~/.bashrc. Say so rather than let it
    # sit there unnoticed.
    if [[ -n "${BASHRC_ENV:-}" && "$BASHRC_ENV" != "$ENV_NAME" \
          && -d "$HOME/miniforge3/envs/$BASHRC_ENV" ]]; then
      warn "env '$BASHRC_ENV' still exists but is no longer activated by ~/.bashrc."
      warn "  keep both, or reclaim the space:  mamba env remove -n $BASHRC_ENV"
      warn "  (to have renamed it instead:      conda rename -n $BASHRC_ENV $ENV_NAME)"
    fi
  fi

  # Probe before solving: without this every re-run does a full network solve
  # for the same 8 packages, so a no-op re-run takes minutes.
  _pkgs_missing=0
  for _p in "${MAMBA_PACKAGES[@]}"; do
    [[ -d "$HOME/miniforge3/envs/$ENV_NAME/conda-meta" ]] \
      && compgen -G "$HOME/miniforge3/envs/$ENV_NAME/conda-meta/${_p}-*.json" >/dev/null \
      || { _pkgs_missing=1; break; }
  done
  if (( ${#MAMBA_PACKAGES[@]} )) && (( ! _pkgs_missing )) && (( ! FORCE_MAMBA )); then
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
  if [[ -x "$HOME/miniforge3/envs/$ENV_NAME/bin/node" ]] && (( ! FORCE_NODE )); then
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
     && "$HOME/miniforge3/envs/$ENV_NAME/bin/python" -c 'import torch' 2>/dev/null && (( ! FORCE_ML )); then
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
      if ! GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
           git clone "$DOOM_REPO" "$HOME/.config/doom"; then
        safe_rmdir "$HOME/.config/doom"
        warn "ssh clone failed (key not registered with GitHub yet?); using https"
        git clone "$DOOM_REPO_HTTPS" "$HOME/.config/doom"
        DOOM_REMOTE_IS_HTTPS=1
      fi
    fi
  fi

  # A reinstall means the doom CORE and its built packages (~/.config/emacs),
  # not the config repo -- that is tracked in git and stays. Already confirmed
  # by the question above, so this does not ask a second time.
  if (( FORCE_EMACS )) && [[ -d "$HOME/.config/emacs" ]]; then
    log "reinstalling doom: removing ~/.config/emacs"
    if (( CHECK_ONLY )); then
      printf '    \033[2m[would remove]\033[0m %s\n' "$HOME/.config/emacs"
    else
      safe_rmdir "$HOME/.config/emacs" confirmed
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
    # A dry run must actually INVOKE the child with --check. Routing it through
    # `run` would only print the command, leaving the entire emacs half
    # uninspected by a dry run.
    doom_args=()
    (( CHECK_ONLY )) && doom_args+=(--check)
    # SKIP_APT is read from the environment by setup.sh, so it has to be
    # exported, not merely set, or the emacs half calls sudo anyway.
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

# ----------------------------------------------------- 12. rootless docker

# Docker for an ordinary account, WITHOUT the docker group. That group is
# root-equivalent: the socket is root:docker, so anyone who can reach it runs
#     docker run -v /:/host -it ubuntu chroot /host
# and reads /etc/shadow, every ~/.ssh key and every stored credential on the
# box. Rootless gives this account its own daemon in its own user namespace
# instead -- containers run AS the account, so bind-mounting / shows only what
# the account could already see.
#
# Needs no root, like the rest of this script. The three root-only pieces (the
# uidmap and docker-ce-rootless-extras packages, and enable-linger) belong to
# provision-ubuntu-server.sh; when one is missing this step prints the exact
# command an admin must run instead of failing part-way through.
if want dockerrootless && (( DO_ROOTLESS )); then
  _rootless_restart=0

  _rootless_missing=()
  for _p in "${DOCKER_ROOTLESS_PKGS[@]}"; do
    [[ "$(dpkg-query -W -f='${Status}' "$_p" 2>/dev/null)" == "install ok installed" ]] \
      || _rootless_missing+=("$_p")
  done

  # adduser writes a subuid/subgid range; an account created with plain useradd
  # can have none, and rootless then has no uids to map into the namespace.
  _rootless_subid=1
  for _f in /etc/subuid /etc/subgid; do
    grep -q "^$(id -un):" "$_f" 2>/dev/null || _rootless_subid=0
  done

  # No pipeline here on purpose: under `set -o pipefail`, `id -nG | grep -q`
  # can report failure when grep exits early and the writer takes SIGPIPE, and
  # silently missing THIS warning is the one outcome worth avoiding.
  if [[ " $(id -nG) " == *" docker "* ]]; then
    warn "$(id -un) is in the 'docker' group, which is ROOT-EQUIVALENT."
    warn "  Rootless is pointless while that holds -- the root-equivalent socket"
    warn "  stays reachable -- and the setup tool refuses to run beside a"
    warn "  writable /var/run/docker.sock. An admin runs:"
    warn "      sudo gpasswd -d $(id -un) docker"
    warn "  then this account logs out and back in (groups are fixed at login)."
  fi

  if (( ${#_rootless_missing[@]} )); then
    warn "rootless docker needs packages this account cannot install: ${_rootless_missing[*]}"
    warn "  an admin runs:  sudo apt install -y ${_rootless_missing[*]}"
    warn "  (provision-ubuntu-server.sh installs both, as part of its packages"
    warn "   and docker steps -- this box has not had them run)"
  elif (( ! _rootless_subid )); then
    warn "no /etc/subuid or /etc/subgid range for $(id -un) -- rootless has no uids to map"
    warn "  an admin runs:"
    warn "      sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)"
  else
    # 1. The daemon. Re-running is safe: an existing unit file and CLI context
    #    are reported and left in place, so a refresh only rewrites the config
    #    files below.
    if have_rootless_docker && (( ! FORCE_ROOTLESS )); then
      skip "rootless docker daemon already set up"
    else
      log "installing the rootless docker daemon for $(id -un)"
      # This also creates and SELECTS a "rootless" CLI context, so a plain
      # `docker` command reaches this daemon with no DOCKER_HOST needed.
      # Never fatal: everything above has already succeeded, and the summary
      # below still has an ssh key to print.
      if ! run dockerd-rootless-setuptool.sh install; then
        warn "dockerd-rootless-setuptool.sh failed. Run it directly to see why:"
        warn "      dockerd-rootless-setuptool.sh install"
      fi
    fi

    # 2. The account's own daemon.json. A rootless daemon reads NOTHING from
    #    /etc/docker, so without this it gets no log rotation -- a long-running
    #    server then fills $HOME -- plus 64M of shm and the default memlock.
    _dj="$HOME/.config/docker/daemon.json"
    if [[ -f "$_dj" ]] && cmp -s "$TEMPLATES/docker-daemon.json" "$_dj"; then
      skip "rootless daemon.json already current"
    else
      backup "$_dj"
      log "installing $_dj"
      run mkdir -p "$(dirname "$_dj")"
      run cp "$TEMPLATES/docker-daemon.json" "$_dj"
      _rootless_restart=1
    fi

    # 3. The account's nvidia-container-runtime config. no-cgroups is mandatory
    #    under rootless: the daemon cannot manage cgroups, nvidia-container-cli
    #    fails without it, and GPU containers simply do not start. Deliberately
    #    the ACCOUNT's copy -- setting it in /etc would also disable cgroup
    #    limits for every rootful container on the box.
    _nvsrc=/etc/nvidia-container-runtime/config.toml
    _nvdst="$HOME/.config/nvidia-container-runtime/config.toml"
    if ! command -v nvidia-ctk >/dev/null || [[ ! -f "$_nvsrc" ]]; then
      skip "no nvidia container toolkit on this host; no GPU config to write"
    elif [[ -f "$_nvdst" ]] \
         && grep -Eq '^[[:space:]]*no-cgroups[[:space:]]*=[[:space:]]*true' "$_nvdst" \
         && (( ! FORCE_ROOTLESS )); then
      skip "nvidia no-cgroups config already in place"
    else
      log "writing $_nvdst with no-cgroups"
      run mkdir -p "$(dirname "$_nvdst")"
      run cp "$_nvsrc" "$_nvdst"
      # --config-file is a flag OF `config`, not a global one: putting it before
      # the subcommand fails. Naming only the key sets a boolean to true.
      run nvidia-ctk config --config-file "$_nvdst" \
          --set nvidia-container-cli.no-cgroups --in-place
      _rootless_restart=1
    fi

    # 4. Pick the two files up -- only when one actually changed, and only if
    #    there is a daemon to restart (step 1 may have just reported why not).
    if (( _rootless_restart )) && systemctl --user is-enabled docker >/dev/null 2>&1; then
      log "restarting the rootless docker daemon to pick up the new config"
      run systemctl --user restart docker
    fi

    # Checked against the live linger state in the summary below.
    NEED_LINGER=1
  fi
fi

# -------------------------------------------------------- 13. optional CLIs

if want claude && (( DO_CLAUDE )); then
  if { command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]]; } && (( ! FORCE_CLAUDE )); then
    skip "claude already installed"
  else
    log "installing Claude Code"
    run bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
    NEED_AUTH_CLAUDE=1
  fi
fi

if want codex && (( DO_CODEX )); then
  NPM="$HOME/miniforge3/envs/$ENV_NAME/bin/npm"
  if [[ -x "$HOME/miniforge3/envs/$ENV_NAME/bin/codex" ]] && (( ! FORCE_CODEX )); then
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
if [[ -n "${NEED_LINGER:-}" ]] && ! loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | grep -qx yes; then
  warn "rootless docker dies when your last session ends. As an admin, run once:"
  warn "    sudo loginctl enable-linger $(id -un)"
fi
[[ -n "${NEED_AUTH_CLAUDE:-}" ]] && warn "AUTHORIZE (offline, interactive): run 'claude' and follow the login prompt"
[[ -n "${NEED_AUTH_CODEX:-}" ]]  && warn "AUTHORIZE (offline, interactive): run 'codex' and follow the login prompt"
exit 0
