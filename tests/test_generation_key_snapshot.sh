#!/usr/bin/env bash
set -eu
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/rootfs/usr/lib/xraywrt/lists.sh"
source "$ROOT_DIR/rootfs/usr/lib/xraywrt/xray-config.sh"
RULES_FILE="$tmpdir/rules"
POLICY_CACHE_DIR="$tmpdir/cache"
mkdir -p "$POLICY_CACHE_DIR"
printf 'source\n' >"$tmpdir/source"
printf 'rules\n' >"$RULES_FILE"
xraywrt_lib_dir() { printf '%s\n' "$ROOT_DIR/rootfs/usr/lib/xraywrt"; }
xray_params_json() { printf '{}\n'; }
lists_rules_urls() { printf '%s\n' 'https://example/a;443' 'https://example/b;443'; }
lists_cache_file() { case "$1" in *a\;443) printf '%s/a\n' "$POLICY_CACHE_DIR" ;; *) printf '%s/b\n' "$POLICY_CACHE_DIR" ;; esac; }
printf 'identical\n' >"$POLICY_CACHE_DIR/a"
a="$(xray_config_key "$tmpdir/source")"
mv "$POLICY_CACHE_DIR/a" "$POLICY_CACHE_DIR/b"
b="$(xray_config_key "$tmpdir/source")"
[ "$a" != "$b" ] || { echo 'cache identity collision' >&2; exit 1; }
sha256sum() {
 local content
 content="$(cat)"
 if [ "$fail_content" = lib ]; then
  case "$content" in *"function group_rule_runs"*) return 1 ;; esac
 elif [ "$content" = "$fail_content" ]; then return 1; fi
 printf '%s' "$content" | command sha256sum
}
for fail_content in source rules identical lib; do
 if xray_config_key "$tmpdir/source" >/dev/null; then echo "hash failure accepted: $fail_content" >&2; exit 1; fi
done
pass 'generation key distinguishes missing cache and fails on hash errors'

(
 source "$ROOT_DIR/rootfs/usr/lib/xraywrt/xray-config.sh"
 lists_rules_remote_json() { return 1; }
 xraywrt-json() { echo 'builder invoked after failed remote capture' >&2; return 0; }
 if xray_params_json >/dev/null; then echo 'remote JSON failure accepted' >&2; exit 1; fi
)
pass 'parameter capture rejects remote JSON failure'

for name in NFT_PREFIXES_CAPTURED NFT_PREFIXES_4 NFT_PREFIXES_6 XRAY_RULE_REMOTE; do
 case " $(sed -n 's/^unset \(.*\)\\$/\1/p' "$ROOT_DIR/tools/harden.sed") " in
  *" $name "*) ;;
  *) echo "snapshot variable missing from package hardening: $name" >&2; exit 1 ;;
 esac
done
pass 'package startup clears inherited snapshot variables'
