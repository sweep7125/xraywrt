PKG_VERSION="dev"
SUPERVISOR_CMD="/usr/bin/xraywrt run-service"
# Anchored: a shell that merely mentions the command must not look like the supervisor.
SUPERVISOR_PATTERN="^(/bin/a?sh )?$SUPERVISOR_CMD\$"
PKG_CONFIG="xraywrt"
CONFLICT_PACKAGES="luci-app-mihowrt xray-core luci-app-xray podkop luci-app-podkop luci-app-passwall luci-app-passwall2 luci-app-openclash luci-app-homeproxy luci-app-nikki nikki luci-app-ssclash luci-app-v2raya luci-app-mihomo https-dns-proxy adguardhome"
PKG_TMP_DIR="/tmp/xraywrt"
PKG_STATE_DIR="/var/run/xraywrt"
SKIP_START_FILE="/tmp/xraywrt.skip-start"
JOBS_DIR="$PKG_STATE_DIR/jobs"
JOB_LOG_MAX="65536"
PKG_PERSIST_DIR="/etc/xraywrt"
POLICY_CACHE_DIR="$PKG_PERSIST_DIR/policy-cache"
LISTS_CACHE_MAX_TOTAL=8388608
RUNNING_MARKER="$PKG_STATE_DIR/running"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
SERVICE_PID_FILE="$PKG_STATE_DIR/xray.pid"
SUPERVISOR_PID_FILE="$PKG_STATE_DIR/supervisor.pid"
RESTART_RESULT_FILE="$PKG_STATE_DIR/restart.result"
ROUTE_STATE_FILE="$PKG_STATE_DIR/route.state"
USER_STOP_FILE="$PKG_STATE_DIR/stopped"
HEALTH_FILE="$PKG_STATE_DIR/health"
DEGRADED_FILE="$PKG_STATE_DIR/degraded"
OBSERVATORY_FILE="$PKG_STATE_DIR/observatory"
LAST_ERROR_FILE="$PKG_STATE_DIR/last_error"
APPLY_WARNING_FILE="$PKG_STATE_DIR/apply_warning"
CONFIG_INVALID_FILE="$PKG_STATE_DIR/config.invalid"
CORE_VERSION_CACHE="$PKG_STATE_DIR/core.version"
CONFIG_TESTED_FILE="$PKG_STATE_DIR/config.tested"
CONFIG_OK_FILE="$PKG_STATE_DIR/config.ok"
CONFIG_ERR_FILE="$PKG_STATE_DIR/config.err"
NFT_APPLIED_FILE="$PKG_TMP_DIR/nft.applied"
NET_FP_FILE="$PKG_STATE_DIR/net.fp"

# Spec 4.5: "core" = the xraywrt-core package from the XrayWRT releases.
CORE_PACKAGE="xraywrt-core"
XRAYWRT_RELEASE_REPO="sweep7125/xraywrt"
# Spec 4.1: file bodies only (hash and tag never), as https://<proxy>/<github URL>.
GITHUB_PROXIES="gh-proxy.com ghproxy.net"
# Core and geodata download routes resolve via WAN DNS (spec 7.1).
CORE_RELEASE_HOSTS="api.github.com github.com objects.githubusercontent.com release-assets.githubusercontent.com raw.githubusercontent.com cdn.jsdelivr.net $GITHUB_PROXIES"
CORE_JSON_FILE="$PKG_PERSIST_DIR/core.json"
CORE_TMP_DIR="$PKG_TMP_DIR/core-update"
# Low-flash restart: readiness (spec 9.1, 30 s) plus prepare.
CORE_READY_WAIT=45
CORE_RELEASE_JSON_MAX_BYTES="2097152"
CORE_ASSET_MAX_BYTES="67108864"

XRAY_DIR="/opt/xraywrt"
XRAY_BIN="$XRAY_DIR/bin/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_CONFIG_BACKUP="$XRAY_DIR/config.json.bak"
XRAY_SHARE_DIR="$XRAY_DIR/share"
# Saved but inactive subscriptions: <id>/{config.json,subscription.json,share/}; same filesystem as share/.
XRAY_SUBS_DIR="$XRAY_DIR/subs"
# Geodata is kept for the active subscription and the most recently used inactive ones, this many in all.
SUBSCRIPTION_GEODATA_KEEP="3"
GEODATA_MANUAL_FILE="$XRAY_SHARE_DIR/.manual"
GEODATA_TMP_DIR="$PKG_TMP_DIR/geodata"
GEODATA_MAX_BYTES="67108864"
RUNTIME_CONFIG="$PKG_TMP_DIR/config.json"
PROFILE_FILE="$RUNTIME_CONFIG.profile"
LIST_DIR="$XRAY_DIR/lst"
# My rules: sites and addresses with a target, one list per subscription.
RULES_FILE="$LIST_DIR/rules.txt"
# Same number as FAKE_LIMIT in xray-config.uc.
RULES_SITES_LIMIT="10000"
SRC_LIST_FILE="$LIST_DIR/always_proxy_src.txt"
DIRECT_SRC_LIST_FILE="$LIST_DIR/direct_src.txt"

# Router-owned Xray values, written into the generated runtime config.
XRAY_API_HOST="127.0.0.1"
XRAY_API_PORT="10085"
XRAY_API_TIMEOUT="3"
# rmo/ado/adrules rebuild handlers and matchers (geodata) in the core.
XRAY_API_APPLY_TIMEOUT="30"
# Total budget of a `balancers` listing (one bi per balancer).
XRAY_API_LIST_TIMEOUT="10"
XRAY_DNS_PORT="7874"
XRAY_TPROXY_PORT="7894"
XRAY_DIRECT_TPROXY_PORT="7895"
XRAY_ROUTING_MARK="2"
FAKEIP_RANGE="198.18.0.0/15"
# Never sent to the core (nft localv4/localv6); freedom blocks them (spec 6.4).
LOCAL_NETS_V4="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3"
LOCAL_NETS_V6="::/127 fe80::/10 fc00::/7 ff00::/8"

WATCHDOG_INTERVAL="15"
WATCHDOG_FAILS="3"
# A healthy provider observatory is read every this many ticks; a failing one every tick.
WATCHDOG_OBSERVE_TICKS="4"
WATCHDOG_PROBE_DOMAIN="openwrt.org"

DNS_CONF_NAME="xraywrt.conf"
DNS_AUTO_RESOLVFILE="/tmp/resolv.conf.d/resolv.conf.auto"
CRON_FILE="/etc/crontabs/root"
OPENWRT_RELEASE_FILE="/etc/openwrt_release"
MEMINFO_FILE="/proc/meminfo"
CRON_MARKER="# xraywrt auto-update"

FW4_INPUT_INCLUDE="/usr/share/nftables.d/chain-pre/input/30-xraywrt.nft"
NFT_TABLE_NAME="xraywrt"
NFT_INTERCEPT_MARK="0x08000000"
NFT_DIRECT_MARK="0x04000000"
ZAPRET_DESYNC_MARK="0x40000000"
ZAPRET_DESYNC_MARK_POSTNAT="0x20000000"
NETBIRD_DEFAULT_MARK="113920"
NETBIRD_DEFAULT_IFACE="wt0"

ROUTE_TABLE_ID_AUTO_MIN="200"
ROUTE_TABLE_ID_AUTO_MAX="252"
ROUTE_RULE_PRIORITY_AUTO_MIN="50"
ROUTE_RULE_PRIORITY_AUTO_MAX="99"
