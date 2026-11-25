#!/usr/bin/env bash
# retropie-setup.sh - set up a fresh RetroPie 4.8 card (Raspberry Pi OS Buster) on a Raspberry Pi 3B.
#
# For RetroPie Pi 3B cards ONLY. It refuses to run anywhere else. Never run the Desktop setup
# script on a RetroPie card, and never run this on a Pi-hole, Kali or OctoPrint card.
#
# What it does (each step can be run alone with --only):
#   preflight  checks the board, OS, RetroPie and network (always runs)
#   fan        installs pi-pwm-fan (pigpiod + pwm-fan service, gaming curve)
#   config     overclock + GPU memory in /boot/config.txt (needs the fan unless forced)
#   bluetooth  installs bluealsa, points RetroArch audio at your speaker (--bt-mac)
#   retroarch  re-applies your RetroArch global settings (retroarch-overrides.cfg)
#   vb         installs the Virtual Boy core (lr-beetle-vb)
#   tailscale  installs Tailscale (you log in yourself; DNS stays on the Pi-hole chain)
#   verify     prints a health summary (always runs last)
# Opt-in only (changes the network, never runs by default):
#   --static-ip 192.168.10.202   writes a dhcpcd static address for wlan0 (applies at next reboot)
#
# Usage: ./retropie-setup.sh [--dry-run] [--only step,step] [--skip step,step]
#                            [--bt-mac AA:BB:CC:DD:EE:FF] [--static-ip IP] [--help]
set -euo pipefail

VERSION="0.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAN_REPO="${FAN_REPO:-https://github.com/AdditiveCraftsman/pi-pwm-fan}"
FAN_REF="${FAN_REF:-30a9b33}"          # the commit tested on the old RetroPie card
FAN_CURVE="${FAN_CURVE:-gaming}"
TS_HOSTNAME="${TS_HOSTNAME:-retropie-v2}"
CONFIG="${CONFIG:-/boot/config.txt}"   # Buster path; Bookworm/Trixie use /boot/firmware/config.txt
RA_CFG="${RA_CFG:-/opt/retropie/configs/all/retroarch.cfg}"
RETROPIE_SETUP="${RETROPIE_SETUP:-$HOME/RetroPie-Setup}"
IFACE="${IFACE:-wlan0}"
GATEWAY="${GATEWAY:-192.168.10.1}"
DNS_SERVER="${DNS_SERVER:-192.168.10.15}"   # Pi-hole
MARK_BEGIN="# BEGIN retropie-setup.sh managed block"
MARK_END="# END retropie-setup.sh managed block"
ALL_STEPS=(preflight fan config bluetooth retroarch vb tailscale verify)

DRY_RUN=0; BT_MAC=""; STATIC_IP=""; ONLY=""; SKIP=""

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
run()  { if ((DRY_RUN)); then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ---- pure helpers (testable without a Pi) ----

# Prints a new config.txt: old file minus any earlier managed block and minus stray copies of
# the keys we manage, then the managed block (in [all]) at the end. Comments stay on their own line.
build_config() {
  awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    skip { next }
    /^(arm_freq|core_freq|sdram_freq|over_voltage|temp_limit|force_turbo|gpu_mem|disable_splash|avoid_safe_mode)=/ { next }
    { print }
  ' "$1"
  printf '%s\n' "$MARK_BEGIN" "[all]" \
    "arm_freq=1350" "core_freq=500" "sdram_freq=500" "over_voltage=2" "temp_limit=80" \
    "force_turbo=0" "gpu_mem=256" "disable_splash=1" "avoid_safe_mode=1" "$MARK_END"
}

# ra_set FILE KEY VALUE: replace an active "key = ..." line, or append one.
ra_set() {
  local f=$1 k=$2 v=$3 esc
  esc=$(printf '%s' "$v" | sed -e 's/[&|\\]/\\&/g')
  if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$f"; then
    sed -i -E "s|^[[:space:]]*${k}[[:space:]]*=.*|${k} = ${esc}|" "$f"
  else
    printf '%s = %s\n' "$k" "$v" >> "$f"
  fi
}

apply_overrides() {  # apply_overrides TARGET OVERRIDES_FILE
  local target=$1 src=$2 line n=0
  local re='^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$'
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ $line =~ $re ]]; then ra_set "$target" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; n=$((n+1)); fi
  done < "$src"
  info "applied $n RetroArch settings"
}

