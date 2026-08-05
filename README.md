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

## Run it with no flags

**That is the intended way to use this, and it is what you want in almost every
case.** With no arguments the script asks first and executes second:

1. **Asks** about each component individually, phrased by what it actually
   found — `install Claude Code?` when it is absent, `Claude Code is installed
   -- reinstall it?` when it is not. Every question comes before any work.
2. **Executes** to completion without stopping, so a run that downloads
   miniforge and builds doom does not pause halfway to ask you something.

Press Enter through everything and you get the conservative answer: missing
things are installed, present things are left alone, drifted config files are
restored from the template with a backup kept.

On an account that is already provisioned and has not drifted, a re-run asks
**nothing at all** and just reports what it found.

**The flags are not the interface.** They exist so a second account, or an
unattended run, can answer the questions up front. The only one worth reaching
for routinely is `--check`, which asks the same questions and then prints what
it would do instead of doing it.

### Where the settings live

| | holds | how you change it |
|---|---|---|
| **the questions** | *what should happen* — install the ML stack or not, refresh a dotfile or not | answer them at the prompt |
| **the `CONFIGURATION` block** at the top of the script | *what values to use* — the package lists, python version, git identity, doom repo | edit those lines once |

The mamba environment name is the one value you *are* asked for, because it
differs per account and per box; everything else in that block is a property of
how you like an account set up, not a per-run decision.

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
| `dockerrootless` | a docker daemon this account owns, without the root-equivalent `docker` group (see below) |
| optional | `--ml`, `--claude`, `--codex`, `--docker-rootless` |

Run a subset with `--only dirs,git`.

## Options

| flag | default | purpose |
|---|---|---|
| `--env NAME` | prompted, default = the env `~/.bashrc` activates, else `llm` | giving the flag skips the prompt |
| `--python VER` | `3.14` | python version for that env |
| `--git-name`, `--git-email` | prairie-guy / `…@users.noreply.github.com` | git identity |
| `--mamba-pkgs "a b c"` | see below | replace the default package list |
| `--ml`, `--claude`, `--codex` | prompted, default no | skip the question by passing the flag |
| `--docker-rootless` | prompted, default no | set up this account's own rootless docker daemon |
| `--no-apt` | off | skip the system-package step even if something is missing |
| `--only a,b` | all | run just these steps |
| `--reinstall` | asked per component | answer yes to every already-present component at once |
| `--check` | off | dry run, change nothing |

None of these are needed for a normal run — the questions cover every decision.
They are for answering up front, so a second account or an unattended run does
not need you at the keyboard.

Defaults also read from the environment: `ENV_NAME`, `PYTHON_VERSION`,
`GIT_NAME`, `GIT_EMAIL`.

## Re-running is safe, and is how you change things

There is no separate "update" mode — **re-running the script *is* the update.**
It probes the account every time rather than tracking what it did last time, so
a package you installed by hand, a dotfile you edited, and a run you interrupted
part-way are all states the next run reads correctly.

On a provisioned account a re-run is mostly `--` skip lines, and in steady state
it asks **nothing at all**: file steps only raise a question when a file has
actually drifted from its template, and component steps only when the component
is already installed.

The rules that make that true:

* **`--check` changes nothing.** Every mutation goes through a `run` wrapper and
  prints as `[would run]`. The emacs step is passed `--check` through to doom's
  own installer rather than being skipped, so a dry run covers that half too.

  ```bash
  ./provision-ubuntu-account.sh --check
  ./provision-ubuntu-account.sh --check --only mamba,node
  ```

* **Files are compared before they are written,** and backed up to
  `NAME.bak-YYYYmmdd-HHMMSS` when they differ. Identical means untouched.

* **Two different defaults, on purpose.** A drifted *file* defaults to **yes,
  replace it** — restoring the template is what the script is for, and a backup
  is kept. An absent *component* defaults to **no, do not install** — nothing
  large or slow arrives because you pressed Enter.

* **No terminal means every default,** so an unattended re-run never blocks.

