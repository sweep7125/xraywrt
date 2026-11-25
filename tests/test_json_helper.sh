#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
helper="$ROOT_DIR/rootfs/usr/bin/xraywrt-json"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
[[ -x "$helper" ]] || fail 'xraywrt-json executable helper is missing'
parity() {
 local label="$1" expected="$2"; shift 2
 local actual
 actual="$("$helper" "$@")" || fail "$label: helper failed"
 assert_eq "$expected" "$actual" "$label"
 pass "JSON helper: $label"
}
text=$'quotes " slash / backslash \\ русский 😀\n\t\r\001\037'
parity 'object escaping and key order' "$(jq -nc --arg name "$text" '{name:$name}')" build object --arg name "$text"
printf '%s\n\n' "$text" >"$tmpdir/raw"
parity 'rawfile keeps trailing newlines' "$(jq -nc --rawfile content "$tmpdir/raw" '{content:$content}')" build object --rawfile content "$tmpdir/raw"
# shellcheck disable=SC2094 # The path is metadata, never an output file.
parity 'pretty config JSON' "$(jq -Rs --arg p "$tmpdir/raw" '{path:$p,content:.}' <"$tmpdir/raw")" build config --arg p "$tmpdir/raw" <"$tmpdir/raw"
for number in '' 01 1.0 1e2 +2 .5 1. Infinity NaN -Infinity 1e999 9007199254740993 1.2345678901234567 '12x' '0x10' ' true '; do
 parity "tonumber parity [$number]" "$(jq -nc --arg interval "$number" '{profile_title:"",announce:"",support_url:"",web_page_url:"",header_interval:($interval|tonumber? // null),upload:null,download:null,total:null,expire:null}')" build metadata --arg interval "$number"
done
for input in '{"a":1.0,"b":1e20,"c":1e-7,"d":9007199254740993,"e":1.2345678901234567}' '{"z":0,"a":"/тест","n":false}' '{}'; do
 parity 'merge number formatting and order' "$(jq -c '. + {now:2}' <<<"$input")" merge object --argjson now 2 <<<"$input"
done
parity 'field default false' '' get header_interval empty <<< '{"header_interval":false}'
parity 'field extraction' 'running:service' get state:op <<< '{"state":"running","op":"service"}'
parity 'object filter rejects arrays' '' object <<< '[]'
assert_false 'invalid JSON fails' "$helper" get state <<< 'not-json'
for value in SGVsbG8= 0KLQtdGB0YI= AA== /w== 77+9 Zm9vCg==; do
 parity "base64 parity $value" "$(printf '%s' "$value" | jq -Rr '@base64d | select(length > 0 and (explode | all(. != 0 and . != 65533)))')" base64 <<<"$value"
done
printf '%s\n' '{"id":"10-20","started":10,"state":"ok"}' >"$tmpdir/a.json"
printf '%s\n' '{"id":"10-3","started":10,"state":"running"}' >"$tmpdir/b.json"
parity 'history numeric tie breaker' "$(jq -s 'sort_by(.started, (.id|split("-")|map(tonumber)))' "$tmpdir/"*.json)" history sort "$tmpdir/"*.json
parity 'history sort-last' '10-20' history sort-last "$tmpdir/"*.json
parity 'history sort-prune retains running and five completed' '' history sort-prune "$tmpdir/"*.json
mkdir "$tmpdir/history"
for n in 20 3 11 2 10 4 5; do
 printf '{"id":"10-%s","started":10,"state":"ok"}\n' "$n" >"$tmpdir/history/$n.json"
done
printf '%s\n' '{"id":"10-1","started":10,"state":"running"}' >"$tmpdir/history/active.json"
parity 'history sort-prune orders numeric IDs and retains active' $'10-2\n10-3' history sort-prune "$tmpdir/history/"*.json
parity 'history sort-last orders numeric IDs' '10-20' history sort-last "$tmpdir/history/"*.json
parity 'history last' '10-20' history last <<< '[{"id":"10-3"},{"id":"10-20"}]'
parity 'history prune keeps five terminal jobs' '1-1' history prune <<< '[{"id":"0-1","state":"running"},{"id":"1-1"},{"id":"2-1"},{"id":"3-1"},{"id":"4-1"},{"id":"5-1"},{"id":"6-1"}]'
for input in '' '1 2' '{"n":1.0}' 'null' 'broken'; do
 printf '%s' "$input" >"$tmpdir/out"
 expected="$(jq -sc 'if length==1 then .[0] else null end' "$tmpdir/out" 2>/dev/null)" || expected=null
 actual="$("$helper" result "$tmpdir/out" 2>/dev/null)" || actual=null
 assert_eq "$expected" "$actual" 'single job result slurp'
