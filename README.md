# outpost

My own AUR-like repo because user account registration is closed right now.

Packages in [`packages/`](packages/) are AUR packages, built from pinned AUR
commits (or a local override when AUR lags behind) and signed in CI, then
published as the pacman repository **`[aurstrich]`**.

## Why AURstrich?

- **Prebuilt.** Packages arrive ready to install. No `makepkg`, no build
  dependencies, no waiting on your own machine for a compile: `pacman -S` and
  you're done.
- **Extreme compression.** Every package is compressed with zstd at its
  maximum level (`--ultra -22`), around 55% smaller than makepkg's default
  for legcord. That costs CI build time, not yours: decompression is just as
  fast, and downloads are smaller.
- **Fast downloads from Cloudflare.** Packages are served through
  Cloudflare's CDN and cached at the edge, so downloads come from a server
  near you with plenty of bandwidth, rather than from a single origin.
- **Signed and built clean.** Every package is built in a fresh Arch Linux
  container in CI and signed, and pacman checks the signature before
  installing.
- **Kept up to date.** Packages with automatic updates are checked against
  upstream daily.

## Using it

Import and trust the signing key:

```bash
curl -fsSL -o /tmp/aurstrich.asc https://outpost.bios.plus/aurstrich/aurstrich.asc
```

```bash
sudo pacman-key --add /tmp/aurstrich.asc
```

```bash
sudo pacman-key --lsign-key DA58A59F420AD590450749472AD5708766431735
```

Add this to the end of `/etc/pacman.conf`:

```ini
[aurstrich]
SigLevel = Required DatabaseOptional
Server = https://outpost.bios.plus/aurstrich/$arch
```

Then sync:

```bash
sudo pacman -Sy
```

## Maintaining

- **Packages come from the AUR.** `packages/<name>/aur.conf` links the AUR
  original and pins a reviewed commit (`pkgbase=` when the AUR package base
  has another name, `commit=` always). CI fetches AUR's files at that commit
  and builds them; nothing from AUR is built until its commit is pinned here.
- **Overrides:** `packages/<name>/override/` holds a full PKGBUILD (and its
  files) that takes precedence over AUR's while its `epoch:pkgver-pkgrel` is
  newer, e.g. a release the AUR maintainer hasn't packaged yet. Once AUR's
  version is equal or newer, AUR's is built again and the daily check opens
  a PR deleting the override. For changes AUR will never have, put
  `permanent=1` in `override/override.conf`: that override is always built.
  Start one with `scripts/add-override.sh [--permanent] <name>`.
- **Add a package:** `scripts/add-package.sh <name>` links it to AUR at the
  current commit (`--override` also starts an override; `--standalone`
  writes a template PKGBUILD for software not on AUR). Read the PKGBUILD,
  test with `scripts/local-build.sh <name>` (needs `devtools`; builds
  whatever CI would), then push to `main`.
- **CI** builds only the packages that changed since the last successful
  push run, one package per workflow run. When a push changes several, its
  run starts one run per package and builds nothing itself, so each package
  has its own status and re-run button; a failed package is not retried by
  the next push, so re-run its run. Each run's publish job adds the package
  to the database on B2, purges the Cloudflare cache, then permanently
  deletes the package's old versions (and any old file versions B2 kept);
  publish jobs queue up and run one at a time.
  To rebuild by hand, run the workflow with a package list or `all`.
- **Republishing the same version needs a `pkgrel` bump.** CI skips versions
  already in the database.
- **Automatic updates** run daily (or by hand: *Check for package updates*).
  Each proposal gets a test build and a PR: ready if the build passed, a
  draft with the build log if it failed. Merge it to publish.
  - *AUR moved past the pin:* an `aur/<name>-<commit>` PR moves the pin and
    shows AUR's diff. Review it: merging is what lets CI build and sign the
    new AUR code. It also deletes an override AUR has caught up with, and
    flags new AUR commits under a permanent override for you to carry over.
  - *Upstream released something newer than both the build and AUR's latest*
    (packages with an `update.conf`, see
    [`packages/legcord/update.conf`](packages/legcord/update.conf)): an
    `update/<name>-<version>` PR bumps the override, creating one from AUR's
    files when there is none.
- **Signed sources:** for a PKGBUILD with `validpgpkeys`, commit each key as
  `packages/<name>/keys/pgp/<fingerprint>.asc` (keys AUR ships in its own
  `keys/pgp/` work too); CI imports them before building.
- **Packages that depend on each other:** push the dependency first. Packages
  changed in the same push are built in no particular order.
- **Removing a package:** run the *Remove package* workflow with its name
  (typed twice). It drops the package from the database, deletes its files
  from B2, closes pending update PRs and deletes `packages/<name>/`.
- **Secrets:** `scripts/set-secrets.sh` checks every value and stores it in
  GitHub.
- **Infrastructure:** [docs/cloudflare-setup.md](docs/cloudflare-setup.md).
