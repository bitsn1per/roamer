#!/bin/sh
# Roamer — seamless Wi-Fi roaming for OpenWrt: 802.11r (FT) + 802.11k/v + usteer.        v8.6
# https://github.com/OWNER/roamer · MIT License · POSIX sh / busybox ash
# Works on any OpenWrt 24.10/25.12 router with a 2.4 and/or 5 GHz radio. Docs: README.md, docs/
#
# Just run it:
#   on your computer:  ./roaming-setup.sh   → home menu; "setup" asks for the router's IP, saves a
#                      backup + log into this folder and runs on the router over SSH.
#                      Gateway first, then each Dumb AP.
#   on a router:       ./roaming-setup.sh   (after copying it there)
#
# Commands (also in the home menu; from the computer they run against $ROUTER):
#   setup | report | state | status | diag | pair | confirm | undo | help
#   lantest   computer only: cabled to a Dumb AP that doesn't answer → measure, name the cause, fix
#
# Variables (anything unset is asked; with no terminal or ASSUME_YES=1 the default is used):
#   ROUTER <ip> (computer)   BACKUP yes|no   ROLE gateway|ap   PAIR ROAM1:…   TAILSCALE yes|no
#   BANDS 2g|5g|both   COUNTRY XX|keep   IFACE_2G/IFACE_5G <section>|new   CH2/CH5 <n>|auto|keep
#   TXP2/TXP5 <dBm>|max|keep   SSID  KEY  ENC keep|sae-mixed|psk2|sae   HIDDEN 0|1
#   MD keep|derive|gen|<4 hex>   ROAM_DBM -70   NAME (Dumb AP hostname)
#   Dumb AP: AP_ADDR static|dhcp  AP_IP  GW_IP  NETMASK  MGMT_IP <ip>|off  (BRIDGE_WAN=1: experts only)
#            CONFIRM_TIMEOUT 300  FORCE_AP=1
#   MONITORING yes|no (default no)  MON_PORT 25826  (Gateway: listen port; Dumb AP: the pairing code brings it)
#   DRY_RUN=1  ASSUME_YES=1  GUARD=0  PING_HOST 1.1.1.1  WIFI_WAIT <s>  CLEAR=0  NO_COLOR=1  COLS <n>
set -eu

VERSION=8.6
NAME_SET=0; [ -n "${NAME+x}" ] && NAME_SET=1
TS="$(date +%Y%m%d-%H%M%S)"
DRY_RUN="${DRY_RUN:-0}"; GUARD="${GUARD:-1}"; PING_HOST="${PING_HOST:-1.1.1.1}"
ASSUME_YES="${ASSUME_YES:-0}"; CONFIRM_TIMEOUT="${CONFIRM_TIMEOUT:-300}"; CLEAR="${CLEAR:-1}"
PAIRFILE=/etc/roaming-setup.pair
APLOG=/tmp/roaming-apply.log; CONFIRMFILE=/tmp/roaming-confirm; STATEFILE=/tmp/roaming-state; JOBPID=/tmp/roaming-job.pid
MONSTATEFILE=/tmp/roaming-monitoring
SYSNET="${SYSNET:-/sys/class/net}"      # override for testing
case "$CONFIRM_TIMEOUT" in ""|*[!0-9]*) echo "ERROR: CONFIRM_TIMEOUT must be seconds" >&2; exit 1;; esac

ESC="$(printf '\033')"
LOGTMP=""
HIDE='s/ROAM1:[A-Za-z0-9+\/=]\{8,\}/ROAM1:(hidden — it holds the Wi-Fi password)/g'   # pairing codes never go into logs
lg()  { if [ -n "$LOGTMP" ]; then printf '%s\n' "$*" | sed "s/${ESC}\[[0-9;]*[A-Za-z]//g; $HIDE" >> "$LOGTMP"; fi; }
die() { echo "${RE:-}ERROR:${N:-} $*" >&2; lg "ERROR: $*"; exit 1; }
out() { printf '%s\n' "$*"; lg "$*"; }
log() { out "$*"; logger -t roaming-setup "$*" 2>/dev/null || true; }
b64e() { ROAM_DATA="$1" ucode -e 'print(b64enc(getenv("ROAM_DATA")))'; }
b64d() { ROAM_DATA="$1" ucode -e 'let d = b64dec(getenv("ROAM_DATA")); if (d == null) exit(1); print(d)'; }

# ================================================================ terminal UI
TTY=0
if [ "$ASSUME_YES" != 1 ] && ( exec </dev/tty ) 2>/dev/null; then TTY=1; fi
B="" D="" CY="" GR="" YE="" RE="" N=""
if [ $TTY = 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  B="${ESC}[1m" D="${ESC}[2m" CY="${ESC}[36m" GR="${ESC}[32m" YE="${ESC}[33m" RE="${ESC}[31m" N="${ESC}[0m"
fi
if [ -z "${COLS:-}" ]; then COLS="$({ stty size </dev/tty; } 2>/dev/null | awk '{print $2}')"; fi
case "${COLS:-}" in ""|*[!0-9]*) COLS=80;; esac
[ "$COLS" -ge 60 ] || COLS=60; [ "$COLS" -le 100 ] || COLS=100
dw() { printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*[A-Za-z]//g" | tr -d '\200-\277' | wc -c | tr -d ' '; }  # display width
rep() { _r=""; _k=0; while [ $_k -lt "$2" ]; do _r="$_r$1"; _k=$((_k+1)); done; printf '%s' "$_r"; }
HR="$(rep '─' "$COLS")"
say()  { if [ $TTY = 1 ]; then printf '%s\n' "$*" >/dev/tty; else printf '%s\n' "$*" >&2; fi; lg "$*"; }
ctr()  { _p=$(( (COLS - $(dw "$1")) / 2 )); [ $_p -gt 0 ] || _p=0; printf '%s%s' "$(rep ' ' $_p)" "$1"; }
sayc() { say "$(ctr "$1")"; }
okl()  { say "  ${GR}✓${N} $*"; }
wrn()  { say "  ${YE}⚠${N} $*"; }
bad()  { say "  ${RE}✗${N} $*"; }
box() {   # box "title" line…  — framed panel, as wide as its longest line (max terminal width)
  _t="$1"; shift
  _w=$(( $(dw "$_t") + 8 )); [ $_w -ge 60 ] || _w=60
  for _l in "$@"; do _x=$(( $(dw "$_l") + 4 )); [ $_x -le $_w ] || _w=$_x; done
  [ -z "${BOXW:-}" ] || [ $_w -ge "$BOXW" ] || _w=$BOXW     # BOXW: minimum width (aligned boxes)
  [ $_w -le $((COLS - 2)) ] || _w=$((COLS - 2))
  say "  ${D}╭─${N} ${B}$_t${N} ${D}$(rep '─' $((_w - $(dw "$_t") - 5)))╮${N}"
  for _l in "$@"; do
    _f=$((_w - $(dw "$_l") - 4)); [ $_f -ge 0 ] || _f=0
    say "  ${D}│${N} $_l$(rep ' ' $_f) ${D}│${N}"
  done
  say "  ${D}╰$(rep '─' $((_w - 2)))╯${N}"
}
STEPN=0; WHO="setup"; BOXW=""
# chapters: names + expected steps per chapter (for the progress bar)
CHN="Start Check Wi-Fi Apply"; CHE="3 2 12 3"; CH="Start"; CURCH=""; CHS=0
chapters() {
  case "$1" in
    computer) CHN="Connect Backup Router Finish"; CHE="1 1 1 1" ;;
    lantest)  CHN="Check Measure Fix Report"; CHE="2 2 2 1" ;;
    tool)     CHN="Connect Run"; CHE="1 1" ;;
    ap)       CHN="Start Check Wi-Fi Address Apply"; CHE="4 2 10 5 2" ;;
    *)        CHN="Start Check Wi-Fi Apply"; CHE="3 2 12 3" ;;
  esac
}
progress() {   # chapter line + bar
  if [ "$CH" = "$CURCH" ]; then CHS=$((CHS+1)); else CURCH="$CH"; CHS=1; fi
  _i=0 _tot=0 _done=0 _found=0 _line=""
  for _c in $CHN; do
    _i=$((_i+1)); _e="$(echo "$CHE" | cut -d' ' -f$_i)"; _tot=$((_tot+_e))
    if [ "$_c" = "$CURCH" ]; then _found=1; _x=$CHS; [ "$_x" -le "$_e" ] || _x=$_e; _done=$((_done+_x)); _m="${CY}${B}◉ $_c${N}"
    elif [ $_found = 0 ]; then _done=$((_done+_e)); _m="${GR}●${N} ${D}$_c${N}"
    else _m="${D}○ $_c${N}"; fi
    _line="$_line${_line:+ ${D}─${N} }$_m"
  done
  _pct=$((_done * 100 / _tot)); [ $_pct -le 99 ] || _pct=99; [ "${1:-}" = final ] && _pct=100
  _bw=16; _f=$((_pct * _bw / 100))
  _bar="${GR}$(rep '█' $_f)${N}${D}$(rep '░' $((_bw - _f)))${N} $(printf '%3d%%' $_pct)"
  _gap=$((COLS - $(dw "$_line") - $(dw "$_bar") - 3)); [ $_gap -ge 1 ] || _gap=1
  say "  $_line$(rep ' ' $_gap)$_bar"
}
step() {   # step "Title" [final]
  STEPN=$((STEPN+1))
  if [ $TTY = 1 ] && [ "$CLEAR" = 1 ]; then printf '\033[H\033[2J' >/dev/tty; fi
  _left=" ROAMER v$VERSION · $WHO"; _right="step $STEPN "
  say "${D}${HR}${N}"
  say "${B}${CY}${_left}${N}$(rep ' ' $((COLS - $(dw "$_left") - $(dw "$_right"))))${D}${_right}${N}"
  progress "${2:-}"
  say "${D}${HR}${N}"
  sayc "${B}$1${N}"; say ""
}
pause() { if [ $TTY = 1 ]; then printf '\n  %sPress Enter to continue…%s ' "$D" "$N" >/dev/tty; IFS= read -r _x </dev/tty || true; fi; }

welcome() {
  [ $TTY = 1 ] || return 0
  [ "$CLEAR" = 1 ] && printf '\033[H\033[2J' >/dev/tty
  say ""; say ""
  _art="$(cat <<'ART'
    ____
   / __ \____  ____ _____ ___  ___  _____
  / /_/ / __ \/ __ `/ __ `__ \/ _ \/ ___/
 / _, _/ /_/ / /_/ / / / / / /  __/ /
/_/ |_|\____/\__,_/_/ /_/ /_/\___/_/
ART
)"
  _mw=0; while IFS= read -r _l; do _x=$(dw "$_l"); [ "$_x" -le "$_mw" ] || _mw=$_x; done <<EOF
$_art
EOF
  _p=$(( (COLS - _mw) / 2 )); [ $_p -gt 0 ] || _p=0
  while IFS= read -r _l; do say "$(rep ' ' $_p)${CY}${B}$_l${N}"; done <<EOF
$_art
EOF
  say ""
  sayc "${B}one Wi-Fi network across all your OpenWrt routers${N}"
  sayc "${D}802.11r fast transition · 802.11k/v · usteer · v$VERSION${N}"
  say ""
  box "How it works" \
    "1. Run it for the Gateway (main router) — Wi-Fi only is changed;" \
    "   you get a pairing code." \
    "2. Run it for each Dumb AP — it joins the Gateway's LAN with the" \
    "   same Wi-Fi; the pairing code fills in SSID, password and more." \
    "" \
    "Each step is one screen; Enter takes the default / keeps current." \
    "Nothing changes before you approve the plan. Backup, recovery card" \
    "and auto-rollback are built in."
  say ""
  sayc "Full guide: ${B}README.md${N}"
  pause
}

# ---------------------------------------------------------------- validators + prompts
v_any()     { :; }
v_ch2()     { case "$1" in keep|auto) return 0;; ""|*[!0-9]*) echo "channel must be 1-14, auto or keep"; return 1;; esac
              [ "$1" -ge 1 ] && [ "$1" -le 14 ] || { echo "2.4 GHz channel must be 1-14"; return 1; }; }
v_ch5()     { case "$1" in keep|auto) return 0;; ""|*[!0-9]*) echo "channel must be a number (36, 40 … 165), auto or keep"; return 1;; esac
              [ "$1" -ge 32 ] && [ "$1" -le 177 ] || { echo "5 GHz channel must be 32-177"; return 1; }; }
v_country() { case "$1" in [A-Za-z][A-Za-z]|00) return 0;; esac; echo "two letters (NL, DE, …) or 00"; return 1; }
v_ssid()    { [ -n "$1" ] && [ "${#1}" -le 32 ] || { echo "SSID must be 1-32 characters"; return 1; }; }
v_key()     { [ "${#1}" -ge 8 ] && [ "${#1}" -le 63 ] || { echo "password must be 8-63 characters"; return 1; }; }
v_md()      { case "$1" in [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) return 0;; esac; echo "4 hex characters, e.g. 4f1a"; return 1; }
v_dbm()     { case "$1" in -[0-9][0-9]) [ "$1" -ge -90 ] && [ "$1" -le -50 ] && return 0;; esac; echo "a value from -90 to -50 (dBm)"; return 1; }
v_host()    { case "$1" in ""|*[!A-Za-z0-9-]*|-*) echo "letters, digits and '-' only"; return 1;; esac; }
v_ip()      { _o="$1."; _n=0
              while [ -n "$_o" ]; do _p="${_o%%.*}"; _o="${_o#*.}"; _n=$((_n+1))
                case "$_p" in ""|*[!0-9]*) echo "not an IPv4 address"; return 1;; esac
                [ "$_p" -le 255 ] || { echo "not an IPv4 address"; return 1; }; done
              [ $_n = 4 ] || { echo "not an IPv4 address"; return 1; }; }
v_ipoff()   { [ "$1" = off ] || v_ip "$1"; }
v_addr()    { case "$1" in [Ff][Ee]80:*) case "$1" in *[!0-9A-Za-z:%._-]*) echo "not a link-local address"; return 1;; esac; return 0;; esac; v_ip "$1"; }

isset() { eval "[ -n \"\${$1+x}\" ]"; }
getv()  { eval "printf '%s' \"\${$1:-}\""; }
setv()  { eval "$1=\$2"; }

ask() {   # ask VAR "question" default [validator]
  _v="${4:-v_any}"
  if isset "$1"; then _r="$($_v "$(getv "$1")")" || die "$1='$(getv "$1")': $_r"; return 0; fi
  while :; do
    if [ $TTY = 1 ]; then
      say "${B}$2${N}"
      if [ -n "$3" ]; then printf '  %s(Enter = %s)%s %s›%s ' "$D" "$3" "$N" "$CY" "$N" >/dev/tty
      else printf '  %s›%s ' "$CY" "$N" >/dev/tty; fi
      IFS= read -r _a </dev/tty || _a=""; _a="${_a:-$3}"
    else _a="$3"; fi
    if _r="$($_v "$_a")"; then setv "$1" "$_a"; lg "  → $_a"; return 0; fi
    [ $TTY = 1 ] || die "$2: '$_a' — $_r"
    bad "$_r — try again"
  done
}
_readsecret() {
  if command -v stty >/dev/null 2>&1; then stty -echo </dev/tty; IFS= read -r _s </dev/tty || _s=""; stty echo </dev/tty
  else IFS= read -rs _s </dev/tty 2>/dev/null || IFS= read -r _s </dev/tty || _s=""; fi
  printf '\n' >/dev/tty
}
ask_secret() {   # ask_secret VAR "question" default validator — hidden; new value typed twice
  if isset "$1"; then _r="$($4 "$(getv "$1")")" || die "$1: $_r"; return 0; fi
  [ $TTY = 1 ] || { _r="$($4 "$3")" || die "$2: $_r"; setv "$1" "$3"; return 0; }
  while :; do
    say "${B}$2${N}"
    if [ -n "$3" ]; then printf '  %s(Enter = keep current)%s %s›%s ' "$D" "$N" "$CY" "$N" >/dev/tty; else printf '  %s›%s ' "$CY" "$N" >/dev/tty; fi
    _readsecret; _a="$_s"
    if [ -z "$_a" ]; then _a="$3"; lg "  → (kept current)"
    else
      _r="$($4 "$_a")" || { bad "$_r — try again"; continue; }
      printf '  %srepeat to check for typos%s %s›%s ' "$D" "$N" "$CY" "$N" >/dev/tty; _readsecret
      [ "$_a" = "$_s" ] || { bad "the two entries differ — try again"; continue; }
      lg "  → (new password set)"
    fi
    if _r="$($4 "$_a")"; then setv "$1" "$_a"; return 0; fi
    bad "$_r — try again"
  done
}
choose() {   # choose VAR "title" default "value|label" …
  _var=$1 _title=$2 _def=$3; shift 3
  isset "$_var" && return 0
  [ $TTY = 1 ] || { setv "$_var" "$_def"; return 0; }
  while :; do
    say "${B}$_title${N}"; _i=0; _defn=""
    for _o in "$@"; do
      _i=$((_i+1)); _m=""
      [ "${_o%%|*}" = "$_def" ] && { _defn=$_i; _m="  ${D}← Enter${N}"; }
      say "  ${CY}$_i${N}) ${_o#*|}$_m"
    done
    printf '  %s(Enter = %s)%s %s›%s ' "$D" "${_defn:-$_def}" "$N" "$CY" "$N" >/dev/tty; IFS= read -r _a </dev/tty || _a=""
    [ -z "$_a" ] && { setv "$_var" "$_def"; lg "  → $_def"; return 0; }
    _i=0
    for _o in "$@"; do _i=$((_i+1)); [ "$_a" = "$_i" ] && { setv "$_var" "${_o%%|*}"; lg "  → ${_o%%|*}"; return 0; }; done
    for _o in "$@"; do [ "$_a" = "${_o%%|*}" ] && { setv "$_var" "$_a"; lg "  → $_a"; return 0; }; done
    bad "invalid choice: $_a"
  done
}
confirm() {
  [ "$ASSUME_YES" = 1 ] || [ $TTY = 0 ] && return 0
  printf '\n  %s%s%s [y/N] %s›%s ' "$B" "$1" "$N" "$CY" "$N" >/dev/tty; IFS= read -r _a </dev/tty || _a=""
  case "$_a" in y|Y|yes|YES) lg "  → yes"; return 0;; *) lg "  → no"; return 1;; esac
}
squote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
PANTS="Don't get caught with your pants down: take a backup before changing anything."

# ================================================================ COMPUTER SIDE
is_openwrt() {
  case "${RS_MODE:-}" in ws) return 1;; router) return 0;; esac     # RS_MODE: override for testing
  [ -f /etc/openwrt_release ] && grep -q "OpenWrt" /etc/openwrt_release 2>/dev/null
}

local_addrs() {   # this computer's IPv4 addresses (best effort, also works without root)
  { ip -4 -o addr show 2>/dev/null | awk '{print $4}'; } | grep -v '^127\.' \
    || ifconfig 2>/dev/null | sed -n 's/.*inet \(addr:\)\{0,1\}\([0-9.]*\).*/\2/p' | grep -v '^127\.' || true
}
local_ifaces() {   # wired-looking network interfaces of this computer (for IPv6 link-local)
  { if [ -d /sys/class/net ]; then for _i in /sys/class/net/*; do [ -e "$_i/wireless" ] || basename "$_i"; done
    else ifconfig -l 2>/dev/null | tr ' ' '\n'; fi; } \
    | grep -Ev '^(lo|lo0|ifb|docker|veth|virbr|br-|tailscale|utun|awdl|llw|gif|stf|anpi|bridge|wg|tun|tap|zt|vmnet|vboxnet)' || true
}
ssh_answers() {   # ssh_answers <host> — an SSH server answers there (login itself not needed)
  _e="$(ssh $SSHB -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=3 "root@$1" true 2>&1 </dev/null)" && return 0
  case "$_e" in *"Permission denied"*) return 0;; esac; return 1
}
try_ll() {   # try_ll <fe80::…> → prints fe80::…%<iface> on the first interface where SSH answers
  for _if in $(local_ifaces); do ssh_answers "$1%$_if" && { echo "$1%$_if"; return 0; }; done; return 1
}
discover_ll() {   # routers (SSH servers) straight on this computer's cables, found via IPv6 link-local
  _own="$( { ip -6 -o addr 2>/dev/null; ifconfig 2>/dev/null; } | tr 'A-F' 'a-f')"; _n=0
  for _if in $(local_ifaces); do
    { ping -6 -c2 -w3 "ff02::1%$_if" 2>/dev/null || ping6 -c2 "ff02::1%$_if" 2>/dev/null; } \
      | sed -n 's/.* from \([fF][eE]80:[0-9a-fA-F:]*\).*/\1/p' | tr 'A-F' 'a-f' | sort -u > "$_tmp/ll.$_if" || true
    while IFS= read -r _a; do
      case "$_own" in *"$_a/"*|*"$_a%"*) continue;; esac
      _n=$((_n+1)); [ $_n -le 8 ] || break
      ssh_answers "$_a%$_if" && echo "$_a%$_if"
    done < "$_tmp/ll.$_if"
  done
}
safe_name() { printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/-/g'; }

# ---------------------------------------------------------------- roamer-data/ (everything a run keeps)
#   roamer-data/
#     Gateway_<hostname>/    backups/<time>_<ip>_backup.tar.gz  logs/<time>_ok.log  pairing.txt
#     DumbAP_<hostname>/     backups/  logs/  recovery/<time>_RECOVERY.txt  lantest/<time>.txt
#     hosts.txt              known Dumb APs: address hostname link-local
DATA="${ROAMER_DATA:-./roamer-data}"
HOSTS="$DATA/hosts.txt"
rdir() { printf '%s/%s_%s' "$DATA" "$1" "$(safe_name "$2")"; }        # rdir <Role> <hostname>
mkd()  { (umask 077; mkdir -p "$@"); }
rel()  { printf '%s' "${1#./}"; }
hosts_get() { awk -v a="$1" '$1==a{print $'"$2"'; exit}' "$HOSTS" ./roaming-hosts.txt 2>/dev/null || true; }
newest_pair() { ls -t "$DATA"/Gateway_*/pairing.txt ./roaming-pair_*.txt 2>/dev/null | head -n1 || true; }
relocate() {   # relocate <from dir> <to dir> — merge a router's folder into its final Role_hostname folder
  [ "$1" != "$2" ] && [ -d "$1" ] || return 0
  mkd "$2"
  ( cd "$1" && find . -type f ) | while IFS= read -r _f; do
    mkd "$2/$(dirname "$_f")"; mv "$1/$_f" "$2/$_f"; done
  find "$1" -depth -type d -exec rmdir {} \; 2>/dev/null || true
}

cant_reach() {   # cant_reach <ip> <ssh error>
  step "Can't reach $1"
  case "$2" in
    *"timed out"*|*"No route"*|*"unreachable"*) why="nothing answers at $1 — no route from this computer";;
    *"refused"*) why="$1 answers but refuses SSH — often a router's WAN side (its firewall blocks SSH)";;
    *"Permission denied"*) why="$1 answers but the login was refused (wrong password/key)";;
    *) why="$(printf '%s' "$2" | tail -n1)";;
  esac
  bad "$why"
  la="$(local_addrs | tr '\n' ' ')"
  case "$1" in
    *:*) ;;
    *) net="${1%.*}."
       case " $la" in *" $net"*) ;; *)
         wrn "this computer has no address in ${net}0/24 (it has: ${la:-none})"
         case " $la" in *" 169.254."*) say "    169.254.x = no DHCP answer on its cable: whatever it is plugged into does not reach the Gateway";; esac
         case " $la" in *" 192.168.1."*) say "    192.168.1.x: a Dumb AP set up by Roamer ≥ 7.3 also answers on its recovery address 192.168.1.<n>";; esac
       ;; esac ;;
  esac
  say "  ${D}Cabled straight to a router? Roamer also tries it over IPv6 link-local (no IP settings needed).${N}"
  say ""
  box "Wirings that work" \
    "Gateway       computer on the Gateway (LAN or Wi-Fi) → its LAN IP" \
    "Dumb AP       computer on the Gateway, the Dumb AP's LAN port cabled to the Gateway" \
    "              (or the computer on a Dumb AP LAN port — it gets its address via the Gateway)" \
    "new router    still at its default address with its own DHCP: computer DIRECTLY on its" \
    "              LAN port, nothing else cabled to it — only for the first run" \
    "Dumb AP alone no DHCP there: give the computer a fixed IP in the Dumb AP's network"
  say ""
}
wait_dumb_ap() {   # wait_dumb_ap <new ip> <timeout> <cabling> <old WAN ip|-> <first LAN port>
  _ip="$1"; _to="$2"; _cab="${3:-lan}"; _old="${4:--}"; _p1="${5:-the first LAN port}"; CH=Finish
  W_CAB="$_cab"; W_OLD="$_old"; W_IP="$_ip"
  step "Reconnecting to the Dumb AP"
  case "$_cab" in
    move)   _c1="1. Move the Gateway cable from the Dumb AP's WAN port to one of its LAN ports (not $_p1)"
            _c1b="   — until then it stays reachable at its old address $_old, nothing is lost";;
    bridge) _c1="1. Leave the Gateway cable in the Dumb AP's WAN port (bridged)"; _c1b="";;
    connect) _c1="1. Connect a Gateway LAN port to a LAN port of the Dumb AP (not $_p1)"; _c1b="";;
    *)      _c1="1. Cables: nothing to change — the Dumb AP's LAN port stays cabled to the Gateway"; _c1b="";;
  esac
  [ "$_old" != - ] || _c1b=""
  set -- "$_c1"; [ -z "$_c1b" ] || set -- "$@" "$_c1b"
  box "Now" "$@" "   Exactly one cable between the Dumb AP and the Gateway." \
            "2. This computer: stay on the Gateway (LAN or Wi-Fi)" \
            "3. Wait — this screen confirms the Dumb AP once it answers at $_ip"
  say ""
  _lim=$((_to - 15)); [ $_lim -ge 60 ] || _lim=60; _ok=0; _seen=""; _last=""; _lm=""
  _t0="$(date +%s)"; _t=0; _rn=0
  while [ $_t -lt $_lim ]; do
    # a FRESH connection to the new address (never the old multiplexed one) proves the new path
    _e="$(ssh $SSHB -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=3 "root@$_ip" true 2>&1 </dev/null)" && _seen=1
    case "$_e" in *"Permission denied"*) _seen=1;; esac
    if [ -n "$_seen" ]; then
      [ $TTY = 1 ] && printf '\r%s\r' "$(rep ' ' $((COLS - 1)))" >/dev/tty
      [ -n "$_lm" ] || say "  ${D}$_ip answers — confirming (you may be asked for the router password) …${N}"
      _r=0; _m="$(ssh $SSHO "root@$_ip" 'sh /tmp/roaming-setup.sh confirm' 2>&1)" || _r=$?
      if [ "$_m" != "${_lm:-}" ]; then printf '%s\n' "$_m" | while IFS= read -r l; do [ -z "$l" ] || out "    $l"; done; fi
      _lm="$_m"
      if [ $_r = 0 ]; then _ok=1; break; fi
      _seen=""
    fi
    # what the Dumb AP itself says (through the still-open session to its old address, if any)
    if [ $((_rn % 3)) = 0 ] && [ "$ROUTER" != "$_ip" ] && [ "$ROUTER" = "$_old" ]; then
      _s="$(ssh $SSHO -o BatchMode=yes -o ConnectTimeout=3 "root@$ROUTER" 'sh /tmp/roaming-setup.sh state' 2>/dev/null | head -n1 || true)"
      [ -z "$_s" ] || _last="$_s"
    fi
    if [ $TTY = 1 ]; then
      _ln="  ${D}waiting for $_ip … $((_lim - _t))s${_last:+ · Dumb AP: $_last}${N}"
      [ "$(dw "$_ln")" -lt "$COLS" ] || _ln="$(printf '%s' "$_ln" | cut -c1-$((COLS - 2)))${N}"
      printf '\r%s\r%s' "$(rep ' ' $((COLS - 1)))" "$_ln" >/dev/tty
    fi
    sleep 5; _rn=$((_rn+1)); _t=$(( $(date +%s) - _t0 ))     # by the clock, like the Dumb AP's own deadline
  done
  [ $TTY = 1 ] && printf '\r%s\r' "$(rep ' ' $((COLS - 1)))" >/dev/tty
  APSTATE=""
  if [ $_ok = 1 ]; then
    say "  ${D}waiting for the Dumb AP to finish …${N}"
    _w=0; while [ $_w -lt 60 ]; do
      APSTATE="$(ssh $SSHO -o ConnectTimeout=5 "root@$_ip" 'sh /tmp/roaming-setup.sh state' 2>/dev/null | head -n1 || true)"
      case "$APSTATE" in ok*|rolled*|none) break;; esac
      sleep 2; _w=$((_w+2))
    done
    case "$APSTATE" in ok*) return 0;; esac
  fi
  [ -n "$APSTATE" ] || APSTATE="${_last:-did not answer at $_ip in time}"
  return 1
}

