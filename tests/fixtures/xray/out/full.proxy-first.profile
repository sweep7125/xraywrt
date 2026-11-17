profile-schema 1
profile Full
set mode direct-first
mode proxy-first
mode-source user
sniff 0
observe-balancer auto
set core_log_level debug
warn fakedns section replaced [E:fakedns_replaced]
server-host node.example.com
rules-target proxy
rules-target auto
direct-domains 0
provider-fake-domains 0
fake-domains 5
fake-enabled 1
geodata geosite.dat https://geo.example.com/geosite.dat
geodata-ref geoip.dat
geodata-ref geosite.dat
