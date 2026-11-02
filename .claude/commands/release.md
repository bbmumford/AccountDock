Prepare an AccountDock release locally. Never create a remote, push, or publish
unless the user gives a separate explicit instruction.

## Procedure

1. Confirm the repository is on `main`, has at least one commit, and is clean.
2. Read `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from `project.yml`.
3. Choose an explicit semantic version or `patch`, `minor`, or `major`.
4. Update `RELEASE_NOTES.md` with concise user-facing changes.
5. Commit the release notes before tagging.
6. Run `./scripts/release.sh <version>`.
7. Verify:
   - both app and widget have the requested marketing version;
   - both targets have the incremented build number;
   - tag `v<version>` points at the version commit;
   - tests pass;
   - no remote operation occurred.

The script creates a version commit and tag locally. It intentionally does not
push. Publishing later requires explicit approval and these separate commands:

```bash
git push origin main
git push origin vX.Y.Z
```

The `v*` tag triggers `.github/workflows/ci-release.yml`, which tests, signs,
packages, notarizes, staples, hashes, and publishes `AccountDock.pkg` and
`AccountDock.pkg.sha256`.

Never use `git push --tags`.