wait_monitoring() {   # a Dumb AP installs monitoring after it is confirmed: wait for it so the report shows the outcome
  _ms="$(ssh $SSHO -o ConnectTimeout=5 "root@$1" "cat $MONSTATEFILE 2>/dev/null" 2>/dev/null || true)"
  case "$_ms" in pending*|running*) ;; *) return 0;; esac
  step "Monitoring on the Dumb AP"
  say "  ${D}roaming is set up; installing monitoring (this never affects it) …${N}"
  _dl=$(( $(date +%s) + ${MON_TIMEOUT:-600} + 30 ))
  while [ "$(date +%s)" -lt "$_dl" ]; do
    _ms="$(ssh $SSHO -o ConnectTimeout=5 "root@$1" "cat $MONSTATEFILE 2>/dev/null" 2>/dev/null || true)"
    case "$_ms" in pending*|running*) sleep 5;; *) break;; esac
  done
  case "$_ms" in
    on*)  okl "monitoring: ${_ms#*|}" ;;
    pending*|running*) wrn "monitoring is still being set up — ./roaming-setup.sh status shows the outcome" ;;
    *)    wrn "monitoring: ${_ms#*|} — roaming is not affected" ;;
  esac
}

final_report() {   # final_report <ok|err> <role> <report host>
  _res="$1" _role="$2" _rh="$3"; CH=Finish
  step "Report" final
  _rep="${REP:-}"
  if [ "$_res" = ok ]; then
    case "$_role" in ap) _hd="✓  Dumb AP is set up successfully";; *) _hd="✓  Gateway is set up successfully";; esac
    sayc "${GR}${B}$_hd${N}"
  elif [ "$_res" = none ]; then
    sayc "${B}Nothing was changed${N}"
  else
    sayc "${RE}${B}✗  Not completed${N}"
    [ -z "${APSTATE:-}" ] || sayc "${D}Dumb AP: $APSTATE${N}"
    [ -z "${GWFAIL:-}" ] || { say ""; wrn "$GWFAIL"; }
  fi
  say ""
  if [ -n "$_rep" ]; then
    set --
    while IFS='|' read -r _k _v; do [ -n "$_k" ] && set -- "$@" "$(printf '%-10s %s' "$_k" "$_v")"; done <<EOF
$_rep
EOF
    box "What is set up on $_rh" "$@"
    _hn="$(printf '%s\n' "$_rep" | sed -n 's/^hostname|\([^ ]*\).*/\1/p')"
    _ll="$(printf '%s\n' "$_rep" | sed -n 's/^link-local|\([^ ]*\).*/\1/p')"
    if [ -n "$_ll" ]; then      # remembered: next time Roamer can reach it over the cable by itself
      mkd "$DATA"; { awk -v a="$_rh" '$1!=a' "$HOSTS" 2>/dev/null || true; echo "$_rh ${_hn:-?} $_ll"; } > "$HOSTS.n"
      mv "$HOSTS.n" "$HOSTS"; chmod 600 "$HOSTS"
    fi
  elif [ "$_res" = ok ]; then say "  (could not read the report from $_rh)"; fi
  set --
  [ ! -f "$BKF" ]       || set -- "$@" "backup     ${BKF#"$RDIR"/}"
  [ ! -f "$RCF" ]       || set -- "$@" "recovery   ${RCF#"$RDIR"/}"
  [ -z "${PAIRF:-}" ]   || set -- "$@" "pairing    ${PAIRF#"$RDIR"/}  (contains the Wi-Fi password)"
  _lf=ok; [ "$_res" != err ] || _lf=err
  set -- "$@" "log        ${LOGB#"$RDIR"/}.$_lf.log"
  box "Saved in $(rel "$RDIR")/" "$@"
  say ""
  if [ "$_res" = ok ]; then
    case "$_role" in
      ap) say "  Reach it at ${B}$_rh${N} from the Gateway's network. Add more Dumb APs: run ./roaming-setup.sh again."
          say "  Check roaming:  ssh root@$_rh 'ubus call usteer remote_hosts'   (lists the other routers)";;
      *)  say "  Next: wire a Dumb AP (README → Wirings that work) and run ./roaming-setup.sh again —"
          say "  it picks up the pairing code from $(rel "$DATA")/ by itself.";;
    esac
  elif [ "$_res" = err ]; then
    if [ "$_role" = ap ] && [ -n "${W_IP:-}" ]; then
      say "  The Dumb AP was not confirmed at $W_IP, so it rolls back by itself to its old settings."
      if [ "${W_OLD:--}" != - ]; then
        say "  ${B}Put the Gateway cable back into its WAN port${N} → it answers at ${B}$W_OLD${N} again (as before)."
        say "  Its own log:  ROUTER=$W_OLD ./roaming-setup.sh status"
      else
        say "  Its own log:  ROUTER=<its address> ./roaming-setup.sh status"
      fi
      say "  Still nothing? Follow ${B}$(rel "$RCF")${N}."
    else
      say "  The error is in the log above and in the log file; on failure Roamer reverts its own changes."
    fi
  fi
}
# ---------------------------------------------------------------- LAN-port test (computer side)
OS="$(uname -s 2>/dev/null || echo ?)"
pingq() {   # pingq <host> [count] — quiet ping, portable
  if [ "$OS" = Darwin ]; then ping -c "${2:-3}" -t $(( ${2:-3} + 2 )) "$1" >/dev/null 2>&1
  else ping -c "${2:-3}" -W 2 "$1" >/dev/null 2>&1; fi
}
my_gw() {
  { ip -4 route show default 2>/dev/null | awk '{print $3; exit}'; } | grep . \
    || route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}' | grep . \
    || netstat -rn 2>/dev/null | awk '$1=="default"||$1=="0.0.0.0"{print $2; exit}'
}
if_to() {
  { ip -4 route get "$1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1; } | grep . \
    || route -n get "$1" 2>/dev/null | awk '/interface:/{print $2; exit}'
}
ip_on() {
  { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4; exit}'; } | grep . \
    || ipconfig getifaddr "$1" 2>/dev/null || ifconfig "$1" 2>/dev/null | awk '/inet /{print $2; exit}'
}
mac_of() { cat "/sys/class/net/$1/address" 2>/dev/null || ifconfig "$1" 2>/dev/null | awk '/ether/{print $2; exit}'; }
arp_of() { { ip neigh show "$1" 2>/dev/null; } | grep . || arp -n "$1" 2>/dev/null | tail -n1; }
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1; }

lantest() {
  chapters lantest; CH=Check; mkd "$DATA/lantest"; LT="$DATA/lantest/${TS}.txt"; : > "$LT"; chmod 600 "$LT"
  lt() { printf '%s\n' "$*" >> "$LT"; }
  step "LAN-port test"
  box "Run it with the cabling that fails" \
    "this computer → a LAN port of the Dumb AP · the Dumb AP → the Gateway" \
    "1. checks this computer's address and the direct path to the Dumb AP" \
    "2. logs in to the Dumb AP through the Gateway (that path works) to look inside" \
    "3. pings it directly while watching from inside, names the cause" \
    "4. backup first, then the fix — every change reverts by itself unless confirmed" \
    "Everything is written to $(rel "$DATA")/DumbAP_<hostname>/lantest/"
  say ""
  _dap="$(awk 'NR==1{print $1}' "$HOSTS" ./roaming-hosts.txt 2>/dev/null | head -n1 || true)"
  ask AP_IP "Dumb AP address" "${_dap:-192.168.1.2}" v_ip
  ask GW_IP "Gateway address (this computer's default gateway)" "$(my_gw || true)" v_ip
  # shellcheck disable=SC2153  # GW_IP comes from ask/preset
  AP="$AP_IP" GW="$GW_IP"
  # separate session sockets: through the Gateway (jm-) vs. direct over the cable (dm-) — never mixed
  # shellcheck disable=SC2086
  jsh() { ssh $SSHB -o ControlMaster=auto -o "ControlPath=$_tmp/jm-%C" -o ControlPersist=900 \
            -o "ProxyCommand=ssh -S $_tmp/gw.sock -W %h:%p root@$GW" "root@$AP" "$@"; }
  # shellcheck disable=SC2086
  dsh() { ssh $SSHB -o ControlMaster=auto -o "ControlPath=$_tmp/dm-%C" -o ControlPersist=900 -o ConnectTimeout=5 "root@$AP" "$@"; }
  drop_jm() { for _cm in "$_tmp"/jm-*; do [ -S "$_cm" ] && ssh -o ControlPath="$_cm" -O exit x >/dev/null 2>&1; done; true; }
  direct_ok() { pingq "$AP" 2 && pingq "$AP" 2 && ssh_answers "$AP"; }    # two ping rounds + SSH, no flukes

  _if="$(if_to "$AP" || true)"; _me="$(ip_on "$_if" || true)"; _me="${_me%/*}"; _mac="$(mac_of "$_if" || true)"
  lt "Roamer v$VERSION lantest $(date) — Dumb AP $AP, Gateway $GW"
  lt "computer: os=$OS if=$_if ip=$_me mac=$_mac default-gw=$(my_gw || true)"
  d_ping=fail; pingq "$AP" && d_ping=ok
  d_ssh=fail; ssh_answers "$AP" && d_ssh=ok
  g_ping=fail; pingq "$GW" && g_ping=ok
  _arp="$(arp_of "$AP" || true)"
  lt "direct: ping-AP=$d_ping ssh-AP=$d_ssh ping-GW=$g_ping arp-AP: $_arp"
  { echo "--- computer addresses/routes"; ip addr 2>/dev/null || ifconfig 2>/dev/null; ip route 2>/dev/null || netstat -rn 2>/dev/null; } >> "$LT"
  box "This computer" "cable interface ${_if:-?} · address ${_me:-none} · MAC ${_mac:-?}" \
    "ping Gateway $GW: $g_ping · ping Dumb AP $AP: $d_ping · SSH Dumb AP: $d_ssh" \
    "its ARP entry for $AP: ${_arp:-none}"
  if [ "$d_ping" = ok ] && [ "$d_ssh" = ok ]; then
    CH=Report; step "Report" final; sayc "${GR}${B}✓  The Dumb AP answers directly on this cable${N}"
    say ""; say "  Saved: $(rel "$LT")"; return 0
  fi
  [ -n "$_me" ] || wrn "this computer has no IPv4 address on that cable — DHCP doesn't get through either"
  pause

  CH=Measure; step "Inside the Dumb AP — through the Gateway"
  say "  Log in to the ${B}Gateway${N} ($GW) first — take your time, nothing times out:"
  # shellcheck disable=SC2086
  if ! ssh $SSHB -o ControlMaster=yes -o "ControlPath=$_tmp/gw.sock" -o ControlPersist=1800 -fN "root@$GW"; then
    bad "could not log in to the Gateway $GW"; lt "gateway login failed"; return 1; fi
  okl "Gateway: logged in"
  say "  Now the ${B}Dumb AP${N} ($AP), through the Gateway:"
  if ! jsh 'cat > /tmp/roaming-setup.sh && chmod +x /tmp/roaming-setup.sh' < "$0" 2>>"$LT"; then
    bad "can't reach the Dumb AP through the Gateway either — details in $(rel "$LT")"; return 1; fi
  okl "Dumb AP: logged in"
  b="$(jsh "sh /tmp/roaming-setup.sh lanprobe '$_me' '$_mac'" 2>&1 || true)"
  say "  ${D}pinging $AP directly from this computer while watching from inside …${N}"
  pingq "$AP" 6 || true
  a="$(jsh "sh /tmp/roaming-setup.sh lanprobe '$_me' '$_mac'" 2>&1 || true)"
  { echo "--- lanprobe before"; echo "$b"; echo "--- lanprobe after"; echo "$a"
    echo "--- diag"; jsh 'sh /tmp/roaming-setup.sh diag' 2>&1 || true; } >> "$LT"
  _gain=""; _gport=""
  for _p in $(printf '%s\n' "$a" | sed -n 's/^port=\([^ ]*\).*/\1/p'); do
    _ra="$(printf '%s\n' "$a" | sed -n "s/^port=$_p .* rx=\([0-9]*\).*/\1/p")"
    _rb="$(printf '%s\n' "$b" | sed -n "s/^port=$_p .* rx=\([0-9]*\).*/\1/p")"
    _d=$(( ${_ra:-0} - ${_rb:-0} )); _gain="$_gain $_p:+$_d"; [ "$_d" -lt 2 ] || _gport="$_gport $_p"
  done
  # now the Dumb AP's name is known: its own folder takes the test (and the backup below)
  _lh="$(kv "$a" host)"; LTD="$(rdir DumbAP "${_lh:-$AP}")"; mkd "$LTD/lantest"
  mv "$LT" "$LTD/lantest/${TS}.txt"; LT="$LTD/lantest/${TS}.txt"; rmdir "$DATA/lantest" 2>/dev/null || true
  _ng="$(kv "$a" neigh)"; _wanbr="$(kv "$a" wanbr)"; _wcar="$(kv "$a" wancarrier)"
  _wc="$(kv "$a" wanconduit)"; _lc="$(kv "$a" lanconduit)"
  _nmac="$(printf '%s' "$_ng" | sed -n 's/.*lladdr \([0-9a-fA-F:]*\).*/\1/p' | tr 'A-F' 'a-f')"
  _flux=""; [ -z "$_nmac" ] || [ -z "$_mac" ] || [ "$_nmac" = "$(echo "$_mac" | tr 'A-F' 'a-f')" ] || _flux="$_nmac"
  lt "measured: rx-gain:$_gain neigh='$_ng' wanbr=$_wanbr wancarrier=$_wcar conduits wan=$_wc lan=$_lc flux=$_flux"
  box "Measured inside the Dumb AP" \
    "frames its processor got per port   $_gain   (6 pings)" \
    "it knows this computer as           ${_ng:-nothing}" \
    "WAN port inside the LAN bridge      ${_wanbr:-no}$([ -n "$_wanbr" ] && echo " · cable in it: $([ "$_wcar" = 1 ] && echo yes || echo no) · links: WAN@$_wc, LAN@$_lc")"
  [ -z "$_flux" ] || { wrn "the Dumb AP has this computer's address $_me on another of its network cards ($_flux) —"
    say "    a second card on the Gateway's network answers for the same IP. Unplug/disable it for clean results."; }
  CAUSE=""
  if [ -n "$_wanbr" ]; then
    CAUSE="wanbr"
    VERDICT="WAN is bridged into the LAN — the Dumb AP's own replies to LAN ports get lost"
  elif [ -n "$_gport" ]; then VERDICT="this computer's frames reach the Dumb AP, but its answers don't get back"
  elif [ -n "$(printf '%s' "$_gain" | tr -d ' ')" ]; then VERDICT="this computer's frames never reach the Dumb AP itself"
  else VERDICT="could not read the Dumb AP's port counters"; fi
  lt "verdict: $VERDICT"
  pause

  CH=Fix
  if [ "$CAUSE" = wanbr ]; then
    step "Found it"
    _c1="The Gateway cable is in the Dumb AP's WAN port, and WAN is a member of its LAN bridge"
    [ "$_wcar" = 1 ] || _c1="The Dumb AP's WAN port is a member of its LAN bridge (no cable in it right now)"
    box "Cause" \
      "$_c1" \
      "(set by an earlier Roamer run; versions up to 7.4 kept it — 7.5 removes it)." \
      "WAN (@$_wc) and the LAN ports (@$_lc) reach the processor over different links. The" \
      "Dumb AP passes traffic between them (so your internet works), but its OWN answers" \
      "to devices on the LAN ports get lost — measured: your pings arrived, no reply left." \
      "Wi-Fi and the Gateway reach it because they don't use that LAN-port path."
    box "Fix" \
      "1. backup of the Dumb AP into this folder" \
      "2. take WAN out of its LAN bridge — reverts by itself in 5 min unless confirmed" \
      "3. YOU move the Gateway cable from its WAN port to a free LAN port (not this one)" \
      "4. this computer confirms over its cable once the Gateway answers on the LAN port"
  else
    step "Fixes to try"
    say "  No configuration fault found. Next: clear tables → restart its network → reboot,"
    say "  re-testing after each."
  fi
  say ""
  BKP=""
  unset _bk; choose _bk "Save a full backup of the Dumb AP into this folder first?" yes \
    "yes|yes — $(rel "$LTD")/backups/${TS}_$(safe_name "$AP")_backup.tar.gz (restore: sysupgrade -r <file>)" "no|no"
  if [ "$_bk" = yes ]; then
    mkd "$LTD/backups"; BKP="$LTD/backups/${TS}_$(safe_name "$AP")_backup.tar.gz"
    if jsh 'sysupgrade -b -' > "$BKP" 2>>"$LT" && gzip -t "$BKP" 2>/dev/null; then chmod 600 "$BKP"; okl "backup saved: $(rel "$BKP")"
    else bad "backup failed — stopping before any change"; lt "backup failed"; return 1; fi
  fi
  FIXED=""
  if [ "$CAUSE" = wanbr ]; then
    unset _go; choose _go "Apply the fix now?" yes "yes|yes" "no|no — leave it as it is"
    if [ "$_go" = yes ]; then
      _r="$(jsh "sh /tmp/roaming-setup.sh unbridge '$_wanbr' 300 '$GW'" 2>&1 || true)"; lt "unbridge: $_r"
      drop_jm
      step "Move the Gateway cable now"
      box "Now" "1. Move the Gateway cable from the Dumb AP's WAN port to a free LAN port" \
                "   (not the one this computer is on). Exactly one cable between them." \
                "2. Leave this computer where it is — it confirms by itself over its cable." \
                "Not confirmed within 5 min → it reverts to how it was (WAN bridged)."
      say ""
      _t=0; _lm=""; _st=""
      while [ $_t -lt 290 ]; do
        if ssh_answers "$AP"; then
          [ -n "$_lm" ] || say "  ${D}$AP answers on this cable — confirming (Dumb AP password) …${N}"
          _m="$(dsh 'sh /tmp/roaming-setup.sh confirm' 2>&1)" || true
          [ "$_m" = "$_lm" ] || printf '%s\n' "$_m" | while IFS= read -r l; do [ -z "$l" ] || out "    $l"; done
          _lm="$_m"
          _st="$(dsh 'sh /tmp/roaming-setup.sh state' 2>/dev/null | head -n1 || true)"
          case "$_st" in ok*) FIXED="taking WAN out of the LAN bridge (Gateway now on a LAN port)"; break;; rolled*) break;; esac
        fi
        [ $TTY = 1 ] && printf '\r%s\r  %s%ds left%s%s' "$(rep ' ' $((COLS - 1)))" "$D" $((290 - _t)) "${_st:+ · $_st}" "$N" >/dev/tty
        sleep 5; _t=$((_t+5))
      done
      [ $TTY = 1 ] && printf '\r%s\r' "$(rep ' ' $((COLS - 1)))" >/dev/tty
      lt "fix (unbridge): ${FIXED:-not confirmed — reverts} · last state: $_st"
      if [ -n "$FIXED" ] && direct_ok; then okl "the Dumb AP answers on this cable"; else [ -n "$FIXED" ] || bad "not confirmed — it reverts to how it was"; fi
    fi
  else
    step "Fix 1 of 3 — clear the Dumb AP's address tables"
    jsh 'ip neigh flush dev br-lan; bridge fdb flush dev br-lan 2>/dev/null; true' >/dev/null 2>&1 || true
    sleep 3; if direct_ok; then FIXED="clearing the address tables"; okl "works now"; else bad "still no answer"; fi
    lt "fix1 (flush): ${FIXED:-no}"
    if [ -z "$FIXED" ]; then
      step "Fix 2 of 3 — restart the Dumb AP's network"
      say "  Rebuilds its bridge and switch setup (Wi-Fi and LAN drop for ~20 s)."
      unset _go; choose _go "Restart its network now?" yes "yes|yes" "skip|skip"
      if [ "$_go" = yes ]; then
        jsh '(sleep 1; /etc/init.d/network restart) </dev/null >/dev/null 2>&1 &' 2>/dev/null || true; drop_jm
        say "  ${D}waiting ~30 s …${N}"; sleep 30
        if direct_ok; then FIXED="restarting its network"; okl "works now"; else bad "still no answer"; fi
      fi
      lt "fix2 (network restart): ${FIXED:-no/${_go:-}}"
    fi
    if [ -z "$FIXED" ]; then
      step "Fix 3 of 3 — reboot the Dumb AP"
      unset _go; choose _go "Reboot it now (~2 min offline)?" yes "yes|yes" "skip|skip"
      if [ "$_go" = yes ]; then
        _u0="$(jsh 'cut -d. -f1 /proc/uptime' 2>/dev/null || echo 0)"
        jsh 'reboot' >/dev/null 2>&1 || true; drop_jm
        say "  ${D}waiting for it to come back (up to 4 min) …${N}"; sleep 45
        _t=0; _u1=""; while [ $_t -lt 200 ]; do
          _u1="$(jsh 'cut -d. -f1 /proc/uptime' 2>/dev/null || true)"; [ -z "$_u1" ] || break; sleep 10; _t=$((_t+10)); done
        if [ -n "$_u1" ] && [ "${_u0:-0}" -gt 0 ] && [ "$_u1" -lt "$_u0" ]; then
          okl "it rebooted (up ${_u1}s)"; if direct_ok; then FIXED="rebooting it"; okl "works now"; else bad "still no answer"; fi
        else bad "it did not reboot (or isn't back yet) — nothing concluded"; fi
        lt "fix3 (reboot): uptime $_u0 → ${_u1:-?} · ${FIXED:-no}"
      fi
    fi
  fi

  CH=Report; step "Report" final
  if [ -n "$FIXED" ]; then sayc "${GR}${B}✓  The Dumb AP answers on this cable now${N}"
  else sayc "${RE}${B}✗  Still no direct answer${N}"; fi
  say ""
  box "Result" "cause   $VERDICT" "fix     ${FIXED:-none applied / not confirmed}" \
    "folder  $(rel "${LTD:-$DATA}")/" "files   ${LT#"${LTD:-$DATA}"/}${BKP:+ · ${BKP#"$LTD"/}}"
  say ""
  [ -n "$FIXED" ] || say "  Send ${B}$(rel "$LT")${N} — it holds everything measured."
  lt "result: ${FIXED:-not fixed}"
  [ -n "$FIXED" ]
}