valid_mac() { [[ $1 =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; }
valid_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# ---- steps ----

step_preflight() {
  log "Preflight"
  ((EUID != 0)) || die "run as the normal user (pi), not root; the script uses sudo where needed"
  local model; model=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)
  info "board: ${model:-unknown}"
  [[ $model == *"Raspberry Pi 3 Model B"* && $model != *"Plus"* ]] || die "this script is for a Raspberry Pi 3 Model B only"
  # shellcheck disable=SC1091
  . /etc/os-release
  info "os: ${PRETTY_NAME:-unknown}"
  [[ ${VERSION_CODENAME:-} == buster ]] || die "expected Raspberry Pi OS Buster (RetroPie 4.8 image); found '${VERSION_CODENAME:-?}'"
  [[ -d /opt/retropie && -d $RETROPIE_SETUP ]] || die "RetroPie not found (/opt/retropie and $RETROPIE_SETUP expected)"
  [[ -f $CONFIG ]] || die "$CONFIG not found"
  [[ -f $RA_CFG ]] || die "$RA_CFG not found; start EmulationStation once so RetroPie creates it"
  sudo -v || die "sudo is required"
  getent hosts github.com >/dev/null || die "no DNS/network: cannot resolve github.com"
  local free_mb; free_mb=$(df -Pm / | awk 'NR==2{print $4}')
  info "free space on /: ${free_mb} MB"
  ((free_mb > 1500)) || die "less than 1.5 GB free on /"
}

step_fan() {
  log "Fan: pi-pwm-fan ($FAN_REF, $FAN_CURVE curve)"
  run sudo apt-get update
  run sudo apt-get install -y git
  local dir="$HOME/pi-pwm-fan"
  if [[ -d $dir/.git ]]; then run git -C "$dir" fetch --all --tags --quiet
  else run git clone "$FAN_REPO" "$dir"; fi
  run git -C "$dir" checkout --quiet "$FAN_REF"
  ((DRY_RUN)) || [[ -x $dir/install-pwm-fan.sh || -f $dir/install-pwm-fan.sh ]] || die "install-pwm-fan.sh not found in $dir at $FAN_REF"
  ( cd "$dir" && run sudo bash ./install-pwm-fan.sh --curve "$FAN_CURVE" )
  if ! ((DRY_RUN)); then
    for s in pigpiod pwm-fan; do systemctl is-active --quiet "$s" && info "$s: active" || warn "$s is not active"; done
  fi
  info "live dashboard: python3 $dir/fan-monitor.py"
}

step_config() {
  log "Overclock and GPU memory in $CONFIG"
  if ! ((DRY_RUN)) && ! systemctl is-active --quiet pwm-fan; then
    [[ ${ALLOW_OC_WITHOUT_FAN:-0} == 1 ]] || die "pwm-fan is not running. Active cooling is required for 1350 MHz. Run the fan step first (or set ALLOW_OC_WITHOUT_FAN=1 if you accept the risk)."
  fi
  local tmp; tmp=$(mktemp)
  build_config "$CONFIG" > "$tmp"
  if cmp -s "$tmp" "$CONFIG"; then info "already up to date"; rm -f "$tmp"; return; fi
  info "changes:"; diff -u "$CONFIG" "$tmp" | sed 's/^/      /' || true
  run sudo cp -n "$CONFIG" "$CONFIG.bak-retropie-setup"
  run sudo cp "$tmp" "$CONFIG"
  rm -f "$tmp"
  info "takes effect after a reboot. Afterwards check: vcgencmd get_throttled (want 0x0)"
}

step_bluetooth() {
  log "Bluetooth audio (bluealsa)"
  if ! apt-cache policy bluealsa 2>/dev/null | grep -q 'Candidate: [^(]'; then
    die "no bluealsa package candidate in apt. Build it from source or tell Claude; do not continue blind."
  fi
  run sudo apt-get install -y bluealsa bluez
  run sudo systemctl enable --now bluetooth bluealsa
  if [[ -n $BT_MAC ]]; then
    info "RetroArch will use bluealsa device $BT_MAC (set in the retroarch step)"
  else
    info "no --bt-mac given: pair the speaker, then re-run: ./retropie-setup.sh --only retroarch --bt-mac AA:BB:CC:DD:EE:FF"
  fi
  info "to pair (interactive): bluetoothctl, then: power on, agent on, scan on, pair MAC, trust MAC, connect MAC"
  info "do NOT disable Bluetooth on this card (controllers and audio use it)"
}

step_retroarch() {
  log "RetroArch global settings"
  [[ -f $SCRIPT_DIR/retroarch-overrides.cfg ]] || die "retroarch-overrides.cfg not found next to the script"
  local sudo_cmd=""; [[ -w $RA_CFG ]] || sudo_cmd="sudo"
  if ((DRY_RUN)); then
    info "[dry-run] would back up $RA_CFG and apply $(grep -cE '^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=' "$SCRIPT_DIR/retroarch-overrides.cfg") settings + audio_driver"
    return
  fi
  $sudo_cmd cp -n "$RA_CFG" "$RA_CFG.bak-retropie-setup"
  local tmp; tmp=$(mktemp); cp "$RA_CFG" "$tmp"
  apply_overrides "$tmp" "$SCRIPT_DIR/retroarch-overrides.cfg"
  ra_set "$tmp" audio_driver '"alsa"'
  if [[ -n $BT_MAC ]]; then
    valid_mac "$BT_MAC" || die "--bt-mac is not a valid Bluetooth address"
    ra_set "$tmp" audio_device "\"bluealsa:DEV=${BT_MAC^^},PROFILE=a2dp\""
  else
    warn "audio_device not set (no --bt-mac); RetroArch will use the default ALSA device"
  fi
  $sudo_cmd cp "$tmp" "$RA_CFG"; rm -f "$tmp"
}

step_vb() {
  log "Virtual Boy core (lr-beetle-vb)"
  cd "$RETROPIE_SETUP"
  if run sudo ./retropie_packages.sh lr-beetle-vb install_bin; then
    run sudo ./retropie_packages.sh lr-beetle-vb configure
  else
    warn "binary install failed; falling back to a source build (slow on a Pi 3B)"
    run sudo ./retropie_packages.sh lr-beetle-vb
  fi
  info "ROM folder: $HOME/RetroPie/roms/virtualboy"
}

step_tailscale() {
  log "Tailscale (hostname $TS_HOSTNAME)"
  if command -v tailscale >/dev/null; then info "already installed"; else
    # Same apt repo that worked on the old card (Nov 21 2026). Not re-verified for this run.
    run sudo apt-get install -y curl gnupg apt-transport-https
    if ((DRY_RUN)); then info "[dry-run] would add pkgs.tailscale.com/stable/raspbian buster repo and install tailscale"
    else
      curl -fsSL https://pkgs.tailscale.com/stable/raspbian/buster.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
      curl -fsSL https://pkgs.tailscale.com/stable/raspbian/buster.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
      sudo apt-get update && sudo apt-get install -y tailscale
    fi
  fi
  run sudo systemctl enable --now tailscaled
  info "log in yourself (it prints a URL):  sudo tailscale up --accept-dns=false --hostname=$TS_HOSTNAME"
  info "then disable key expiry for $TS_HOSTNAME in the Tailscale admin console"
}

step_static_ip() {
  log "Static IP $STATIC_IP on $IFACE (applies at next reboot)"
  valid_ipv4 "$STATIC_IP" || die "--static-ip is not a valid IPv4 address"
  if ping -c1 -W2 "$STATIC_IP" >/dev/null 2>&1; then die "$STATIC_IP answers on the network: it is in use. Pick another."; fi
  local f=/etc/dhcpcd.conf tmp; tmp=$(mktemp)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{s=1;next} $0==e{s=0;next} !s{print}' "$f" > "$tmp"
  { printf '%s\n' "$MARK_BEGIN" "interface $IFACE" "static ip_address=$STATIC_IP/24" \
      "static routers=$GATEWAY" "static domain_name_servers=$DNS_SERVER" "$MARK_END"; } >> "$tmp"
  diff -u "$f" "$tmp" | sed 's/^/      /' || true
  run sudo cp -n "$f" "$f.bak-retropie-setup"
  run sudo cp "$tmp" "$f"; rm -f "$tmp"
  warn "not restarting networking (would drop your SSH session). Reboot when ready; the Pi will then answer at $STATIC_IP"
}

step_verify() {
  log "Verify"
  info "model:    $(tr -d '\0' </proc/device-tree/model)"
  info "temp:     $(vcgencmd measure_temp 2>/dev/null || echo n/a)"
  info "throttle: $(vcgencmd get_throttled 2>/dev/null || echo n/a)   (want 0x0)"
  info "arm_freq: $(vcgencmd get_config arm_freq 2>/dev/null | tr '\n' ' ')   (shows 1350 only after the reboot)"
  for s in pigpiod pwm-fan bluetooth bluealsa tailscaled; do
    info "$s: $(systemctl is-active "$s" 2>/dev/null || true)"
  done
  info "undervoltage lines: $(dmesg 2>/dev/null | grep -ci 'undervoltage' || true)   (check: sudo dmesg | grep -i voltage)"
}

# ---- main ----
in_list() { local x=$1; shift; local i; for i in "$@"; do [[ $i == "$x" ]] && return 0; done; return 1; }

main() {
  while (($#)); do
    case $1 in
      --dry-run) DRY_RUN=1 ;;
      --only)      ONLY=${2:?--only needs a value}; shift ;;
      --skip)      SKIP=${2:?--skip needs a value}; shift ;;
      --bt-mac)    BT_MAC=${2:?--bt-mac needs a value}; shift ;;
      --static-ip) STATIC_IP=${2:?--static-ip needs a value}; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac; shift
  done
  [[ -z $BT_MAC ]] || valid_mac "$BT_MAC" || die "--bt-mac is not a valid Bluetooth address"
  local LOG="$HOME/retropie-setup.log"
  exec > >(tee -a "$LOG") 2>&1
  echo "retropie-setup.sh v$VERSION  $(date '+%F %T')  dry-run=$DRY_RUN"
  local -a only=() skip=() steps=()
  IFS=, read -r -a only <<<"$ONLY"; IFS=, read -r -a skip <<<"$SKIP"
  local s
  for s in "${ALL_STEPS[@]}"; do
    if [[ $s == preflight || $s == verify ]]; then steps+=("$s"); continue; fi
    if ((${#only[@]})) && ! in_list "$s" "${only[@]}"; then continue; fi
    if ((${#skip[@]})) && in_list "$s" "${skip[@]}"; then continue; fi
    steps+=("$s")
  done
  for s in "${steps[@]}"; do
    if [[ $s == verify && -n $STATIC_IP ]]; then step_static_ip; fi
    "step_$s"
  done
  log "Done. Log: $LOG"
  info "Reboot to apply config.txt and static-IP changes."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
