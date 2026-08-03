# Home directory scheme

Three working directories, sorted by **where the versioning lives** and **how
big things are**. This same README is in each of them.

## `~/scratch` — IS saved to github

`~/scratch` is *itself* a single git repository, pushed to github.

For projects that:

- are worth saving, but are **not** their own github projects
- are reasonably sized — **not** large artifacts such as AI models, which
  would bloat the shared repo

## `~/stuff` — is NOT saved to github

`~/stuff` is not a repository. Everything inside either versions itself or is
too large to version at all.

For projects that:

- **are** their own github projects, so the parent needs no versioning
- are too large to save, i.e. large AI models

## `~/junk` — is NOT saved to github

For projects and files that:

- are temporary in nature
- can be thrown away without much concern

---

`~/bin` is separate: personal executables and symlinks, put on `PATH` by
`~/.bashrc`. It is not a working directory and holds no projects.
