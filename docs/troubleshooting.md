# Troubleshooting

## The computer can't reach a router

Roamer explains why: nothing answers, SSH refused (often a WAN side), login refused, or *this
computer has no address in that network*. It then tries the router over IPv6 link-local, and
offers **retry**, **another address** or **go through the Gateway** (log in to the Gateway once,
every connection hops through it).

## Wi-Fi gone after a run (LuCI shows "802.11s? Install mesh wpad")

That LuCI text is only a link next to "Mode" whenever the installed wpad has no mesh support. It
is not the problem; don't install `wpad-mesh-*` (it conflicts with the others and also lacks
802.11v).

**Installed the full wpad and it still fails?** Ask the binaries — a hostapd with 802.11v has the
literal `bss_transition` in its config parser:

```sh
tr '\000' '\n' < /usr/sbin/hostapd | grep -x bss_transition                 # installed hostapd
# the ones running now (pidof misses the jailed hostapd — look at /proc instead):
for d in /proc/[0-9]*; do case "$(readlink $d/exe)" in */wpad*|*/hostapd*)
  echo "pid ${d#/proc/}: $(readlink $d/exe) 802.11v=$(tr '\000' '\n' < $d/exe | grep -cx bss_transition)";; esac; done
```

All networks of a radio share one hostapd config: if hostapd can't do 802.11v, a `bss_transition`
left on *any* network of that radio keeps the whole radio down.

- installed yes, running no → the running hostapd is the old one: `/etc/init.d/wpad restart; wifi`
  (or reboot). Roamer ≥ 8.4 does this by itself.
- installed no → the package on disk has no 802.11v; check `apk list --installed | grep -E 'wpad|hostapd'`.

Either way Roamer ≥ 8.4 brings Wi-Fi up: if hostapd refuses 802.11v it first restarts `wpad` (when the
installed hostapd can do it), else removes the option from every network on that radio (setting it to 0
is not enough — the wifi scripts still pass the key on) and keeps 802.11r/k.

The original cause, fixed in 8.1: the router had `wpad-basic-*`, Roamer 8.0 and older didn't swap it
for the full wpad but enabled 802.11v (`bss_transition`), and basic hostapd refuses that whole AP
config. On the router:

```sh
# 1. which wpad is installed, and what can hostapd do?
apk list --installed | grep -E '^(wpad|hostapd)'          # opkg: opkg list-installed | grep wpad
for f in 11r acs sae mesh; do hostapd -v$f >/dev/null 2>&1 && echo "hostapd: $f"; done

# 2. get Wi-Fi back right away: remove 802.11v from every network that has it
for s in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)\.bss_transition='[^']*'$/\1/p"); do
  uci delete wireless.$s.bss_transition; done      # delete — "=0" is still passed on
uci commit wireless; wifi

# 3. install the full wpad, restart it, switch 802.11v back on
apk del wpad-basic-mbedtls && apk add wpad-mbedtls      # opkg: opkg remove … && opkg install …
/etc/init.d/wpad restart
for s in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)\.ieee80211r='1'$/\1/p"); do
  uci set wireless.$s.bss_transition=1; done
uci commit wireless; wifi
```

If the log mentions `ACS` or `survey`, the radio's driver can't pick channels by itself: give it a
fixed one (`uci set wireless.radio1.channel=36; uci -q delete wireless.radio1.channels;
uci commit wireless; wifi`).

Still nothing? `logread -e hostapd | tail -30` names the refused option, and `./roaming-setup.sh diag`
shows radios, interfaces and hostapd features. Roamer 8.1 checks after applying that every roaming
network really broadcasts, and rolls the Wi-Fi back if it doesn't. If LuCI keeps showing old hints
after a package change, log out and in again; it caches the hostapd feature list per session.

## "Wi-Fi did not start" but hostapd logged no error

Roamer ≥ 8.5 checks each roaming network through hostapd's own status, then `iw`, then `iwinfo`, and
the failure line lists what each said. To look yourself:

```sh
ubus list 'hostapd.*'                                   # one object per running Wi-Fi network
ubus call hostapd.phy0-ap0 get_status | grep -E '"(status|ssid)"'   # status ENABLED = broadcasting
iw dev                                                  # type AP + ssid per interface
```

If those show the network as running and Roamer still says it isn't, open an issue with the log
(`roamer-data/<Role>_<host>/logs/`). `WIFI_WAIT=<s>` lengthens the wait for slow radios.

## Laptop on a Dumb AP's LAN port: internet works, the Dumb AP doesn't answer

Frames between that port and the Gateway are switched fine, but the path between that port and the
Dumb AP's own processor is broken. From that laptop, with that cabling:

