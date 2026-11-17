profile-schema 1
profile NL Amsterdam
mode direct-first
mode-source user
sniff 0
warn the provider config has no sniffing: domain rules see only IP addresses [E:provider_no_sniffing]
observe-balancer auto
set core_log_level warning
server-host nl1.example.com
server-host nl2.example.com
rules-target proxy-1
rules-target proxy-2
rules-target auto
direct-domains 0
provider-fake-domains 0
fake-domains 5
fake-enabled 1
geodata-ref geoip.dat
geodata-ref geosite.dat
