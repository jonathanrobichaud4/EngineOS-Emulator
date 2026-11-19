# Releasing

The version is in `VERSION`. Changing it on main runs `.github/workflows/release.yml`: the
tests, then both apps and their installers from that commit, published together as release
`vX.Y.Z` (the workflow creates the tag) with `version.txt`.

```sh
echo 1.2.1 > VERSION
git commit -am "Release 1.2.1"
git push
```

Every other push runs the tests and makes test builds of the apps that changed, kept as
workflow artifacts (Actions tab).

## How updates reach people

- The apps compare their own version with the newest release's `version.txt` and replace
  themselves when it's newer (an option in their settings). Test builds (`dev`) never do.
- The apps move the emulator in the VM / WSL (a git checkout) to the tag of their own version,
  so app and emulator always match. That's why a change to a format in [cli.md](cli.md) can ship
  in one release.
- The legacy `mac-app` and `windows-app` releases get each new build too, which moves apps from
  before versioned releases over.

## Before bumping

- `sudo tests/run.sh` passes (CI runs it too).
- Boot at least one deck of each model the change touches.
- If the shim or a panel changed, the regenerated files are committed (the tests check).