* **All questions are asked up front**, before any work starts.

### What a re-run will never do

| it will never | why |
|---|---|
| regenerate your ssh key | it is registered with GitHub and every host you have copied it to; even `--reinstall` will not touch an existing key |
| delete an environment | choosing a new `--env` name creates a second one and tells you the old is still on disk |
| delete a directory silently | the one `rm -rf` (a failed doom clone) prints the path, size, entry count and git state, then requires you to type `DELETE` |
| remove `$HOME`, or its own directory | `safe_rmdir` hard-refuses `/`, `$HOME`, the script's directory and every ancestor, before it asks anything |
| overwrite `~/.bashrc` without a backup | timestamped backup first, every time |
| escalate to sudo | only the `apt` step can, and only for genuinely missing packages — after `provision-ubuntu-server.sh` has run, never |
| carry credentials between machines | `dotfiles` installs UI settings only; `.credentials.json` and machine-local permissions are deliberately excluded |

### Recipes

**The plain interactive run handles most of these** — re-run with no flags and
answer the question about the thing you want to change. These are the unattended
equivalents, for when you already know the answer.

| to change | do this | what a later plain re-run does |
|---|---|---|
| mamba packages | edit `MAMBA_PACKAGES`, re-run | installs only what is missing |
| update those packages | `--only mamba --reinstall` | leaves them alone |
| python version | `--python 3.13 --env NEWNAME` | keeps both envs; activates the one in `~/.bashrc` |
| switch env | `--env other` | follows `~/.bashrc`, so the new one sticks |
| add the ML stack later | `--ml` | reports present, does not reinstall |
| update Claude Code / Codex | `--claude` / `--codex`, answer yes | asks only because they are present; defaults to no |
| restore a drifted dotfile | just re-run and answer yes | asks only while it differs |
| change the bashrc template | edit `templates/bashrc`, re-run | offers to replace, keeps a backup |
| rebuild doom | `--only emacs --reinstall` | syncs, does not rebuild |
| add rootless docker | `--docker-rootless` | reports already set up |

`--reinstall` answers yes to every already-present component at once — mamba
packages, node, the ML stack, doom, Claude, Codex. It is the blunt instrument;
prefer `--only STEP --reinstall` when you mean one thing.

### A note on the GPU driver

This script never touches the nvidia driver — that is entirely
`provision-ubuntu-server.sh`, which **holds** it so that neither `apt` nor
`unattended-upgrades` nor a routine re-run can move it. If `nvidia-smi` starts
reporting a driver/library version mismatch, that is a server-side event, not
anything a per-account run did.

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

Each component is asked about separately, and the wording follows what is
actually there — `install` when absent, `update`/`reinstall` when present:

```
~/.bashrc differs from the template -- replace it (a backup is kept)?  [Y/n]
files in ~/bin or the directory READMEs differ -- replace them?        [Y/n]
gitignore / zellij / claude settings differ -- replace them?           [Y/n]
mamba packages (bat, tree, ...) are installed -- update them?          [y/N]
node/npm is installed -- update it?                                    [y/N]
install the ML stack (pytorch, polars, jupyterlab, ~3GB)?              [y/N]
Claude Code is installed -- reinstall it?                              [y/N]
doom emacs is installed -- reinstall it (deletes ~/.config/emacs)?     [y/N]
install OpenAI Codex CLI?                                              [y/N]
```

The file questions appear **only when a file has actually drifted** from the
template, so a steady-state re-run does not ask them at all. They default to
**yes** — replacing a drifted file is what the script is for — so they are an
opt-out, and an unattended run still updates. The others default to no.

Reinstalling doom removes `~/.config/emacs` (the doom core and its built
packages) and rebuilds. It does **not** touch `~/.config/doom`, which is your
tracked configuration.

Answers are independent: saying yes to mamba does not touch Codex. Components
that are absent and not opt-in (node) are simply installed without asking.

