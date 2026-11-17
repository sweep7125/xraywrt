profile-schema 1
profile Node
mode direct-first
mode-source user
sniff 0
set core_log_level debug
server-host node.example.com
uses-wan-dns
rules-target proxy
direct-domains 0
provider-fake-domains 0
fake-domains 5
fake-enabled 1
geodata-ref geoip.dat
geodata-ref geosite.dat
