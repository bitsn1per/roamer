#!/bin/sh
# Roamer test suite. Uses stand-ins for OpenWrt tools (tests/mock/bin) and a fake UCI database.
# It writes to /etc, /bin and /tmp, so it runs inside a throwaway container:
#   tests/run.sh              → starts an Alpine container (docker or podman) and runs there
#   ROAMER_IN_CONTAINER=1 tests/run.sh   → run here (only inside a disposable container/VM!)
set -u
T="$(cd "$(dirname "$0")" && pwd)"
if [ "${ROAMER_IN_CONTAINER:-0}" != 1 ]; then
  eng="$(command -v docker || command -v podman || true)"
  [ -n "$eng" ] || { echo "need docker or podman (or ROAMER_IN_CONTAINER=1 inside a disposable box)"; exit 2; }
  exec "$eng" run --rm -v "$T/..:/src:ro" -w /src alpine:3.20 sh -c \
    'apk add -q python3 util-linux-misc >/dev/null && cp -r /src /work && cd /work && ROAMER_IN_CONTAINER=1 sh tests/run.sh'
fi
. "$T/lib.sh"
GWJSON='{"up":true,"l3_device":"wan","ipv4-address":[{"address":"192.168.2.10","mask":24}],"route":[{"target":"0.0.0.0","nexthop":"192.168.2.1"}]}'
WIFI0="TAILSCALE=no IFACE_2G=default_radio0 IFACE_5G=default_radio1 CH2=auto CH5=auto TXP2=keep TXP5=keep"
WIFI="$WIFI0 MONITORING=no"
GWARGS="RS_MODE=ws ROUTER=192.168.2.1 ROLE=gateway BANDS=both COUNTRY=NL SSID=MyHome KEY=homepass1 ENC=sae-mixed HIDDEN=0 ROAM_DBM=-70 MOCK_BRIP=192.168.2.1/24"
APARGS="RS_MODE=ws ROUTER=192.168.2.2 MOCK_BRIP=192.168.2.2/24 MOCK_GWLAN=192.168.2.1|192.168.2.157|24 MOCK_PING_OK=192.168.2.1 NAME=ap9 AP_ADDR=static AP_IP=192.168.2.2 CONFIRM_TIMEOUT=120"
CRON='0 * * * * service luci_statistics backup'
GWLOG='roamer-data/Gateway_*/logs/*.ok.log'

echo "== help"
fixture
run help "" help RS_MODE=ws
has help "Commands" "help screen lists the commands"

echo "== Gateway, from the computer (home menu → setup)"
fixture lanip=192.168.2.1 hostname=gateway
# welcome · menu=setup · backup · [router] device · mobility domain · plan
# shellcheck disable=SC2086
run gw '\n\n\n\n\ny\n' "" RS_MODE=ws ROUTER=192.168.2.1 ROLE=gateway BANDS=both COUNTRY=NL $WIFI \
  SSID=MyHome KEY=homepass1 ENC=sae-mixed HIDDEN=0 ROAM_DBM=-70 MOCK_BRIP=192.168.2.1/24