ws_main() {
  WHO="computer"; chapters computer; CH=Connect
  command -v ssh >/dev/null || die "ssh client not found"
  _tmp="$(mktemp -d)"; RDIR=""; BKF=""; RCF=""; LOGB=""
  : > "$_tmp/ssh_config"     # stays empty unless you choose "through the Gateway"
  SSHB="-F $_tmp/ssh_config -o UserKnownHostsFile=$_tmp/known_hosts -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
  # one multiplexed session PER HOST (%C) — a session to the old address must never answer for the new one
  SSHO="$SSHB -o ControlMaster=auto -o ControlPath=$_tmp/cm-%C -o ControlPersist=300 -o ConnectTimeout=8"
  SSHO="$SSHO -o ServerAliveInterval=5 -o ServerAliveCountMax=6"
  PAIRF=""; APSTATE=""; W_IP=""; W_OLD="-"; W_CAB=""
  trap 'for _cm in "$_tmp"/cm-* "$_tmp"/jm-* "$_tmp"/dm-* "$_tmp"/gw.sock; do [ -S "$_cm" ] && ssh -o ControlPath="$_cm" -O exit x >/dev/null 2>&1; done; rm -rf "$_tmp"
        if [ -n "$LOGTMP" ] && [ -f "$LOGTMP" ]; then mv "$LOGTMP" "${LOGTMP%.log.part}_err.log"; echo "log saved: ${LOGTMP%.log.part}_err.log" >&2; fi' EXIT
  # shellcheck disable=SC2086
  rsh() { ssh $SSHO "root@$ROUTER" "$@"; }

  ACTION="${ACTION:-}"
  case "${1:-}" in
    "") ;;
    setup|lantest|report|state|status|diag|pair|confirm|undo|help) ACTION="$1" ;;
    -h|--help) ACTION=help ;;
    *) die "unknown command '$1' — run ./roaming-setup.sh help" ;;
  esac
  DIRECT=0; [ -z "$ACTION" ] || DIRECT=1          # a command on the command line runs once, then exits
  [ "$DIRECT" = 1 ] || welcome
  while :; do
    [ -n "$ACTION" ] || home_menu
    _rc=0
    case "$ACTION" in
      quit)    return 0 ;;
      setup)   ws_setup; return $? ;;
      lantest) lantest || _rc=$? ;;
      help)    help_screen ;;
      *)       ws_tool "$ACTION" || _rc=$? ;;
    esac
    { [ "$DIRECT" = 0 ] && [ $TTY = 1 ]; } || return $_rc
    pause; ACTION=""
  done
}

connect_router() {   # asks for the router (once per session) and opens the SSH session
  [ -z "${CONNECTED:-}" ] || return 0
  WHO="computer"; chapters "${CHAPTERS:-computer}"; CH=Connect
  while :; do
    step "Router"
    ask ROUTER "IP address of the router (as seen from this computer)" "192.168.1.1" v_addr
    say "  ${D}connecting to root@$ROUTER …${N}"
    if rsh true 2>"$_tmp/err"; then break; fi
    # cabled straight to it? reach it over IPv6 link-local — works with any (or no) IPv4 settings
    _ll=""; case "$ROUTER" in *%*) ;; [Ff][Ee]80:*) _ll="$ROUTER";;
      *) _ll="$(hosts_get "$ROUTER" 3)";; esac
    _z=""
    if [ -n "$_ll" ]; then say "  ${D}trying $_ll over the cable (IPv6 link-local) …${N}"; _z="$(try_ll "$_ll" || true)"; fi
    if [ -z "$_z" ]; then
      say "  ${D}looking for routers straight on this computer's cables (IPv6 link-local) …${N}"
      _c="$(discover_ll || true)"
      case "$(printf '%s\n' "$_c" | grep -c .)" in
        0) ;;
        1) _z="$_c" ;;
        *) set --; for _a in $_c; do set -- "$@" "$_a|$_a"; done; unset _pick
           choose _pick "Several routers answer on this computer's cables — which one?" "${_c%%
*}" "$@"; _z="$_pick" ;;
      esac
    fi
    if [ -n "$_z" ]; then
      _was="$ROUTER"; ROUTER="$_z"
      if _id="$(rsh 'echo "$(uci -q get system.@system[0].hostname) · $(cat /tmp/sysinfo/model 2>/dev/null)"' 2>"$_tmp/err")"; then
        okl "$_was did not answer — but '$_id' answers on the cable at $_z (link-local)"
        unset _use; [ $TTY = 1 ] || _use=no      # unattended: never switch to another router by itself
        choose _use "Set up this router?" yes "yes|yes — it is the one (reached over the cable)" "no|no — back"
        [ "$_use" = yes ] && break
        for _cm in "$_tmp"/cm-*; do [ -S "$_cm" ] && ssh -o ControlPath="$_cm" -O exit x >/dev/null 2>&1; done
      fi
      ROUTER="$_was"
    fi
    cant_reach "$ROUTER" "$(cat "$_tmp/err")"
    [ $TTY = 1 ] || die "cannot SSH to root@$ROUTER: $(tail -n1 "$_tmp/err")"   # unattended: no endless retry
    unset _nx
    choose _nx "What now?" retry "retry|retry (after fixing the wiring)" "change|use another IP address" \
      "gw|go through the Gateway — log in to it, then hop on to $ROUTER" "quit|quit"
    # shellcheck disable=SC2154
    case "$_nx" in
      change) unset ROUTER;;
      gw) unset _gwj; ask _gwj "Gateway address (as seen from this computer)" "$(my_gw || echo 192.168.1.1)" v_ip
          say "  Log in to the Gateway ($_gwj):"
          if ssh $SSHB -o ControlMaster=yes -o "ControlPath=$_tmp/gw.sock" -o ControlPersist=3600 -fN "root@$_gwj"; then
            printf 'Host * !%s\n  ProxyCommand ssh -S %s -W %%h:%%p root@%s\n' "$_gwj" "$_tmp/gw.sock" "$_gwj" > "$_tmp/ssh_config"
            okl "from now on every connection hops through the Gateway $_gwj"
          else bad "could not log in to the Gateway"; fi;;
      quit) exit 1;;
    esac
  done
  rsh '[ -f /etc/openwrt_release ]' || die "root@$ROUTER is not OpenWrt"
  host="$(rsh 'uci -q get system.@system[0].hostname || echo OpenWrt')"
  PREROLE="$(rsh 'if [ "$(uci -q get dhcp.lan.ignore)" = 1 ]; then echo DumbAP; elif [ -f /etc/roaming-setup.pair ]; then echo Gateway; else echo Router; fi' 2>/dev/null || echo Router)"
  set_paths "$(rdir "$PREROLE" "$host")"
  CONNECTED=1
}

set_paths() {   # set_paths <router dir> — where this run's files go
  RDIR="$1"
  BKF="$RDIR/backups/${TS}_$(safe_name "$ROUTER")_backup.tar.gz"
  RCF="$RDIR/recovery/${TS}_RECOVERY.txt"
  LOGB="$RDIR/logs/${TS}"
}

home_menu() {
  WHO="computer"; CHN="Home"; CHE="1"; CH=Home
  step "What do you want to do?"
  [ -z "${CONNECTED:-}" ] || say "  ${D}router: root@$ROUTER ($host)${N}"; [ -z "${CONNECTED:-}" ] || say ""
  unset ACTION
  choose ACTION "Choose:" setup \
    "setup|Set up a router — the Gateway first, then each Dumb AP" \
    "lantest|LAN-port test — this computer is cabled to a Dumb AP that doesn't answer" \
    "report|Report — what is set up on a router" \
    "state|State — one line: where a Dumb AP switch-over stands" \
    "status|Status — a Dumb AP's switch-over log, monitoring" \
    "diag|Diagnostics — what a Dumb AP's LAN ports and bridge see" \
    "pair|Pairing code — show the Gateway's code again" \
    "confirm|Confirm — confirm a Dumb AP switch-over by hand" \
    "undo|Undo — restore a router to how it was before the last Roamer run (reboots)" \
    "help|Help — commands, variables, files" \
    "quit|Quit"
}

help_screen() {
  WHO="computer"; CHN="Home"; CHE="1"; CH=Home
  step "Help"
  box "Commands  (./roaming-setup.sh <command> runs one directly)" \
    "setup     set up a router (default)       lantest  cabled to a Dumb AP, no answer" \
    "report    what is set up on a router      state    Dumb AP switch-over, one line" \
    "status    switch-over log, monitoring     diag     Dumb AP LAN-side view" \
    "pair      Gateway's pairing code again    confirm  confirm a switch-over by hand" \
    "undo      restore the pre-run snapshot    help     this screen"
  box "Files: $(rel "$DATA")/  (one folder per router, mode 600, git-ignored)" \
    "Gateway_<host>/backups/<time>_<ip>_backup.tar.gz   full backup (sysupgrade -r)" \
    "Gateway_<host>/logs/<time>.ok.log | .err.log        session log" \
    "Gateway_<host>/pairing.txt                          pairing code (Wi-Fi password!)" \
    "DumbAP_<host>/recovery/<time>_RECOVERY.txt         how to get it back" \
    "DumbAP_<host>/lantest/<time>.txt                    LAN-port test" \
    "hosts.txt                                          known Dumb APs (link-local)"
  say "  Every prompt can be preset with a variable (ROUTER, ROLE, SSID, …): see the script header"
  say "  and README.md. Docs: docs/ in the project."
}

ws_tool() {   # run one router sub-command from the computer
  CHAPTERS=tool; connect_router
  CHN="Connect Run"; CHE="1 1"; CH=Run
  rsh 'cat > /tmp/roaming-setup.sh && chmod +x /tmp/roaming-setup.sh' < "$0"
  case "$1" in
    report)
      step "Report — $host" final
      _rep="$(rsh 'sh /tmp/roaming-setup.sh report' 2>&1 || true)"
      set --; while IFS='|' read -r _k _v; do [ -n "$_k" ] && set -- "$@" "$(printf '%-10s %s' "$_k" "$_v")"; done <<EOF
$_rep
EOF
      box "What is set up on $ROUTER" "$@" ;;
    undo)
      step "Undo — $host"
      _u="$(rsh 'readlink /etc/roaming-setup.bak/restore-latest.sh 2>/dev/null' || true)"
      [ -n "$_u" ] || { bad "no Roamer snapshot on $host — nothing to undo"; return 1; }
      say "  Restores ${B}$(dirname "$_u")${N} (Wi-Fi, usteer, hostname; on a Dumb AP also network + DHCP)"
      say "  and reboots $host. On a Dumb AP it returns to its old address — see its _RECOVERY.txt."
      confirm "Restore and reboot $host now?" || { say "  nothing changed"; return 0; }
      rsh 'sh /tmp/roaming-setup.sh undo' || true
      okl "restoring — $host reboots now" ;;
    *)
      step "$1 — $host" final
      rsh "sh /tmp/roaming-setup.sh $1" ;;
  esac
}

ws_setup() {
  connect_router
  WHO="computer"; chapters computer; CH=Backup

  mkd "$RDIR/logs"; LOGTMP="$LOGB.log.part"; : > "$LOGTMP"; chmod 600 "$LOGTMP"
  lg "Roamer v$VERSION — $(date) — router $ROUTER ($host)"

  pf="$(newest_pair)"
  if [ -n "$pf" ] && ! isset PAIR && ! isset ROLE; then
    step "What is $ROUTER ($host)?"
    say "  A pairing code from an earlier Gateway run is in this folder: ${B}$pf${N}"; say ""
    choose _kind "Is this router a Dumb AP that should join that Gateway?" ap \
      "ap|yes — a Dumb AP: use the pairing code (SSID, password, … are filled in)" \
      "gateway|no — this is the Gateway (or I'll answer everything myself)"
    # shellcheck disable=SC2154  # _kind is set by choose() via eval
    if [ "$_kind" = ap ]; then PAIR="$(cat "$pf")"; ROLE=ap; fi
  fi

  if ! isset BACKUP; then step "Backup"; wrn "$PANTS"; say ""; fi
  CH=Router
  choose BACKUP "Save a full backup of $host into this folder first?" yes \
    "yes|yes — $(rel "$BKF")  (restore: sysupgrade -r <file>; reboot)" "no|no, skip"
  if [ "$BACKUP" = yes ]; then
    mkd "$RDIR/backups"
    rsh 'sysupgrade -b -' > "$BKF" || die "backup failed"
    chmod 600 "$BKF"
    gzip -t "$BKF" 2>/dev/null || die "backup file is damaged"
    out "backup saved: $(rel "$BKF") ($(wc -c < "$BKF") bytes)"
  fi

  rsh 'cat > /tmp/roaming-setup.sh && chmod +x /tmp/roaming-setup.sh' < "$0"
  # presets travel in a 0600 file, never on the command line (the Wi-Fi password would show up in `ps`)
  { echo "export WS=1 BACKUP=no NOLOG=1 COLS=$COLS"; [ -z "${NO_COLOR:-}" ] || echo "export NO_COLOR=1"
    for v in ROLE PAIR TAILSCALE BANDS COUNTRY IFACE_2G IFACE_5G CH2 CH5 HT2 HT5 TXP2 TXP5 SSID KEY ENC HIDDEN MD \
             ROAM_DBM NAME AP_ADDR AP_IP GW_IP NETMASK BRIDGE_WAN MGMT_IP TS_ACCEPT CONFIRM_TIMEOUT FORCE_AP \
             DRY_RUN ASSUME_YES GUARD PING_HOST CLEAR WIFI_WAIT MONITORING MON_PORT; do
      if isset "$v"; then echo "export $v=$(squote "$(getv "$v")")"; fi
    done; } | rsh 'umask 077; cat > /tmp/roaming-env'
  tflag="-t"; [ $TTY = 1 ] || tflag="-T"
  # shellcheck disable=SC2086
  { ssh $tflag $SSHO "root@$ROUTER" "cd /tmp && . ./roaming-env && rm -f ./roaming-env && TERM=${TERM:-xterm} ./roaming-setup.sh"; echo $? > "$_tmp/rc"; } 2>&1 | tee "$_tmp/raw"
  rc="$(cat "$_tmp/rc" 2>/dev/null || echo 1)"
  sed "s/${ESC}\[[0-9;]*[A-Za-z]//g; s/\r\$//; $HIDE" "$_tmp/raw" >> "$LOGTMP"

  code="$(grep -o 'ROAM1:[A-Za-z0-9+/=]*' "$_tmp/raw" | tail -n1 || true)"
  GWFAIL="$(sed "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$_tmp/raw" | tr -d '\r' | grep -o 'FAIL: .*' | tail -n1 | sed 's/ — rolling back.*//' || true)"
  role="${ROLE:-}"; gw_ok=0; grep -q "Gateway is set up successfully" "$_tmp/raw" && { gw_ok=1; role=gateway; }
  if grep -q "Gateway is set up successfully" "$_tmp/raw" && [ -n "$code" ]; then
    PAIRF="$RDIR/pairing.txt"; printf '%s\n' "$code" > "$PAIRF"; chmod 600 "$PAIRF"
    lg "pairing code saved: $PAIRF"
  fi
  if grep -q -- '----- RECOVERY CARD -----' "$_tmp/raw"; then
    mkd "$RDIR/recovery"
    sed -n '/----- RECOVERY CARD -----/,/----- END -----/p' "$_tmp/raw" | sed "s/${ESC}\[[0-9;]*[A-Za-z]//g; s/\r\$//" > "$RCF"
    chmod 600 "$RCF"; lg "recovery card saved: $(rel "$RCF")"
  fi
  rhost=""; [ "$rc" = 0 ] && [ $gw_ok = 1 ] && rhost="$ROUTER"
  sw="$(sed "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$_tmp/raw" | tr -d '\r' | grep -o 'ROAMER-SWITCH .*' | tail -n1 || true)"
  if [ -n "$sw" ] && [ "$rc" = 0 ]; then
    # shellcheck disable=SC2086
    set -- $sw; role=ap
    if wait_dumb_ap "$2" "$3" "${4:-lan}" "${5:--}" "${6:-}"; then rhost="$2"; wait_monitoring "$2"; else rc=1; rhost=""; fi
  fi
  if [ "$DRY_RUN" = 1 ]; then st=err; [ "$rc" = 0 ] && st=ok; mv "$LOGTMP" "$LOGB.dryrun_$st.log"; LOGTMP=""; echo "log saved: $(rel "$LOGB").dryrun_$st.log"; return "$rc"; fi
  st=err; [ "$rc" = 0 ] && st=ok
  res="$st"; [ "$st" = ok ] && [ -z "$rhost" ] && res=none     # finished without changing anything
  # what is set up now — and the router's final folder: Role_<hostname as it is now>
  REP=""; [ -z "$rhost" ] || REP="$(ssh $SSHO -o BatchMode=yes -o ConnectTimeout=5 "root@$rhost" 'sh /tmp/roaming-setup.sh report' 2>/dev/null || true)"
  _fh="$(printf '%s\n' "$REP" | sed -n 's/^hostname|\([^ ]*\).*/\1/p')"
  _fr="$PREROLE"; [ "$res" != ok ] || { [ "$role" = ap ] && _fr=DumbAP || _fr=Gateway; }
  _nd="$(rdir "$_fr" "${_fh:-$host}")"
  if [ "$_nd" != "$RDIR" ]; then
    _old="$RDIR"; relocate "$_old" "$_nd"
    LOGTMP="$_nd${LOGTMP#"$_old"}"; [ -z "$PAIRF" ] || PAIRF="$_nd${PAIRF#"$_old"}"
    _b="$BKF"; _r="$RCF"; set_paths "$_nd"; BKF="$_nd${_b#"$_old"}"; RCF="$_nd${_r#"$_old"}"
  fi
  final_report "$res" "$role" "$rhost"
  if [ "$st" = ok ] && [ "$role" = gateway ] && [ -n "$PAIRF" ]; then
    say ""; say "  Pairing code (also in ${PAIRF#./}):"; say "$code"
  fi
  mv "$LOGTMP" "$LOGB.${st}.log"; LOGTMP=""
  return "$rc"
}

if ! is_openwrt; then ws_main "${1:-}"; exit $?; fi

# ================================================================ ROUTER SIDE
sections() { uci show "$1" 2>/dev/null | sed -n "s/^$1\.\([^.=]*\)=$2\$/\1/p"; }
iget() { uci -q get "wireless.$1.$2" || true; }
health() { ip -4 route show default 2>/dev/null | grep -q . && ping -c1 -W2 "$PING_HOST" >/dev/null 2>&1; }
is_private() { case "$1" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0;; esac; return 1; }
cval() { /bin/ipcalc.sh "$1" ${2:+"$2"} ${3:+"$3"} 2>/dev/null | sed -n "s/^$4=//p"; }
jf() { jsonfilter -s "$1" -e "$2" 2>/dev/null | head -n1; }
randhex4() { dd if=/dev/urandom bs=16 count=1 2>/dev/null | md5sum | cut -c1-4; }
radio_if() { _i="$(ubus call network.wireless status 2>/dev/null | jsonfilter -e "@.$1.interfaces[*].ifname" 2>/dev/null | head -n1 || true)"; echo "${_i:-$1}"; }
opchan() { iwinfo "$(radio_if "$1")" info 2>/dev/null | sed -n 's/.*Channel: \([0-9][0-9]*\).*/\1/p' | head -n1; }
conduit_of() { ip -o link show "$1" 2>/dev/null | sed -n 's/^[0-9]*: [^@:]*@\([^:]*\):.*/\1/p'; }
brsec() { uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.name='br-lan'\$/\1/p" | head -n1; }
own_ip() { ip -4 -o addr show 2>/dev/null | awk -v a="$1" '{split($4,x,"/"); if (x[1]==a) f=1} END{exit !f}'; }

# package manager
if command -v apk >/dev/null 2>&1; then PM=apk; elif command -v opkg >/dev/null 2>&1; then PM=opkg; else PM=none; fi
case "${RS_PM:-}" in apk|opkg) PM="$RS_PM";; esac      # RS_PM: override for testing
# exact package names only: with apk, wpad-basic-* *provides* "hostapd"/"wpa-supplicant", so
# `apk info -e hostapd` is true on a basic build — that once made Roamer skip the full-wpad swap
pkg_has()   { case $PM in
                apk)  grep -qx "P:$1" /lib/apk/db/installed 2>/dev/null || apk list --installed 2>/dev/null | grep -q "^$1-[0-9]";;
                opkg) opkg list-installed "$1" 2>/dev/null | grep -q "^$1 ";;
                *) return 1;; esac; }
wpad_pkgs() { { { sed -n 's/^P://p' /lib/apk/db/installed || true; }; { apk list --installed 2>/dev/null | sed 's/-[0-9].*//' || true; }; { sed -n 's/^Package: //p' /usr/lib/opkg/status || true; }; } 2>/dev/null | grep -E '^(wpad|hostapd)' | sort -u | tr '\n' ' '; }
# does this hostapd binary know 802.11v? Its config parser holds the literal "bss_transition" only when
# 802.11v is compiled in (works on /proc/<pid>/exe too — i.e. on the hostapd that is RUNNING)
bin_wnm() { [ -r "$1" ] && tr '\000' '\n' < "$1" 2>/dev/null | grep -qx bss_transition; }
pkg_avail() { case $PM in apk) apk search "$1" 2>/dev/null | grep -q "^$1-[0-9]";; opkg) opkg list "$1" 2>/dev/null | grep -q "^$1 - ";; *) return 1;; esac; }
pkg_update(){ case $PM in apk) apk update;; opkg) opkg update;; *) return 1;; esac; }
pkg_add()   { case $PM in apk) apk add "$@";; opkg) opkg install "$@";; *) return 1;; esac; }
pkg_del()   { case $PM in apk) apk del "$@";; opkg) opkg remove "$@";; *) return 1;; esac; }