`--reinstall` answers yes to every component that is already present, for
unattended use. Neither the prompts nor the flag force the **file** steps —
those compare content already, so they pick up a changed template on their own,
and forcing them would only produce `.bak-` copies of identical files. The ssh
key is never regenerated, since that would invalidate every host it is
registered with.

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
  ipython        # doom's python REPL (C-c C-b) uses it
)
```

`--mamba-pkgs "bat fzf"` overrides the list for one run without editing.

`xclip` is deliberately absent: it is useless on a headless box, where the
clipboard goes over OSC-52 instead.

## The ML stack (`--ml`)

Not installed by default — it is ~3GB, and most servers have no use for it.

The dataframe stack is **polars**, with the optional dependencies pip ships as
`polars[all]`: `pyarrow` (arrow interop and the parquet/IPC backend),
`connectorx` (read straight from SQL), `deltalake`, `fsspec` (s3/gcs/http),
and `xlsx2csv`/`openpyxl` for spreadsheets. `pandas` is kept for interop only —
plenty of libraries hand back a DataFrame, and `polars.from_pandas` needs it.

conda-forge splits polars into a thin wrapper plus a runtime. The default,
`polars-runtime-32`, indexes up to about 4.2 billion rows; swap in
`polars-runtime-64` if you ever exceed that.

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

## Docker without root (`dockerrootless`)

Ordinary accounts have **no** docker access by default: `/var/run/docker.sock`
is `root:docker`, so anything else gets "permission denied". There are exactly
two ways to change that, and only one of them is safe for an account an agent
drives:

| | grants | suitable for |
|---|---|---|
| `sudo usermod -aG docker NAME` | **root-equivalent** | a human admin |
| this step — a rootless daemon | containers only, as that account | an agent, or any untrusted worker |

The group is root-equivalent because membership lets you run

```bash
docker run -v /:/host -it ubuntu chroot /host
```

which is a root shell: it reads `/etc/shadow`, every `~/.ssh` key and every
stored credential on the box. No password, no exploit — it is what the socket
does. An account in that group is not a restricted worker; it is root that
happens not to have `sudo`.

This step instead gives the account **its own daemon in its own user
namespace**. Containers run as the account, so bind-mounting `/` shows only
what the account could already see. It is per-account and never automatic:
provisioning one account grants nothing to the next.

What it writes, all under `$HOME`:

* the rootless daemon itself, via `dockerd-rootless-setuptool.sh`, which also
  creates and selects a `rootless` CLI context — so a plain `docker` command
  reaches this daemon with no `DOCKER_HOST` needed
* `~/.config/docker/daemon.json`, because **a rootless daemon reads nothing
  from `/etc/docker`**. Without it the account gets no log rotation (a
  long-running server then fills `$HOME`), 64 MB of shm, and the default memlock
* `~/.config/nvidia-container-runtime/config.toml` with `no-cgroups`, which is
  what makes GPUs work at all — a rootless daemon cannot manage cgroups, and
  `nvidia-container-cli` fails without it. Deliberately the *account's* copy:
  setting it in `/etc` would also disable cgroup limits for rootful containers

Three things need root and therefore belong to `provision-ubuntu-server.sh`,
not here. The step checks each and prints the exact command when one is missing:

```bash
sudo apt install -y uidmap docker-ce-rootless-extras   # in SYSTEM_PACKAGES / the docker step
sudo gpasswd -d NAME docker      # revoke the root-equivalent group, if present
sudo loginctl enable-linger NAME # or the daemon dies with the last session
```

Verify:

```bash
docker info -f '{{.SecurityOptions}}'      # includes name=rootless
docker run --rm --device nvidia.com/gpu=all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi -L
```

Note `--device nvidia.com/gpu=all`, not `--gpus all`: Docker 29 routes `--gpus`
through CDI as vendor-agnostic and fails with `AMD CDI spec not found` even when
the NVIDIA spec is present.

Images live in `~/.local/share/docker`, so they are not shared with other
accounts and the disk usage shows up in the account's own home.

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