has gw "What do you want to do?" "home menu shown"
has gw "Mobility domain" "mobility-domain screen"
has gw "Don't" "mobility-domain do's and don'ts"
has gw "Gateway is set up successfully" "Gateway set up"
has gw "What is set up on 192.168.2.1" "report screen"
exists "$MOCK_STATE/ws/roamer-data/Gateway_gateway/pairing.txt" "pairing code saved in roamer-data/Gateway_<host>/"
exists "$MOCK_STATE/ws/roamer-data/Gateway_gateway/backups/*_192.168.2.1_backup.tar.gz" "backup in backups/"
exists "$MOCK_STATE/ws/roamer-data/Gateway_gateway/logs/*.ok.log" "log in logs/ as .ok.log"
if ls -d "$MOCK_STATE/ws/roamer-data"/Router_* >/dev/null 2>&1; then nok "pre-run folder merged into Gateway_<host>"; else ok "pre-run folder merged into Gateway_<host>"; fi
if grep -q "ROAM1:[A-Za-z0-9]" "$MOCK_STATE/ws/roamer-data"/Gateway_gateway/logs/*.ok.log; then nok "pairing code hidden in the log"; else ok "pairing code hidden in the log"; fi
if [ -e /tmp/roaming-env ]; then nok "presets file removed after use"; else ok "presets file removed after use"; fi
uci_is wireless.default_radio1.ieee80211r 1 "802.11r on"
cp "$MOCK_STATE/ws/roamer-data/Gateway_gateway/pairing.txt" /tmp/pair.keep 2>/dev/null || true
PAIRCODE="$(cat /tmp/pair.keep 2>/dev/null || true)"

echo "== Dumb AP, Gateway cable in WAN (temporary WAN path, cable move)"
fixture lanip=192.168.1.1 hostname=ap1
# welcome · menu · backup · [router] device · wiring · plan
# shellcheck disable=SC2086
run apwan '\n\n\n\n\ny\n' "" RS_MODE=ws ROUTER=192.168.2.10 PAIR="$PAIRCODE" WAN_JSON="$GWJSON" $WIFI \
  MOCK_WANIP=192.168.2.10/24 MOCK_BRIP=192.168.2.2/24 MOCK_PING_OK=192.168.2.10 MOCK_PING_AFTER=192.168.2.1 \
  MOCK_LATE_IP=192.168.2.2 MOCK_LATE_N=3 SSH_CLIENT="192.168.2.3 1 22" MOCK_ROUTE="192.168.2.3 dev wan" \
  NAME=ap1 AP_ADDR=static AP_IP=192.168.2.2 CONFIRM_TIMEOUT=120
has apwan "until you do, this router stays reachable at its current WAN address 192.168.2.10" "wiring check: Gateway on WAN"
has apwan "WAN keeps its lease (192.168.2.10)" "plan: temporary WAN path"
has apwan "Dumb AP is set up successfully" "Dumb AP confirmed and set up"
exists "$MOCK_STATE/ws/roamer-data/DumbAP_ap1/recovery/*_RECOVERY.txt" "recovery card in DumbAP_<host>/recovery/"
file_has "$MOCK_STATE/ws/roamer-data/hosts.txt" "192.168.2.2 ap1 fe80::" "Dumb AP remembered in hosts.txt"
file_has /tmp/roaming-apply.log "the Gateway answers through the LAN ports" "confirmed only via the LAN path"
file_has /tmp/roaming-apply.log "temporary WAN path removed" "temporary WAN path removed after confirmation"
uci_is network.wan '<unset>' "wan interface gone"
uci_is network.mgmt.ipaddr 192.168.1.2 "recovery address set"
uci_is dhcp.lan.ignore 1 "own DHCP off"

echo "== Dumb AP with WAN bridged into the LAN (the v4 leftover)"
WANCARRIER=1 fixture lanip=192.168.2.2 wanbr=1 hostname=obsidian
# shellcheck disable=SC2086
run apbr '\n\n\n\n\ny\n' "" RS_MODE=ws ROUTER=192.168.2.2 PAIR="$PAIRCODE" $WIFI MOCK_BRIP=192.168.2.2/24 \
  MOCK_GWLAN="192.168.2.1|192.168.2.157|24" MOCK_PING_OK=192.168.2.1 SSH_CLIENT="192.168.2.3 1 22" \
  NAME=obsidian AP_ADDR=static AP_IP=192.168.2.2 CONFIRM_TIMEOUT=120
has apbr "WAN port is bridged into its LAN" "wiring check spots the bridged WAN"
has apbr "WAN port: taken OUT of the LAN bridge" "plan removes it"
has apbr "Dumb AP is set up successfully" "set up"
uci_is network.cfg030f15.ports "lan1 lan2 lan3 lan4" "WAN no longer in br-lan"

echo "== lantest: laptop on a LAN port of a Dumb AP with bridged WAN"
WANCARRIER=1 fixture lanip=192.168.2.2 wanbr=1 hostname=obsidian
# check pause · measure pause · backup · apply
run lt '\n\n\n\n\n' lantest RS_MODE=ws AP_IP=192.168.2.2 GW_IP=192.168.2.1 MOCK_DOWN=192.168.2.2 \
  MOCK_FIXED_IP=192.168.2.2 MOCK_PING_OK=192.168.2.1 MOCK_BRIP=192.168.2.2/24
has lt "Found it" "names the cause"
has lt "backup saved" "backup before the change"
has lt "The Dumb AP answers on this cable now" "fixed and confirmed"
uci_is network.cfg030f15.ports "lan1 lan2 lan3 lan4" "WAN taken out of br-lan"
exists "$MOCK_STATE/ws/roamer-data/DumbAP_obsidian/backups/*_backup.tar.gz" "lantest backup in DumbAP_<host>/backups/"
exists "$MOCK_STATE/ws/roamer-data/DumbAP_obsidian/lantest/*.txt" "lantest report in DumbAP_<host>/lantest/"

echo "== the router's own current address is not 'in use'"
fixture lanip=192.168.2.10
# shellcheck disable=SC2086
run own '\n\n\n\n\n192.168.2.10\n' "" RS_MODE=ws ROUTER=192.168.2.10 PAIR="$PAIRCODE" $WIFI DRY_RUN=1 \
  MOCK_BRIP=192.168.2.10/24 MOCK_GWLAN="192.168.2.1|192.168.2.10|24" MOCK_PING_OK="192.168.2.10 192.168.2.50" \
  NAME=ap2 AP_ADDR=static
has own "192.168.2.10 is this router's current address" "own address accepted"
hasnt own "already in use by another device" "no false conflict"

echo "== run on the router itself: home menu → report"
fixture lanip=192.168.1.1
run rmenu '\n2\n' "" RS_MODE=router
has rmenu "Report — what is set up here" "router home menu"
has rmenu "role|Gateway" "report printed"

echo "== basic wpad on the router: swapped for the full one (apk 'provides' must not fool the check)"
WPAD=wpad-basic-mbedtls fixture lanip=192.168.2.1 hostname=gw2
# welcome · menu · backup · [router] device · install bundle y · pause · mobility domain · plan
# shellcheck disable=SC2086
run wpad '\n\n\n\ny\n\n\ny\n' "" RS_MODE=ws ROUTER=192.168.2.1 ROLE=gateway BANDS=both COUNTRY=NL $WIFI \
  SSID=MyHome KEY=homepass1 ENC=sae-mixed HIDDEN=0 ROAM_DBM=-70 MOCK_BRIP=192.168.2.1/24
has wpad "wpad-mbedtls  (full hostapd, replaces wpad-basic-mbedtls)" "basic wpad detected as not full"
file_has "$MOCK_STATE/apk.installed" "wpad-mbedtls" "full wpad installed"
if grep -qx wpad-basic-mbedtls "$MOCK_STATE/apk.installed"; then nok "basic wpad removed"; else ok "basic wpad removed"; fi
uci_is wireless.default_radio1.bss_transition 1 "802.11v on with the full wpad"
has wpad "Gateway is set up successfully" "set up"

echo "== Wi-Fi refuses to start → the Gateway rolls its Wi-Fi back"
fixture lanip=192.168.2.1 hostname=gw3
# shellcheck disable=SC2086
run wifail '\n\n\n\n\ny\n' "" RS_MODE=ws ROUTER=192.168.2.1 ROLE=gateway BANDS=both COUNTRY=NL $WIFI \
  SSID=MyHome KEY=homepass1 ENC=sae-mixed HIDDEN=0 ROAM_DBM=-70 MOCK_BRIP=192.168.2.1/24 MOCK_WIFI_FAIL=1 WIFI_WAIT=6
has wifail "Wi-Fi did not start" "Wi-Fi failure detected"
has wifail "ROLLED BACK: Wi-Fi settings restored" "Wi-Fi rolled back"
has wifail "the check saw: radio" "the reason names what the Wi-Fi check saw"
hasnt wifail "Gateway is set up successfully" "no false success"

echo "== running hostapd is old (installed one can do 802.11v) → wpad restarted, 802.11v kept"
WPADBIN=1 fixture lanip=192.168.2.1 hostname=gw5
# shellcheck disable=SC2086
run stale '\n\n\n\n\ny\n' "" RS_MODE=ws ROUTER=192.168.2.1 ROLE=gateway BANDS=both COUNTRY=NL $WIFI \
  SSID=MyHome KEY=homepass1 ENC=sae-mixed HIDDEN=0 ROAM_DBM=-70 MOCK_BRIP=192.168.2.1/24 \
  MOCK_WIFI_NOWNM=1 MOCK_NOWNM_UNTIL_RESTART=1 WIFI_WAIT=6
has stale "restarting wpad so that one runs" "old running hostapd restarted"
has stale "Wi-Fi up with 802.11v after restarting wpad" "802.11v kept"
has stale "Gateway is set up successfully" "set up"
hasnt stale "802.11v is off" "no needless 802.11v removal"
uci_is wireless.default_radio1.bss_transition 1 "bss_transition still on"
rm -f /usr/sbin/wpad /usr/sbin/hostapd

echo "== hostapd refuses 802.11v (no 802.11v anywhere) → removed from the whole radio, not rolled back"
fixture lanip=192.168.2.1 hostname=gw4 extra=1
# shellcheck disable=SC2086
run nownm '\n\n\n\n\ny\n' "" RS_MODE=ws ROUTER=192.168.2.1 ROLE=gateway BANDS=both COUNTRY=NL $WIFI \
  SSID=MyHome KEY=homepass1 ENC=sae-mixed HIDDEN=0 ROAM_DBM=-70 MOCK_BRIP=192.168.2.1/24 MOCK_WIFI_NOWNM=1 WIFI_WAIT=6
has nownm "retrying without 802.11v" "bss_transition refusal recognised"
has nownm "Gateway is set up successfully" "set up anyway"
has nownm "802.11v is off" "user told 802.11v is off and why"
uci_is wireless.default_radio1.bss_transition '<unset>' "bss_transition removed (=0 is still refused by such a hostapd)"
has nownm "unknown configuration item 'bss_transition'" "hostapd's own reason shown"
uci_is wireless.wifinet2.bss_transition '<unset>' "also removed from the other network on that radio"
has nownm "802.11v removed from: default_radio0 wifinet2" "user told which networks changed"

echo "== OpenWrt 25.12-style box without the iwinfo CLI → hostapd's own ubus status confirms Wi-Fi"
fixture lanip=192.168.2.1 hostname=gw6
# shellcheck disable=SC2086
run noiw '\n\n\n\n\ny\n' "" RS_MODE=ws ROUTER=192.168.2.1 ROLE=gateway BANDS=both COUNTRY=NL $WIFI \
  SSID=MyHome KEY=homepass1 ENC=sae-mixed HIDDEN=0 ROAM_DBM=-70 MOCK_BRIP=192.168.2.1/24 MOCK_NO_IWINFO=1 WIFI_WAIT=6
has noiw "Gateway is set up successfully" "set up without iwinfo"
hasnt noiw "Wi-Fi did not start" "no false Wi-Fi failure"
has noiw "ROAMER v$(sed -n 's/^VERSION=//p' "$ROOT/roaming-setup.sh")" "version in the screen header"

echo "== netifd status without section names → hostapd BSSes with our SSID count"
fixture lanip=192.168.2.1 hostname=gw7
# shellcheck disable=SC2086
run nosec '\n\n\n\n\ny\n' "" RS_MODE=ws ROUTER=192.168.2.1 ROLE=gateway BANDS=both COUNTRY=NL $WIFI \
  SSID=MyHome KEY=homepass1 ENC=sae-mixed HIDDEN=0 ROAM_DBM=-70 MOCK_BRIP=192.168.2.1/24 MOCK_NO_IWINFO=1 MOCK_NOSECTION=1 WIFI_WAIT=6
has nosec "Gateway is set up successfully" "set up via hostapd's SSID list"

# ---------------------------------------------------------------- monitoring
for PMK in apk opkg; do
  echo "== monitoring on the Gateway ($PMK)"
  fixture lanip=192.168.2.1 hostname=gwm
  # shellcheck disable=SC2086
  run gwm '\n\n\n\n\ny\n\n' "" $GWARGS $WIFI MONITORING=yes RS_PM=$PMK
  has gwm "Gateway is set up successfully" "set up"
  has gwm "monitoring: LuCI Statistics, listens on port 25826" "shown in the plan"
  installed luci-app-statistics "luci-app-statistics installed"
  installed collectd-mod-iwinfo "collectd-mod-iwinfo installed"
  installed collectd-mod-network "collectd-mod-network installed"
  uci_is luci_statistics.collectd_iwinfo.enable 1 "iwinfo plugin on"
  uci_is luci_statistics.collectd_network.enable 1 "network plugin on"
  uci_is luci_statistics.collectd_rrdtool.enable 1 "RRD output on"
  uci_is luci_statistics.collectd_rrdtool.backup 1 "RRD backup on"
  uci_count luci_statistics collectd_network_listen 1 "one listen section"
  uci_is luci_statistics.roamer_listen.host 0.0.0.0 "listens on all addresses"
  uci_is luci_statistics.roamer_listen.port 25826 "default port"
  uci_is luci_statistics.collectd.Hostname gwm "collectd hostname is the router's"
  line_count /etc/crontabs/root "$CRON" 1 "one cron line"
  file_has "$MOCK_STATE/svc.log" "cron restart" "cron restarted"
  file_has "$MOCK_STATE/svc.log" "cron enable" "cron enabled"
  file_has "$MOCK_STATE/svc.log" "luci_statistics restart" "luci_statistics restarted"
  file_has "$MOCK_STATE/svc.log" "collectd restart" "collectd restarted"
  uci_is wireless.default_radio1.ieee80211r 1 "roaming configured"
  echo "== re-run is idempotent ($PMK)"
  # shellcheck disable=SC2086
  run gwm2 '\n\n\n\ny\n\n' "" $GWARGS $WIFI MD=keep MONITORING=yes RS_PM=$PMK   # MD preset: no mobility-domain screen
  has gwm2 "Gateway is set up successfully" "set up again"
  uci_count luci_statistics collectd_network_listen 1 "still one listen section"
  line_count /etc/crontabs/root "$CRON" 1 "still one cron line"
  if [ "$(grep -cx luci-app-statistics "$MOCK_STATE/apk.installed")" = 1 ]; then ok "not installed twice"; else nok "not installed twice"; fi
  exists "/etc/roaming-setup.bak/*/luci_statistics" "pre-change snapshot holds luci_statistics"
  exists "/etc/roaming-setup.bak/*/crontabs.root" "pre-change snapshot holds the crontab"
  if sh -n /etc/roaming-setup.bak/restore-latest.sh; then ok "restore script parses"; else nok "restore script parses"; fi
  file_has /etc/roaming-setup.bak/restore-latest.sh 'for f in luci_statistics collectd' "undo restores the monitoring config"
  file_has /etc/roaming-setup.bak/restore-latest.sh 'crontabs.root' "undo restores the crontab"