# ---------------------------------------------------------------- monitoring (optional)
# LuCI Statistics graphs of Wi-Fi clients per AP, all viewable on the Gateway. Asked before the plan, applied
# only after roaming is verified; nothing here can stop or roll back roaming: every failure is a warning.
#
# UCI names, checked against openwrt/luci, applications/luci-app-statistics:
#   root/etc/config/luci_statistics          sections collectd, collectd_iwinfo, collectd_network, collectd_rrdtool
#   root/usr/libexec/stat-genconfig          collectd_network_listen / collectd_network_server (host, port); Hostname
#   htdocs/.../view/statistics/plugins/network.js  the same section types and option names in LuCI's form
#   root/etc/init.d/luci_statistics          `backup` command; collectd_rrdtool.backup + DataDir enable it
# Bare collectd (Dumb AP), checked against openwrt/packages, utils/collectd/files/:
#   collectd.uci, collectd.init              globals, plugin 'iwinfo'/'network'/'rrdtool', network_server (host, port)
#
# A Dumb AP only sends, so it gets bare collectd instead of luci-app-statistics, which hard-depends on rrdtool1,
# librrd1 and collectd-mod-rrdtool even with RRD output off. Feed sizes (OpenWrt 24.10, aarch64_cortex-a53, packages
# a router with LuCI doesn't have yet): 133 KiB download / 540 KiB installed, against 347 KiB / 1920 KiB. Both use
# collectd's default 30 s interval, which the Gateway's RRD files expect. A router that already has
# luci-app-statistics keeps it: its init script owns collectd's config there.
MON_DEFPORT=25826
MON_CRON='0 * * * * service luci_statistics backup'
MON_GW_PKGS="luci-app-statistics collectd-mod-iwinfo collectd-mod-network"
MON_AP_PKGS="collectd collectd-mod-iwinfo collectd-mod-network"
# what those pull in beyond a stock router: the list sized by the space check
MON_GW_ALL="luci-app-statistics collectd libltdl7 rrdtool1 librrd1 collectd-mod-rrdtool collectd-mod-iwinfo collectd-mod-network collectd-mod-cpu collectd-mod-memory collectd-mod-interface collectd-mod-load"
MON_AP_ALL="collectd libltdl7 collectd-mod-iwinfo collectd-mod-network"
# Space check, KiB on the overlay. Reserve = room left after installing: on the Gateway the hourly RRD archive
# (/etc/luci_statistics/rrdbackup.tgz, a few hundred KiB with several APs). Fallback = used when the package
# manager gives no sizes: the feed sizes above rounded up, plus the reserve. No LuCI yet = what
# luci-app-statistics pulls in on top of that (measured from the same feed: 4450 - 1920 KiB).
MON_GW_RESERVE=1024; MON_AP_RESERVE=256
MON_GW_FALLBACK=3072; MON_AP_FALLBACK=1024
MON_NOLUCI=2560
MON_TIMEOUT="${MON_TIMEOUT:-600}"     # seconds before a hung install is given up on

v_port() { case "$1" in ""|*[!0-9]*) echo "a port number, 1-65535"; return 1;; esac
           [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || { echo "a port number, 1-65535"; return 1; }; }
mon_state() { echo "$*" > "$MONSTATEFILE" 2>/dev/null || true; }
mon_warn()  { log "  ⚠ monitoring: $*"; }
mon_skip()  { mon_warn "$1 — skipped; roaming is not affected"; mon_state "$2|$1"; return 1; }

mon_pkg_kb() {   # KiB one package takes once installed, or nothing when the package manager doesn't say
  case $PM in
    apk)  apk info -s "$1" 2>/dev/null | awk '$2=="B"{print int($1/1024)+1; exit} $2=="KiB"{print $1+0; exit} $2=="MiB"{print $1*1024; exit}' ;;
    # opkg only reports the compressed package ("Size:", bytes): x3 is on the safe side of the installed size
    opkg) opkg info "$1" 2>/dev/null | awk '/^Size: /{print int($2*3/1024)+1; exit}' ;;
  esac
}
mon_measure() {  # sets MON_NEED (KiB needed on the overlay for what is missing) and MON_BASIS
  if [ "$ROLE" = ap ]; then _a="$MON_AP_ALL" _res=$MON_AP_RESERVE _fb=$MON_AP_FALLBACK
  else _a="$MON_GW_ALL" _res=$MON_GW_RESERVE _fb=$MON_GW_FALLBACK; fi
  _sum=0
  for _p in $_a; do
    pkg_has "$_p" && continue
    _k="$(mon_pkg_kb "$_p")"
    case "$_k" in ""|*[!0-9]*) _sum=""; break;; esac
    _sum=$((_sum + _k))
  done
  if [ -n "$_sum" ]; then MON_NEED=$((_sum + _res)); MON_BASIS="package sizes + $_res KiB reserve"
  else MON_NEED=$_fb; MON_BASIS="no package sizes available, fixed minimum"; fi
  if [ "$ROLE" != ap ] && ! pkg_has luci-base; then MON_NEED=$((MON_NEED + MON_NOLUCI)); MON_BASIS="$MON_BASIS, + LuCI"; fi
}
mon_free() { { df -k /overlay 2>/dev/null || df -k / 2>/dev/null; } | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4}'; }

mon_install() {  # installs what is missing. 0 = all there; otherwise it warned and wrote the state file
  _miss=""; for _p in $MON_PKGS; do pkg_has "$_p" || _miss="$_miss $_p"; done
  [ -n "$_miss" ] || return 0
  [ "$PM" != none ] || { mon_skip "no package manager found" skipped; return 1; }
  # a Dumb AP's network was reloaded moments ago: one retry
  pkg_update >/dev/null 2>&1 || { sleep 10; pkg_update >/dev/null 2>&1; } \
    || { mon_skip "could not update the package lists (no internet?)" failed; return 1; }
  mon_measure
  _free="$(mon_free)"
  [ -n "$_free" ] || { mon_skip "could not read the free flash space" skipped; return 1; }
  if [ "$_free" -lt "$MON_NEED" ]; then
    mon_skip "not enough flash: needs about $MON_NEED KiB ($MON_BASIS), $_free KiB free" skipped; return 1
  fi
  log "  monitoring: installing$_miss ($_free KiB free, about $MON_NEED KiB needed) …"
  # shellcheck disable=SC2086  # a list of package names
  if pkg_add $_miss >/tmp/roamer-mon-pkg.log 2>&1; then
    _bad=""; for _p in $MON_PKGS; do pkg_has "$_p" || _bad="$_bad $_p"; done
    if [ -z "$_bad" ]; then rm -f /tmp/roamer-mon-pkg.log; return 0; fi
  else _bad="$_miss"; fi
  mon_warn "package manager: $(tail -n 2 /tmp/roamer-mon-pkg.log 2>/dev/null | tr '\n' ' ')"
  rm -f /tmp/roamer-mon-pkg.log
  # opkg isn't atomic: don't leave half an install filling the flash
  for _p in $_miss; do if pkg_has "$_p"; then pkg_del "$_p" >/dev/null 2>&1 || true; fi; done
  mon_skip "could not install:$_bad" failed; return 1
}
mon_section() {  # mon_section <config> <type> <host> <port>: exactly one section with this target, re-runs included
  _me="roamer_${2##*_}"; _other=0
  for _s in $(sections "$1" "$2"); do
    [ "$_s" != "$_me" ] || continue
    if [ "$(uci -q get "$1.$_s.host" || true)" = "$3" ] && [ "$(uci -q get "$1.$_s.port" || echo "$MON_DEFPORT")" = "$4" ]; then _other=1; fi
  done
  if [ $_other = 1 ]; then uci -q delete "$1.$_me" || true; return 0; fi    # one made by hand already does this
  uci set "$1.$_me=$2" && uci set "$1.$_me.host=$3" && uci set "$1.$_me.port=$4"
}
mon_cfg_luci() {
  _c=luci_statistics; [ -f /etc/config/$_c ] || : > /etc/config/$_c
  uci set $_c.collectd=statistics && uci set "$_c.collectd.Hostname=$MON_NAME" \
    && uci set $_c.collectd_iwinfo=statistics && uci set $_c.collectd_iwinfo.enable=1 \
    && uci set $_c.collectd_network=statistics && uci set $_c.collectd_network.enable=1 \
    && uci set $_c.collectd_rrdtool=statistics || return 1
  if [ "$ROLE" = ap ]; then
    uci set $_c.collectd_rrdtool.enable=0 && mon_section $_c collectd_network_server "$GW_IP" "$MON_PORT" || return 1
  else
    uci set $_c.collectd_rrdtool.enable=1 && uci set $_c.collectd_rrdtool.backup=1 \
      && mon_section $_c collectd_network_listen 0.0.0.0 "$MON_PORT" || return 1
  fi
  uci commit $_c || return 1
  # the luci_statistics init script writes /etc/collectd.conf; collectd must read that one
  if [ "$(uci -q get collectd.globals || true)" = globals ]; then
    uci set collectd.globals.alt_config_file=/etc/collectd.conf && uci commit collectd || return 1
  fi
}
mon_cfg_bare() {
  _c=collectd; [ -f /etc/config/$_c ] || : > /etc/config/$_c
  uci set $_c.globals=globals || return 1
  uci -q delete $_c.globals.alt_config_file || true    # collectd.init would ignore UCI if that file exists
  uci set "$_c.globals.Hostname=$MON_NAME" \
    && uci set $_c.iwinfo=plugin && uci set $_c.iwinfo.enable=1 \
    && uci set $_c.network=plugin && uci set $_c.network.enable=1 && uci set $_c.network.Forward=0 \
    && uci set $_c.rrdtool=plugin && uci set $_c.rrdtool.enable=0 \
    && mon_section $_c network_server "$GW_IP" "$MON_PORT" \
    && uci commit $_c
}
mon_cron() {     # the hourly RRD backup: RRD files live in /tmp, this limits a crash to about an hour of history
  _f=/etc/crontabs/root; mkdir -p /etc/crontabs || return 1; [ -f "$_f" ] || : > "$_f" || return 1
  if ! grep -qxF "$MON_CRON" "$_f"; then
    [ -z "$(tail -c 1 "$_f")" ] || echo >> "$_f"      # a last line without newline must not swallow ours
    echo "$MON_CRON" >> "$_f" || return 1
  fi
  /etc/init.d/cron enable 2>/dev/null; /etc/init.d/cron restart >/dev/null 2>&1
}
mon_services() { # mon_services <service>…: enable + restart; a failure is reported, the others still run
  _bad=""
  for _s; do
    if [ -x "/etc/init.d/$_s" ]; then /etc/init.d/"$_s" enable >/dev/null 2>&1 || true
      /etc/init.d/"$_s" restart >/dev/null 2>&1 || _bad="$_bad $_s"
    else _bad="$_bad $_s"; fi
  done
  [ -z "$_bad" ] || mon_warn "could not restart:$_bad — ./roaming-setup.sh status shows what is running"
}
mon_apply() {
  umask 022
  MON_NAME="${NAME:-$HOST}"
  if [ "$ROLE" = ap ] && ! pkg_has luci-app-statistics; then MON_PKGS="$MON_AP_PKGS" _be=bare
  else MON_PKGS="$MON_GW_PKGS" _be=luci; fi
  mon_state "running|installing packages"
  mon_install || return 1
  mon_state "running|configuring"
  if [ "$_be" = bare ]; then
    mon_cfg_bare || { uci revert collectd 2>/dev/null || true; mon_skip "could not write /etc/config/collectd" failed; return 1; }
    mon_services collectd
  else
    mon_cfg_luci || { uci revert luci_statistics 2>/dev/null || true; mon_skip "could not write /etc/config/luci_statistics" failed; return 1; }
    if [ "$ROLE" != ap ]; then mon_cron || mon_warn "could not set up the hourly backup in cron: history is lost on a crash or reboot"; fi
    mon_services luci_statistics collectd
  fi
  if [ "$ROLE" = ap ]; then mon_state "on|sends to $GW_IP:$MON_PORT as $MON_NAME"; log "  ✓ monitoring: sends to $GW_IP:$MON_PORT as $MON_NAME"
  else mon_state "on|listens on port $MON_PORT as $MON_NAME"; log "  ✓ monitoring: listens on port $MON_PORT as $MON_NAME (Statistics → Graphs → Wireless)"; fi
}
mon_run() {      # the step, in a subshell with a deadline: whatever happens in there, the run goes on
  [ "${MONITORING:-no}" = yes ] || return 0
  ( mon_apply ) & _mp=$!
  _dl=$(( $(date +%s) + MON_TIMEOUT ))
  while kill -0 "$_mp" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$_dl" ]; then
      kill "$_mp" 2>/dev/null || true
      mon_warn "gave up after ${MON_TIMEOUT}s — skipped; roaming is not affected"
      mon_state "failed|gave up after ${MON_TIMEOUT}s"
      break
    fi
    sleep 2
  done
  wait "$_mp" 2>/dev/null || true
  case "$(cat "$MONSTATEFILE" 2>/dev/null)" in      # the step died without saying why
    running*) mon_warn "stopped unexpectedly — roaming is not affected"; mon_state "failed|stopped unexpectedly";;
  esac
}

mon_backend() { if pkg_has luci-app-statistics; then echo luci; elif pkg_has collectd; then echo bare; fi; }
mon_targets() {  # mon_targets <config> <type> → host:port …
  for _s in $(sections "$1" "$2"); do
    printf '%s:%s ' "$(uci -q get "$1.$_s.host" || echo '?')" "$(uci -q get "$1.$_s.port" || echo "$MON_DEFPORT")"
  done
}
mon_onoff() { [ "$(uci -q get "$1" || true)" = 1 ] && echo on || echo off; }
mon_status() {   # the `status` part: what monitoring looks like on this router, per role
  echo ""; echo "== monitoring"
  _isap=0; [ "$(uci -q get dhcp.lan.ignore || true)" != 1 ] || _isap=1
  [ $_isap = 1 ] && echo "   role      Dumb AP (sender)" || echo "   role      Gateway (listener + graphs)"
  _b="$(mon_backend)"
  _ls="$(cut -d'|' -f1 "$MONSTATEFILE" 2>/dev/null || true)"; _lm="$(cut -d'|' -f2- "$MONSTATEFILE" 2>/dev/null || true)"
  [ -z "$_ls" ] || echo "   last run  $_ls${_lm:+: $_lm}"
  _pl="$MON_GW_PKGS"; [ "$_b" != bare ] || _pl="$MON_AP_PKGS"
  _pt=""; for _p in $_pl; do if pkg_has "$_p"; then _pt="$_pt $_p ✓"; else _pt="$_pt $_p ✗"; fi; done
  echo "   packages $_pt"
  if [ -z "$_b" ]; then echo "   not set up"; return 0; fi
  _run=stopped; pgrep -x collectd >/dev/null 2>&1 && _run=running
  if [ "$_b" = bare ]; then
    echo "   plugins   iwinfo $(mon_onoff collectd.iwinfo.enable) · network $(mon_onoff collectd.network.enable) · rrdtool $(mon_onoff collectd.rrdtool.enable)"
    echo "   server    $(mon_targets collectd network_server)"
    echo "   hostname  $(uci -q get collectd.globals.Hostname || echo '(system hostname)')"
  else
    echo "   plugins   iwinfo $(mon_onoff luci_statistics.collectd_iwinfo.enable) · network $(mon_onoff luci_statistics.collectd_network.enable) · rrdtool $(mon_onoff luci_statistics.collectd_rrdtool.enable) (backup $(mon_onoff luci_statistics.collectd_rrdtool.backup))"
    if [ $_isap = 1 ]; then echo "   server    $(mon_targets luci_statistics collectd_network_server)"
    else echo "   listen    $(mon_targets luci_statistics collectd_network_listen)"; fi
    echo "   hostname  $(uci -q get luci_statistics.collectd.Hostname || echo '(system hostname)')"
  fi
  echo "   collectd  $_run"
  if [ $_isap = 0 ]; then
    if grep -qxF "$MON_CRON" /etc/crontabs/root 2>/dev/null; then echo "   cron      $MON_CRON"; else echo "   cron      no hourly backup line"; fi
  fi
}
mon_report() {   # the `report` row; silent on a router that never had monitoring
  _ls="$(cut -d'|' -f1 "$MONSTATEFILE" 2>/dev/null || true)"; _lm="$(cut -d'|' -f2- "$MONSTATEFILE" 2>/dev/null || true)"
  case "$_ls" in skipped|failed) echo "monitoring|$_ls: $_lm"; return 0;; esac
  case "$(mon_backend)" in
    luci) _t="$(mon_targets luci_statistics collectd_network_listen)"
          if [ "$(uci -q get dhcp.lan.ignore || true)" = 1 ]; then echo "monitoring|sends to $(mon_targets luci_statistics collectd_network_server)"
          elif [ -n "$_t" ]; then echo "monitoring|listens on $_t· graphs: Statistics → Graphs → Wireless"; fi ;;
    bare) echo "monitoring|sends to $(mon_targets collectd network_server)" ;;
  esac
}

state_line() {   # one line for the computer: "<state> · …"
  [ -f "$STATEFILE" ] || { echo "none"; return; }
  IFS='|' read -r _st _new _dl _msg < "$STATEFILE" || true
  _left=""; case "$_dl" in ""|*[!0-9]*) ;; *) _left=" · rollback in $((_dl - $(date +%s))) s";; esac
  echo "$_st${_left}${_msg:+ · $_msg}"
}
report() {   # key|value lines describing this router's roaming setup
  _h="$(uci -q get system.@system[0].hostname || echo OpenWrt)"
  _rel="$( [ -f /etc/openwrt_release ] && . /etc/openwrt_release; echo "${DISTRIB_DESCRIPTION:-OpenWrt}" )"
  echo "router|$(cat /tmp/sysinfo/model 2>/dev/null || echo ?) · $_rel"
  _kh="$(cat /proc/sys/kernel/hostname 2>/dev/null || echo "$_h")"
  if [ "$_kh" = "$_h" ]; then echo "hostname|$_h"; else echo "hostname|$_h (running: $_kh — applies after: /etc/init.d/system reload)"; fi
  if [ "$(uci -q get dhcp.lan.ignore || true)" = 1 ]; then
    echo "role|Dumb AP — bridge only; DHCP/RA server and firewall off"
    echo "LAN|$(ip -4 -o addr show br-lan 2>/dev/null | awk '{print $4}' | tr '\n' ' ')· gateway $(uci -q get network.lan.gateway || echo DHCP)"
    [ "$(uci -q get network.wan || true)" = interface ] && echo "WAN|still configured (temporary path — removed after confirmation)"
    _m="$(uci -q get network.mgmt.ipaddr || true)"
    [ -z "$_m" ] || echo "recovery|$_m — laptop cabled to it with fixed ${_m%.*}.10/24"
    _ll="$(ip -6 -o addr show dev br-lan scope link 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    [ -z "$_ll" ] || echo "link-local|$_ll — cabled laptop, no IP settings: add %<interface>"
  else
    echo "role|Gateway — only Wi-Fi, usteer and hostname were changed"
    echo "LAN|$(ip -4 -o addr show br-lan 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
  fi
  for _s in $(sections wireless wifi-iface); do
    [ "$(iget "$_s" ieee80211r)" = 1 ] && [ "$(iget "$_s" disabled)" != 1 ] || continue
    _r="$(iget "$_s" device)"; _b="$(uci -q get "wireless.$_r.band" || echo ?)"
    _c="$(opchan "$_r" || true)"; [ -n "$_c" ] || _c="$(uci -q get "wireless.$_r.channel" || echo auto) (starting)"
    _hd=""; [ "$(iget "$_s" hidden)" = 1 ] && _hd=" hidden"
    echo "Wi-Fi $_b|ch $_c · '$(iget "$_s" ssid)'$_hd · $(iget "$_s" encryption) · MD $(iget "$_s" mobility_domain) · 802.11r/k$([ "$(iget "$_s" bss_transition)" = 1 ] && echo /v)"
  done
  _us=stopped; pgrep -x usteer >/dev/null 2>&1 && _us=running
  echo "steering|usteer $_us · steer below $(uci -q get usteer.@usteer[0].roam_trigger_snr 2>/dev/null || echo ?) dBm"
  _pk="$( { { sed -n 's/^P://p' /lib/apk/db/installed || true; }; { sed -n 's/^Package: //p' /usr/lib/opkg/status || true; }; { apk list --installed 2>/dev/null | sed 's/-[0-9].*//' || true; }; } 2>/dev/null \
         | grep -E '^(wpad|hostapd|usteer|luci-app-usteer|tailscale)' | sort -u | tr '\n' ' ')"
  [ -z "$_pk" ] || echo "packages|$_pk"
  mon_report
  _u="$(readlink /etc/roaming-setup.bak/restore-latest.sh 2>/dev/null || true)"
  [ -z "$_u" ] || echo "undo|sh $_u"
}

diag() {   # what a cable on this router sees — run it while the laptop is plugged into the Dumb AP
  echo "== $(cat /proc/sys/kernel/hostname 2>/dev/null) · $(date)"
  echo "-- br-lan addresses"; ip -o addr show dev br-lan 2>/dev/null | awk '{print "   "$3" "$4}'
  echo "-- LAN ports (carrier 1 = cable with link)"
  for _p in /sys/class/net/br-lan/brif/*; do _p="${_p##*/}"; [ "$_p" != "*" ] || continue
    echo "   $_p carrier=$(cat /sys/class/net/$_p/carrier 2>/dev/null || echo -) $(cat /sys/class/net/$_p/operstate 2>/dev/null)"; done
  echo "-- devices seen behind each port (bridge forwarding table)"
  _fdb="$(bridge fdb show br br-lan 2>/dev/null | grep -v -e permanent -e ' self' | awk '{print "   "$1" on "$3}')"
  [ -n "$_fdb" ] || _fdb="$(brctl showmacs br-lan 2>/dev/null | sed 's/^/   /')"
  echo "${_fdb:-   (nothing learned, or no 'bridge'/'brctl' tool)}"
  echo "-- neighbours on br-lan (IP ↔ MAC this router talked to)"; ip neigh show dev br-lan 2>/dev/null | sed 's/^/   /'
  echo "-- DHCP on br-lan"
  _pr=/tmp/roamer-diag.sh; printf '#!/bin/sh\n[ "$1" = bound ] && echo "   Gateway DHCP answers: offer $ip from ${serverid:-?} (router ${router:-?})"\nexit 0\n' > $_pr; chmod +x $_pr
  udhcpc -i br-lan -f -q -n -t 2 -T 2 -s $_pr 2>/dev/null | grep . || echo "   no DHCP server answers on br-lan (Gateway not reachable on the LAN ports?)"
  rm -f $_pr
  echo "-- routing"; ip -4 route 2>/dev/null | sed 's/^/   /'; ip rule 2>/dev/null | grep -v -e 'lookup local' -e 'lookup main' -e 'lookup default' | sed 's/^/   rule /'
  if command -v tailscale >/dev/null 2>&1; then
    echo "-- tailscale"; tailscale debug prefs 2>/dev/null | grep -E '"(RouteAll|AdvertiseRoutes|ExitNodeID)"' | sed 's/^ */   /'
    ip -4 route show table 52 2>/dev/null | grep -v '^100\.' | sed 's/^/   table 52: /'
  fi
  echo "-- Wi-Fi"
  echo "   wpad: $( { { sed -n 's/^P://p' /lib/apk/db/installed || true; }; { apk list --installed 2>/dev/null | sed 's/-[0-9].*//' || true; }; { sed -n 's/^Package: //p' /usr/lib/opkg/status || true; }; } 2>/dev/null | grep -E '^(wpad|hostapd)' | sort -u | tr '\n' ' ')"
  _f=""; for _x in 11r 11ax acs sae mesh; do hostapd -v"$_x" >/dev/null 2>&1 && _f="$_f $_x"; done
  _h="$(readlink -f /usr/sbin/hostapd 2>/dev/null)"; [ -r "$_h" ] && tr '\000' '\n' < "$_h" | grep -qx bss_transition && _f="$_f 11v"
  echo "   hostapd features:${_f:- ?}"
  for _p in $(pidof hostapd 2>/dev/null); do
    _v=no; tr '\000' '\n' < "/proc/$_p/exe" 2>/dev/null | grep -qx bss_transition && _v=yes
    echo "   running hostapd pid $_p: $(readlink "/proc/$_p/exe") · 802.11v=$_v"; done
  _ws="$(ubus call network.wireless status 2>/dev/null)"
  for _r in $(sections wireless wifi-device); do
    echo "   $_r up=$(jf "$_ws" "@.$_r.up") ch=$(uci -q get "wireless.$_r.channel") list=$(uci -q get "wireless.$_r.channels" || uci -q get "wireless.$_r.chanlist" || echo -) country=$(uci -q get "wireless.$_r.country" || echo -)"
    for _n in $(jsonfilter -s "$_ws" -e "@.$_r.interfaces[*].ifname" 2>/dev/null); do
      echo "     $_n: $(iwinfo "$_n" info 2>/dev/null | sed -n 's/.*\(Mode: [A-Za-z]*\).*/\1/p' | head -n1)"; done
  done
  logread -e hostapd 2>/dev/null | tail -n 8 | sed 's/^/   log: /'
  echo "-- ssh server"; uci -q show dropbear | sed 's/^/   /'
  (netstat -ltn 2>/dev/null || ss -ltn 2>/dev/null) | grep ':22 ' | sed 's/^/   /'
}

