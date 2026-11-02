# Unattended use

Every prompt has a variable; anything unset is asked. With no terminal (or `ASSUME_YES=1`) the
defaults are used, and a router that can't be reached ends the run instead of retrying.

```sh
ROUTER=192.168.1.1 ROLE=gateway BANDS=both CH2=1 CH5=36 SSID='Home' KEY='…' ENC=sae-mixed \
  MD=derive TAILSCALE=no ASSUME_YES=1 ./roaming-setup.sh setup

ROUTER=192.168.1.1 PAIR="$(cat roamer-data/Gateway_*/pairing.txt)" CH2=6 CH5=100 NAME=ap-hall \
  AP_ADDR=static AP_IP=192.168.1.2 ASSUME_YES=1 ./roaming-setup.sh setup
```

## Variables

| Variable | Values |
|---|---|
| `ROUTER` | router address as seen from the computer (IPv4, or `fe80::…%iface`) |
| `ROAMER_DATA` | where run files go (default `./roamer-data`) |
| `ACTION` | home-menu choice: `setup lantest report state status diag pair confirm undo help` |
| `BACKUP` | `yes` / `no` |
| `ROLE` | `gateway` / `ap` |
| `PAIR` | pairing code `ROAM1:…` (implies `ROLE=ap`) |
| `TAILSCALE` | `yes` / `no` |
| `BANDS` | `2g` / `5g` / `both` |
| `COUNTRY` | `XX` / `keep` |
| `IFACE_2G`, `IFACE_5G` | wifi-iface section or `new` |
| `CH2`, `CH5` | channel / `auto` / `keep` |
| `HT2`, `HT5` | htmode / `keep` |
| `TXP2`, `TXP5` | dBm / `max` / `keep` |
| `SSID`, `KEY` | network name, password (8–63) |
| `ENC` | `keep` / `sae-mixed` / `psk2` / `sae` |
| `HIDDEN` | `0` / `1` |
| `MD` | `keep` / `derive` / `gen` / 4 hex |
| `ROAM_DBM` | steering threshold, −90…−50 (default −70) |
| `NAME` | Dumb AP hostname |
| `AP_ADDR` | `static` / `dhcp` |
| `AP_IP`, `GW_IP`, `NETMASK` | Dumb AP address, Gateway address, netmask |
| `MGMT_IP` | recovery address or `off` |
| `TS_ACCEPT` | `off` / `keep` (Tailscale accept-routes on a Dumb AP) |
| `CONFIRM_TIMEOUT` | seconds before a Dumb AP rolls back (default 300, `0` = never) |
| `BRIDGE_WAN` | `1` = keep WAN bridged into the LAN (experts; refused when WAN/LAN use different CPU links) |
| `FORCE_AP` | `1` = override the "this looks like a Gateway" refusals |
| `MONITORING` | `yes` / `no` (default `no`): see README → Monitoring |
| `MON_PORT` | collectd port, default `25826`. Gateway: where it listens. A Dumb AP gets it from the pairing code |
| `DRY_RUN` | `1` = show plan + UCI changes, write nothing |
| `ASSUME_YES` | `1` = no questions |
| `GUARD` | `0` = no internet guard on the Gateway |
| `PING_HOST` | internet check target (default 1.1.1.1) |
| `WIFI_WAIT` | seconds to wait for Wi-Fi to come up after applying (default 90, 160 with DFS) |
| `CLEAR`, `NO_COLOR`, `COLS` | screen clearing, colours, width |

## Sub-commands

`setup`, `lantest` (computer only), `report`, `state`, `status`, `diag`, `pair`, `confirm`, `undo`,
`help`. From the computer they run against `ROUTER`; on a router, against itself.