done
pass 'JSON helper: job result slurp'
release='{"tag_name":"v1","assets":[{"name":"a","browser_download_url":"https://x/$(touch /tmp/injected)","size":1.0},{"name":"other"}]}'
parity 'release assets text is never evaluated' "$(jq -r '.assets[]?|"\(.name)\t\(.digest // "")\t\(.size // "")"' <<<"$release")" assets <<<"$release"
# Exercise the documented 8 MiB cap without argv-size limits.
awk 'BEGIN { for(i=0;i<131072;i++) print "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/" }' >"$tmpdir/large"
"$helper" build object --rawfile content "$tmpdir/large" >"$tmpdir/actual"
jq -nc --rawfile content "$tmpdir/large" '{content:$content}' >"$tmpdir/expected"
assert_true 'large rawfile byte parity' cmp -s "$tmpdir/expected" "$tmpdir/actual"
pass 'JSON helper: 8 MiB rawfile byte parity'
parity 'status keeps a multiline settings error as one entry' "$(jq -nc '{apply_warning:null,observatory_signal:false,has_balancers:false,netbird:false,degraded_reason:null,overrides:0,running:false,enabled:false,state:"failed",last_error:"",version:"",core:"",core_installed:false,subscription_configured:false,subscription_insecure:false,config_valid:null,config_backup:false,config_error:"",dns_mode:"",dns_ok:null,policy_active:false,flags:{dns_hijack:null,disable_quic:null,bypass_ntp:null,bypass_subscription_dns:null,block_client_ipv6:false,enabled:false},mode:"",block_client_ipv6:false,interfaces:[],custom_dns_servers:[],lists:{dst:0,src:0,direct:0,direct_src:0},route:{table:"",priority:""},errors:["first\nsecond"],profile:{name:null,selected:null,pinned:false},core_source:{source:null,channel:null,tag:null,version:null},warnings:[],fake_enabled:false,fake_domains:null,direct_domains:null,sniff:"0",geodata:[]}')" build status --argjson running false --argjson enabled false --arg state failed --arg last_error '' --arg version '' --arg core '' --arg url '' --argjson config_valid null --argjson config_backup false --arg config_error '' --arg dns_mode '' --argjson dns_ok null --argjson policy false --arg mode '' --arg block_client_ipv6 0 --arg interfaces '' --arg custom '' --arg dst 0 --arg src 0 --arg direct 0 --arg direct_src 0 --arg table '' --arg priority '' --arg errors $'first\nsecond'
parity 'empty history stream is silent' '' history last </dev/null
parity 'empty pruning stream is silent' '' history prune </dev/null
for bytes in '\xff\xc0\xaf' '\xe2\x82' '\xe2\x82A' '\xed\xa0\x80' '\xf4\x90\x80\x80' '\xe0\x80\x80' '\xf5\x80\x80\x80'; do
 printf '%b' "$bytes" >"$tmpdir/invalid"
 parity "rawfile invalid UTF-8 [$bytes]" "$(jq -nc --rawfile content "$tmpdir/invalid" '{content:$content}')" build object --rawfile content "$tmpdir/invalid"
done
for input in '{"n":1,"a":[0,42,-42],"s":"1.5"}' '{"n":1.5,"a":[1,2.00]}' '{"n":1e2}' '{"n":9007199254740993}' '{"n":-9007199254740993}' '{"n":-0}' '{"n":9007199254740992}' '{"n":-9007199254740992}'; do
 parity "native/decimal parser parity [$input]" "$(jq -c '.+{now:2}' <<<"$input")" merge object --argjson now 2 <<<"$input"
done
for input in '{"n":Infinity}' '{"n":-Infinity}' '{"n":NaN}' '{"d":1.0,"n":Infinity}'; do
 parity "non-finite JSON number parity [$input]" "$(jq -c '.+{now:2}' <<<"$input")" merge object --argjson now 2 <<<"$input"
done
# jq clamps/underflows here; parity intentionally not kept for out-of-double-range exponents.
for number in 1e1000000000 1e-99999999999999; do
 "$helper" build metadata --arg interval "$number" >"$tmpdir/extreme.json"
 assert_true "out-of-double-range exponent $number stays valid JSON" jq -e 'type == "object" and (.header_interval | type) == "number"' "$tmpdir/extreme.json" >/dev/null
 pass "JSON helper: out-of-double-range exponent $number stays valid JSON"
done
# The precision-preserving token walk rejects json-c extensions without hanging.
for input in '/* comment */{"a":1.5}' $'{"a":1.5// comment\n}' '{"a":1.5/* comment */}' "{'a':1.5}" '{"a":1.5,}' '[1.5,]' '{"a":1.5' "{\"a\":1.5,'x':1}" '{"a":1.5/*"*/}' '{"a":1'; do
 rc=0
 timeout 5 "$helper" object <<<"$input" >"$tmpdir/malformed.out" 2>"$tmpdir/malformed.err" || rc=$?
 assert_eq 1 "$rc" "malformed JSON rejects without hanging [$input]"
 assert_false 'malformed JSON emits no stdout' test -s "$tmpdir/malformed.out"
 assert_false 'jq rejects the same malformed input' jq -e . <<<"$input" >/dev/null 2>&1
 pass "JSON helper: malformed input rejects within timeout [$input]"
done
for input in '{"a":1.5,"x":"quote\" : []"}' '{"a":[1.50,{"b":true},null],"x":{"empty":[],"obj":{}}}' $'{\n "a" : 1.5, "x" : [false, "1.5"]\n}'; do
 parity 'tokenized nested/escaped JSON parity' "$(jq -c . <<<"$input")" object <<<"$input"
done
rc=0
"$helper" object <<< 'not-json' >"$tmpdir/error.out" 2>"$tmpdir/error.err" || rc=$?
assert_eq 1 "$rc" 'JSON parse error exit status'
assert_eq 1 "$(wc -l <"$tmpdir/error.err" | tr -d ' ')" 'JSON parse error has one line for job stderr'
assert_file_not_contains "$tmpdir/error.err" 'stacktrace' 'JSON parse error hides stack frames'
# Native errors currently stringify only their message. Force a structured error
# at the real handler entry to pin the message-only branch without a production hook.
sed "s/} catch (e) {/} catch (e) { e = {message: 'safe JSON error', stacktrace: ['private stack frame']};/" "$helper" >"$tmpdir/structured-error.uc"
rc=0
ucode "$tmpdir/structured-error.uc" object <<< 'not-json' >"$tmpdir/error.out" 2>"$tmpdir/error.err" || rc=$?
assert_eq 1 "$rc" 'structured JSON error exit status'
assert_eq 'xraywrt-json: safe JSON error' "$(cat "$tmpdir/error.err")" 'structured JSON error exposes message only'
pass 'JSON helper: error handler prints message only, without stack trace'
# Read-only snapshots deliberately keep malformed numeric state as null, not jq errors.
status_args=(--argjson running false --argjson enabled false --arg state stopped --arg last_error '' --arg version '' --arg core '' --arg url '' --argjson config_valid null --argjson config_backup false --arg config_error '' --arg dns_mode '' --argjson dns_ok null --argjson policy false --arg mode '' --arg block_client_ipv6 0 --arg interfaces '' --arg custom '' --arg dst '' --arg src not-a-number --arg direct 0 --arg direct_src 0 --arg table '' --arg priority '' --arg errors '')
"$helper" build status "${status_args[@]}" >"$tmpdir/lenient-status.json"
assert_true 'status numeric snapshot leniency' jq -e '.lists == {dst:null,src:null,direct:0,direct_src:0}' "$tmpdir/lenient-status.json" >/dev/null
pass 'JSON helper: empty and malformed status counts are null'
parity 'empty profile has no targets' '{"mode":"proxy-first","mode_source":null,"fake_enabled":false,"direct_domains":null,"sniff":"0","dns":"redir-host","provider":{},"overrides":0,"targets":[],"sniff_skipped_targets":[],"reserved":[],"provider_lists":false,"provider_sources":{"vpn":{"addresses":[],"links":0,"truncated":false},"direct":{"addresses":[],"links":0,"truncated":false}}}' build profile --arg mode proxy-first --arg dns redir-host --arg provider '' --arg overrides '' --arg targets '' --arg reserved ''
parity 'diagnostics omit unused ports' '{"conflicts":[],"flash_free_kb":null,"tmp_xraywrt_kb":null,"ram_available_kb":null,"xray_rss_kb":null,"router_model":null,"dns_guard_error":null,"config_test":{"valid":null,"output":[]}}' build diagnostics --arg ports ''
printf '%s\n' '{"id":"10-3","started":10,"state":"ok"}' >"$tmpdir/history-valid.json"
printf '%s\n' '{"id":"10-x","started":10,"state":"ok"}' >"$tmpdir/history-invalid.json"
parity 'non-numeric history id segment sorts as null' $'[\n  {\n    "id": "10-x",\n    "started": 10,\n    "state": "ok"\n  },\n  {\n    "id": "10-3",\n    "started": 10,\n    "state": "ok"\n  }\n]' history sort "$tmpdir/history-valid.json" "$tmpdir/history-invalid.json"
# Pin multibyte characters across a 64 KiB boundary before streaming raw files.
for character in '¢' '€' '😀'; do
 printf '%65535s%s\n"\\/\001' '' "$character" >"$tmpdir/boundary"
 "$helper" build object --rawfile first "$tmpdir/boundary" --rawfile second "$tmpdir/boundary" >"$tmpdir/streamed.json"
 "$helper" build object --arg whole '' --rawfile first "$tmpdir/boundary" --rawfile second "$tmpdir/boundary" | jq -c 'del(.whole)' >"$tmpdir/whole.json"
 assert_true "streamed/whole UTF-8 boundary parity [$character]" cmp -s "$tmpdir/whole.json" "$tmpdir/streamed.json"
 pass "JSON helper: streamed/whole UTF-8 boundary parity [$character]"
done
for bytes in '\xe2\x82' '\xe0\x80\x80' '\xf0\x9f\x98\x80' '\xff\x00\xc0\xaf'; do
 { printf '%65535s' ''; printf '%b' "$bytes"; printf '\n'; } >"$tmpdir/boundary"
 "$helper" build object --rawfile content "$tmpdir/boundary" >"$tmpdir/streamed.json"
 jq -nc --rawfile content "$tmpdir/boundary" '{content:$content}' >"$tmpdir/whole.json"
 assert_true "streamed/jq malformed UTF-8 boundary parity [$bytes]" cmp -s "$tmpdir/whole.json" "$tmpdir/streamed.json"
 pass "JSON helper: streamed/jq malformed UTF-8 boundary parity [$bytes]"
done
rc=0
"$helper" build object --rawfile content "$tmpdir" >/dev/null 2>"$tmpdir/read-error.err" || rc=$?
assert_eq 1 "$rc" 'streaming read failure is not successful truncated JSON'
pass 'JSON helper: streaming rawfile read error fails'

# Intentional json-c leniency on the native small-integer path: always re-encode strictly.
lax_inputs=('/* comment */{"a":1}' $'{"a":1// comment\n}' '{"a":1/* comment */}' "{'a':1}" '{"a":1,}' '[1,]' "{\"a\":1,'x':1}" '{"a":1/*"*/}')
lax_outputs=('{"a":1}' '{"a":1}' '{"a":1}' '{"a":1}' '{"a":1}' '[1]' '{"a":1,"x":1}' '{"a":1}')
for i in "${!lax_inputs[@]}"; do
 rc=0
 timeout 5 "$helper" result <<<"${lax_inputs[$i]}" >"$tmpdir/lax.out" 2>"$tmpdir/lax.err" || rc=$?
 assert_eq 0 "$rc" "native JSON leniency does not hang [${lax_inputs[$i]}]"
 assert_eq "${lax_outputs[$i]}" "$(cat "$tmpdir/lax.out")" 'native JSON leniency emits strict JSON'
 assert_true 'native JSON leniency output is valid JSON' jq -e . "$tmpdir/lax.out" >/dev/null
 pass "JSON helper: native leniency emits strict JSON [${lax_inputs[$i]}]"
done

parity 'profile targets of My rules and reserved tags' '{"mode":"direct-first","mode_source":null,"fake_enabled":false,"direct_domains":null,"sniff":"0","dns":"","provider":{},"overrides":0,"targets":["proxy","pool"],"sniff_skipped_targets":[],"reserved":["direct"],"provider_lists":false,"provider_sources":{"vpn":{"addresses":[],"links":0,"truncated":false},"direct":{"addresses":[],"links":0,"truncated":false}}}' build profile --arg mode direct-first --arg dns '' --arg provider '' --arg overrides '' --arg targets $'proxy\npool' --arg reserved direct
