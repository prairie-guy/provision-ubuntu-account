# provision-ubuntu-account

Provisions a **user account**, not the server. Everything lands under `$HOME`;
the only step needing sudo is a small apt install that `--no-apt` skips
entirely, so a server-level script can own system packages instead.

```
git clone git@github.com:prairie-guy/provision-ubuntu-account.git ~/stuff/provision-ubuntu-account
cd ~/stuff/provision-ubuntu-account
./provision-ubuntu-account.sh --check     # dry run first
./provision-ubuntu-account.sh
```

`git clone` creates missing parent directories, so this works on a bare account
before `~/stuff` exists — the script creates it properly on its first run.

`~/stuff` rather than `~/.config` because this is a standalone project with its
own remote, not configuration read by any program. That is the rule the
directory scheme in `templates/dirs-README.md` describes.

Run it **as the user being provisioned** — never under `sudo`, which would make
`$HOME` be `/root`. The script refuses to run as root.

Idempotent: re-running is safe. Existing files are backed up
(`~/.bashrc.bak-<timestamp>`), never silently clobbered.

## What it does

| step | what |
|---|---|
| `dirs` | `~/bin` (added to PATH), `~/scratch`, `~/stuff`, `~/junk`; the shared `README.org` explainer into the last three |
| `bashrc` | installs `templates/bashrc` with the env name substituted, backing up any existing one |
| `loginshell` | verifies a login shell actually reaches `~/.bashrc` (see below) |
| `git` | global `user.name`/`user.email`, `init.defaultBranch` |
| `dotfiles` | global gitignore, zellij config, and Claude UI settings — files no other repo carries |
| `ssh` | ed25519 keypair if absent, then prints the public key to add to GitHub |
| `apt` | `git curl wget bc less` only — everything else comes from mamba |
| `mamba` | miniforge3, then an env with your chosen name and python version |
| `node` | `nodejs` (node + npm) into that env |
| `emacs` | clones the doom config and delegates to its own `setup.sh` |
| optional | `--ml`, `--claude`, `--codex` |

Run a subset with `--only dirs,git`.

## Options

| flag | default | purpose |
|---|---|---|
| `--env NAME` | `llm` | mamba environment name |
| `--python VER` | `3.14` | python version for that env |
| `--git-name`, `--git-email` | prairie-guy / `…@users.noreply.github.com` | git identity |
| `--mamba-pkgs "a b c"` | see below | replace the default package list |
| `--claude`, `--codex` | off | install the AI CLIs |
| `--no-apt` | off | skip system packages entirely |
| `--only a,b` | all | run just these steps |
| `--check` | off | dry run, change nothing |

Defaults also read from the environment: `ENV_NAME`, `PYTHON_VERSION`,
`GIT_NAME`, `GIT_EMAIL`.

## Customising the package set

The intended way is to **edit `MAMBA_PACKAGES` at the top of the script and
delete the lines you do not want**. Each is commented with why it is there:

```bash
MAMBA_PACKAGES=(
  bat            # cat replacement, aliased to `b`
  tree           # directory listing, aliased via `treeacl`
  dust           # du replacement
  fd-find        # find replacement; provides the real `fd` name
  ripgrep-all    # provides `rga`, aliased to `rgac`; pulls in ripgrep
  fzf            # fuzzy finder, aliased to `fz`; wired into bash
  zoxide         # smarter cd, wired into bash
  zellij         # terminal multiplexer
)
```

`--mamba-pkgs "bat fzf"` overrides the list for one run without editing.

`xclip` is deliberately absent: it is useless on a headless box, where the
clipboard goes over OSC-52 instead.

## The ML stack (`--ml`)

Not installed by default — it is ~3GB, and most servers have no use for it.

**No GPU detection is needed.** conda exposes the driver as a `__cuda` virtual
package, so the same package names resolve to CUDA builds on a GPU box and CPU
builds everywhere else. On this hardware that means PyTorch 2.13 / CUDA 13.0 /
py3.14, which covers Blackwell's sm_120.

`--ml` installs into the **main** env, matching the "one main env plus throwaway
envs for experiments" workflow. For anything volatile, prefer a separate env
over growing the one every shell activates:

```
mamba create -n experiment-x python=3.14 pytorch transformers
```

That keeps a torch upgrade from taking `fzf`, `zoxide` and `zellij` down with it.

## Authorization is offline, by design

`claude` and `codex` are installed but **not** authenticated. Both use an
interactive browser/device login, and credentials should not flow through a
provisioning script. The script prints what to run at the end:

```
claude      # then follow the login prompt
codex       # then follow the login prompt
```

## Why the `loginshell` check exists

Bash reads **only the first** of `~/.bash_profile`, `~/.bash_login`,
`~/.profile` that exists. Ubuntu ships the `source ~/.bashrc` line in
`~/.profile`, so the default chain works — but if anything ever drops a
`~/.bash_profile` in place, `~/.profile` is silently skipped, `~/.bashrc` never
loads over ssh, and your whole environment disappears on login while still
working fine in a subshell. That is an unpleasant thing to debug.

The step verifies the chain rather than assuming it: it finds which file a
login shell will actually read, and warns if that file does not source
`~/.bashrc`. If none of the three exists, it writes a minimal `~/.profile`.

## The ssh / GitHub ordering problem

The doom config clones over ssh so it can push later, but a brand-new account
has no key registered with GitHub. The script generates a key, and the doom
installer falls back to https when the ssh clone fails. After adding the
printed key at <https://github.com/settings/keys>:

```
git -C ~/.config/doom remote set-url origin git@github.com:prairie-guy/doom-emacs_dot_file.git
```

## Relationship to the other repos

* `~/.config/doom` — emacs configuration, with its own `setup.sh`. This script
  clones it and delegates; it does not duplicate that logic. It lives in
  `~/.config` rather than `~/stuff` because it genuinely *is* configuration:
  Emacs reads it at startup, by that name. (`$DOOMDIR` can override the
  location, but only where a shell has set it — a systemd-launched daemon
  would not see it and would silently load a default config instead.)
* a server-level `provision-ubuntu-server.sh` would handle things this script
  deliberately does not: tailscale, mosh, the nvidia stack, sshd policy,
  account creation, firewall, and the GPU power cap as a systemd unit.