done

echo "== status + report on a Gateway with monitoring"
run gwst '' status RS_MODE=ws ROUTER=192.168.2.1 MOCK_BRIP=192.168.2.1/24 RS_PM=opkg
has gwst "Gateway (listener + graphs)" "status: role"
has gwst "luci-app-statistics ✓" "status: packages"
has gwst "iwinfo on · network on · rrdtool on (backup on)" "status: plugins"
has gwst "listen    0.0.0.0:25826" "status: listen target"
has gwst "cron      $CRON" "status: cron line"
has gwst "collectd  running" "status: collectd running"
run gwrep '' report RS_MODE=router RS_PM=opkg
has gwrep "monitoring|listens on 0.0.0.0:25826" "report row"

echo "== hand-made listen section, last line of the crontab without newline"
fixture lanip=192.168.2.1 hostname=gwh
mkdir -p /etc/crontabs; printf '5 4 * * * /bin/true' > /etc/crontabs/root
python3 "$T/mock/bin/uci.py" add luci_statistics collectd_network_listen >/dev/null
python3 "$T/mock/bin/uci.py" set luci_statistics.@collectd_network_listen[0].host=0.0.0.0
python3 "$T/mock/bin/uci.py" set luci_statistics.@collectd_network_listen[0].port=25826
# shellcheck disable=SC2086
run gwh '\n\n\n\n\ny\n\n' "" $GWARGS $WIFI MONITORING=yes
uci_count luci_statistics collectd_network_listen 1 "the hand-made section is reused"
line_count /etc/crontabs/root '5 4 * * * /bin/true' 1 "existing cron line intact"
line_count /etc/crontabs/root "$CRON" 1 "ours on its own line"