lanprobe() {   # lanprobe <computer ip> <computer mac> — machine-readable view of one LAN client
  _ip="$1"; _mac="$(echo "$2" | tr 'A-F' 'a-f')"
  echo "host=$(uci -q get system.@system[0].hostname || echo OpenWrt)"
  echo "brmac=$(cat /sys/class/net/br-lan/address 2>/dev/null)"
  echo "braddr=$(ip -4 -o addr show dev br-lan 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
  echo "brrx=$(cat /sys/class/net/br-lan/statistics/rx_packets 2>/dev/null)"
  for _p in /sys/class/net/br-lan/brif/*; do _p="${_p##*/}"; [ "$_p" != "*" ] || continue
    echo "port=$_p carrier=$(cat /sys/class/net/$_p/carrier 2>/dev/null || echo -) rx=$(cat /sys/class/net/$_p/statistics/rx_packets 2>/dev/null) tx=$(cat /sys/class/net/$_p/statistics/tx_packets 2>/dev/null) conduit=$(ip -o link show "$_p" 2>/dev/null | sed -n 's/^[0-9]*: [^@:]*@\([^:]*\):.*/\1/p')"
  done
  _wd="$(uci -q get network.wan.device 2>/dev/null || echo wan)"; _br="$(brsec)"
  case " $(uci -q get "network.$_br.ports") " in *" $_wd "*) echo "wanbr=$_wd";; esac
  echo "wancarrier=$(cat /sys/class/net/$_wd/carrier 2>/dev/null || echo 0)"
  echo "wanconduit=$(conduit_of "$_wd")"
  for _p in $(uci -q get "network.$_br.ports"); do [ "$_p" = "$_wd" ] || { echo "lanconduit=$(conduit_of "$_p")"; break; }; done
  [ -z "$_ip" ] || echo "neigh=$(ip neigh show "$_ip" dev br-lan 2>/dev/null | head -n1)"
  if [ -n "$_mac" ]; then
    _f="$(bridge fdb show br br-lan 2>/dev/null | tr 'A-F' 'a-f' | grep "^$_mac " | grep -v ' self' | awk '{print $3}' | head -n1)"
    [ -n "$_f" ] || _f="$(brctl showmacs br-lan 2>/dev/null | tr 'A-F' 'a-f' | awk -v m="$_mac" '$2==m{print "port-no "$1}' | head -n1)"
    echo "fdb=${_f:-unknown}"
  fi
  [ -z "$_ip" ] || { if ping -c2 -W1 -I br-lan "$_ip" >/dev/null 2>&1; then echo "ap2pc=ok"; else echo "ap2pc=fail"; fi; }
}

unbridge() {   # unbridge <wan dev> <seconds> <gateway ip> — take WAN out of br-lan; auto-revert unless confirmed
  _wd="${1:-wan}"; _to="${2:-300}"; _gw="${3:-}"; _br="$(brsec)"
  case " $(uci -q get "network.$_br.ports") " in *" $_wd "*) ;; *) echo "$_wd is not in the LAN bridge — nothing to change"; exit 0;; esac
  _S="/etc/roaming-setup.bak/$(date +%Y%m%d-%H%M%S)-unbridge"; mkdir -p "$_S"; cp /etc/config/network "$_S/"
  printf '#!/bin/sh\ncp %s/network /etc/config/network; /etc/init.d/network restart\n' "$_S" > "$_S/restore.sh"; chmod 700 "$_S/restore.sh"
  uci -q del_list "network.$_br.ports=$_wd"; uci commit network
  rm -f "$CONFIRMFILE"; echo "applying|||taking $_wd out of the LAN bridge" > "$STATEFILE"
  if [ -f "$JOBPID" ] && kill -0 "$(cat "$JOBPID" 2>/dev/null)" 2>/dev/null; then kill "$(cat "$JOBPID")" 2>/dev/null || true; fi
  ( trap '' HUP INT; exec </dev/null >>"$APLOG" 2>&1
    alog() { echo "$(date +%T) $*"; logger -t roaming-setup "$*"; }
    sleep 3; alog "unbridge: $_wd out of br-lan (backup $_S), restarting network"
    /etc/init.d/network restart; sleep 8
    _ip="$(ip -4 -o addr show dev br-lan | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    _dl=$(( $(date +%s) + _to )); _how=""
    while [ "$(date +%s)" -lt "$_dl" ]; do
      _lp=no; if [ -z "$_gw" ] || ping -c1 -W2 -I br-lan "$_gw" >/dev/null 2>&1; then _lp=yes; fi
      [ -f "$CONFIRMFILE" ] && _how=yes
      if [ -n "$_how" ] && [ $_lp = yes ]; then
        echo "ok|$_ip||WAN is out of the LAN bridge; Gateway on a LAN port" > "$STATEFILE"; alog "unbridge confirmed"; exit 0; fi
      echo "waiting|$_ip|$_dl|Gateway via LAN ports: $_lp · confirmation: ${_how:-none yet}" > "$STATEFILE"
      sleep 3
    done
    alog "unbridge NOT confirmed — reverting"; cp "$_S/network" /etc/config/network; /etc/init.d/network restart
    echo "rolled-back|||not confirmed — WAN bridged again as before (Gateway cable back into WAN)" > "$STATEFILE"
  ) &
  echo $! > "$JOBPID"
  echo "WAN ($_wd) leaves the LAN bridge in 3 s — reverts in ${_to}s unless confirmed (backup: $_S)"
}

RACT="${1:-}"; WELCOMED=0
if [ -z "$RACT" ] && [ "${WS:-0}" != 1 ] && [ $TTY = 1 ] && ! isset ROLE && ! isset PAIR; then
  welcome; WELCOMED=1
  CHN="Home"; CHE="1"; CH=Home; WHO="$(uci -q get system.@system[0].hostname || echo router)"
  step "What do you want to do?"
  unset RACT
  choose RACT "Choose:" setup \
    "setup|Set up this router — as the Gateway or as a Dumb AP" \
    "report|Report — what is set up here" \
    "state|State — one line: where a Dumb AP switch-over stands" \
    "status|Status — the Dumb AP switch-over log, monitoring" \
    "diag|Diagnostics — what the LAN ports and bridge see" \
    "pair|Pairing code — show this Gateway's code again" \
    "confirm|Confirm — confirm a Dumb AP switch-over by hand" \
    "undo|Undo — restore how it was before the last Roamer run (reboots)" \
    "quit|Quit"
  WHO="setup"; CH=Start; CURCH=""; chapters gateway
  case "$RACT" in setup) RACT="";; quit) exit 0;; esac
fi
case "$RACT" in
  undo)
    _u="$(readlink /etc/roaming-setup.bak/restore-latest.sh 2>/dev/null || true)"
    [ -n "$_u" ] && [ -f "$_u" ] || die "no Roamer snapshot here — nothing to undo"
    if [ "${WS:-0}" != 1 ] && [ $TTY = 1 ]; then confirm "Restore $(dirname "$_u") and reboot?" || exit 0; fi
    echo "restoring $(dirname "$_u") — rebooting"; ( sleep 1; sh "$_u" ) </dev/null >/dev/null 2>&1 &
    exit 0 ;;
  unbridge) unbridge "${2:-wan}" "${3:-300}" "${4:-}"; exit 0 ;;
  confirm)
    _st="$(cut -d'|' -f1 "$STATEFILE" 2>/dev/null || echo none)"
    case "$_st" in
      ok)         echo "Dumb AP is already confirmed."; exit 0 ;;
      none|"")    touch "$CONFIRMFILE"; echo "confirmation noted."; exit 0 ;;
      waiting)    ;;
      *)          echo "not ready yet: $(state_line)"; exit 3 ;;
    esac
    _new="$(cut -d'|' -f2 "$STATEFILE")"; _srv="$(echo "${SSH_CONNECTION:-}" | awk '{print $3}')"
    if [ -n "$_srv" ] && ! ip -4 -o addr show dev br-lan 2>/dev/null | grep -q " $_srv/"; then   # must come in over the LAN side
      echo "you reached this router at $_srv, not at its new address $_new — that does not prove the new path."
      echo "Connect to $_new (through the Gateway) and confirm there."; exit 3
    fi
    touch "$CONFIRMFILE"; echo "Confirmed — auto-rollback cancelled."; exit 0 ;;
  status)  cat "$APLOG" 2>/dev/null || echo "no $APLOG"; mon_status; exit 0 ;;
  state)   state_line; exit 0 ;;
  diag)    diag; exit 0 ;;
  lanprobe) lanprobe "${2:-}" "${3:-}"; exit 0 ;;
  report)  report; exit 0 ;;
  pair)    [ -f "$PAIRFILE" ] || die "no pairing data on this router (run the setup as Gateway first)"
           echo "ROAM1:$(b64e "$(cat "$PAIRFILE")")"; exit 0 ;;
  "") ;;
  *) die "unknown sub-command '$RACT' (pair|confirm|status|state|report|diag|undo — lantest runs on the computer)" ;;
esac

HOST="$(uci -q get system.@system[0].hostname || echo OpenWrt)"
if [ "${NOLOG:-0}" != 1 ]; then
  LOGBASE="$PWD/roaming-setup_${HOST}_$TS"; LOGTMP="$LOGBASE.log.part"
  : > "$LOGTMP" 2>/dev/null && chmod 600 "$LOGTMP" || LOGTMP=""
  lg "Roamer v$VERSION — $(date)"
fi

PKGS=""; STAGED=0; COMMITTED=0; TMPNET=0; TS_FIX=0
cleanup() {
  rc=$?
  { command -v stty >/dev/null && stty echo </dev/tty; } 2>/dev/null || true
  tmpnet_down 2>/dev/null || true
  if [ "$STAGED" = 1 ] && [ "$COMMITTED" != 1 ]; then
    for p in $PKGS; do uci revert "$p" 2>/dev/null || true; done
    echo "(staged changes reverted — nothing was written)" >&2; lg "(staged changes reverted)"
  fi
  if [ -n "$LOGTMP" ] && [ -f "$LOGTMP" ]; then
    st=err; [ "$rc" = 0 ] && st=ok
    mv "$LOGTMP" "${LOGBASE}_$st.log" 2>/dev/null && echo "log saved: ${LOGBASE}_$st.log" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM


# first LAN port as failsafe sees it (board.json), else first br-lan port
P1="$(jsonfilter -i /etc/board.json -e '@.network.lan.ports[0]' 2>/dev/null || true)"
[ -n "$P1" ] || P1="$(uci -q get "network.$(brsec).ports" 2>/dev/null | awk '{print $1}')"
P1="${P1:-lan1}"

[ "${WS:-0}" = 1 ] || [ "$WELCOMED" = 1 ] || welcome

# ---------------------------------------------------------------- 1. device
CH=Start
RADIOS2="" RADIOS5=""
for r in $(sections wireless wifi-device); do
  case "$(uci -q get wireless.$r.band || true)" in 2g) RADIOS2="$RADIOS2 $r";; 5g) RADIOS5="$RADIOS5 $r";; esac
done
step "This router"
REL="$( [ -f /etc/openwrt_release ] && . /etc/openwrt_release; echo "${DISTRIB_DESCRIPTION:-?}|${DISTRIB_ARCH:-?}|${DISTRIB_TARGET:-?}" )" || REL="?|?|?"
cpu="$(sed -n 's/^\(model name\|cpu model\|Hardware\)[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n1)"
ram="$(awk '/^MemTotal/{printf "%d MB", $2/1024}' /proc/meminfo 2>/dev/null)"
fl="$(df -k /overlay 2>/dev/null | awk 'NR==2{printf "%.1f MB free of %.1f MB", $4/1024, $2/1024}')"
rl=""; for r in $RADIOS2 $RADIOS5; do rl="$rl $r ($(uci -q get wireless.$r.band))"; done
box "Device" \
  "model     $(cat /tmp/sysinfo/model 2>/dev/null || echo ?)" \
  "board     $(cat /tmp/sysinfo/board_name 2>/dev/null || echo ?)" \
  "cpu       ${cpu:-?}" \
  "arch      $(echo "$REL" | cut -d'|' -f2) · target $(echo "$REL" | cut -d'|' -f3)" \
  "release   ${REL%%|*} · kernel $(uname -r)" \
  "memory    ${ram:-?} RAM · flash ${fl:-?}" \
  "radios   ${rl:- none}" \
  "LAN       $(uci -q get "network.$(brsec).ports" 2>/dev/null || echo ?) · first LAN port: $P1" \
  "packages  $PM · hostname $HOST"
[ -n "$RADIOS2$RADIOS5" ] || die "no 2.4/5 GHz radios found in /etc/config/wireless"
pause

# ---------------------------------------------------------------- 2. backup
if ! isset BACKUP; then step "Backup"; wrn "$PANTS"; say ""; fi
choose BACKUP "Save a full backup of this router's configuration into $PWD first?" yes \
  "yes|yes — roaming-setup_${HOST}_${TS}_backup.tar.gz" "no|no, skip"
if [ "$BACKUP" = yes ]; then
  bf="$PWD/roaming-setup_${HOST}_${TS}_backup.tar.gz"
  sysupgrade -b "$bf" >/dev/null 2>&1 || die "backup failed"
  chmod 600 "$bf"; okl "backup saved: $bf"; say "    restore with: sysupgrade -r $bf; reboot"
  case "$PWD" in /tmp*|/var*) wrn "$PWD is RAM — copy it off:  ssh root@<this router> cat $bf > backup.tar.gz";; esac
  pause
fi

# ---------------------------------------------------------------- 3. role / pairing
if isset PAIR && [ -n "$PAIR" ] && ! isset ROLE; then ROLE=ap; fi
if ! isset ROLE; then
  step "Role"
  choose ROLE "What is THIS router?" gateway \
    "gateway|the Gateway — main router (WAN, DHCP, firewall); only its Wi-Fi is changed" \
    "ap|a Dumb AP — joins the Gateway's LAN (you need the Gateway's pairing code)"
fi
case "$ROLE" in
  gateway) PKGS="wireless usteer system"; WHO="Gateway"; chapters gateway ;;
  ap)      PKGS="wireless usteer system network dhcp"; WHO="Dumb AP"; chapters ap ;;
  *) die "ROLE must be gateway|ap" ;;
esac

P_GW_CH2="" P_GW_CH5="" P_POOL_START="" P_POOL_LIMIT="" P_GW_NAME="" P_GW_PREFIX=""
if [ "$ROLE" = ap ]; then
  isset PAIR || step "Pairing code"
  ask PAIR "Paste the pairing code printed at the end of the Gateway run (Enter = answer everything manually)" "" v_any
  if [ -n "$PAIR" ]; then
    command -v ucode >/dev/null || die "ucode not found — cannot read the pairing code; pass values as variables"
    PAIR="$(printf '%s' "$PAIR" | tr -d ' \r\n\t')"
    case "$PAIR" in ROAM1:*) ;; *) die "the pairing code must start with ROAM1:";; esac
    payload="$(b64d "${PAIR#ROAM1:}")" || die "pairing code is damaged — copy the whole line"
    _n=0
    while IFS= read -r line; do
      k="${line%%=*}"; v="${line#*=}"
      case "$k" in
        SSID|KEY|ENC|MD|HIDDEN|COUNTRY|BANDS|ROAM_DBM|GW_IP) isset "$k" || setv "$k" "$v"; _n=$((_n+1)) ;;
        GW_CH2|GW_CH5|POOL_START|POOL_LIMIT|GW_NAME|GW_PREFIX) setv "P_$k" "$v" ;;
        MON_PORT) isset MON_PORT || setv MON_PORT "$v" ;;
      esac
    done <<EOF
$payload
EOF
    [ $_n -ge 9 ] || die "pairing code incomplete"
    [ "${COUNTRY:-}" = keep ] && unset COUNTRY
    lg "pairing code accepted (Gateway ${P_GW_NAME:-?} $GW_IP, SSID $SSID)"
  else unset PAIR; fi
fi

# ---------------------------------------------------------------- 4. Dumb AP: wiring (measured, not assumed)
TOPO="" GWR="" GWL_IP="" GWL_PFX="" wup="" wip="" wmask="" wgw="" wdev="" WANBR=0 WANCAR=0 WANC="" LANC="" OLDREACH=""
detect_wiring() {
  wst="$(ifstatus wan 2>/dev/null || true)"
  wproto="$(uci -q get network.wan.proto || true)"
  wup="$(jf "$wst" '@.up')"; wip="$(jf "$wst" '@["ipv4-address"][0].address')"
  wmask="$(jf "$wst" '@["ipv4-address"][0].mask')"; wgw="$(jf "$wst" '@.route[@.target="0.0.0.0"].nexthop')"
  wdev="$(jf "$wst" '@.l3_device')"; [ -n "$wdev" ] || wdev="$(uci -q get network.wan.device || echo wan)"
  [ "$wup" = true ] && [ -n "$wip" ] || wup=""
  # is the Gateway's DHCP server answering on this router's LAN ports?
  GWR="" GWL_IP="" GWL_PFX=""
  _pr=/tmp/roamer-probe.sh
  printf '#!/bin/sh\n[ "$1" = bound ] && echo "${router%%%% *}|$ip|$mask" > /tmp/roamer-probe.out\nexit 0\n' > $_pr; chmod +x $_pr
  rm -f /tmp/roamer-probe.out
  udhcpc -i br-lan -f -q -n -t 2 -T 2 -s $_pr >/dev/null 2>&1 || true
  if [ -s /tmp/roamer-probe.out ]; then IFS='|' read -r GWR GWL_IP GWL_PFX < /tmp/roamer-probe.out; fi
  rm -f $_pr /tmp/roamer-probe.out
  # own DHCP server state on br-lan (dnsmasq skips DHCP when it saw another server)
  OWNDHCP=0
  if [ "$(uci -q get dhcp.lan.ignore || true)" != 1 ] && pgrep -x dnsmasq >/dev/null 2>&1; then
    case "$(cat /var/run/dnsmasq.*.br-lan.dhcp 2>/dev/null | head -n1)" in 1) ;; *) OWNDHCP=1;; esac
  fi
  # console path
  CON_IP="${SSH_CLIENT:-}"; CON_IP="${CON_IP%% *}"; CON_VIA="" CON_DEV=""
  if [ -n "$CON_IP" ]; then
    _rt="$(ip -4 route get "$CON_IP" 2>/dev/null | head -n1)"
    CON_DEV="$(echo "$_rt" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
    case "$_rt" in *" via "*) CON_VIA="$(echo "$_rt" | sed -n 's/.* via \([^ ]*\).*/\1/p')";; esac
  fi
  if [ -n "$GWR" ]; then TOPO=lan; elif [ -n "$wup" ]; then TOPO=wan; else TOPO=none; fi
  # WAN port inside the LAN bridge? (an earlier setup bridged it) — then the Gateway may sit on WAN
  WANBR=0 WANCAR=0; wdev="${wdev:-wan}"
  case " $(uci -q get "network.$(brsec).ports" 2>/dev/null) " in *" $wdev "*) WANBR=1;; esac
  [ "$(cat "$SYSNET/$wdev/carrier" 2>/dev/null)" = 1 ] && WANCAR=1
  WANC="$(conduit_of "$wdev")"; LANC="$(conduit_of "$P1")"
  OLDREACH="$(ip -4 -o addr show dev br-lan 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
}
refuse() { if [ "${FORCE_AP:-0}" = 1 ]; then wrn "(FORCE_AP=1) $*"; else die "$* — not converting (FORCE_AP=1 overrides)"; fi; }

CH=Check
if [ "$ROLE" = ap ]; then
  while :; do
    step "Wiring check"
    say "  ${D}measuring how this router is connected …${N}"; detect_wiring
    [ -z "${PAIR:-}" ] || okl "pairing code: SSID '$SSID' · $ENC · MD $MD · Gateway '${P_GW_NAME:-?}' at $GW_IP"
    case "$wproto" in pppoe|pppoa|pptp|l2tp|3g|qmi|mbim|ncm|modemmanager)
      refuse "WAN uses '$wproto' — this router faces the ISP, it is a Gateway";; esac
    if [ -n "$wup" ] && ! is_private "$wip"; then refuse "WAN has public/CGNAT address $wip — this router faces the ISP, it is a Gateway"; fi
    TS_RA=0; command -v tailscale >/dev/null 2>&1 && tailscale debug prefs 2>/dev/null | grep -q '"RouteAll": true' && TS_RA=1
    if command -v tailscale >/dev/null 2>&1 && tailscale debug prefs 2>/dev/null | grep -q '"AdvertiseRoutes": \['; then
      refuse "Tailscale on this router advertises routes — that is the Gateway's job"
    fi
    case "$TOPO" in
      lan)  g="on a LAN port here (its DHCP server $GWR answers)"
            [ "$WANBR" = 0 ] || [ "$WANCAR" = 0 ] || g="answers on the LAN bridge ($GWR) — probably through the bridged WAN";;
      wan)  g="on this router's WAN — got $wip/$wmask from ${wgw:-?}";;
      none) g="${YE}not connected${N}";;
    esac
    if [ -z "${CON_IP:-}" ]; then c="not over SSH (local console)"
    elif [ -n "$CON_VIA" ]; then c="$CON_IP — through $CON_VIA, not on this router's LAN"
    elif [ "$CON_DEV" = br-lan ]; then c="$CON_IP — directly on this router's LAN"
    else c="$CON_IP — via $CON_DEV"; fi
    box "Measured" "Gateway   $g" "console   $c" "failsafe  only on $P1 (first LAN port), fixed IP 192.168.1.10/24"
    say ""
    gw_seen="${GWR:-$wgw}"
    if isset GW_IP && [ -n "$gw_seen" ] && [ "$gw_seen" != "$GW_IP" ]; then
      wrn "the Gateway found here is $gw_seen, but the pairing code says $GW_IP — check the cabling"; fi
    case "$TOPO" in
      lan)  if [ "$WANBR" = 1 ]; then
              wrn "This router's WAN port is bridged into its LAN (an earlier setup did that)$([ "$WANCAR" = 1 ] && echo ";")"
              [ "$WANCAR" != 1 ] || say "    a cable is in WAN — most likely the Gateway's."
              if [ -n "$WANC" ] && [ -n "$LANC" ] && [ "$WANC" != "$LANC" ]; then
                say "    WAN ($wdev@$WANC) and LAN ports ($P1@$LANC) use different links to the processor —"
                say "    then devices on the LAN ports can't reach the Dumb AP itself."; fi
              say "    The switch-over takes WAN out of the LAN$([ "$WANCAR" = 1 ] && echo "; move the Gateway cable to a LAN")"
              [ "$WANCAR" != 1 ] || say "    port other than $P1 when told."
            else okl "Wiring is already final — nothing to recable."; fi
            [ "$OWNDHCP" = 0 ] || wrn "this router's DHCP server is also active on the Gateway's LAN (ends with the switch)"
            [ -z "$CON_VIA" ] || say "    Your console goes through the Gateway: after the switch use the new address the same way."
            ;;
      wan)  okl "Wiring OK. After the switch you move the Gateway cable from WAN to a LAN port other than $P1;"
            say "    until you do, this router stays reachable at its current WAN address $wip."
            if [ -n "${CON_IP:-}" ] && { [ -n "$CON_VIA" ] || [ "$CON_DEV" != br-lan ]; }; then
              wrn "your console is not on this router's LAN — after the switch reach it through the Gateway's LAN."; fi
            ;;
      none) wrn "Connect a Gateway LAN port to this router's WAN (recommended — gives it internet for package"
            say "    installs) or to a LAN port other than $P1, then re-check."
            ;;
    esac
    say "  ${D}Recovery is easiest with a laptop that can be cabled to $P1.${N}"
    say ""
    wdef=go; [ "$TOPO" = none ] && [ $TTY = 1 ] && wdef=recheck
    unset WIRE
    choose WIRE "Continue?" "$wdef" "go|continue" "recheck|re-check the wiring" "quit|quit — nothing changed"
    case "$WIRE" in go) break;; quit) exit 0;; esac
  done
