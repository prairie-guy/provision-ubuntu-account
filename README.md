# provision-ubuntu-account

Provisions a **user account**, not the server. Everything lands under `$HOME`;
sudo is only ever invoked if a system package is actually missing, so on a box
already provisioned by `provision-ubuntu-server.sh` this needs no privilege at
all.

```
git clone https://github.com/prairie-guy/provision-ubuntu-account.git ~/stuff/provision-ubuntu-account
cd ~/stuff/provision-ubuntu-account
./provision-ubuntu-account.sh --check     # dry run first
./provision-ubuntu-account.sh
```

Clone over **https**, not ssh: a newly created account has no key registered
with GitHub, so an ssh clone fails with `Permission denied (publickey)` before
anything else can run. The repo is public, so https needs no credentials.

The script generates an ssh key for the account as it runs and prints the
public key at the end. Once you have added that at
<https://github.com/settings/keys>, switch the remote if you want to push:

```
git remote set-url origin git@github.com:prairie-guy/provision-ubuntu-account.git
```

`git clone` creates missing parent directories, so this works on a bare account
before `~/stuff` exists — the script creates it properly on its first run.

`~/stuff` rather than `~/.config` because this is a standalone project with its
own remote, not configuration read by any program. That is the rule the
directory scheme in `templates/dirs-README.md` describes.

Run it **as the user being provisioned** — never under `sudo`, which would make
`$HOME` be `/root`. The script refuses to run as root.

## Creating the account first

If the account does not exist yet, create it from an account that has sudo:

```
sudo adduser scratch          # full account: home, /etc/skel, group, bash shell
```

Use `adduser`, not `useradd` — `useradd` creates only the passwd entry, with no
home directory, no skel files and no group. `adduser` prompts for a password,
then for Full Name / Room / Phone, which you can just press Enter through.

Then log in as that user:

```
sudo su - scratch             # or: sudo -i -u scratch
```

The `-` matters: it makes this a *login* shell, so `~/.profile` runs and sources
`~/.bashrc`. Without it you get the user's identity but your own environment.
(`login scratch` is not the tool for this — it is what getty runs, and it fails
with "Cannot possibly work without effective root".)

To reach the account over ssh instead, install your key while you still have
sudo, or from the account itself once it has a password:

```
ssh-copy-id scratch@localhost
```

### Where this fits in a full build

```
1.  install Ubuntu Server from the ISO      # also creates the first user, with sudo
2.  log in as that user
3.  git clone <provision-ubuntu-server>     # git ships with the ISO
4.  ./provision-ubuntu-server.sh            # system: docker, nvidia, tailscale, mosh, sshd
5.  git clone <this repo>            # https; no key registered yet
6.  ./provision-ubuntu-account.sh           # first account: has sudo, installs system pkgs
7.  sudo adduser scratch                    # each additional account
8.  sudo su - scratch
9.  git clone <this repo>            # https, as the new user
10. ./provision-ubuntu-account.sh          # same command; needs no sudo
```

No `apt install git` step is required: git is part of the standard Ubuntu
Server image. (The installer's **minimized** option does strip it — on such a
system, `sudo apt install git` before step 3.)

### Every account runs the same command

Both scripts probe with
`dpkg-query` first and only invoke `sudo` if a package is genuinely missing, so
once `provision-ubuntu-server.sh` has installed them the apt step is a no-op
that reports "already present" and never escalates.

```
./provision-ubuntu-account.sh
```

A second account therefore does not need to be in the `sudo` group, and does
not need `--no-apt`. Keep it out of `sudo`: everything the script does for that
account lives under `$HOME`.

`--no-apt` remains available for the case where packages *are* missing and you
want the account script to skip them rather than fail — for instance when a
parent script will install them later.

Idempotent: re-running is safe. Existing files are backed up
(`~/.bashrc.bak-<timestamp>`), never silently clobbered.

## What it does

| step | what |
|---|---|
| `dirs` | `~/bin` (added to PATH), `~/scratch`, `~/stuff`, `~/junk`; the shared `README.md` explainer into the last three |
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
| `--env NAME` | prompted, default = the env `~/.bashrc` activates, else `llm` | giving the flag skips the prompt |
| `--python VER` | `3.14` | python version for that env |
| `--git-name`, `--git-email` | prairie-guy / `…@users.noreply.github.com` | git identity |
| `--mamba-pkgs "a b c"` | see below | replace the default package list |
| `--ml`, `--claude`, `--codex` | prompted, default no | skip the question by passing the flag |
| `--no-apt` | off | skip the system-package step even if something is missing |
| `--only a,b` | all | run just these steps |
| `--reinstall` | prompted on a provisioned account | re-run the package installs even when already present |
| `--check` | off | dry run, change nothing |

Defaults also read from the environment: `ENV_NAME`, `PYTHON_VERSION`,
`GIT_NAME`, `GIT_EMAIL`.

### Interactive prompts

Run interactively with no `--env`, and the script asks:

```
mamba env name [llm]:
```

On a re-run the default is whatever `~/.bashrc` currently activates, so
pressing Enter keeps the environment you already have. On a fresh account it is
`llm`. Type another name to use a different one.

**Choosing a different name creates a second environment; it never deletes the
first.** That is the safe default — nothing you installed by hand is lost — but
the old env stays on disk while no longer being activated, so the script says
so and prints both ways out:

```
mamba env remove -n <old>          # reclaim the space
conda rename -n <old> <new>        # or keep its contents under the new name
```
 On a box with several accounts a
per-account name such as `scratch-llm` keeps `mamba env list` and the shell
prompt unambiguous, but that is a choice you make at the prompt, not a default.

It then asks about the three optional installs, all defaulting to no:

```
install the ML stack (pytorch/numpy/pandas/jupyterlab, ~3GB)? [y/N]
install Claude Code? [y/N]
install OpenAI Codex CLI? [y/N]
```

On an account that has been provisioned before, it also offers:

```
this account is already provisioned -- refresh components that are already installed? [y/N]
```

Answering yes (or passing `--reinstall`) re-runs the **package** steps — mamba,
node, ML, claude, codex — so they pull updates instead of reporting "already
present". It deliberately does not force the file steps: those compare content
already, so they pick up a changed template on their own, and forcing them would
only produce `.bak-` copies of identical files. The ssh key is never regenerated
by it, since that would invalidate every host the key is registered with.

These are asked **before any work starts**, so a long run never stops for
input. Passing `--ml`, `--claude` or `--codex` answers the corresponding
question and skips it.

`claude` and `codex` are installed but not authenticated — both use an
interactive browser/device login, which you do afterwards by running each once. The prompt is skipped entirely when `--env` is given,
when `ENV_NAME` is exported, or when there is no terminal to ask on — so a
parent provisioning script or a piped invocation never blocks. A typed name is
validated the same way the flag is.

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