echo "== MONITORING=no on a router that has it: left untouched"
uci_before="$(python3 "$T/mock/bin/uci.py" show luci_statistics)"; pk_before="$(cat "$MOCK_STATE/apk.installed")"; cr_before="$(cat /etc/crontabs/root)"
: > "$MOCK_STATE/svc.log"
# shellcheck disable=SC2086
run gwoff '\n\n\n\ny\n' "" $GWARGS $WIFI MD=keep
has gwoff "Gateway is set up successfully" "set up"
if [ "$(python3 "$T/mock/bin/uci.py" show luci_statistics)" = "$uci_before" ]; then ok "statistics config untouched"; else nok "statistics config untouched"; fi
if [ "$(cat "$MOCK_STATE/apk.installed")" = "$pk_before" ]; then ok "nothing uninstalled"; else nok "nothing uninstalled"; fi
if [ "$(cat /etc/crontabs/root)" = "$cr_before" ]; then ok "crontab untouched"; else nok "crontab untouched"; fi
if grep -q 'luci_statistics\|collectd\|cron' "$MOCK_STATE/svc.log"; then nok "no monitoring service restarted"; else ok "no monitoring service restarted"; fi

for PMK in apk opkg; do
  echo "== monitoring on a Dumb AP: bare collectd ($PMK)"
  WANCARRIER=1 fixture lanip=192.168.2.2 hostname=ap9
  # shellcheck disable=SC2086
  run apm '\n\n\n\n\ny\n' "" $APARGS PAIR="$PAIRCODE" $WIFI SSH_CLIENT="192.168.2.3 1 22" MONITORING=yes RS_PM=$PMK
  wait_mon
  has apm "Dumb AP is set up successfully" "set up"
  has apm "monitoring: sends to 192.168.2.1:25826 once" "shown in the plan"
  has apm "monitoring: sends to 192.168.2.1:25826 as ap9" "outcome shown on the computer"
  has apm "monitoring sends to 192.168.2.1:25826" "report row"
  installed collectd "collectd installed"
  installed collectd-mod-iwinfo "collectd-mod-iwinfo installed"
  installed collectd-mod-network "collectd-mod-network installed"
  not_installed luci-app-statistics "no luci-app-statistics: it would pull in rrdtool"
  not_installed rrdtool1 "no rrdtool1"
  not_installed librrd1 "no librrd1"
  uci_is collectd.iwinfo.enable 1 "iwinfo plugin on"
  uci_is collectd.network.enable 1 "network plugin on"
  uci_is collectd.rrdtool.enable 0 "RRD output off"
  uci_count collectd network_server 1 "one server section"
  uci_is collectd.roamer_server.host 192.168.2.1 "server is the Gateway from the pairing code"
  uci_is collectd.roamer_server.port 25826 "server port"
  uci_is collectd.globals.Hostname ap9 "collectd hostname is the AP's NAME"
  uci_is collectd.globals.alt_config_file '<unset>' "collectd.init reads UCI, not /etc/collectd.conf"
  file_has "$MOCK_STATE/svc.log" "collectd restart" "collectd restarted"
  if [ -e /etc/crontabs/root ]; then nok "no cron line on a Dumb AP"; else ok "no cron line on a Dumb AP"; fi
  echo "== Dumb AP re-run is idempotent ($PMK)"
  # shellcheck disable=SC2086
  run apm2 '\n\n\n\n\ny\n' "" $APARGS PAIR="$PAIRCODE" $WIFI SSH_CLIENT="192.168.2.3 1 22" MONITORING=yes RS_PM=$PMK MD=keep
  wait_mon
  has apm2 "Dumb AP is set up successfully" "set up again"
  uci_count collectd network_server 1 "still one server section"
  exists "/etc/roaming-setup.bak/*/collectd" "pre-change snapshot holds collectd's config"
