# OpenWrt 25.12.6 x86_64 VM Test Harness

Isolated OpenWrt 25.12.6 x86/64 test harness running under native arm64 QEMU TCG in Docker on Apple Silicon (Colima). Provides real OpenWrt Linux kernel 6.12, procd init system, nftables fw4, apk package manager, and dropbear SSH.

## Architecture

- **QEMU TCG**: Containerized `qemu-system-x86_64` running native arm64 binary directly on Apple Silicon to eliminate nested emulation overhead.
- **Kernel & Disk**:
  - Kernel: Official `openwrt-25.12.6-x86-64-generic-kernel.bin` (SHA256: `8f70595f3a6eec3112e007450a1a600153904deffa52ab368712342583cb387c`)
  - Rootfs: Official `openwrt-25.12.6-x86-64-generic-ext4-rootfs.img.gz` (SHA256: `8c243392d09b960a9f0edbfd996153bec213435b0034e6b2db9437115c5178ec`)
  - Disposable ext4 disk resized to 1GiB (`truncate`/`resize2fs`).
  - Preseeded ed25519 root public key in `/etc/dropbear/authorized_keys` via `debugfs` (no host loop mounts or root privileges required).
- **Network**:
  - `eth0` (LAN): Bridge `br-lan` at `192.168.1.1/24`, QEMU host at `192.168.1.2`, port forwarding to guest `192.168.1.1:22`.
  - `eth1` (WAN): DHCP `10.0.2.0/24`, default gateway `10.0.2.2`, DNS `10.0.2.3` with live outbound internet access.
  - SSH mapping: `127.0.0.1:2222` (or `ROUTER_PORT=2223` when port 2222 is held by Colima's SSH mux).
- **Persistence**: All downloads, disposable disks, SSH keys, and logs live in git-ignored `.build/router/`.

## Commands

```bash
# Start VM harness (downloads images, pre-seeds key, boots VM, waits for SSH ready)
./tests/router/start.sh

# Check VM status and connectivity
./tests/router/status.sh

# Interactive SSH shell or command runner
./tests/router/ssh.sh
./tests/router/ssh.sh "uname -a; ubus call system board; apk --version"

# Run smoke tests
./tests/router/run-smoke.sh                 # Baseline proof (kernel, ubus, apk, nftables, procd)
./tests/router/run-smoke.sh --integration   # Install the app, translation and XrayWRT core 0.26.2 x86_64 VM package, test service lifecycle, nft, DNS, watchdog
XRAY_TEST_CORE=installed ./tests/router/run-smoke.sh --integration   # Keep the guest's installed core (e.g. xraywrt-core) instead of Go Xray

# Synthetic client-IPv6 / coexistence acceptance (guest-only, no real peers)
./tests/router/run-network.sh

# Direct serial console diagnostics
./tests/router/serial-cmd.sh "ip -o addr; ps"

# Stop and remove test container
./tests/router/stop.sh

# Automated TAP test harness
XRAYWRT_ROUTER_TESTS=1 ./tests/test_router_harness.sh
```

## Network acceptance (`run-network.sh`)

`./tests/router/run-network.sh` is the repeatable synthetic network acceptance for the direct-first client IPv6 bypass ban and its coexistence with local IPv6, IPv4, the Xray core, NetBird marks, routes and DNS. It exits 0 only when all required rows (`ROWS` in `run-network.sh`: `nft syntax`, `control reachable`, `client IPv6 rejected`, `local and IPv4 retained`, `core and other ingress retained`, `NetBird synthetic`, `routes and DNS boundaries`, `local names`, `fake-IP direct devices`, `lifecycle`, `port forward and WAN service replies`, `IPv6 disabled`, `policy rule precedence`, `loopback TPROXY`, `geodata download`, `geosite fake-IP`, `stale fake-IP`, `native DNS paths`, `DNS query types`, `server bootstrap`, `balancer overrides`, `hot subscription TCP`, `routing strategy restart`, `zapret marks`, `guest zone`, `sticky stop`, `DNS path fail-open`) PASS and guest restoration PASS; a missing prerequisite or transport is exit 1, never PASS.

- **Prerequisites**: the VM from `./tests/router/start.sh` with the development APKs and XrayWRT core installed (`./tests/router/run-smoke.sh --integration --watchdog`), and guest tools `ip` (netns, veth), `nft`, `tcpdump`, `curl`, `dnsmasq`, `uhttpd`, `odhcp6c`, `odhcpd`, `jq`, `hexdump`, `nc` (BusyBox), `socat` (UDP probes), `netstat`, `kmod-veth`. The host entry installs only the missing test tools `ip-full` (BusyBox `ip` has no netns), `tcpdump`, `socat` and `kmod-veth` with `apk add` before the run; the guest script itself installs nothing and fails on any missing tool.
- **Isolation**: the host entry pins `ROUTER_HOST=127.0.0.1`, `ROUTER_SSH_FORCE_DOCKER=1` and the `xraywrt-openwrt-test` container; it refuses anything that is not the QEMU guest (MAC `52:54:00:12:34:01`). Clients, local peer, WAN and NetBird endpoints are veth/namespaces (`m22-*`, `m22*`, `wt0`) inside the VM, with a second Xray process (`xray run -c node.json`, SOCKS5 inbound on port 1080, no auth) as the synthetic node. Path evidence never reads the router core's log, so the same rows run for any core: the WAN fixture CGIs return the peer address the server saw (client = bypass, router = the core's direct socket, node = the proxy outbound), the node's access log since the row start, nft counters and packet captures.
- **Guest mutation and cleanup**: `/tmp/xraywrt-network-test` (owner file, refused if it exists) holds the fixtures; UCI (`xraywrt`, `dhcp`, `firewall`, `network`, including the WAN DNS that geodata rows point at the synthetic resolver), `config.json` and `config.json.bak`, `/opt/xraywrt/share`, policy lists and service state are snapshotted and restored through the config API; only tracked PIDs, namespaces and links are removed. The cleanup trap ignores SIGINT/SIGTERM/SIGHUP, and the guest runs detached from SSH, so a host disconnect still restores. Offloaded flows are not flushed (no global conntrack flush).
- **Report**: `.build/verification-0110/network/REPORT.md`, with per-run logs, expected/actual/exit status, kernel, rule/route snapshots and pcaps under `.build/verification-0110/network/run.*`.
- **Not tested** (reported as NOT TESTED, never PASS): real NetBird peers/STUN/DERP, hardware/previously offloaded flows, Telegram IPv4 fallback.
- `NETWORK_ROWS="row,row"` selects rows for development; a filtered run cannot exit 0.
- `NETWORK_NODE_XRAY=<host path>` runs the synthetic node with that x86_64 Xray binary instead of the router core (needed when the core is a client-only build such as xraywrt-core, which refuses non-loopback inbounds).

