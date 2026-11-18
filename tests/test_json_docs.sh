#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
for name in README.md README.ru.md; do
 file="$ROOT_DIR/$name"
 assert_file_contains "$file" 'apk update && apk add luci-base cgi-io ucode ucode-mod-fs nftables kmod-nft-tproxy curl ca-bundle' "$name manual APK dependencies"
 assert_file_contains "$file" 'sweep7125/xraywrt' "$name current release account"
 assert_file_not_contains "$file" 'opkg install' "$name has no opkg install instructions"
 assert_file_not_contains "$file" 'opkg remove' "$name has no opkg remove instructions"
 assert_file_not_contains "$file" '.ipk' "$name has no ipk assets"
 assert_file_not_contains "$file" 'cgi-io jq nftables' "$name must not install jq at runtime"
 pass "JSON docs: $name package instructions"
done
assert_file_contains "$ROOT_DIR/docs/development.md" 'ucode-mod-fs' 'development docs name the helper module'
assert_file_contains "$ROOT_DIR/tools/build-sdk.sh" 'Runtime dependencies (curl, ucode, ucode-mod-fs, nftables)' 'SDK help names current runtime dependencies'
assert_file_contains "$ROOT_DIR/README.md" '## If internet is lost' 'README has recovery section'
assert_file_contains "$ROOT_DIR/README.ru.md" '## Если пропал интернет' 'README.ru has recovery section'
assert_file_contains "$ROOT_DIR/docs/user-guide.md" '## If internet is lost' 'user guide has recovery section'
assert_file_contains "$ROOT_DIR/docs/development.md" 'SHA256SUMS-core' 'release includes core checksums'
assert_file_contains "$ROOT_DIR/docs/development.md" 'sweep7125/xraywrt-core' 'release workflow names core repository'
assert_file_not_contains "$ROOT_DIR/docs/development.md" 'draft release' 'release workflow publishes app release'
assert_file_contains "$ROOT_DIR/docs/development.md" 'git tag vX && git push origin vX' 'release tag workflow'
pass 'JSON docs: recovery and release workflow'
