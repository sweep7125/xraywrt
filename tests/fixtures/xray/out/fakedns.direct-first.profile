profile-schema 1
profile Fake
set mode direct-first
mode direct-first
mode-source user
sniff 0
warn the provider config has no sniffing: domain rules see only IP addresses [E:provider_no_sniffing]
server-host node.example.com
rules-target proxy
direct-domains 0
provider-fake-domains 2
fake-domains 7
fake-enabled 1
geodata geosite.dat https://geo.example.com/geosite.dat
geodata geoip.dat https://geo.example.com/geoip.dat
geodata-ref geoip.dat
geodata-ref geosite.dat