The stable-review rows add:

| Row | Proof |
|---|---|
| `port forward and WAN service replies` | fw4 DNAT to a LAN host and a router WAN listener, TCP/UDP in both policy modes; marked-reply counters stay zero and conntrack tuples show real replies. Removing each reply guard breaks a fresh TCP control. Probe ports must be free; tracked, non-forking listeners receive TERM then KILL if needed. |
| `IPv6 disabled` | Guest-only `all.disable_ipv6=1`: service starts, IPv4 reaches TPROXY, IPv6 rules/routes are unchanged and no IPv6 path can set the intercept mark or reach TPROXY. Inert inet ip6 sets/guards may remain. The original sysctls, addresses and routes are restored even after failure; restarting proves IPv6 interception returns. |
| `policy rule precedence` | Synthetic NetBird priorities 105/110 and mwan3 mask `0x3f00/0x3f00` at 2001 exist before start. The allocated priority is 50–99, dual-stack marked flows reach TPROXY with mwan3 bits intact, foreign rules survive, and stored priority-1000 rules/routes disappear. Existing NetBird and route/DNS rows continue covering producer order, reconnect, marks and occupied slots. |
| `loopback TPROXY` | Spec 6.3 / plan 0.4: the core listens on `127.0.0.1`/`::1` port 7894 only (no wildcard), nft TPROXY targets those addresses, and TCP and UDP over IPv4 and IPv6 from a client reach the core (counter) and leave through the SOCKS node (the WAN server sees the node; the node's access log shows the router's TCP and UDP flows). |
| `geodata download` | Spec 10, 7.1: with `geosite.dat` absent, installing a config whose `geodata.assets` names `https://geo22.example.net:8443/geosite.dat` fetches it before use (byte-identical, node access log shows the router's TLS request), and dnsmasq resolves the asset host through WAN DNS. The test certificate (made by `xray tls cert`) joins the system CA bundle through a bind mount that the cleanup removes; the CLI ignores `CURL_CA_BUNDLE`. |
| `geosite fake-IP` | Spec 7.2, 8, direct-first: a domain from the locally built `geosite:m22` gets a fake-IP and leaves through the SOCKS node; a domain outside the list gets its real IP and never reaches the core (zero counter, the WAN server sees the client); a listed direct device keeps the fake-IP but leaves through `xraywrt-direct` (the WAN server sees the router), while an unlisted device still uses the proxy rule (it sees the node). |
| `stale fake-IP` | Spec 7.2, 6.5.3: after a core restart (new pid) the old fake-IP has no record and is refused through `xraywrt-block`: curl exits 52 (accepted and closed empty) and a capture on every link shows no TCP SYN but the client's; a fresh DNS answer works again. |
| `native DNS paths` | With hijack off, provider DNS handles external TCP and UDP in both modes; direct-first selects the resolver explicitly. Distinct original and WAN resolvers, per-name captures and WAN logs verify A/AAAA replies without a loop. LAN-to-router TCP/UDP checks local, FakeDNS and WAN answers. |
| `DNS query types` | Spec 7.5: an HTTPS RR that the WAN resolver has (control) comes back empty NOERROR through dnsmasq and the core; by default a TXT query gets an empty answer and never reaches the WAN resolver; with `dns_forward_other_types=1` and `dns_raw_upstream` it reaches the WAN resolver from the router and returns its record, while a whitelist domain's TXT stays empty. |
| `server bootstrap` | Spec 7.4: the SOCKS node given by name (`node22.example.net`, a hosts file of the WAN resolver, WAN DNS pointed at it) gets a dnsmasq bypass, and the router adds no DNS server of its own for it (with `ForceIPv4` the provider config carries the `127.0.0.1:53` server for the host, as the user guide shows); a loopback capture shows no `node22.example.net` query to the core's DNS inbound (port 7874, a loop). The core's own DNS module dials with the router mark (through `xraywrt-direct`), a system resolver does not; an nft counter of marked loopback DNS proves that with `AsIs` the core does no lookup of its own, with `sockopt.domainStrategy: ForceIPv4` exactly one (one A query, no AAAA) answered `198.20.22.2` by that server. The WAN resolver sees the router's query and the request reaches the node. |
| `balancer overrides` | Two balancers listed; live pin reaches the selected proxy without restart (the WAN server sees the node, not the router), survives a restart, and an empty target restores auto. |
| `hot subscription TCP` | Spec 17 / C3: a single non-retrying curl receives `hot-tcp.before` through unchanged `proxy` (the WAN server sees the node); a subscription changes only unused `hot-idle` from freedom to blackhole; action is `hot_reloaded`, core PID unchanged, and the same stream receives `hot-tcp.after` with one node connection. CGI holds up to 120 seconds; curl is bounded at 150 seconds and locally trapped for cleanup. Evidence: `hot-tcp.*`, `hot-subscription.result.json`. |
| `routing strategy restart` | A subscription changes only `routing.domainStrategy` from AsIs to IPIfNonMatch; action is `restarted`, PID changes, the runtime has the new strategy, readiness and fresh proxy traffic succeed. Evidence: `strategy.*`. |
| `zapret marks` | Router output to a listed WAN host is intercepted without a mark (control) and stays direct with zapret desync marks `0x40000000` or `0x20000000` set before the policy. |
| `guest zone` | The client zone with fw4 input REJECT: the XrayWRT include accepts TPROXY and hijacked DNS, a router service stays rejected; deleting the include's DNS rule breaks hijacked DNS until fw4 reloads. |
| `sticky stop` | Spec 9.1: after Stop, a hotplug `ifup`, a UCI reload trigger and `reload` leave the service stopped; without the Stop marker the same `ifup` starts it. |
| `DNS path fail-open` | Spec 9.2: with every non-loopback DNS packet from the router dropped, the live core goes degraded, the policy and dnsmasq redirect are removed and clients go direct; once DNS answers, the same core pid recovers the policy. |

## Known Limitations

- **No Hardware Offload**: Software QEMU TCG cannot validate hardware flow offloading (NSS, PPE, WED).
- **No Real P2P Traversal**: User-mode NAT (SLIRP) cannot test real STUN/DERP peer-to-peer punching across external carrier NATs.
- **CPU Throughput**: Emulated TCG CPU is meant for configuration, packaging, and policy validation, not raw multi-gigabit throughput benchmarking.
- **Safety**: Test policies avoid contacting real NetBird accounts or modifying host network interfaces.
