# provision-ubuntu-account

Provisions a **user account**, not the server. Everything lands under `$HOME`;
the only step needing sudo is a small apt install that `--no-apt` skips
entirely, so a server-level script can own system packages instead.

```
git clone <this repo> ~/.config/provision-ubuntu-account
~/.config/provision-ubuntu-account/provision-ubuntu-account.sh --check   # dry run first
~/.config/provision-ubuntu-account/provision-ubuntu-account.sh
```

Run it **as the user being provisioned** — never under `sudo`, which would make
`$HOME` be `/root`. The script refuses to run as root.

Idempotent: re-running is safe. Existing files are backed up
(`~/.bashrc.bak-<timestamp>`), never silently clobbered.

## What it does

| step | what |
|---|---|
| `dirs` | `~/bin` (added to PATH), `~/scratch`, `~/stuff`, `~/junk`; the shared `README.org` explainer into the last three |
| `bashrc` | installs `templates/bashrc` with the env name substituted, backing up any existing one |
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
| `--git-name`, `--git-email` | prairie-guy / cdaniels@nandor.net | git identity |
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
  clones it and delegates; it does not duplicate that logic.
* a server-level `setup-linux-server.sh` would handle things this script
  deliberately does not: tailscale, mosh, the nvidia stack, users, firewall.
