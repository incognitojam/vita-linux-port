# Worktree-Based Development Workflow

This project uses a three-tier worktree model to support parallel development
across kernel drivers, scripts/docs, and integration work — by both humans and
AI agents.

## Architecture Overview

```
~/.cache/vita-linux/linux.git            bare cache (all remotes, shared objects)

vita-linux-port/                          main checkout (integration, primary build)
├── linux_vita/                           submodule checkout (default kernel)
├── Makefile                              orchestration (LINUX_VITA_DIR-aware)
├── .linux-vita-dir                       optional: override kernel path (gitignored)
└── ...

../vita-wt/<name>/                        outer worktrees (scripts, docs, agents)
├── logs/ → ../../vita-linux-port/logs    symlinked
├── refs/ → ../../vita-linux-port/refs    symlinked
├── .linux-vita-dir                       points to a kernel worktree
└── (no linux_vita/ by default)

../vita-kernel-wt/<name>/                 kernel worktrees (driver/feature work)
├── .config                               copied from main
├── rootfs.cpio.zst                       copied from main (built by 'make rootfs')
└── (full kernel working tree, shared objects with linux_vita/)
```

### Three Tiers

| Tier | Purpose | Location | Kernel checkout? |
|------|---------|----------|-----------------|
| Kernel worktree | Driver/feature branches | `../vita-kernel-wt/<name>/` | Yes (shared objects via git worktree) |
| Outer worktree | Scripts, Makefile, docs, agents | `../vita-wt/<name>/` | No (uses `LINUX_VITA_DIR`) |
| Integration worktree | Submodule pin/bump, PR/CI validation | `../vita-wt/<name>/` with `INIT_SUBMODULES=1` | Yes (submodule init with `--reference`) |

## Quick Reference

```sh
# One-time setup
make setup-cache              # create bare cache (speeds up clones/fetches)
make setup-git-config         # enable rerere + rebase.updateRefs in linux_vita

# Kernel feature work
make kernel-worktree NAME=mmc-dma          # create kernel worktree + switch to it
make build                                  # builds against the kernel worktree
make kernel-use NAME=usb-gadget            # switch to a different kernel worktree
make kernel-use RESET=1                    # switch back to ./linux_vita

# Outer worktree (scripts/docs)
make worktree NAME=fix-boot-watch          # create outer worktree
make worktree NAME=pr-review INIT_SUBMODULES=1  # integration worktree

# Submodule management
make kernel-bump                           # pin linux_vita to HEAD of current kernel dir
make kernel-bump COMMIT=abc123             # pin to a specific commit

# Cache maintenance
make update-cache                          # fetch all remotes into bare cache
```

## Kernel Directory Resolution

The Makefile resolves the kernel source directory using a fallback chain
(first wins):

1. `LINUX_VITA_DIR` environment variable or Make command-line argument
2. `.linux-vita-dir` file in the repo root (one line, path)
3. `./linux_vita` (submodule default)

This means existing workflows (`make build` with the default submodule) are
unchanged. The new helpers write `.linux-vita-dir` to redirect builds to kernel
worktrees.

Relative paths in `.linux-vita-dir` resolve relative to the repo root (where
the Makefile lives), not the caller's CWD.

## Bare Cache

**Location:** `~/.cache/vita-linux/linux.git`

A bare clone with all known remotes. Used as `--reference-if-able` when
initializing submodules, and as the object source for kernel worktrees. This
avoids re-downloading the full Linux kernel history for each worktree.

```sh
make setup-cache     # create + fetch all remotes (idempotent, safe to re-run)
make update-cache    # fetch new objects (run occasionally)
```

The cache is optional. If it doesn't exist, `--reference-if-able` silently
falls back to a normal fetch. CI and fresh machines work without it.

### Remotes in the cache

