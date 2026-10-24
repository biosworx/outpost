# outpost

My own AUR-like repo because user account registration is closed right now.

PKGBUILDs in [`packages/`](packages/) are built and signed in CI, then
published as the pacman repository **`[aurstrich]`**.

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

- **Add a package:** `scripts/add-package.sh <name>`, edit the PKGBUILD, run
  `updpkgsums`, test with `scripts/local-build.sh <name>` (needs `devtools`),
  then push to `main`.
- **CI** builds only the packages that changed since the last successful run,
  each in its own job, so one failure doesn't hold up the rest. A final
  publish job adds whatever built to the database on B2 and purges the
  Cloudflare cache.
  To rebuild by hand, run the workflow with a package list or `all`.
- **Republishing the same version needs a `pkgrel` bump.** CI skips versions
  already in the database.
- **Automatic updates:** packages with an `update.conf` (see
  [`packages/legcord/update.conf`](packages/legcord/update.conf)) are checked
  daily. A new upstream version gets a test build and a PR: a ready PR if the
  build passed, a draft PR with the build log if it failed. Merge it to
  publish. Run *Check for package updates* by hand to check now.
- **Packages that depend on each other:** push the dependency first. Packages
  changed in the same push are built in no particular order.
- **Removing a package:** run the *Remove package* workflow with its name
  (typed twice). It drops the package from the database, deletes its files
  from B2, closes pending update PRs and deletes `packages/<name>/`.
- **Secrets:** `scripts/set-secrets.sh` checks every value and stores it in
  GitHub.
- **Infrastructure:** [docs/cloudflare-setup.md](docs/cloudflare-setup.md).