done

echo "== status on a Dumb AP with monitoring"
run apst '' status RS_MODE=ws ROUTER=192.168.2.2 MOCK_BRIP=192.168.2.2/24 RS_PM=opkg
has apst "Dumb AP (sender)" "status: role"
has apst "iwinfo on · network on · rrdtool off" "status: plugins"
has apst "server    192.168.2.1:25826" "status: server target"
hasnt apst "cron " "status: no cron on a Dumb AP"

echo "== Dumb AP that already has luci-app-statistics: its init script owns collectd"
WANCARRIER=1 fixture lanip=192.168.2.2 hostname=ap9
PATH="$T/mock/bin:$PATH" "$T/mock/bin/mock-pkg" atomic luci-app-statistics
# shellcheck disable=SC2086
run apl '\n\n\n\n\ny\n' "" $APARGS PAIR="$PAIRCODE" $WIFI SSH_CLIENT="192.168.2.3 1 22" MONITORING=yes
wait_mon
has apl "Dumb AP is set up successfully" "set up"
uci_is luci_statistics.collectd_rrdtool.enable 0 "RRD output off"
uci_is luci_statistics.roamer_server.host 192.168.2.1 "server is the Gateway"
uci_count luci_statistics collectd_network_server 1 "one server section"
uci_count luci_statistics collectd_network_listen 0 "no listener on a Dumb AP"
uci_is collectd.globals.alt_config_file /etc/collectd.conf "collectd reads the generated config"
if grep -qF "$CRON" /etc/crontabs/root 2>/dev/null; then nok "no cron line"; else ok "no cron line"; fi