fi

if [ "$ROLE" = ap ] && [ "${TS_RA:-0}" = 1 ]; then
  isset TS_ACCEPT || step "Tailscale on this router"
  wrn "Tailscale on this router accepts subnet routes (accept-routes)."
  say "    The Gateway advertises this LAN, so this Dumb AP would send its replies to LAN devices into"
  say "    the tailnet — unreachable from a cable or Wi-Fi. A Dumb AP doesn't need tailnet routes."
  say ""
  choose TS_ACCEPT "Turn accept-routes off on this router?" off \
    "off|yes — turn it off when applying (recommended)" "keep|no, keep it"
  [ "$TS_ACCEPT" != off ] || TS_FIX=1
fi

# ---------------------------------------------------------------- preflight (before anything is installed)
pat="$(echo "$PKGS" | tr ' ' '|')"
other="$(uci changes 2>/dev/null | grep -vE "^-?($pat)\." || true)"
[ -z "$other" ] || { echo "$other" >&2; die "uncommitted UCI changes in other packages (above). 'uci commit <pkg>' or 'uci revert <pkg>' first."; }
mine="$(uci changes 2>/dev/null | grep -E "^-?($pat)\." || true)"
[ -z "$mine" ] || { echo "$mine" >&2; die "uncommitted changes already pending in $PKGS (above) — 'uci revert <pkg>' first."; }

# ---------------------------------------------------------------- 5. packages
tmpnet_up() {    # Dumb AP without WAN: borrow a lease from the Gateway on br-lan for package downloads
  [ "${TOPO:-}" = lan ] && [ -n "$GWL_IP" ] && [ -n "$GWR" ] || return 1
  ip -4 addr add "$GWL_IP/${GWL_PFX:-24}" dev br-lan 2>/dev/null || return 1
  ip -4 route add default via "$GWR" dev br-lan metric 4000 2>/dev/null || true
  mkdir -p /tmp/resolv.conf.d
  grep -qx "nameserver $GWR" /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null \
    || echo "nameserver $GWR" >> /tmp/resolv.conf.d/resolv.conf.auto
  TMPNET=1; sleep 3
}
tmpnet_down() {
  [ "${TMPNET:-0}" = 1 ] || return 0
  ip -4 route del default via "$GWR" dev br-lan metric 4000 2>/dev/null || true
  ip -4 addr del "$GWL_IP/${GWL_PFX:-24}" dev br-lan 2>/dev/null || true
  sed -i "/^nameserver $GWR\$/d" /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null || true
  TMPNET=0
}
FULLW="wpad-mbedtls wpad-wolfssl wpad-openssl wpad hostapd-mbedtls hostapd-wolfssl hostapd-openssl hostapd"
have_full=""; for p in $FULLW; do pkg_has "$p" && { have_full="$p"; break; }; done
basic=""; for p in wpad-basic-mbedtls wpad-basic-wolfssl wpad-basic-openssl wpad-basic wpad-mini hostapd-basic-mbedtls hostapd-basic-wolfssl hostapd-basic-openssl hostapd-basic; do
  pkg_has "$p" && { basic="$p"; break; }; done
case "$basic" in *wolfssl) want_full=wpad-wolfssl;; *openssl) want_full=wpad-openssl;; *) want_full=wpad-mbedtls;; esac
LUCI=0; pkg_has luci-base && LUCI=1
R_NEED=""; R_LINES=""
add_r() { R_LINES="$R_LINES$1
"; }
if [ -n "$have_full" ]; then add_r "${GR}✓${N} $have_full  (full hostapd: 802.11r/k/v)"
else R_NEED="$want_full"; add_r "${RE}✗${N} $want_full  (full hostapd${basic:+, replaces $basic})"; fi
for p in usteer ucode; do
  if pkg_has "$p"; then add_r "${GR}✓${N} $p"; else R_NEED="$R_NEED $p"; add_r "${RE}✗${N} $p"; fi
done
if [ $LUCI = 1 ]; then
  if pkg_has luci-app-usteer; then add_r "${GR}✓${N} luci-app-usteer"; else R_NEED="$R_NEED luci-app-usteer"; add_r "${RE}✗${N} luci-app-usteer  (LuCI page)"; fi
fi
T_NEED=""; T_LINES=""
add_t() { T_LINES="$T_LINES$1
"; }
for p in tailscale $( [ $LUCI = 1 ] && echo luci-app-tailscale-community ); do
  if pkg_has "$p"; then add_t "${GR}✓${N} $p"; else T_NEED="$T_NEED $p"; add_t "${D}·${N} $p"; fi
done
set -- $R_NEED; R_NEED="$*"; set -- $T_NEED; T_NEED="$*"     # squeeze whitespace

step "Packages"
set --; while IFS= read -r l; do [ -n "$l" ] && set -- "$@" "$l"; done <<EOF
$R_LINES
EOF
box "Roaming bundle — required" "$@"
set --; while IFS= read -r l; do [ -n "$l" ] && set -- "$@" "$l"; done <<EOF
$T_LINES
EOF
box "Tailscale bundle — optional" "$@"
say "  ${D}package manager $PM · flash ${fl:-?}${N}"; say ""

[ "$PM" != none ] || { [ -z "$R_NEED" ] || die "no package manager found and roaming packages are missing: $R_NEED"; }
if [ -n "$R_NEED" ]; then
  wrn "Roaming needs: ${B}$R_NEED${N} — they will be installed now (internet required)."
  [ -z "$basic" ] || [ -n "$have_full" ] || wrn "$basic is swapped for $want_full: Wi-Fi restarts briefly — stay on a cable."
  confirm "Install the roaming bundle?" || die "roaming cannot work without these packages — stopped, nothing changed"
fi
if [ -n "$T_NEED" ]; then
  say ""
  choose TAILSCALE "Install Tailscale too?" no \
    "no|no — skip" \
    "yes|yes — install only; set it up yourself afterwards (tailscale up … or LuCI › Services › Tailscale)"
else TAILSCALE=no; fi
if [ -n "$R_NEED" ] || [ "$TAILSCALE" = yes ]; then
  if [ "$DRY_RUN" = 1 ]; then say "  ${D}(dry run — would install: $R_NEED $( [ "$TAILSCALE" = yes ] && echo "$T_NEED"))${N}"
  else
    say "  ${D}updating package lists …${N}"
    if ! pkg_update >/dev/null 2>&1; then
      if tmpnet_up && pkg_update >/dev/null 2>&1; then okl "using a temporary connection through the Gateway on the LAN"
      else die "this router has no internet. Connect its WAN to the Gateway's LAN (or any internet) and run again."; fi
    fi
    for p in $R_NEED; do
      case "$p" in
        luci-app-usteer) pkg_avail "$p" || { wrn "$p not in the feed — skipped"; continue; } ;;
      esac
      if [ "$p" = "$want_full" ] && [ -n "$basic" ]; then
        say "  installing $p (replacing $basic) …"
        if pkg_del "$basic" >/dev/null 2>&1 && pkg_add "$p" >/dev/null 2>&1 && pkg_has "$p" && ! pkg_has "$basic"; then
          okl "$p"; [ ! -x /etc/init.d/wpad ] || /etc/init.d/wpad restart >/dev/null 2>&1 || true
        else pkg_add "$basic" >/dev/null 2>&1 || true; die "could not install $p ($basic restored)"; fi
      else
        say "  installing $p …"; pkg_add "$p" >/dev/null 2>&1 && okl "$p" || die "could not install $p"
      fi
    done
    if [ "$TAILSCALE" = yes ]; then
      for p in $T_NEED; do
        pkg_avail "$p" || { wrn "$p not in the feed — skipped"; continue; }
        say "  installing $p …"; if pkg_add "$p" >/dev/null 2>&1; then okl "$p"; else wrn "could not install $p (continuing)"; fi
      done
      pkg_has tailscale && say "    ${D}Tailscale is installed but NOT configured — set it up later (tailscale up / LuCI).${N}"
    fi
    tmpnet_down
  fi
  pause
fi

# full hostapd present (exact package)? Only then 802.11v (bss_transition): a basic build is compiled
# without it and refuses the whole AP config — no Wi-Fi at all.
WNM=0; for p in $FULLW; do pkg_has "$p" && { WNM=1; break; }; done
HBIN="$(readlink -f /usr/sbin/hostapd 2>/dev/null || true)"
# the binary itself: a positive answer is certain (the literal is in its config parser); a negative one
# only means "not seen" — so it can switch 802.11v ON for an oddly named package, never OFF
if [ "$WNM" = 0 ] && [ -n "$HBIN" ] && bin_wnm "$HBIN"; then WNM=1; fi
[ "$DRY_RUN" != 1 ] || [ -z "$R_NEED" ] || WNM=1          # dry run: the plan assumes the install happens
[ "$WNM" = 1 ] || wrn "802.11v (BSS transition) stays off on this router; 802.11r/k still work"

# ---------------------------------------------------------------- 6. bands
CH=Wi-Fi
if ! isset BANDS; then
  step "Bands"
  _rows=""
  for r in $RADIOS2 $RADIOS5; do
    st="on"; [ "$(uci -q get wireless.$r.disabled || true)" = 1 ] && st="${YE}OFF${N}"
    _rows="$_rows${B}$r${N} $(uci -q get wireless.$r.band) · ch $(uci -q get wireless.$r.channel || echo auto) · $(uci -q get wireless.$r.htmode || echo -) · $(uci -q get wireless.$r.txpower || echo max) dBm · $(uci -q get wireless.$r.country || echo --) · $st
"
    for s in $(sections wireless wifi-iface); do
      [ "$(iget "$s" device)" = "$r" ] || continue
      d=""; [ "$(iget "$s" disabled)" = 1 ] && d=" ${D}[off]${N}"; h=""; [ "$(iget "$s" hidden)" = 1 ] && h=" (hidden)"
      _rows="$_rows  $s · $(iget "$s" mode) · '$(iget "$s" ssid)'$h · $(iget "$s" network) · $(iget "$s" encryption)$d
"
    done
  done
  set --; while IFS= read -r l; do [ -n "$l" ] && set -- "$@" "$l"; done <<EOF
$_rows
EOF
  box "Wi-Fi now" "$@"; say ""
fi
defb=both; [ -z "$RADIOS2" ] && defb=5g; [ -z "$RADIOS5" ] && defb=2g
set --
[ -n "$RADIOS2" ] && set -- "$@" "2g|2.4 GHz only"
[ -n "$RADIOS5" ] && set -- "$@" "5g|5 GHz only"
[ -n "$RADIOS2" ] && [ -n "$RADIOS5" ] && set -- "$@" "both|both bands (same SSID — enables band steering)"
choose BANDS "Which bands carry the roaming Wi-Fi?" "$defb" "$@"
case "$BANDS" in 2g) SEL="$RADIOS2";; 5g) SEL="$RADIOS5";; both) SEL="$RADIOS2 $RADIOS5";; *) die "BANDS must be 2g|5g|both";; esac
set -- $SEL; SEL="$*"; [ -n "$SEL" ] || die "this router has no radio for BANDS=$BANDS"

# ---------------------------------------------------------------- 7. country
first="${SEL%% *}"; curc="$(uci -q get wireless.$first.country || true)"
isset COUNTRY || step "Country"
choose COUNTRY "Wi-Fi country (regulatory domain) for the selected radios:" keep \
  "keep|keep current (${curc:-unset})" "NL|NL Netherlands" "BE|BE Belgium" "DE|DE Germany" \
  "FR|FR France" "GB|GB United Kingdom" "US|US United States" "other|other (type the code)"
if [ "$COUNTRY" = other ]; then unset COUNTRY; ask COUNTRY "Two-letter country code" "${curc:-NL}" v_country; fi
[ "$COUNTRY" = keep ] || { _r="$(v_country "$COUNTRY")" || die "COUNTRY: $_r"; COUNTRY="$(echo "$COUNTRY" | tr '[:lower:]' '[:upper:]')"; }

# ---------------------------------------------------------------- 8. per radio
autolist() {   # 'auto' = hostapd ACS restricted to these channels
  case "$1" in
    2g) if [ "$ROLE" = ap ]; then case "$P_GW_CH2" in 1) echo "6 11";; 6) echo "1 11";; 11) echo "1 6";; *) echo "1 6 11";; esac
        else echo "1 6 11"; fi ;;
    5g) if [ "$ROLE" = ap ]; then case "$P_GW_CH5" in 3[6-9]|4[0-8]) echo "100 104 108 112";; *) echo "36 40 44 48";; esac
        else echo "36 40 44 48"; fi ;;
  esac
}
sugg_ch() {
  case "$1" in
    2g) case "$P_GW_CH2" in 1) echo 6;; 6) echo 11;; 11) echo 1;; *) echo keep;; esac ;;
    5g) case "$P_GW_CH5" in 3[2-9]|4[0-9]|5[0-9]|6[0-4]) echo 100;; 1[0-9][0-9]) echo 36;; *) echo keep;; esac ;;
  esac
}
txlevels() {
  iwinfo "$(radio_if "$1")" txpowerlist 2>/dev/null | sed -n 's/^[* ]*\([0-9][0-9]*\) dBm.*/\1/p' \
    | sort -un -r | awk 'NR==1 || $1 <= last-3 {print; last=$1}'
}
PLAN=""; SRC_IFACE=""
for r in $SEL; do
  band="$(uci -q get wireless.$r.band)"
  case "$band" in
    2g) bv=IFACE_2G cv=CH2 hv=HT2 tv=TXP2 bl="2.4 GHz" vc=v_ch2 ;;
    5g) bv=IFACE_5G cv=CH5 hv=HT5 tv=TXP5 bl="5 GHz"   vc=v_ch5 ;;
  esac
  uplink=""; aps=""; defi=new; defd=""
  for s in $(sections wireless wifi-iface); do
    [ "$(iget "$s" device)" = "$r" ] || continue
    m="$(iget "$s" mode)"
    if [ "$(iget "$s" disabled)" != 1 ]; then
      case "$m" in sta|mesh|adhoc) uplink="$s";; esac
      [ "$(iget "$s" wds)" = 1 ] && uplink="$s"
    fi
    [ "$m" = ap ] || continue
    aps="$aps $s"
    case " $(iget "$s" network) " in
      *" lan "*) if [ "$(iget "$s" disabled)" = 1 ]; then [ -n "$defd" ] || defd="$s"
                 elif [ "$defi" = new ]; then defi="$s"; fi ;;
    esac
  done
  [ "$defi" != new ] || [ -z "$defd" ] || defi="$defd"
  set --
  for s in $aps; do
    d=""; [ "$(iget "$s" disabled)" = 1 ] && d=", off"
    set -- "$@" "$s|reuse '$(iget "$s" ssid)' ($s, net=$(iget "$s" network), $(iget "$s" encryption)$d)"
  done
  set -- "$@" "new|create a NEW Wi-Fi network on $r (existing ones untouched)"
  if isset "$bv"; then iface="$(getv "$bv")"; unset "$bv"; else unset iface; step "$bl ($r) · Wi-Fi network"; fi
  isset iface || choose iface "Which Wi-Fi network on $r becomes the roaming one?" "$defi" "$@"
  isnew=0
  if [ "$iface" = new ]; then isnew=1; iface="roam_$r"
  else
    [ "$(uci -q get wireless.$iface || true)" = wifi-iface ] || die "$iface is not a wifi-iface"
    [ "$(iget "$iface" device)" = "$r" ] && [ "$(iget "$iface" mode)" = ap ] || die "$iface is not an access-point network on $r"
    [ -n "$SRC_IFACE" ] || SRC_IFACE="$iface"
  fi
  curch="$(uci -q get wireless.$r.channel || echo auto)"
  ht="$(getv "$hv")"; [ -n "$ht" ] || ht=keep
  if [ -n "$uplink" ]; then
    wrn "$r carries uplink '$uplink' — keeping its channel, htmode, txpower and country"
    ch=keep ht=keep txp=keep
  else
    dch=keep; [ "$ROLE" = ap ] && dch="$(sugg_ch "$band")"
    gwch=""; [ "$band" = 2g ] && gwch="$P_GW_CH2"; [ "$band" = 5g ] && gwch="$P_GW_CH5"
    al="$(autolist "$band")"
    if isset "$cv"; then ch="$(getv "$cv")"; _r="$($vc "$ch")" || die "$cv='$ch': $_r"
    else
      unset ch; step "$bl ($r) · channel"
      box "Channel" "now        $curch${gwch:+ · the Gateway uses $gwch}" \
        "auto       picked at start-up from: $al" \
        "$(case "$al" in 100*) echo "           (DFS: 60 s radar check after boot)";; *) echo "";; esac)" \
        "tip        fixed, different channels per router roam most predictably"
      say ""
      ask ch "$bl channel — a number, auto, or keep" "$dch" "$vc"
    fi
    curtx="$(uci -q get wireless.$r.txpower || true)"
    if isset "$tv"; then txp="$(getv "$tv")"
    else
      levels="$(txlevels "$r" || true)"
      if [ -n "$levels" ]; then
        set -- "keep|keep current (${curtx:-max}${curtx:+ dBm})" "max|maximum allowed ($(echo "$levels" | head -n1) dBm)"
        for l in $(echo "$levels" | sed 1d); do
          set -- "$@" "$l|$l dBm (~$(awk -v d="$l" 'BEGIN{printf "%.0f", 10^(d/10)}') mW)"
        done
        unset txp; step "$bl ($r) · transmit power"
        say "  Levels this radio may use here. Lower power = clients move to the nearer router sooner."; say ""
        choose txp "Transmit power for $r:" keep "$@"
      else txp=keep; fi
    fi
    case "$txp" in keep|max|[0-9]|[0-9][0-9]) ;; *) die "$tv='$txp': dBm number, max or keep";; esac
  fi
  PLAN="$PLAN$r|$band|$iface|$isnew|$uplink|$ch|$ht|$txp
"
done

# ---------------------------------------------------------------- 9. network-wide settings
d_ssid="" d_key="" d_enc="" d_md="" d_hid=0
if [ -n "$SRC_IFACE" ]; then
  d_ssid="$(iget "$SRC_IFACE" ssid)"; d_key="$(iget "$SRC_IFACE" key)"
  case "$(iget "$SRC_IFACE" encryption)" in sae-mixed*|psk2*|sae) d_enc="$(iget "$SRC_IFACE" encryption)"; d_enc="${d_enc%%+*}";; esac
  d_md="$(iget "$SRC_IFACE" mobility_domain)"; [ "$(iget "$SRC_IFACE" hidden)" = 1 ] && d_hid=1
fi
isset SSID || step "Network name"
ask SSID "Roaming SSID (identical on the Gateway and every Dumb AP)" "$d_ssid" v_ssid
isset KEY || step "Password"
ask_secret KEY "Wi-Fi password" "$d_key" v_key
isset ENC || step "Encryption"
set --
[ -n "$d_enc" ] && set -- "keep|keep current ($d_enc)"
set -- "$@" "sae-mixed|WPA2/WPA3 mixed (FT-SAE + FT-PSK)" "psk2|WPA2-PSK (FT-PSK — most compatible with 802.11r)" "sae|WPA3-SAE only"
edef=sae-mixed; [ -n "$d_enc" ] && edef=keep
choose ENC "Encryption:" "$edef" "$@"
[ "$ENC" = keep ] && ENC="$d_enc"
case "$ENC" in sae) MFP=2 ;; sae-mixed|psk2) MFP=1 ;; *) die "ENC must be keep|sae-mixed|psk2|sae";; esac
isset HIDDEN || step "Visibility"
choose HIDDEN "Broadcast the SSID?" "$d_hid" \
  "0|visible (recommended — hidden SSIDs make clients probe more and roam worse)" "1|hidden (not broadcast)"
case "$HIDDEN" in 0|1) ;; *) die "HIDDEN must be 0 or 1";; esac
md_derive="$(printf '%s\n' "$SSID" | md5sum | cut -c1-4)"
mdef=derive; [ -n "$d_md" ] && mdef=keep
if ! isset MD; then
  step "Mobility domain"
  say "  A 4-hex ID that groups routers for 802.11r fast transition: a phone connected"
  say "  to one of them hands over to the next in ~50 ms instead of a full reconnect."
  say ""
  BOXW=76
  box "${GR}✓${N} Do" \
    "same ID on the Gateway and every Dumb AP, with the same SSID + password" \
    "keep the current ID when re-running Roamer — just press Enter" \
    "derive it from the SSID if unsure — every router computes the same ID"
  box "${RE}✗${N} Don't" \
    "different IDs per router — clients reconnect slowly instead of roaming" \
    "the same ID for another SSID (e.g. guest) — each SSID gets its own" \
    "change it on one router only — a new ID means re-running all of them" \
    "a new ID to fix a client that won't roam — tune the threshold instead"
  BOXW=""
  say ""
fi
set --
[ -n "$d_md" ] && set -- "$@" "keep|keep current ($d_md)"
set -- "$@" "derive|derive from the SSID ($md_derive — same result on every router with this SSID)" \
            "gen|generate a random one" "type|type it (4 hex)"
choose MD "Mobility domain:" "$mdef" "$@"
case "$MD" in
  keep) MD="$d_md" ;;
  derive) MD="$md_derive" ;;
  gen) MD="$(randhex4)"; okl "generated: $MD" ;;
  type) unset MD; ask MD "Mobility domain (4 hex)" "$md_derive" v_md ;;
esac
_r="$(v_md "$MD")" || die "MD: $_r"; MD="$(echo "$MD" | tr A-F a-f)"
d_dbm="$(uci -q get usteer.@usteer[0].roam_trigger_snr 2>/dev/null || true)"
case "$d_dbm" in -[0-9][0-9]) ;; *) d_dbm=-70;; esac
if ! isset ROAM_DBM; then
  step "Roaming threshold"
  box "usteer" "asks a client to move to a better router when its signal drops below this" \
    "-65  roams early   ·   -70  balanced   ·   -75  roams late"
  say ""
fi
ask ROAM_DBM "Signal threshold in dBm (-90 … -50)" "$d_dbm" v_dbm
ROAM_SCAN=$((ROAM_DBM + 5))
if [ "$ROLE" = ap ]; then
  CH=Address
  [ "$NAME_SET" = 1 ] || step "Hostname"
  ask NAME "Hostname of the Dumb AP (LuCI, prompt, usteer; in the Gateway's DHCP list only with DHCP)" "$HOST" v_host
else NAME="${NAME:-}"; fi

