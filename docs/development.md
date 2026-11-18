# XrayWRT development

[English README](../README.md) · [Русский](../README.ru.md) · [User guide](user-guide.md)

## Build

Linux and macOS builds use Docker and the OpenWrt 25.12.6 SDK. The app packages
are architecture-independent; the core is a separate package. Only OpenWrt
25.12 (apk) is supported.

```sh
./tools/build-sdk.sh build
./tools/build-sdk.sh help
```

The SDK archive is checksum-verified and cached in `.sdk/`. The case-sensitive
SDK tree uses the Docker volume `xraywrt-sdk-25.12.6`. Built app and Russian
translation APKs go to `dist/`. See `Makefile` for dependencies and hooks.
Runtime JSON uses `ucode` and `ucode-mod-fs`; jq is a test/build tool, not a
runtime dependency.

## Tests and standards

Run tests in the test container, from the repository root:

```sh
docker build -t xraywrt-test:local -f Dockerfile.test .
docker run --rm -v "$PWD:/workspace" -w /workspace xraywrt-test:local bash tests/<file>.sh
docker run --rm -v "$PWD:/workspace" -w /workspace xraywrt-test:local bash tests/run.sh
```

`tests/run.sh` runs the full suite and does not select files from arguments.
Follow `tests/testlib.sh` and nearby tests. Add a failing regression test before
changing behavior, then verify red and green. Report actual test results.

Shell targets BusyBox ash, not host bash. LuCI user strings are English with
Russian entries in `po/ru/xraywrt.po`. CSS is layout-only. Build new UI from
standard LuCI components and theme classes (`form.Map`, `ui.*`, `cbi-*`,
`alert-message`); add no new custom CSS rules or `mw-*` classes unless no
standard equivalent exists. Keep steady-state flash writes and resource costs
minimal.

For isolated VM tests and their prerequisites, see [the router harness](../tests/router/README.md).
Do not point VM tests at a real router without explicit approval.

## Releases

The public app repository is `sweep7125/xraywrt`; core packages are published
in `sweep7125/xraywrt-core`. The core builder remains private.
`PKG_VERSION` and `PKG_RELEASE` are defined in `Makefile`. Keep the version
unchanged across release candidates and bump the package revision for each new
candidate and for changed code before final release. Update the matching
changelog section.

Release actions require explicit approval to tag, push and publish:

1. Review changes and test results. A tag must match `v<PKG_VERSION>` or
   `v<PKG_VERSION>-rc<N>` with numeric N. A final release tag must point to a
   commit on main. An RC is a pre-release and is not selected by latest.
2. Push the approved tag. For example, after separate final approval:
   ```sh
   git tag vX && git push origin vX
   ```
   Replace X with `PKG_VERSION`. A tag push triggers the workflow; it is not just
   a build check. `workflow_dispatch` runs tests, builds and inspects without
   publishing.
3. A tag push waits up to 15 minutes for a passing `test` run on the exact
   tagged commit from a branch push (`main` for stable releases). It does not
   rerun the suite. GitHub then builds and inspects the app APKs and publishes
   them with `SHA256SUMS`. The workflow does not build the core.
4. Build and publish approved core packages separately in `sweep7125/xraywrt-core`,
   with every supported production APK and `SHA256SUMS-core`. Verify assets
   before publication. Retain old releases in both repositories for rollback.
   Packages are not signed; checksums do not authenticate a release.

For RC testing, `XRAYWRT_RELEASE_URL` selects **app assets only**. Core updates
always select the latest stable core from the separate core repository; RCs are
not selected by latest. To test a core prerelease, manually verify its
`SHA256SUMS-core` and install the matching APK. The default installer selects
latest stable app and core releases independently.