echo "== a custom port travels in the pairing code"
fixture lanip=192.168.2.1 hostname=gwp
# shellcheck disable=SC2086
run gwp '\n\n\n\n\ny\n\n' "" $GWARGS $WIFI MONITORING=yes MON_PORT=25999
uci_is luci_statistics.roamer_listen.port 25999 "Gateway listens on MON_PORT"
PORTPAIR="$(cat "$MOCK_STATE"/ws/roamer-data/Gateway_gwp/pairing.txt)"
WANCARRIER=1 fixture lanip=192.168.2.2 hostname=ap9
# shellcheck disable=SC2086
run app '\n\n\n\n\ny\n' "" $APARGS PAIR="$PORTPAIR" $WIFI SSH_CLIENT="192.168.2.3 1 22" MONITORING=yes
wait_mon
uci_is collectd.roamer_server.port 25999 "Dumb AP sends to that port"

echo "== not enough flash: skipped, the run succeeds, a warning is logged"
fixture lanip=192.168.2.1 hostname=gwf
# shellcheck disable=SC2086
run gwf '\n\n\n\n\ny\n\n' "" $GWARGS $WIFI MONITORING=yes MOCK_OVERLAY_KB=1200
has gwf "Gateway is set up successfully" "Gateway: set up"
has gwf "not enough flash: needs about 2224 KiB (package sizes + 1024 KiB reserve), 1200 KiB free" "Gateway: clear message"
glob_has "$MOCK_STATE/ws/$GWLOG" "not enough flash" "Gateway: warning in the log"
not_installed luci-app-statistics "Gateway: nothing installed"
uci_is wireless.default_radio1.ieee80211r 1 "Gateway: roaming configured"
exists "$MOCK_STATE/ws/roamer-data/Gateway_gwf/pairing.txt" "Gateway: pairing code saved"
has gwf "monitoring skipped: not enough flash" "Gateway: in the report"
WANCARRIER=1 fixture lanip=192.168.2.2 hostname=ap9
# shellcheck disable=SC2086
run apf '\n\n\n\n\ny\n' "" $APARGS PAIR="$PAIRCODE" $WIFI SSH_CLIENT="192.168.2.3 1 22" MONITORING=yes MOCK_OVERLAY_KB=500
wait_mon
has apf "Dumb AP is set up successfully" "small-flash AP: set up"
has apf "not enough flash: needs about 656 KiB" "small-flash AP: clear message"
file_has /tmp/roaming-apply.log "not enough flash" "small-flash AP: warning in its log"
glob_has "$MOCK_STATE/ws/roamer-data/DumbAP_ap9/logs/*.ok.log" "not enough flash" "small-flash AP: warning in the computer's log"
not_installed collectd "small-flash AP: nothing installed"
uci_is dhcp.lan.ignore 1 "small-flash AP: still converted"
uci_is network.lan.ipaddr 192.168.2.2 "small-flash AP: address kept"
WANCARRIER=1 fixture lanip=192.168.2.2 hostname=ap9
# shellcheck disable=SC2086
run apf2 '\n\n\n\n\ny\n' "" $APARGS PAIR="$PAIRCODE" $WIFI SSH_CLIENT="192.168.2.3 1 22" MONITORING=yes MOCK_OVERLAY_KB=900
wait_mon
installed collectd "small-flash AP with 900 KiB free: bare collectd fits"