# ---------------------------------------------------------------- 10. Dumb AP: uplink + address
MGMT_PC=""; TMPWAN=0; CAB=lan; FROMWAN=0
if [ "$ROLE" = ap ]; then
  isset GW_IP || step "Gateway address"
  ask GW_IP "Gateway LAN IP" "${GWR:-${wgw:-192.168.1.1}}" v_ip
  PFX="${P_GW_PREFIX:-${GWL_PFX:-${wmask:-24}}}"
  if isset NETMASK; then PFX="$(cval "$GW_IP/$NETMASK" "" "" PREFIX)"; fi
  NETMASK="$(cval "$GW_IP/$PFX" "" "" NETMASK)"; GWNET="$(cval "$GW_IP/$PFX" "" "" NETWORK)"
  [ -n "$NETMASK" ] && [ -n "$GWNET" ] || die "cannot compute subnet for $GW_IP/$PFX (/bin/ipcalc.sh missing?)"

  # Uplink = a LAN port. Bridging the WAN port into the LAN is not offered any more: on routers whose
  # WAN and LAN ports reach the CPU through different links it leaves the LAN ports dead (measured).
  [ "$TOPO" = lan ] && BRIDGE_WAN=0
  BRIDGE_WAN="${BRIDGE_WAN:-0}"
  case "$BRIDGE_WAN" in 0|1) ;; *) die "BRIDGE_WAN must be 0 or 1";; esac
  if [ "$BRIDGE_WAN" = 1 ]; then
    cw="$(conduit_of "$wdev")"; cl="$(conduit_of "$P1")"
    if [ -n "$cw" ] && [ -n "$cl" ] && [ "$cw" != "$cl" ]; then
      refuse "BRIDGE_WAN=1: WAN ($wdev@$cw) and LAN ($P1@$cl) reach the CPU through different links — the LAN ports would stop working"
    fi
  fi

  isset AP_ADDR || step "Dumb AP address"
  choose AP_ADDR "How does the Dumb AP get its LAN address?" static \
    "static|fixed address in the Gateway's LAN, outside its DHCP pool — always known (recommended)" \
    "dhcp|DHCP from the Gateway — it picks the address; find it as $NAME.lan or via a recovery address"
  case "$AP_ADDR" in dhcp|static) ;; *) die "AP_ADDR must be static|dhcp";; esac

  inuse() {   # does ANOTHER device answer on $1 in the Gateway's LAN? (callers rule out own addresses)
    if [ "$TOPO" = wan ] && [ -n "$wdev" ]; then ping -c1 -W1 -I "$wdev" "$1" >/dev/null 2>&1; return; fi
    if [ "$TOPO" = lan ] && [ -n "$GWL_IP" ]; then
      _add=0; own_ip "$GWL_IP" || { ip -4 addr add "$GWL_IP/${GWL_PFX:-24}" dev br-lan 2>/dev/null && _add=1; }
      _x=0; ping -c1 -W1 -I br-lan "$1" >/dev/null 2>&1 || _x=1
      [ $_add = 0 ] || ip -4 addr del "$GWL_IP/${GWL_PFX:-24}" dev br-lan 2>/dev/null || true
      return $_x
    fi
    return 1
  }
  if [ "$AP_ADDR" = static ]; then
    pool="OpenWrt default .100-.249"
    [ -n "$P_POOL_START" ] && pool="$(cval "$GW_IP/$PFX" "$P_POOL_START" "${P_POOL_LIMIT:-150}" START) - $(cval "$GW_IP/$PFX" "$P_POOL_START" "${P_POOL_LIMIT:-150}" END)"
    isset AP_IP || say "  ${D}Gateway's DHCP pool: $pool — pick an address outside it.${N}"
    d_ap="$(cval "$GW_IP/$PFX" 2 1 START)"
    while :; do
      ask AP_IP "Dumb AP LAN IP" "${d_ap:-192.168.1.2}" v_ip
      why=""
      [ "$AP_IP" != "$GW_IP" ] || why="that is the Gateway"
      [ -n "$why" ] || [ "$(cval "$AP_IP/$PFX" "" "" NETWORK)" = "$GWNET" ] || why="not in the Gateway's LAN $GWNET/$PFX"
      [ -n "$why" ] || [ "$AP_IP" != "$GWNET" ] || why="that is the network address"
      [ -n "$why" ] || [ "$AP_IP" != "$(cval "$GW_IP/$PFX" "" "" BROADCAST)" ] || why="that is the broadcast address"
      if [ -z "$why" ] && own_ip "$AP_IP"; then
        if [ "$AP_IP" = "$wip" ]; then
          wrn "$AP_IP is the address the Gateway's DHCP gave this router's WAN port — it moves to the LAN side."
          say "    Make sure it is outside the Gateway's DHCP pool or reserved for this router there."
        else okl "$AP_IP is this router's current address — it keeps it."; fi
        break
      fi
      if [ -z "$why" ] && inuse "$AP_IP"; then why="already in use by another device (answers ping in the Gateway's LAN)"; fi
      [ -n "$why" ] || break
      [ $TTY = 1 ] || die "AP_IP=$AP_IP: $why"
      bad "$AP_IP: $why — try again"; unset AP_IP
    done
  fi
  # Recovery address: a second, fixed address on the Dumb AP's LAN side in a separate small network,
  # for a laptop cabled straight to it (with or without the Gateway). Same subnet as failsafe uses.
  rnet=192.168.1; [ "$GWNET" != 192.168.1.0 ] || rnet=192.168.254
  ro=1; [ "$AP_ADDR" != static ] || ro="${AP_IP##*.}"; case "$ro" in 0|10|255) ro=1;; esac
  if [ "$AP_ADDR" = static ]; then MGMT_IP="${MGMT_IP:-$rnet.$ro}"     # automatic (no prompt) in static mode
  else ask MGMT_IP "Recovery address on the Dumb AP — reachable without the Gateway ('off' = none)" "$rnet.$ro" v_ipoff; fi
  if [ "$MGMT_IP" != off ]; then
    _r="$(v_ip "$MGMT_IP")" || die "MGMT_IP: $_r"
    [ "$(cval "$MGMT_IP/24" "" "" NETWORK)" != "$GWNET" ] || die "MGMT_IP $MGMT_IP must not be inside the Gateway's LAN"
    MGMT_PC="${MGMT_IP%.*}.10"; [ "$MGMT_PC" != "$MGMT_IP" ] || MGMT_PC="${MGMT_IP%.*}.250"
  fi
  # While the Gateway cable is still in WAN, keep the WAN lease as a temporary way in (old address),
  # removed only after the Dumb AP was confirmed through its LAN ports.
  TMPWAN=0
  [ "$TOPO" = wan ] && [ "$BRIDGE_WAN" = 0 ] && [ "$AP_ADDR" = static ] && [ "$AP_IP" != "$wip" ] && TMPWAN=1
  FROMWAN=0
  if [ "$BRIDGE_WAN" = 1 ]; then CAB=bridge
  elif [ "$TOPO" = wan ]; then CAB=move; FROMWAN=1
  elif [ "$WANBR" = 1 ] && [ "$WANCAR" = 1 ]; then CAB=move; FROMWAN=1     # Gateway on a bridged WAN port
  elif [ "$TOPO" = lan ]; then CAB=lan
  else CAB=connect; fi
fi

# ---------------------------------------------------------------- monitoring: the question (applied after roaming works)
MON_HAS="$(mon_backend)"
if ! isset MONITORING; then
  step "Monitoring (optional)"
  if [ "$ROLE" = ap ]; then _mw="this Dumb AP sends its Wi-Fi client counts to the Gateway ($GW_IP)"
  else _mw="this Gateway collects every AP's Wi-Fi client counts: LuCI graphs, 24 h and 30 days"; fi
  box "Monitoring" "$_mw" "a roam shows up as one AP's count dropping while another's rises" \
    "installed after roaming is verified; if it fails you get a warning, roaming stays"
  [ -z "$MON_HAS" ] || say "  ${D}already installed here; \"no\" leaves it exactly as it is.${N}"
  say ""
fi
choose MONITORING "Enable monitoring?" no "no|no — skip" "yes|yes — install and set up"
MON_PORT="${MON_PORT:-$MON_DEFPORT}"
case "$MONITORING" in yes|no) ;; *) wrn "MONITORING='$MONITORING' is not yes or no — monitoring stays off"; MONITORING=no;; esac
if [ "$MONITORING" = yes ] && ! v_port "$MON_PORT" >/dev/null; then wrn "MON_PORT='$MON_PORT' is not a port — monitoring stays off"; MONITORING=no; fi

# ---------------------------------------------------------------- 11. plan
CH=Apply
step "Plan — nothing has been changed yet"
echo "$PLAN" | while IFS='|' read -r r band iface isnew uplink ch ht txp; do
  [ -n "$r" ] || continue
  rd=""; [ "$(uci -q get wireless.$r.disabled || true)" = 1 ] && rd="  ${YE}radio is OFF → will be switched ON${N}"
  say "  ${B}$r${N} ($band)$rd"
  if [ -n "$rd" ]; then
    for s in $(sections wireless wifi-iface); do
      [ "$(iget "$s" device)" = "$r" ] && [ "$s" != "$iface" ] && [ "$(iget "$s" disabled)" != 1 ] || continue
      wrn "also comes up with the radio: $s '$(iget "$s" ssid)' (net=$(iget "$s" network))"
    done
  fi
  if [ "$isnew" = 1 ]; then say "    new Wi-Fi network $iface on 'lan'"
  else
    say "    reuse $iface (net=$(iget "$iface" network))"
    [ "$(iget "$iface" ssid)" = "$SSID" ] || wrn "SSID '$(iget "$iface" ssid)' → '$SSID'  (its clients must reconnect)"
    [ "$(iget "$iface" key)" = "$KEY" ]   || wrn "password changes  (its clients must re-enter it)"
    [ "$(iget "$iface" encryption)" = "$ENC" ] || say "    encryption $(iget "$iface" encryption) → $ENC"
  fi
  case "$ch" in keep) ;; auto) say "    channel $(uci -q get wireless.$r.channel || echo auto) → auto from: $(autolist "$band")";;
                *) say "    channel $(uci -q get wireless.$r.channel || echo auto) → $ch";; esac
  [ "$ht" = keep ]  || say "    htmode $(uci -q get wireless.$r.htmode || echo -) → $ht"
  [ "$txp" = keep ] || say "    txpower $(uci -q get wireless.$r.txpower || echo max) → $txp"
  [ -n "$uplink" ] || [ "$COUNTRY" = keep ] || [ "$COUNTRY" = "$(uci -q get wireless.$r.country || true)" ] \
    || say "    country $(uci -q get wireless.$r.country || echo unset) → $COUNTRY"
done
say ""
say "  SSID ${B}'$SSID'${N} ($([ "$HIDDEN" = 1 ] && echo hidden || echo visible)) · $ENC · MD $MD · steer below $ROAM_DBM dBm"
for r in $(sections wireless wifi-device); do case " $SEL " in *" $r "*) ;; *) say "  ${D}untouched: $r${N}";; esac; done
if [ "$ROLE" = ap ]; then
  say ""
  if [ "$AP_ADDR" = dhcp ]; then say "  LAN: DHCP client of the Gateway · hostname $NAME"
  else say "  LAN: ${B}$AP_IP/$PFX${N} · gateway + DNS $GW_IP · hostname $NAME"; fi
  [ -z "$MGMT_PC" ] || say "  recovery address $MGMT_IP/24 — a laptop cabled to it with fixed $MGMT_PC/24 reaches it, Gateway or not"
  [ "$TS_FIX" != 1 ] || say "  tailscale on this router: accept-routes → off (it would pull the LAN into the tailnet)"
  say "  this router's own DHCP/RA server + firewall: OFF"
  [ "$WANBR" = 0 ] || [ "$BRIDGE_WAN" = 1 ] || say "  WAN port: taken OUT of the LAN bridge (an earlier setup had put it there)"
  case "$CAB" in
    lan)     say "  uplink: the Gateway is already on a LAN port — no recabling";;
    connect) say "  uplink: connect the Gateway to a LAN port other than $P1 when told";;
    bridge)  say "  uplink: WAN port bridged into the LAN (BRIDGE_WAN=1)";;
    move)    say "  uplink: you MOVE the Gateway cable from WAN to a LAN port other than $P1 when told"
             [ "$TMPWAN" = 0 ] || say "          WAN keeps its lease ($wip) until the Dumb AP is confirmed on $AP_IP — a way back in";;
  esac
  say ""
  say "  ${B}Safety${N}: recovery card + restore.sh are saved first · self-check after the switch ·"
  say "  confirmed only when the Gateway answers through the LAN ports AND you log in (SSH/LuCI) or"
  say "  run ./roaming-setup.sh confirm — otherwise rollback after ${CONFIRM_TIMEOUT}s"
fi
if [ "$MONITORING" = yes ]; then
  say ""
  if [ "$ROLE" = ap ]; then say "  monitoring: sends to $GW_IP:$MON_PORT once this Dumb AP is confirmed; a failure only warns"
  else say "  monitoring: LuCI Statistics, listens on port $MON_PORT, hourly backup in cron — after Wi-Fi is verified; a failure only warns"; fi
fi
[ "$DRY_RUN" = 1 ] || confirm "Apply this plan?" || { say "  aborted — nothing changed"; exit 0; }

# ---------------------------------------------------------------- recovery card / restore.sh
OLDIP=""; LL=""
[ "$ROLE" != ap ] || LL="$(ip -6 -o addr show dev br-lan scope link 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
recovery_card() {
  if [ "$ROLE" = ap ]; then cat <<EOT
LAPTOP CABLED TO ANY LAN PORT OF THE DUMB AP (Gateway connected or not):$(
 [ -z "$MGMT_PC" ] || printf '\n - give the laptop the fixed address %s/24  →  ssh root@%s' "$MGMT_PC" "$MGMT_IP")$(
 [ -z "$LL" ] || printf '\n - or no settings at all (IPv6 link-local):  ssh root@%s%%<interface>\n   interface = the laptop'"'"'s cable port: Linux eth0/enp…, macOS en…, Windows its number' "$LL")
 - with the Gateway cabled to it, a laptop on DHCP gets a Gateway address → ssh root@${AP_IP:-<its address>}

IF THE DUMB AP BECOMES UNREACHABLE   (copy on the Dumb AP: $SNAP/RECOVERY.txt)
 1. Wait. Unless confirmed within ${CONFIRM_TIMEOUT}s it rolls back by itself; once the Gateway
    cable is out of its LAN ports it returns to ${OLDIP:-its old address} with DHCP on.$(
 [ "${FROMWAN:-0}" != 1 ] || printf '
    Put the Gateway cable back into its WAN port: %s it is reachable
    at its old address %s again (from the Gateway).' "$([ "${TMPWAN:-0}" = 1 ] && echo "before confirmation and after a rollback" || echo "after a rollback")" "${wip:-${OLDREACH:-}}")
 2. Unplug the Gateway cable from the Dumb AP, power-cycle it (no buttons), wait 3 min.
    A PC on its first LAN port ($P1) should get an address → ssh root@${OLDIP:-192.168.1.1}
 3. Failsafe — always works:
    - PC on the FIRST LAN port ($P1) with a FIXED address 192.168.1.10/24 (failsafe has no
      DHCP and listens only there; a phone/proot shell can't set this — use a laptop)
    - power on, tap reset as soon as the status LED blinks → it blinks fast (failsafe)
    - ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@192.168.1.1
    - mount_root; sh $SNAP/restore.sh      (factory reset instead: firstboot -y && reboot -f)
 4. Last resort: the device's bootloader recovery (TFTP / web / nmrpflash) — see its page
    in the OpenWrt Table of Hardware.
EOT
  else cat <<EOT
UNDO ON THE GATEWAY:  sh $SNAP/restore.sh   (restores Wi-Fi, usteer, hostname; reboots)
EOT
  fi
}
mkrestore() {
  if [ "$ROLE" = ap ]; then files="network dhcp wireless system"; else files="wireless system"; fi
  {
    echo '#!/bin/sh'
    echo "# Roamer v$VERSION — restore the configuration saved before the run $TS"
    echo "D=$SNAP"
    echo "for f in $files; do cp \"\$D/\$f\" /etc/config/\$f; done"
    echo 'if [ -f "$D/usteer" ]; then cp "$D/usteer" /etc/config/usteer; else rm -f /etc/config/usteer; fi'
    echo '[ -f "$D/.usteer_was_enabled" ] || /etc/init.d/usteer disable 2>/dev/null'
    [ "$ROLE" = ap ] && echo "for s in $SVC_ON; do /etc/init.d/\$s enable; done"
    if [ "${MONITORING:-no}" = yes ]; then     # this run set monitoring up: undo that too (packages stay installed)
      echo 'for f in luci_statistics collectd; do if [ -f "$D/$f" ]; then cp "$D/$f" /etc/config/$f; elif [ -x /etc/init.d/$f ]; then /etc/init.d/$f stop; /etc/init.d/$f disable; fi; done'
      echo 'if [ -f "$D/crontabs.root" ]; then cp "$D/crontabs.root" /etc/crontabs/root; else sed -i "/ service luci_statistics backup\$/d" /etc/crontabs/root 2>/dev/null; fi'
    fi
    echo 'sync; echo "restored from $D — rebooting"; reboot -f'
  } > "$SNAP/restore.sh"
  chmod 700 "$SNAP/restore.sh"
  ln -sf "$SNAP/restore.sh" /etc/roaming-setup.bak/restore-latest.sh
  recovery_card > "$SNAP/RECOVERY.txt"
}

# ---------------------------------------------------------------- snapshot
SNAP="/etc/roaming-setup.bak/$TS"
SVC_ON=""
if [ "$DRY_RUN" != 1 ]; then
  mkdir -p "$SNAP"
  for f in wireless usteer system network dhcp firewall luci_statistics collectd; do if [ -f /etc/config/$f ]; then cp /etc/config/$f "$SNAP/"; fi; done
  if [ -f /etc/crontabs/root ]; then cp /etc/crontabs/root "$SNAP/crontabs.root"; fi
  if /etc/init.d/usteer enabled 2>/dev/null; then touch "$SNAP/.usteer_was_enabled"; fi
  for s in dnsmasq odhcpd firewall; do if /etc/init.d/$s enabled 2>/dev/null; then SVC_ON="$SVC_ON $s"; fi; done
  OLDIP="$(awk '/^config interface .lan.$/{f=1;next} /^config /{f=0} f && $2=="ipaddr"{gsub(/\047/,"",$3); sub(/\/.*/,"",$3); print $3; exit}' "$SNAP/network" 2>/dev/null || true)"
  mkrestore
  log "snapshot + restore script: $SNAP"
fi

# ---------------------------------------------------------------- stage
STAGED=1
echo "$PLAN" | while IFS='|' read -r r band iface isnew uplink ch ht txp; do
  [ -n "$r" ] || continue
  uci set wireless.$r.disabled='0'
  if [ -z "$uplink" ]; then
    [ "$COUNTRY" = keep ] || uci set wireless.$r.country="$COUNTRY"
    case "$ch" in
      keep) ;;
      auto) uci set wireless.$r.channel='auto'; uci -q delete wireless.$r.chanlist || true; uci -q delete wireless.$r.channels || true
            for c in $(autolist "$band"); do uci add_list wireless.$r.channels="$c"; done ;;
      *)    uci set wireless.$r.channel="$ch"; uci -q delete wireless.$r.chanlist || true; uci -q delete wireless.$r.channels || true ;;
    esac
    [ "$ht" = keep ] || uci set wireless.$r.htmode="$ht"
    case "$txp" in keep) ;; max) uci -q delete wireless.$r.txpower || true ;; *) uci set wireless.$r.txpower="$txp" ;; esac
  fi
  if [ "$isnew" = 1 ]; then
    uci set wireless.$iface=wifi-iface
    uci set wireless.$iface.device="$r"
    uci set wireless.$iface.mode='ap'
    uci set wireless.$iface.network='lan'
  fi
  uci set wireless.$iface.ssid="$SSID"
  uci set wireless.$iface.encryption="$ENC"
  uci set wireless.$iface.key="$KEY"
  uci set wireless.$iface.ieee80211w="$MFP"
  if [ "$HIDDEN" = 1 ]; then uci set wireless.$iface.hidden='1'; else uci -q delete wireless.$iface.hidden || true; fi
  uci -q delete wireless.$iface.disabled || true
  uci set wireless.$iface.ieee80211r='1'
  uci set wireless.$iface.mobility_domain="$MD"
  uci set wireless.$iface.ft_over_ds='0'
  uci -q delete wireless.$iface.ft_psk_generate_local || true
  uci set wireless.$iface.reassociation_deadline='20000'
  uci set wireless.$iface.ieee80211k='1'
  if [ "$WNM" = 1 ]; then uci set wireless.$iface.bss_transition='1'; else uci -q delete wireless.$iface.bss_transition || true; fi
  lg "staged $r ($band) -> $iface"
done
if [ ! -f /etc/config/usteer ] && [ "$DRY_RUN" != 1 ]; then touch /etc/config/usteer; fi
if [ -f /etc/config/usteer ]; then
  [ -n "$(sections usteer usteer)" ] || uci add usteer usteer >/dev/null
  for kv in network=lan local_mode=0 ipv6=0 syslog=1 debug_level=2 assoc_steering=1 \
            band_steering_threshold=5 band_steering_min_snr=-60 roam_scan_snr=$ROAM_SCAN \
            roam_trigger_snr=$ROAM_DBM signal_diff_threshold=8; do
    uci set "usteer.@usteer[0].${kv%%=*}=${kv#*=}"
  done
fi
if [ -n "$NAME" ]; then uci set system.@system[0].hostname="$NAME"; fi

LANPORTS=""; BRMAC=""
if [ "$ROLE" = ap ]; then
  br="$(brsec)"; [ -n "$br" ] || die "br-lan device section not found"
  BRMAC="$(cat "$SYSNET/br-lan/address" 2>/dev/null || true)"
  _bm="$(uci -q get network.$br.macaddr || true)"; _wm="$(cat "$SYSNET/${wdev:-wan}/address" 2>/dev/null || true)"
  if [ -n "$_bm" ] && [ -n "$_wm" ] && [ "$_bm" = "$_wm" ]; then uci -q delete network.$br.macaddr || true; fi   # undo an old WAN-MAC clone only
  if [ "$AP_ADDR" = dhcp ]; then
    uci set network.lan.proto='dhcp'
    for o in ipaddr netmask gateway dns ip6assign; do uci -q delete network.lan.$o || true; done
  else
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$AP_IP"
    uci set network.lan.netmask="$NETMASK"
    uci set network.lan.gateway="$GW_IP"
    uci -q delete network.lan.dns || true
    uci add_list network.lan.dns="$GW_IP"
    uci -q delete network.lan.ip6assign || true
  fi
  if [ "$BRIDGE_WAN" = 1 ]; then
    uci show network.$br.ports 2>/dev/null | grep -q "'$wdev'" || uci add_list network.$br.ports="$wdev"
  else
    uci -q del_list network.$br.ports="$wdev" || true      # WAN never stays inside the LAN bridge
  fi
  LANPORTS="$(uci -q get network.$br.ports || true)"
  uci -q delete network.wan6 || true
  if [ "$TMPWAN" = 1 ]; then          # temporary way in on the old WAN lease; removed after confirmation
    uci set network.wan.defaultroute='0'; uci set network.wan.peerdns='0'
    uci -q delete network.wan.metric || true
    uci set network.lan.metric='10'   # while both exist, replies to the old address leave through WAN
  else
    uci -q delete network.wan || true
  fi
  if [ "$MGMT_IP" != off ]; then
    uci set network.mgmt=interface
    uci set network.mgmt.proto='static'
    uci set network.mgmt.device='br-lan'
    uci set network.mgmt.ipaddr="$MGMT_IP"
    uci set network.mgmt.netmask='255.255.255.0'
  else uci -q delete network.mgmt || true; fi
  uci set dhcp.lan.ignore='1'
  uci -q delete dhcp.lan.ra || true
  uci -q delete dhcp.lan.dhcpv6 || true
fi

# ---------------------------------------------------------------- pairing payload (Gateway)
mkpair() {   # $1 = 1 → use operating channels (after apply)
  c2="" c5=""
  for r in $SEL; do
    oc=""; [ "${1:-0}" = 1 ] && oc="$(opchan "$r" || true)"
    [ -n "$oc" ] || oc="$(uci -q get wireless.$r.channel || echo auto)"
    case "$(uci -q get wireless.$r.band)" in 2g) c2="$oc";; 5g) c5="$oc";; esac
  done
  lraw="$(uci -q get network.lan.ipaddr || true)"; lraw="${lraw%% *}"
  case "$lraw" in */*) lip="${lraw%/*}"; lpf="${lraw#*/}";;
    *) lip="$lraw"; lpf="$(cval "$lip/$(uci -q get network.lan.netmask || echo 255.255.255.0)" "" "" PREFIX)";; esac
  cc="$COUNTRY"; [ "$cc" = keep ] && cc="${curc:-keep}"
  printf 'V=1\nSSID=%s\nKEY=%s\nENC=%s\nMD=%s\nHIDDEN=%s\nCOUNTRY=%s\nBANDS=%s\nROAM_DBM=%s\nGW_IP=%s\nGW_PREFIX=%s\nGW_CH2=%s\nGW_CH5=%s\nPOOL_START=%s\nPOOL_LIMIT=%s\nGW_NAME=%s\n' \
    "$SSID" "$KEY" "$ENC" "$MD" "$HIDDEN" "$cc" "$BANDS" "$ROAM_DBM" "$lip" "${lpf:-24}" "$c2" "$c5" \
    "$(uci -q get dhcp.lan.start || echo 100)" "$(uci -q get dhcp.lan.limit || echo 150)" "$HOST"
  _mp="$(uci -q get luci_statistics.roamer_listen.port || true)"; [ -z "$_mp" ] || printf 'MON_PORT=%s\n' "$_mp"
}

if [ "$DRY_RUN" = 1 ]; then
  out ""; out "---- staged changes (DRY_RUN — reverting, nothing written) ----"
  uci changes | sed "s/\(\.key=\).*/\1'********'/" | while IFS= read -r l; do out "$l"; done
  if [ "$ROLE" = gateway ] && command -v ucode >/dev/null; then
    out "---- pairing code this run would produce ----"; out "ROAM1:$(b64e "$(mkpair 0)")"
  fi
  for p in $PKGS; do uci revert "$p" 2>/dev/null || true; done
  STAGED=0; exit 0
