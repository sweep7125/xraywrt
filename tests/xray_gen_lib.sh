# Shared helpers for xray-config.uc tests; needs testlib.sh and $tmpdir.
# shellcheck shell=bash disable=SC2154
FX="$ROOT_DIR/tests/fixtures/xray"

# gen <src> [jq filter applied to the default params]: sets rc, out (runtime
# JSON), prof (profile) and errtxt.
gen() {
	jq "${2:-.}" "$FX/params/default.json" >"$tmpdir/params.json"
	rm -f "$tmpdir/out.json" "$tmpdir/out.json.profile"
	xraywrt-json gen "$1" "$tmpdir/out.json" "$tmpdir/params.json" 2>"$tmpdir/err" && rc=0 || rc=$?
	out="$(cat "$tmpdir/out.json" 2>/dev/null || :)"
	prof="$(cat "$tmpdir/out.json.profile" 2>/dev/null || :)"
	errtxt="$(cat "$tmpdir/err")"
}
gen_fails() {
	gen "$1" "${3:-.}"
	assert_eq 1 "$rc" "$1 must fail"
	grep -Eq ' \[E:[a-z0-9_]+(\|[^]|]*)*\]$' <<<"$errtxt" || fail "missing error code: $errtxt"
	assert_eq "xraywrt-json: $(printf '%s' "$2" | tr '|]\r\n' '////')" "${errtxt% \[E:*}" "$1 error"
	assert_false "$1: no runtime config" test -e "$tmpdir/out.json"
}
src_json() { printf '%s\n' "$1" >"$tmpdir/src.json"; }
# shellcheck disable=SC2001 # Strip tails on every profile line, not just the last.
prof_has() { grep -qxF -- "$1" <<<"$(sed 's/ \[E:[a-z0-9_]*[^]]*\]$//' <<<"$prof")" || fail "profile lacks '$1': $prof"; }
# shellcheck disable=SC2001 # Strip tails on every profile line, not just the last.
prof_lacks() { ! grep -qxF -- "$1" <<<"$(sed 's/ \[E:[a-z0-9_]*[^]]*\]$//' <<<"$prof")" || fail "profile has '$1': $prof"; }