echo "== no package sizes: the fixed minimum decides"
fixture lanip=192.168.2.1 hostname=gwt
# shellcheck disable=SC2086
run gwt '\n\n\n\n\ny\n\n' "" $GWARGS $WIFI MONITORING=yes MOCK_OVERLAY_KB=3000 MOCK_NO_SIZES=1
has gwt "needs about 3072 KiB (no package sizes available, fixed minimum), 3000 KiB free" "Gateway minimum: 3072 KiB"
has gwt "Gateway is set up successfully" "set up"
fixture lanip=192.168.2.1 hostname=gwt
# shellcheck disable=SC2086
run gwt2 '\n\n\n\n\ny\n\n' "" $GWARGS $WIFI MONITORING=yes MOCK_OVERLAY_KB=3100 MOCK_NO_SIZES=1 RS_PM=opkg
installed luci-app-statistics "just above the minimum: installed"
fixture lanip=192.168.2.1 hostname=gwd
# shellcheck disable=SC2086
run gwd '\n\n\n\n\ny\n\n' "" $GWARGS $WIFI MONITORING=yes MOCK_NO_DF=1
has gwd "could not read the free flash space" "unreadable flash: skipped"
not_installed luci-app-statistics "unreadable flash: nothing installed"

echo "== package install fails: non-fatal, roaming config intact"
fixture lanip=192.168.2.1 hostname=gwi
# shellcheck disable=SC2086
run gwi '\n\n\n\n\ny\n\n' "" $GWARGS $WIFI MONITORING=yes MOCK_PKG_FAIL=collectd-mod-network RS_PM=opkg
has gwi "Gateway is set up successfully" "Gateway: set up"
has gwi "could not install: luci-app-statistics collectd-mod-iwinfo collectd-mod-network" "Gateway: says what failed"
glob_has "$MOCK_STATE/ws/$GWLOG" "could not install" "Gateway: warning in the log"
not_installed luci-app-statistics "Gateway: a half-done opkg install is removed again"
uci_is wireless.default_radio1.ieee80211r 1 "Gateway: 802.11r on"
uci_is wireless.default_radio1.mobility_domain "$(python3 "$T/mock/bin/uci.py" get wireless.default_radio0.mobility_domain)" "Gateway: mobility domain set"
if [ -e /etc/crontabs/root ]; then nok "Gateway: no cron line"; else ok "Gateway: no cron line"; fi
exists "$MOCK_STATE/ws/roamer-data/Gateway_gwi/pairing.txt" "Gateway: pairing code saved"
WANCARRIER=1 fixture lanip=192.168.2.2 hostname=ap9
# shellcheck disable=SC2086
run api '\n\n\n\n\ny\n' "" $APARGS PAIR="$PAIRCODE" $WIFI SSH_CLIENT="192.168.2.3 1 22" MONITORING=yes MOCK_PKG_FAIL=collectd
wait_mon
has api "Dumb AP is set up successfully" "Dumb AP: set up"
has api "could not install" "Dumb AP: says what failed"
file_has /tmp/roaming-apply.log "could not install" "Dumb AP: warning in its log"
if grep -q "^rolled" /tmp/roaming-state; then nok "Dumb AP: not rolled back"; else ok "Dumb AP: not rolled back"; fi
uci_is dhcp.lan.ignore 1 "Dumb AP: conversion kept"
uci_is wireless.default_radio1.ieee80211r 1 "Dumb AP: 802.11r on"