fi

for p in $PKGS; do uci commit "$p"; done
COMMITTED=1
[ ! -x /etc/init.d/system ] || /etc/init.d/system reload 2>/dev/null || true     # applies the new hostname now
/etc/init.d/usteer enable

# ================================================================ apply: Dumb AP
# Is a roaming network broadcasting? hostapd itself is asked first (ubus hostapd.<if> get_status —
# present on every wpad build), then iw, then iwinfo; any one that says "AP running" is enough.
# Interface names come from netifd's status; if that lookup fails, an enabled hostapd BSS with our
# SSID counts. (≤ 8.4 trusted only "iwinfo … Mode: Master" — a missing or differently-worded iwinfo
# made a working Wi-Fi look dead.)
wif_name() {     # <radio> <wifi-iface section> → kernel interface name, or nothing
  _ws="$(ubus call network.wireless status 2>/dev/null)" || return 0
  for _q in "@.$1.interfaces[@.section=\"$2\"].ifname" "@.$1.interfaces[@.section='$2'].ifname"; do
    _x="$(jsonfilter -s "$_ws" -e "$_q" 2>/dev/null | head -n1)"; [ -z "$_x" ] || { echo "$_x"; return 0; }
  done
}
bss_up() {       # <ifname> → 0 when that interface is an AP that is running
  ubus call "hostapd.$1" get_status 2>/dev/null | grep -q '"status": *"ENABLED"' && return 0
  iw dev "$1" info 2>/dev/null | grep -q 'type AP' && return 0
  iwinfo "$1" info 2>/dev/null | grep -qE 'Mode: (Master|AP)' && return 0
  return 1
}
ssid_bss() {     # number of enabled hostapd BSSes broadcasting our SSID
  _k=0
  for _o in $(ubus list 'hostapd.*' 2>/dev/null); do
    _st="$(ubus call "$_o" get_status 2>/dev/null)"
    printf '%s' "$_st" | grep -q '"status": *"ENABLED"' || continue
    [ "$(jf "$_st" '@.ssid')" = "$SSID" ] && _k=$((_k + 1))
  done; echo $_k
}
wifi_up() {      # every roaming Wi-Fi network is broadcasting
  _need=0; _bad=0
  for _e in $(printf '%s\n' "$PLAN" | cut -d'|' -f1,3); do
    _need=$((_need + 1)); _ifn="$(wif_name "${_e%%|*}" "${_e#*|}")"
    [ -n "$_ifn" ] && bss_up "$_ifn" || _bad=$((_bad + 1))
  done
  [ "$_need" -gt 0 ] || return 1
  [ "$_bad" = 0 ] || [ "$(ssid_bss)" -ge "$_need" ]     # hostapd itself reports our SSID on enough BSSes
}
wifi_fail() {    # one line: why Wi-Fi counts as not started
  _y="$(wifi_why)"
  if [ -n "$_y" ]; then echo "Wi-Fi did not start — hostapd: $_y · the check saw: $(wifi_facts)"
  else echo "Wi-Fi did not start within ${WIFI_MAX}s — hostapd logged no error; the check saw: $(wifi_facts)"; fi
}
wifi_facts() {   # what the Wi-Fi check saw, per roaming network (no secrets) — for the log on failure
  for _e in $(printf '%s\n' "$PLAN" | cut -d'|' -f1,3); do
    _r="${_e%%|*}"; _s="${_e#*|}"; _ifn="$(wif_name "$_r" "$_s")"
    printf '%s/%s → %s' "$_r" "$_s" "${_ifn:-no interface}"
    if [ -n "$_ifn" ]; then
      printf ' · hostapd %s · iw %s · iwinfo %s' \
        "$(ubus call "hostapd.$_ifn" get_status 2>/dev/null | sed -n 's/.*"status": *"\([A-Z_]*\)".*/\1/p' | head -n1 | grep . || echo -)" \
        "$(iw dev "$_ifn" info 2>/dev/null | sed -n 's/^[[:space:]]*type //p' | head -n1 | grep . || echo -)" \
        "$(iwinfo "$_ifn" info 2>/dev/null | sed -n 's/.*Mode: \([A-Za-z]*\).*/\1/p' | head -n1 | grep . || echo -)"
    fi; printf '; '
  done
  printf 'hostapd BSSes with SSID %s: %s' "'$SSID'" "$(ssid_bss)"
}
WIFI_MAX="${WIFI_WAIT:-90}"; isset WIFI_WAIT || case " $(autolist 5g 2>/dev/null) $(printf '%s' "$PLAN" | cut -d'|' -f6 | tr '\n' ' ') " in *" 1"[0-4][0-9]" "*|*" 5"[2-9]" "*|*" 6"[0-4]" "*) WIFI_MAX=160;; esac   # DFS: 60 s radar check
wifi_wait() {
  _d=$(( $(date +%s) + WIFI_MAX ))
  while [ "$(date +%s)" -lt "$_d" ]; do
    wifi_up && return 0
    hlog | tail -n +$((HLOG0 + 1)) | grep -qE 'errors found in configuration|add_iface failed' && { sleep 2; return 1; }
    sleep 3
  done; return 1
}
hapd_pids() {    # running hostapd/wpad processes — via /proc/*/exe, which also finds them inside ujail
  for _d in /proc/[0-9]*; do
    case "$(readlink "$_d/exe" 2>/dev/null)" in */wpad*|*/hostapd*) echo "${_d#/proc/}";; esac; done
}
wpad_stale() {   # the RUNNING hostapd is not the installed one: replaced binary, or one without 802.11v
  for _p in $(hapd_pids); do
    readlink "/proc/$_p/exe" 2>/dev/null | grep -q '(deleted)' && return 0
    bin_wnm "${HBIN:-/nonexistent}" && ! bin_wnm "/proc/$_p/exe" && return 0      # installed has 802.11v, running hasn't
  done; return 1
}
wpad_fresh() {   # make sure the hostapd that will read our config is the installed one
  wpad_stale || return 0
  log "the running hostapd is not the installed one (replaced by a package update) — restarting wpad"
  /etc/init.d/wpad restart >/dev/null 2>&1 || true; sleep 3
}
hlog() { logread 2>/dev/null | grep -v 'roaming-setup' | grep -E 'hostapd|wpad' || true; }   # hostapd's own lines only
HLOG0=0; hmark() { HLOG0="$(hlog | wc -l)"; }                    # remember where the log was before we applied
drop_wnm() {     # this hostapd refuses 802.11v: remove the option entirely — the wifi scripts pass it
                 # on whenever it is SET (even =0), and such a hostapd rejects the key itself. All networks
                 # of a radio share one hostapd config, so one leftover elsewhere on the radio breaks it too.
  _dl=""
  for _s in $(sections wireless wifi-iface); do
    case " $SEL " in *" $(iget "$_s" device) "*) ;; *) continue;; esac
    [ -n "$(iget "$_s" bss_transition)" ] || continue
    uci -q delete "wireless.$_s.bss_transition" || true; _dl="$_dl $_s"
  done
  log "  802.11v removed from:${_dl:- (nothing set)}"
  uci commit wireless; hmark; wifi >/dev/null 2>&1 || true
}
wifi_recover() { # Wi-Fi didn't come up. Returns 0 when it is up after the fixes below; sets WNMOFF=1 if 802.11v had to go
  wifi_why | grep -q bss_transition || return 1
  log "hostapd refuses 802.11v (bss_transition)"; log "  hostapd: $(wifi_why)"; log "  $(wnm_facts)"
  if bin_wnm "${HBIN:-/nonexistent}"; then          # the installed one can — so the running one is old
    log "  the installed hostapd can do 802.11v — restarting wpad so that one runs"
    /etc/init.d/wpad restart >/dev/null 2>&1 || true; sleep 3; hmark; wifi >/dev/null 2>&1 || true
    if wifi_wait; then log "  ✓ Wi-Fi up with 802.11v after restarting wpad"; return 0; fi
    log "  still refused after the restart: $(wifi_why)"
  fi
  log "  retrying without 802.11v"; drop_wnm; WNMOFF=1
  wifi_wait
}
wifi_why() {     # hostapd's complaint since we applied (not older lines, not Roamer's own)
  _w="$(hlog | tail -n +$((HLOG0 + 1)))"; [ -n "$_w" ] || _w="$(hlog | tail -n 20)"
  printf '%s\n' "$_w" | grep -iE 'unknown|invalid|fail|error|could not' | sed -E 's/^.*(hostapd|wpad)[^:]*: *//' \
    | awk '!seen[$0]++' | tail -n 3 | tr '\n' ' '
}
wnm_facts() { echo "installed: $(wpad_pkgs)· /usr/sbin/hostapd → ${HBIN:-?} 802.11v=$(bin_wnm "${HBIN:-/nonexistent}" && echo yes || echo no) · running: $(for _p in $(hapd_pids); do printf '%s %s(802.11v=%s) ' "$_p" "$(readlink "/proc/$_p/exe")" "$(bin_wnm "/proc/$_p/exe" && echo yes || echo no)"; done)"; }
LOGIN_RE='[Aa]uth succeeded|accepted login'
logins() { logread -e "$LOGIN_RE" 2>/dev/null | wc -l; }
brok() {   # every LAN port is in br-lan — carrier is NOT required (cables may be moving right now)
  [ -d "$SYSNET/br-lan" ] || return 1
  for p in $LANPORTS; do [ -e "$SYSNET/br-lan/brif/$p" ] || return 1; done
}
lanpath() {   # does the Gateway answer through br-lan (the LAN ports), not through the old WAN path?
  if [ "$AP_ADDR" = dhcp ]; then [ -n "$(jf "$(ifstatus lan 2>/dev/null)" '@["ipv4-address"][0].address')" ]; return; fi
  ping -c1 -W2 -I br-lan "$GW_IP" >/dev/null 2>&1 && return 0
  ip neigh show "$GW_IP" dev br-lan 2>/dev/null | grep -q REACHABLE
}

if [ "$ROLE" = ap ]; then
  [ "$TS_FIX" != 1 ] || { tailscale set --accept-routes=false 2>/dev/null && lg "tailscale: accept-routes off"; } || true
  for s in dnsmasq odhcpd firewall; do /etc/init.d/$s disable 2>/dev/null || true; done
  wpad_fresh
  rm -f "$CONFIRMFILE"
  if [ -f "$JOBPID" ] && kill -0 "$(cat "$JOBPID" 2>/dev/null)" 2>/dev/null; then
    kill "$(cat "$JOBPID")" 2>/dev/null || true; lg "stopped an earlier Roamer background job"; fi
  echo "applying|||switching over in 5 s" > "$STATEFILE"
  if [ "$MONITORING" = yes ]; then mon_state pending; else rm -f "$MONSTATEFILE"; fi
  if [ "$AP_ADDR" = static ]; then RECONNECT="$AP_IP"; NEWADDR="$AP_IP"; else RECONNECT="$NAME.lan"; NEWADDR=dhcp; fi
  case "$CAB" in
    lan)    step1="No cable changes — the Gateway is already on a LAN port.";;
    bridge) step1="Leave the Gateway cable in the Dumb AP's WAN port.";;
    move)   step1="MOVE the Gateway cable from the Dumb AP's WAN port to a LAN port other than $P1."
            if [ "$TMPWAN" = 1 ]; then step1="$step1
     Until you do, it stays reachable at its old address $wip (within ${CONFIRM_TIMEOUT}s)."
            else step1="$step1
     Until you do, it can't reach the Gateway; without that it rolls back after ${CONFIRM_TIMEOUT}s."; fi;;
    *)      step1="Connect the Gateway to a LAN port of the Dumb AP other than $P1 — now.";;
  esac
  step "Switching over — read this"
  out "  The Dumb AP switches over in ~5 s; this session ends now."
  out ""
  out "  1. $step1"
  out "     Exactly ONE cable between the Dumb AP and the Gateway — never two (= loop)."
  out "  2. Wait ~30 s. The Dumb AP's LAN ports drop briefly during the network restart, so wired"
  out "     clients ask the Gateway for a fresh address (replug a cable if one doesn't)."
  out "  3. Put your computer on the Gateway (LAN/Wi-Fi) — or on a Dumb AP LAN port once the Dumb"
  out "     AP is cabled to the Gateway — and log in:  ssh root@$RECONNECT"
  out "     It is confirmed when the Gateway answers through its LAN ports AND you log in"
  out "     (SSH/LuCI)$([ "${WS:-0}" = 1 ] && echo " — the computer does that for you"). Otherwise: rollback after ${CONFIRM_TIMEOUT}s."
  [ -z "$MGMT_PC" ] || out "     Laptop cabled straight to the Dumb AP: fixed $MGMT_PC/24 → ssh root@$MGMT_IP"
  [ -z "$LL" ] || out "     or with no settings at all (IPv6 link-local): ssh root@$LL%<laptop's cable interface>"
  [ "$AP_ADDR" = static ] || out "     Dumb AP LAN MAC ${BRMAC:-?} — reserve an address for it on the Gateway if you like."
  out "  Progress on the Dumb AP:  ./roaming-setup.sh state | status   or   logread -e roaming-setup"
  out ""
  out "----- RECOVERY CARD -----"
  recovery_card | while IFS= read -r l; do out "$l"; done
  out "----- END -----"
  _o=-; [ "$TMPWAN" != 1 ] || _o="$wip"
  [ "${WS:-0}" = 1 ] && out "${D}ROAMER-SWITCH $RECONNECT $CONFIRM_TIMEOUT $CAB $_o $P1${N}"

  ( trap '' HUP INT
    exec </dev/null >"$APLOG" 2>&1
    alog() { echo "$(date +%T) $*"; logger -t roaming-setup "$*"; }
    st() { echo "$*" > "$STATEFILE"; }
    rollback() {
      st "rolling-back|||$1"; rm -f "$MONSTATEFILE"
      alog "ROLLING BACK ($1) to $SNAP"
      alt=""; gw_here=0; ping -c1 -W1 "$GW_IP" >/dev/null 2>&1 && gw_here=1
      for f in network dhcp wireless system; do cp "$SNAP/$f" /etc/config/$f; done
      if [ -f "$SNAP/usteer" ]; then cp "$SNAP/usteer" /etc/config/usteer; else rm -f /etc/config/usteer; fi
      [ -f "$SNAP/.usteer_was_enabled" ] || { /etc/init.d/usteer stop; /etc/init.d/usteer disable; } || true
      rip="$(uci -q get network.lan.ipaddr || true)"; rip="${rip%% *}"
      if [ $gw_here = 1 ] && [ "${rip%/*}" = "$GW_IP" ]; then
        alt="${AP_IP:-$(cval "$GW_IP/$PFX" 2 1 START)}"
        case "$rip" in */*) uci set network.lan.ipaddr="$alt/${rip#*/}";; *) uci set network.lan.ipaddr="$alt";; esac
        uci commit network
        alog "the Gateway $GW_IP is reachable on this LAN — rolled-back router uses $alt instead of $GW_IP"
      fi
      for s in $SVC_ON; do /etc/init.d/$s enable || true; done
      [ ! -x /etc/init.d/system ] || /etc/init.d/system reload || true
      /etc/init.d/network restart; sleep 10
      for s in firewall dnsmasq odhcpd; do case " $SVC_ON " in *" $s "*) /etc/init.d/$s start || true;; esac; done
      sleep 3; wifi up || true
      back="router again at $(uci -q get network.lan.ipaddr)"
      [ "$FROMWAN" != 1 ] || back="$back; Gateway cable back into WAN → reachable as before"
      st "rolled-back|||$1 — $back"
      alog "ROLLED BACK: $back"
      if [ $gw_here = 1 ]; then
        alog "Gateway is on this LAN — waiting (up to 60 min) for its cable to be unplugged"
        t=0; while [ $t -lt 3600 ]; do
          sleep 15; t=$((t+15))
          udhcpc -n -q -s /bin/true -t 1 -T 2 -i br-lan >/dev/null 2>&1 && continue
          if [ -n "$alt" ]; then uci set network.lan.ipaddr="$rip"; uci commit network; ifup lan; sleep 5; fi
          /etc/init.d/dnsmasq restart || true
          alog "Gateway gone from the LAN — router at ${rip%/*} with DHCP on again"
          break
        done
      fi
      exit 1
    }
    sleep 5
    st "applying|||restarting the network"
    alog "Dumb AP conversion: stopping DHCP/RA + firewall, restarting network (snapshot $SNAP)"
    for s in odhcpd dnsmasq firewall; do /etc/init.d/$s stop || true; done
    hmark; /etc/init.d/network restart; sleep 10
    sleep 3; wifi up || true
    sleep 5; /etc/init.d/usteer restart || true
    if ! brok; then alog "self-check: bridge incomplete ($(ls "$SYSNET/br-lan/brif" 2>/dev/null | tr '\n' ' ')) — reloading network"
      ubus call network reload; sleep 8; brok || rollback "LAN ports did not join br-lan"; fi
    if [ "$AP_ADDR" = static ]; then
      t=0; until ip -4 addr show br-lan 2>/dev/null | grep -q " $AP_IP/"; do
        t=$((t+2)); [ $t -le 20 ] || rollback "br-lan never got $AP_IP"; sleep 2; done
    fi
    alog "self-check OK: br-lan $(ip -4 -o addr show br-lan | awk '{print $4}' | tr '\n' ' ')· ports $(ls "$SYSNET/br-lan/brif" | tr '\n' ' ')"
    [ "$TMPWAN" = 0 ] || alog "temporary way in: WAN $(ip -4 -o addr show "$wdev" 2>/dev/null | awk '{print $4}' | head -n1)"
    st "applying|||starting Wi-Fi (DFS channels need ~60 s)"
    if wifi_wait; then alog "Wi-Fi is up on: $SEL"
    elif WNMOFF=0; wifi_recover; then
      alog "Wi-Fi is up on: $SEL$([ "$WNMOFF" = 1 ] && echo " (802.11v off — see the log above)")"
    else rollback "$(wifi_fail)"; fi
    DL=$(( $(date +%s) + CONFIRM_TIMEOUT ))
    n0="$(logins)"; t=0; ok=0; last=""; how=""; msg=""
    while :; do
      if [ -z "$how" ] && [ -f "$CONFIRMFILE" ]; then how="confirm"; fi
      if [ -z "$how" ]; then
        n="$(logins)"; [ "$n" -ge "$n0" ] || n0="$n"
        if [ "$n" -gt "$n0" ]; then
          src="$(logread -e "$LOGIN_RE" | tail -n1 | sed -n 's/.* from \([0-9.]*\).*/\1/p')"; how="login from ${src:-?}"; fi
      fi
      lp=no; if lanpath; then lp=yes; fi
      if [ -n "$how" ] && [ $lp = yes ]; then ok=1; alog "confirmed ($how) — the Gateway answers through the LAN ports"; break; fi
      if [ "$CONFIRM_TIMEOUT" = 0 ]; then ok=1; alog "CONFIRM_TIMEOUT=0 — rollback disabled"; break; fi
      msg="Gateway via LAN ports: $lp · confirmation: ${how:-none yet}"
      st "waiting|$NEWADDR|$DL|$msg"
      cur="$(ip -4 -o addr show br-lan 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
      [ "$cur$msg" = "$last" ] || alog "br-lan: ${cur:-no address} · $msg"
      last="$cur$msg"
      [ "$(date +%s)" -lt "$DL" ] || break      # by the clock: each round also spends time in ping/logread
      sleep 3
    done
    [ $ok = 1 ] || rollback "not confirmed within ${CONFIRM_TIMEOUT}s — $msg"
    if [ "$TMPWAN" = 1 ]; then
      uci -q delete network.wan || true; uci commit network; ubus call network reload || true
      alog "temporary WAN path removed"
    fi
    st "ok|$NEWADDR||set up successfully"
    alog "Dumb AP is set up successfully: $(ip -4 -o addr show br-lan | awk '{print $4}' | tr '\n' ' ')"
    # roaming is confirmed and the state says so: from here on nothing can roll it back
    LOGTMP=""; mon_run
  ) &
  echo $! > "$JOBPID"
  exit 0
fi

# ================================================================ apply: Gateway
trap '' HUP
step "Applying"
was_ok=0; if health; then was_ok=1; fi
log "applying (internet before: $([ $was_ok = 1 ] && echo up || echo DOWN))"
wpad_fresh; hmark
ubus call network reload; sleep 2; wifi >/dev/null 2>&1 || true
sleep 3; /etc/init.d/usteer restart
ok=1; WHY=""; WNMOFF=0
say "  ${D}waiting for Wi-Fi to come up (up to ${WIFI_MAX}s) …${N}"
if ! wifi_wait && ! wifi_recover; then ok=0; WHY="$(wifi_fail)"; fi
if [ $ok = 1 ] && [ "$GUARD" = 1 ] && [ "$was_ok" = 1 ]; then
  t=0; while [ $t -lt 45 ]; do health && break; sleep 3; t=$((t+3)); done
  health || { ok=0; WHY="internet lost after apply"; }
fi
if [ $ok = 0 ]; then
  log "FAIL: $WHY — rolling back wireless/usteer/system from $SNAP"
  cp "$SNAP/wireless" /etc/config/wireless; cp "$SNAP/system" /etc/config/system
  [ ! -x /etc/init.d/system ] || /etc/init.d/system reload 2>/dev/null || true
  if [ -f "$SNAP/usteer" ]; then cp "$SNAP/usteer" /etc/config/usteer; else rm -f /etc/config/usteer; fi
  [ -f "$SNAP/.usteer_was_enabled" ] || { /etc/init.d/usteer stop; /etc/init.d/usteer disable; } 2>/dev/null || true
  ubus call network reload
  t=0; while [ $t -lt 45 ]; do health && break; sleep 3; t=$((t+3)); done
  if [ "$WHY" != "internet lost after apply" ]; then log "ROLLED BACK: Wi-Fi settings restored. Details: logread -e hostapd"
  elif health; then log "ROLLED BACK: internet restored — cause is the Wi-Fi change. Send: logread | grep -E 'netifd|hostapd'"
  else log "STILL DOWN after rollback — not the Wi-Fi change: 'network reload' applied network/firewall config from disk that differed from what was running. Check: logread | grep -E 'netifd|udhcpc|pppd'; ifstatus wan."; fi
  exit 1
fi
CHK=""
[ "$was_ok" = 1 ] && { log "✓ internet still up"; CHK="✓ internet still up"; }
if command -v tailscale >/dev/null; then
  if tailscale status >/dev/null 2>&1; then CHK="$CHK  ✓ tailscale up"; else CHK="$CHK  · tailscale not set up"; fi
fi
t=0; while [ $t -lt 20 ]; do
  pending=0; for r in $SEL; do [ -n "$(opchan "$r" || true)" ] || pending=1; done
  [ $pending = 0 ] && break; sleep 2; t=$((t+2))
done
if [ "$MONITORING" = yes ]; then step "Monitoring"; mon_run; pause; else rm -f "$MONSTATEFILE"; fi
umask 077; mkpair 1 > "$PAIRFILE"
CODE="(ucode missing — no pairing code)"; command -v ucode >/dev/null && CODE="ROAM1:$(b64e "$(cat "$PAIRFILE")")"
chs=""; for r in $SEL; do chs="$chs $(uci -q get wireless.$r.band) ch $(opchan "$r" || echo '?')"; done
step "Done" final
out ""
out "$(ctr "${GR}${B}✓  Gateway is set up successfully${N}")"
out ""
[ "$WNMOFF" = 0 ] || { out "  ${YE}⚠${N} 802.11v is off: this router's hostapd can't do it (802.11r/k work)."
  out "    $(wnm_facts)"; out "    Fix: install the full wpad, reboot, run Roamer again — see docs/troubleshooting.md"; }
[ -z "$CHK" ] || out "  $CHK"
out "  SSID '$SSID' ($([ "$HIDDEN" = 1 ] && echo hidden || echo visible)) · $ENC · MD $MD · steer < $ROAM_DBM dBm ·$chs"
out ""
out "  PAIRING CODE for the Dumb AP — contains the Wi-Fi password, keep it private:"
out ""
out "$CODE"
out ""
if [ "${WS:-0}" = 1 ]; then
  out "  Saved on your computer. Next: connect to a Dumb AP and run ./roaming-setup.sh again —"
  out "  it picks the code up by itself."
else
  out "  Next, on a Dumb AP:   PAIR='$CODE' ./roaming-setup.sh"
  out "  Show the code again:  ./roaming-setup.sh pair"
fi
out ""
recovery_card | while IFS= read -r l; do out "  $l"; done
exit 0