| Name | URL |
|------|-----|
| `origin` | `https://github.com/incognitojam/linux_vita.git` |
| `upstream` | `https://github.com/xerpi/linux_vita.git` |
| `techflashYT` | `https://github.com/techflashYT/linux-custom.git` |
| `torvalds` | `https://github.com/torvalds/linux.git` |

Edit `CACHE_REMOTES` in the Makefile to add or remove remotes.

## Kernel Worktrees

Create a kernel worktree for feature/driver development:

```sh
make kernel-worktree NAME=mmc-dma
# Creates ../vita-kernel-wt/mmc-dma/ on branch topic/mmc-dma
# Copies .config and rootfs.cpio.zst from main linux_vita/ (build with 'make rootfs')
# Writes .linux-vita-dir so subsequent builds use this worktree
```

Options:

```sh
make kernel-worktree NAME=mmc-dma BASE=v6.12     # branch from a tag
make kernel-worktree NAME=mmc-dma NO_CONFIG=1    # skip .config copy
make kernel-worktree NAME=mmc-dma NO_ROOTFS=1    # skip rootfs copy
```

### Switching between kernel worktrees

```sh
make kernel-use NAME=mmc-dma       # switch to ../vita-kernel-wt/mmc-dma
make kernel-use DIR=/other/path    # switch to arbitrary kernel path
make kernel-use RESET=1            # revert to ./linux_vita (default)
```

### One-off builds without switching

```sh
make build LINUX_VITA_DIR=../vita-kernel-wt/usb-gadget
```

## Outer Worktrees

Create an outer worktree for script/doc/agent work:

```sh
make worktree NAME=fix-boot-watch
# Creates ../vita-wt/fix-boot-watch/ on branch fix-boot-watch
# Symlinks logs/ and refs/ from main worktree
```

For integration work (needs kernel submodule):

```sh
make worktree NAME=pr-review INIT_SUBMODULES=1
# Also initializes submodules using the bare cache for speed
```

Options:

```sh
make worktree NAME=feature BASE=some-branch   # branch from specific ref
```

## Submodule Bumping

After finishing kernel work, pin the submodule to the new commit:

```sh
# From main worktree (or integration worktree with submodule checkout)
make kernel-bump                    # pin to HEAD of current kernel dir
make kernel-bump COMMIT=abc123      # pin to specific commit
# Then: git diff --cached && git commit
```

The target validates that the commit is reachable from a remote branch (pushed),
so CI and other contributors can access it.

## Branch Naming Convention (linux_vita)

| Prefix | Purpose | Examples |
|--------|---------|---------|
| `upstream/*` | Tracking upstream Linux releases | `upstream/v6.12`, `upstream/v6.18` |
| `vendor/*` | Imported work from collaborators | `vendor/xerpi-6.7-rebase` |
| `port/vita-dev` | Main integration branch | `port/vita-dev` |
| `topic/*` | Feature branches (auto-created by `make kernel-worktree`) | `topic/mmc-dma`, `topic/usb-gadget` |

## Device Locking

The `boot` and `deploy` targets acquire a lock (`/tmp/vita-deploy-<host>.lock`)
to prevent two terminals or agents from deploying to the same Vita
simultaneously. If the lock is held, you'll see:

```
ERROR: Device vita is locked by another process.
  Wait or use a different device with VITA_HOST=<other>.
```

The `push` target does not lock (FTP uploads are idempotent).

## Git Config

The following git config is recommended for `linux_vita`:

```sh
make setup-git-config
# Sets:
#   rerere.enabled = true       (cache conflict resolutions for rebases)
#   rebase.updateRefs = true    (auto-update stacked branch pointers on rebase)
```

After a big rebase, use `range-diff` to verify nothing was dropped:

```sh
git range-diff <old-base>..<old-tip> <new-base>..<new-tip>
```

## What Doesn't Change

- **CI** continues using `./linux_vita` submodule directly
- **`git clone --recursive`** still works for new contributors
- **Existing `make build/push/boot/deploy`** unchanged when no override is set
- **Submodule tracking** still committed in the outer repo, pinned to a SHA