echo "== other failures: no internet, a service that won't restart, a hung install"
fixture lanip=192.168.2.1 hostname=gwu
# shellcheck disable=SC2086
run gwu '\n\n\n\n\ny\n\n' "" $GWARGS $WIFI MONITORING=yes MOCK_UPDATE_FAIL=1
has gwu "could not update the package lists" "no internet: warned"
has gwu "Gateway is set up successfully" "no internet: set up"
fixture lanip=192.168.2.1 hostname=gws
# shellcheck disable=SC2086
run gws '\n\n\n\n\ny\n\n' "" $GWARGS $WIFI MONITORING=yes MOCK_SVC_FAIL=collectd
has gws "could not restart: collectd" "service failure: warned"
has gws "Gateway is set up successfully" "service failure: set up"
fixture lanip=192.168.2.1 hostname=gwg
# shellcheck disable=SC2086
run gwg '\n\n\n\n\ny\n\n' "" $GWARGS $WIFI MONITORING=yes MOCK_PKG_HANG=4 MON_TIMEOUT=1
has gwg "gave up after 1s" "hung install: given up on"
has gwg "Gateway is set up successfully" "hung install: set up"
python3 -c "import time; time.sleep(4)"     # the stand-in install still finishes: not into the next fixture
fixture lanip=192.168.2.1 hostname=gwb
# shellcheck disable=SC2086
run gwb '\n\n\n\n\ny\n' "" $GWARGS $WIFI0 MONITORING=maybe
has gwb "MONITORING='maybe' is not yes or no" "wrong value: warned"
has gwb "Gateway is set up successfully" "wrong value: set up"
not_installed luci-app-statistics "wrong value: stays off"
fixture lanip=192.168.2.1 hostname=gwb
# shellcheck disable=SC2086
run gwb2 '\n\n\n\n\ny\n' "" $GWARGS $WIFI MONITORING=yes MON_PORT=99999
has gwb2 "MON_PORT='99999' is not a port" "wrong port: warned"
not_installed luci-app-statistics "wrong port: stays off"

echo "== the prompt: default is no"
fixture lanip=192.168.2.1 hostname=gwq
# welcome · menu · backup · device · mobility domain · Enable monitoring? · plan
# shellcheck disable=SC2086
run gwq '\n\n\n\n\n\ny\n' "" $GWARGS $WIFI0
has gwq "Enable monitoring?" "asked"
has gwq "ROAMER v$(sed -n 's/^VERSION=//p' "$ROOT/roaming-setup.sh")" "version on the screen"
has gwq "Gateway is set up successfully" "set up"
not_installed luci-app-statistics "Enter = no"
echo "== the prompt: answered yes"
fixture lanip=192.168.2.1 hostname=gwy
# shellcheck disable=SC2086
run gwy '\n\n\n\n\nyes\ny\n\n' "" $GWARGS $WIFI0
installed luci-app-statistics "installed"
echo "== ASSUME_YES=1 without MONITORING: stays off"
fixture lanip=192.168.2.1 hostname=gwa
# shellcheck disable=SC2086
run gwa '' setup $GWARGS $WIFI0 ASSUME_YES=1 MD=derive
has gwa "Gateway is set up successfully" "set up"
not_installed luci-app-statistics "nothing installed"
uci_count luci_statistics collectd_network_listen 0 "no listen section"
if [ -e /etc/crontabs/root ]; then nok "no cron line"; else ok "no cron line"; fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]