```sh
./roaming-setup.sh lantest
```

1. checks the laptop's address and the direct path;
2. logs in to the Gateway (no time limit), then to the Dumb AP through it;
3. pings the Dumb AP directly while watching its port counters, ARP and bridge from inside;
4. names the cause and fixes it after a **backup**:
   - **WAN bridged into the LAN** (the usual cause; left behind by Roamer ≤ 7.4): WAN leaves the
     bridge, you move the Gateway cable to a free LAN port, your laptop confirms over its cable.
     Not confirmed within 5 minutes → it reverts by itself.
   - otherwise: clear its tables → restart its network → reboot (checked by uptime), re-testing
     after each; "works" needs two ping rounds plus SSH.

Everything goes into `roamer-data/DumbAP_<host>/lantest/<time>.txt`. Attach it to an issue if nothing helped.

A laptop with **two network cards in the same network** (e.g. one cabled to the Dumb AP, one to the
Gateway) answers ARP for its address on both, and replies can go to the wrong card. Unplug one or
set `net.ipv4.conf.all.arp_ignore=1` and `arp_announce=2`. `lantest` warns when it sees this.

## diag, state, status, report

```sh
./roaming-setup.sh diag     # LAN ports + link state, devices per port, Gateway DHCP, routing, Tailscale, SSH
./roaming-setup.sh state    # one line: applying / waiting · rollback in N s · Gateway via LAN ports · confirmation
./roaming-setup.sh status   # the Dumb AP's switch-over log, then the monitoring state
./roaming-setup.sh report   # what is set up
```

## Monitoring: an AP is missing from the Gateway's graphs

`./roaming-setup.sh status` on that AP shows what happened in its last run and where it sends to, and
on the Gateway what it listens on. Then, on the Gateway, wait a minute and look for its data:

```sh
ls /tmp/rrd/                              # one folder per host that has sent something
logread -e collectd | tail                # plugin or network errors on either router
```

- **Not enough flash**: monitoring was skipped, which is expected on small routers. Roaming isn't affected.
- **The port differs**: an AP paired before the Gateway's `MON_PORT` changed still sends to the old
  one. Run Roamer on the AP again with a fresh pairing code.
- **A LAN firewall on the Gateway** that rejects input: allow UDP 25826 from the LAN. OpenWrt's default
  LAN zone accepts it.
- **Two routers with the same hostname** share one entry in the host dropdown: give them different names.

## Reading the usteer page

- A phone appears on **every** router's usteer page: each router hears its probes. **Load**
  counts associated clients, so "load 1 on the Gateway, 0 on the Dumb AP" means it is on the
  Gateway right now.
- The **IP** column comes from what that router knows locally. A Dumb AP has no DHCP leases, so it
  may label the phone with another address it knows (e.g. its tailnet address). That's only a label.

## Verify roaming

```sh
ubus call usteer remote_hosts      # every router sees the others
ubus call usteer get_clients       # client signal as seen by each router
hostapd_cli -i <phyX-apY> all_sta | grep -E '^[0-9a-f:]{17}$|AKMSuiteSelector'   # 000fac-4/-9 = FT-PSK/FT-SAE
logread -f | grep -Ei 'usteer|FT|auth'
```

If some clients struggle with FT in WPA2/WPA3 mixed mode, choose `psk2` (FT-PSK) on all routers.

## Tailscale on a Dumb AP

Optional and usually unnecessary. With **accept-routes**, the Gateway's advertised LAN route makes
the Dumb AP answer LAN devices through the tailnet, and it disappears from the LAN. Roamer
detects this and offers to turn it off. It refuses a Dumb AP that *advertises* routes.

## Getting a Dumb AP back

1. **Wait** for the automatic rollback (300 s). If the Gateway cable was in its WAN port before,
   put it back there.
2. **Laptop on any LAN port**: link-local or recovery address (see [wiring](wiring.md)).
3. **Unplug the Gateway cable and power-cycle**; a laptop on its first LAN port gets an address from
   its old DHCP → `ssh root@<old address>`.
4. **Failsafe**: laptop on the **first LAN port** with a **fixed 192.168.1.10/24**; power on, tap
   reset when the status LED blinks (it then blinks fast); `ssh root@192.168.1.1`, `mount_root`,
   `sh /etc/roaming-setup.bak/restore-latest.sh` (or `firstboot -y && reboot -f`).
5. The device's bootloader recovery (TFTP / web / nmrpflash): see its OpenWrt wiki page.

Undo on any router: home menu → **undo**, or `./roaming-setup.sh undo`.
