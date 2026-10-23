#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

GH=https://github.com/X11Libre
XPURL=${XORGPROTO_URL:-https://gitlab.freedesktop.org/xorg/proto/xorgproto.git}
ST=/var/lib/xlup
MANI=$ST/manifests
STATE=$ST/state.env
DRVF=$ST/drivers
SELF=/usr/local/sbin/xlup
CACHE=/var/cache/xlup
BACKUP=
ARMED=0

log()  { printf 'xlup: %s\n' "$*"; }
warn() { printf 'xlup: warning: %s\n' "$*" >&2; }
die()  {
  trap - ERR INT TERM
  printf 'xlup: error: %s\n' "$*" >&2
  if [[ $ARMED -eq 1 ]]; then rollback || true; fi
  exit 1
}

drop() {
  local f
  while read -r f; do
    [[ -n $f ]] || continue
    if [[ -d $f && ! -L $f ]]; then
      $SUDO rmdir -- "$f" 2>/dev/null || true
    else
      $SUDO rm -f -- "$f"
    fi
  done
}

rollback() {
  ARMED=0
  warn "rolling back to previous state"
  local n o
  n=$(mktemp)
  o=$(mktemp)
  cat "$MANI"/*.list 2>/dev/null | sort -u >"$n" || true
  cat "$MANI.prev"/*.list 2>/dev/null | sort -u >"$o" || true
  drop < <(comm -23 "$n" "$o" | sort -r)
  rm -f "$n" "$o"
  if [[ -n $BACKUP && -f $BACKUP ]]; then
    $SUDO tar -xzPf "$BACKUP"
  fi
  if [[ -d $MANI.prev ]]; then
    $SUDO rm -rf "$MANI"
    $SUDO mv "$MANI.prev" "$MANI"
  fi
  if [[ -f $DRVF.prev ]]; then
    $SUDO mv -f "$DRVF.prev" "$DRVF"
  fi
  $SUDO ldconfig || true
  warn "rollback complete"
}

trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR
trap 'die "interrupted"' INT TERM

usage() {
  cat <<'EOF'
usage: xlup [-c] [-a] [-A] [-d] [-x] [-y] [-h]

  xlup        install or update XLibre from source
  xlup -c     check for updates (exit 10 if any)
  xlup -a     enable weekly auto-update
  xlup -A     disable auto-update
  xlup -d     show how to make XLibre the default X server
  xlup -x     uninstall everything xlup installed
  xlup -y     assume yes (non-interactive)
  xlup -h     this help

Builds XLibre (xserver + drivers from github.com/X11Libre) with meson/ninja,
installs into /usr/local (the system Xorg is not touched), records manifests in
/var/lib/xlup, and keeps the last 3 backups of /etc/X11 and /usr/bin/Xorg in
/var/lib/xlup/backups. At the end it offers to configure ~/.xserverrc.
EOF
}

MODE=install
EXPL=0
AUTO=0
ASSUME_YES=0

while getopts ':caxAdhy' o; do
  case $o in
    c) MODE=check; EXPL=1 ;;
    x) MODE=remove; EXPL=1 ;;
    A) MODE=autooff; EXPL=1 ;;
    d) MODE=hint; EXPL=1 ;;
    a) AUTO=1 ;;
    y) ASSUME_YES=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

SUDO=""
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null || die "run as root or install sudo"
  SUDO="sudo"
fi

TARGET_USER="${SUDO_USER:-${USER:-root}}"
TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)
[[ -n $TARGET_HOME && -d $TARGET_HOME ]] || TARGET_HOME=""

S_PREFIX=''
S_PINNED=''
S_DRIVERS=''
S_BUILDTYPE=''
S_SERVER_REF=''
S_SERVER_SHA=''
S_XP=0
S_XP_REF=''
S_XP_SHA=''
HAVE=0

if [[ -f $STATE ]]; then
  . "$STATE"
  HAVE=1
fi

PREFIX=${S_PREFIX:-/usr/local}
PINNED=$S_PINNED
DRIVERS=${S_DRIVERS:-xf86-input-libinput}
BUILDTYPE=${S_BUILDTYPE:-release}
JOBS=$(nproc 2>/dev/null || echo 2)
MEM=$(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo 2>/dev/null || echo 2)
[[ $MEM -ge 1 ]] || MEM=1
[[ $JOBS -le $MEM ]] || JOBS=$MEM
WORK=$CACHE
SRC=$WORK/src

MA=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/$MA/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"

latest_tag() {
  git ls-remote --tags --refs "$1" "$2" |
    awk '{print $2}' |
    sed 's#refs/tags/##' |
    grep -E -- '-[0-9]+(\.[0-9]+)+$' |
    sort -V |
    tail -n1
}

remote_sha() {
  local url=$1 ref=${2:-}

  if [[ -z $ref ]]; then
    git ls-remote "$url" HEAD | awk 'NR==1{print $1}'
    return
  fi

  git ls-remote "$url" \
    "refs/heads/$ref" \
    "refs/tags/$ref" \
    "refs/tags/$ref^{}" |
    awk '{ if ($2 ~ /\^\{\}$/) p=$1; else if (!f) f=$1 } END { print (p ? p : f) }'
}

clone() {
  rm -rf "$2"

  if [[ -n ${3:-} ]]; then
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$3" "$1" "$2"
  else
    git -c advice.detachedHead=false clone -q --depth 1 "$1" "$2"
  fi
}

server_ref() {
  if [[ -n $PINNED ]]; then
    echo "$PINNED"
    return
  fi

  local t
  t=$(latest_tag "$GH/xserver.git" 'xlibre-xserver-*' || true)
  echo "${t:-master}"
}

drv_prev() {
  [[ -f $DRVF ]] || return 0
  awk -v n="$1" -v f="$2" '$1==n {print $f}' "$DRVF"
}

libs_broken() {
  local f

  for f in "$S_PREFIX/bin/Xorg" $(find "$S_PREFIX/lib" -name '*_drv.so' 2>/dev/null); do
    [[ -e $f ]] || continue

    if ldd "$f" 2>/dev/null | grep -q 'not found'; then
      return 0
    fi
  done

  return 1
}

CHANGES=()

changes() {
  CHANGES=()
  local ref sha t d

  ref=$(server_ref)
  sha=$(remote_sha "$GH/xserver.git" "$ref" || true)
  [[ -n $sha ]] || die "cannot query $GH/xserver.git"

  if [[ $S_SERVER_SHA != "$sha" ]]; then
    CHANGES+=("xserver ${S_SERVER_REF:-?} (${S_SERVER_SHA:0:8}) -> $ref (${sha:0:8})")
  fi

  if [[ $S_XP -eq 1 ]]; then
    t=$(latest_tag "$XPURL" 'xorgproto-*' || true)

    if [[ -n $t ]]; then
      sha=$(remote_sha "$XPURL" "$t" || true)
      [[ $S_XP_SHA == "$sha" ]] || CHANGES+=("xorgproto ${S_XP_REF:-?} (${S_XP_SHA:0:8}) -> $t (${sha:0:8})")
    fi
  fi

  for d in $DRIVERS; do
    sha=$(remote_sha "$GH/$d.git" || true)
    [[ -n $sha ]] || continue
    [[ $(drv_prev "$d" 2) == "$sha" ]] || CHANGES+=("$d new commit (${sha:0:8})")
  done

  if [[ $HAVE -eq 1 ]] && libs_broken; then
    CHANGES+=("installed binaries have missing libraries")
  fi

  return 0
}

detect_init() {
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    echo systemd
  elif [[ -d /run/openrc ]] || command -v rc-status >/dev/null 2>&1 || [[ -x /sbin/openrc ]]; then
    echo openrc
  else
    echo other
  fi
}

auto_off() {
  if [[ -f /etc/systemd/system/xlup.timer ]] && command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl disable --now xlup.timer 2>/dev/null || true
    $SUDO rm -f /etc/systemd/system/xlup.timer /etc/systemd/system/xlup.service
    $SUDO systemctl daemon-reload 2>/dev/null || true
  fi

  $SUDO rm -f /etc/periodic/weekly/xlup /etc/cron.weekly/xlup /etc/cron.d/xlup
}

install_self() {
  local src="${BASH_SOURCE[0]:-$0}"
  src="$(readlink -f -- "$src" 2>/dev/null || true)"

  if [[ -z $src || ! -f $src ]]; then
    warn "cannot determine script path; $SELF not installed"
    return 1
  fi

  case "$(basename -- "$src")" in
    bash|sh|"")
      warn "running from stdin/pipe; $SELF not installed"
      return 1
      ;;
  esac

  if [[ $src == "$(readlink -f -- "$SELF" 2>/dev/null || true)" ]]; then
    return 0
  fi

  if ! $SUDO install -Dm755 "$src" "$SELF"; then
    warn "failed to install $src to $SELF"
    return 1
  fi

  [[ -x $SELF ]] || {
    warn "$SELF is not executable"
    return 1
  }

  return 0
}

auto_on_systemd() {
  local cmd=$1

  $SUDO tee /etc/systemd/system/xlup.service >/dev/null <<EOF
[Unit]
Description=XLibre update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Nice=10
ExecStart=$cmd
EOF

  $SUDO tee /etc/systemd/system/xlup.timer >/dev/null <<'EOF'
[Unit]
Description=Weekly XLibre update

[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now xlup.timer
}

auto_on_openrc() {
  local cmd=$1
  local body

  body=$(cat <<EOF
#!/bin/sh
exec $cmd >>/var/log/xlup.log 2>&1
EOF
)

  local installed=0

  if [[ -d /etc/periodic/weekly ]]; then
    printf '%s\n' "$body" | $SUDO tee /etc/periodic/weekly/xlup >/dev/null
    $SUDO chmod +x /etc/periodic/weekly/xlup
    log "openrc: installed /etc/periodic/weekly/xlup"
    installed=1
  fi

  if [[ -d /etc/cron.weekly ]]; then
    printf '%s\n' "$body" | $SUDO tee /etc/cron.weekly/xlup >/dev/null
    $SUDO chmod +x /etc/cron.weekly/xlup
    log "openrc: installed /etc/cron.weekly/xlup"
    installed=1
  fi

  if [[ $installed -eq 0 ]]; then
    if command -v crond >/dev/null 2>&1 ||
       command -v cron >/dev/null 2>&1 ||
       [[ -d /etc/cron.d ]]; then
      $SUDO install -d /etc/cron.weekly
      printf '%s\n' "$body" | $SUDO tee /etc/cron.weekly/xlup >/dev/null
      $SUDO chmod +x /etc/cron.weekly/xlup
      log "openrc: created /etc/cron.weekly/xlup"
      installed=1
    fi
  fi

  if [[ $installed -eq 0 ]]; then
    warn "openrc detected but no cron/periodic directory found"
    warn "install a cron daemon (busybox crond / cronie) and re-run 'xlup -a'"
    return 1
  fi

  if command -v rc-service >/dev/null 2>&1; then
    if ! rc-service crond status >/dev/null 2>&1 &&
       ! rc-service cron status >/dev/null 2>&1; then
      warn "cron service not running; enable it:"
      warn "  rc-update add crond default"
      warn "  rc-update add cron default"
    fi
  fi

  return 0
}

auto_on_manual() {
  local cmd=$1

  warn "unrecognized init system; automatic setup not possible"

  {
    echo
    echo "To enable weekly auto-update manually, add a job that runs:"
    echo "    $cmd"
    echo
    echo "Examples:"
    echo "  cron:   echo '0 4 * * 0 root $cmd >> /var/log/xlup.log 2>&1' | sudo tee /etc/cron.d/xlup"
    echo "  runit:  mkdir -p /etc/sv/xlup && printf '#!/bin/sh\\nexec $cmd\\n' > /etc/sv/xlup/run"
    echo "          chmod +x /etc/sv/xlup/run && ln -s /etc/sv/xlup /var/service/"
    echo "  s6:     create /etc/s6/service/xlup/run and register with s6-rc"
    echo "  dinit:  create /etc/dinit.d/xlup and add to boot"
    echo "  custom: use whatever scheduler your init provides"
    echo
    echo "Or just run 'xlup' manually whenever you want to update."
  } >&2

  return 0
}

auto_on() {
  install_self || die "auto-update requires the script to be run from a file"
  [[ -x $SELF ]] || die "$SELF not found after install"

  local cmd="$SELF -y"
  local init

  init=$(detect_init)

  case $init in
    systemd)
      auto_on_systemd "$cmd" || die "systemd setup failed"
      log "weekly auto-update enabled (systemd timer)"
      ;;
    openrc)
      auto_on_openrc "$cmd" || die "openrc auto-update setup failed"
      log "weekly auto-update enabled (openrc)"
      ;;
    *)
      auto_on_manual "$cmd"
      ;;
  esac
}

record() {
  grep -qxF "$1" "$MANI/extra.list" 2>/dev/null ||
    echo "$1" | $SUDO tee -a "$MANI/extra.list" >/dev/null
}

divert_off() {
  if dpkg-divert --list /usr/bin/Xorg 2>/dev/null | grep -q " by xlup$"; then
    $SUDO rm -f /usr/bin/Xorg
    $SUDO dpkg-divert --package xlup --remove --rename /usr/bin/Xorg >/dev/null || true
  fi
}

is_default() {
  local x=$PREFIX/bin/Xorg
  [[ -n $TARGET_HOME ]] || return 1
  grep -qs -- "$x" "$TARGET_HOME/.xserverrc" && return 0
  return 1
}

note() {
  if ! is_default; then
    log "note: XLibre is not the default X server yet; run 'xlup -d' to see how"
  fi
}

set_default() {
  local x=$PREFIX/bin/Xorg

  [[ -x $x ]] || return 0
  [[ -n $TARGET_HOME ]] || {
    warn "cannot determine home directory for user $TARGET_USER"
    return 1
  }

  local rc="$TARGET_HOME/.xserverrc"

  if [[ -f $rc ]] && grep -qs -- "$x" "$rc"; then
    log "already configured: $rc"
    return 0
  fi

  if [[ $ASSUME_YES -eq 0 ]]; then
    [[ -t 0 ]] || {
      warn "no tty; skipping ~/.xserverrc"
      return 1
    }

    local ans

    if [[ -e $rc ]]; then
      read -r -p "xlup: $rc exists, overwrite with XLibre config? [y/N] " ans
    else
      read -r -p "xlup: create ~/.xserverrc so startx uses XLibre? [y/N] " ans
    fi

    [[ $ans =~ ^[Yy] ]] || {
      log "keeping existing configuration"
      return 1
    }
  fi

  printf '#!/bin/sh\nexec %s -keeptty -nolisten tcp "$@"\n' "$x" |
    $SUDO tee "$rc" >/dev/null

  $SUDO chmod +x "$rc"
  log "startx: $rc configured to use $x"
}

hint() {
  local x=$PREFIX/bin/Xorg
  log "test XLibre first: sudo $x :1 vt8 -keeptty"
  log "startx (as the user who starts X, not with sudo):"
  echo "  printf '#!/bin/sh\nexec $x -keeptty -nolisten tcp \"\$@\"\n' > ~/.xserverrc && chmod +x ~/.xserverrc"
  log "verify: pgrep -a Xorg"
}

case $MODE in
  remove)
    [[ -d $MANI ]] || die "nothing to remove"
    divert_off

    $SUDO rm -f \
      /etc/apt/apt.conf.d/99xlup \
      /etc/lightdm/lightdm.conf.d/50-xlibre.conf \
      /etc/sddm.conf.d/50-xlibre.conf

    if [[ -n $TARGET_HOME && -f $TARGET_HOME/.xserverrc ]] &&
       grep -qs -- "$S_PREFIX/bin/Xorg" "$TARGET_HOME/.xserverrc"; then
      drop <<<"$TARGET_HOME/.xserverrc"
    fi

    drop < <({ cat "$MANI"/*.list 2>/dev/null || true; } | sort -ur)

    if [[ -n $S_PREFIX && $S_PREFIX != /usr && $S_PREFIX != /usr/local ]]; then
      $SUDO find "$S_PREFIX" -depth -type d -empty -delete
    fi

    auto_off
    $SUDO rm -f "$SELF"
    $SUDO rm -rf "$ST"
    $SUDO ldconfig || true
    log "removed"
    exit 0
    ;;

  hint)
    [[ $HAVE -eq 1 ]] || die "not installed"
    hint
    exit 0
    ;;

  autooff)
    auto_off
    log "auto-update disabled"
    exit 0
    ;;

  check)
    [[ $HAVE -eq 1 ]] || die "not installed"
    changes
    log "installed: $S_SERVER_REF in $S_PREFIX"
    note

    if [[ ${#CHANGES[@]} -eq 0 ]]; then
      log "up to date"
      exit 0
    fi

    printf '  %s\n' "${CHANGES[@]}"
    exit 10
    ;;

  install)
    if [[ $HAVE -eq 1 && $AUTO -eq 1 && $EXPL -eq 0 ]]; then
      auto_on
      exit 0
    fi

    if [[ $HAVE -eq 1 ]]; then
      changes

      if [[ ${#CHANGES[@]} -eq 0 ]]; then
        log "up to date ($S_SERVER_REF)"
        set_default || true
        note
        exit 0
      fi

      printf '  %s\n' "${CHANGES[@]}"
    fi
    ;;
esac

[[ -r /etc/os-release ]] || die "no /etc/os-release"
. /etc/os-release

case "${ID:-}:${ID_LIKE:-}" in
  *debian*|*ubuntu*|*devuan*) ;;
  *) die "Debian-family system required" ;;
esac

command -v apt-get >/dev/null || die "apt-get not found"

log "system: ${PRETTY_NAME:-unknown}"
log "prefix: $PREFIX  drivers: $DRIVERS  jobs: $JOBS"

if [[ $PREFIX == /usr ]] && dpkg -s xserver-xorg-core >/dev/null 2>&1; then
  die "prefix /usr conflicts with xserver-xorg-core; use /usr/local or /opt/xlibre"
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  [[ -t 0 ]] || die "no tty for confirmation; pass -y"
  read -r -p "xlup: proceed with build and install into $PREFIX? [y/N] " ans
  [[ $ans =~ ^[Yy] ]] || die "aborted"
fi

mkdir -p "$WORK"

AVAIL=$(df -Pk "$WORK" | awk 'NR==2{print $4}')
[[ $AVAIL -ge 1048576 ]] || die "less than 1 GB free in $WORK"

if command -v flock >/dev/null; then
  exec 9>"$WORK/.lock"
  flock -n 9 || die "another build is running"
fi

REQ=(
  git
  ca-certificates
  build-essential
  meson
  ninja-build
  pkg-config
  autoconf
  automake
  libtool
  xutils-dev
  x11proto-dev
  xtrans-dev
  libpixman-1-dev
  libxkbcommon-x11-dev
  libxfont-dev
  libxcvt-dev
  libdrm-dev
  libepoxy-dev
  libxkbfile-dev
  libudev-dev
  libxshmfence-dev
  libbsd-dev
  libgl-dev
  libglu1-mesa-dev
  mesa-common-dev
  libgbm-dev
  libxcb-shape0-dev
  libxcb-util-dev
  libxcb-icccm4-dev
  nettle-dev
  libpciaccess-dev
  libx11-dev
  libxau-dev
  libxdmcp-dev
  libxext-dev
  libinput-dev
  libevdev-dev
  libmtdev-dev
  libdbus-1-dev
  xkb-data
  x11-xkb-utils
  xinit
)

OPT=(
  libseat-dev
  libelogind-dev
  libssl-dev
  libselinux1-dev
  libaudit-dev
  libunwind-dev
  libxcb-keysyms1-dev
  libxcb-image0-dev
  libxcb-render-util0-dev
  libxcb-randr0-dev
  libxcb-xkb-dev
  libxcb-xv0-dev
  libxcb-glx0-dev
  libxcb-xf86dri0-dev
  libxcb-render0-dev
  libxcb-composite0-dev
  libxcb-xinput-dev
  libxcb-ewmh-dev
  libxcb-present-dev
  libxcb-dri2-0-dev
  libxcb-dri3-0-dev
  libxcb-res0-dev
  libxcb-shm0-dev
  libxcb-sync-dev
  libxcb-xfixes0-dev
  libxcb-xinerama0-dev
  libx11-xcb-dev
  libxmu-dev
  libxrender-dev
  libxi-dev
  libxres-dev
  libxtst-dev
  libxrandr-dev
  libxfixes-dev
  libxv-dev
  libxvmc-dev
  libxinerama-dev
  libxcursor-dev
  libxdamage-dev
  libxxf86vm-dev
  libxaw7-dev
  libxt-dev
  libxpm-dev
  libxss-dev
  x11-xserver-utils
  xfonts-base
)

log "installing build dependencies"

$SUDO apt-get -o DPkg::Lock::Timeout=300 update ||
  warn "apt-get update failed; using existing indexes"

AV=()
MISS=()

for p in "${REQ[@]}"; do
  if apt-cache show "$p" >/dev/null 2>&1; then
    AV+=("$p")
  else
    MISS+=("$p")
  fi
done

[[ ${#MISS[@]} -eq 0 ]] || die "missing apt packages: ${MISS[*]}"

for p in "${OPT[@]}"; do
  if apt-cache show "$p" >/dev/null 2>&1; then
    AV+=("$p")
  fi
done

DEBIAN_FRONTEND=noninteractive \
  $SUDO apt-get \
  -o DPkg::Lock::Timeout=300 \
  install -y \
  --no-install-recommends \
  "${AV[@]}"

command -v meson >/dev/null || die "meson not found"

MV=$(meson --version)

[[ $(printf '%s\n0.61.0\n' "$MV" | sort -V | head -n1) == 0.61.0 ]] ||
  die "meson >= 0.61 required (found $MV)"

meson_record() {
  grep '^/' "$2/meson-logs/install-log.txt" |
    $SUDO tee "$MANI/$1.list" >/dev/null
}

xp_ok() {
  local reqs name ver

  reqs=$(grep -oE "dependency\('[a-z0-9]+proto', *version: *'>= *[0-9.]+'" "$SRC/xserver/meson.build" |
    sed -E "s/dependency\('([a-z0-9]+)', *version: *'>= *([0-9.]+)'/\1 \2/" || true)

  reqs+=$'\npresentproto 1.4\ndri3proto 1.4'

  while read -r name ver; do
    [[ -n $name ]] || continue

    if ! pkg-config --atleast-version="$ver" "$name" 2>/dev/null; then
      warn "system $name too old (need >= $ver)"
      return 1
    fi
  done <<<"$reqs"
}

XP=0
XP_REF=
XP_SHA=

build_xp() {
  local ref

  ref=$(latest_tag "$XPURL" 'xorgproto-*' || true)
  [[ -n $ref ]] || die "cannot reach $XPURL"

  log "building xorgproto $ref"

  clone "$XPURL" "$SRC/xorgproto" "$ref"

  (
    cd "$SRC/xorgproto"
    meson setup build \
      --prefix "$PREFIX" \
      --buildtype "$BUILDTYPE"
    ninja -C build -j "$JOBS"
    $SUDO ninja -C build install
    meson_record xorgproto build
  )

  XP=1
  XP_REF=$ref
  XP_SHA=$(git -C "$SRC/xorgproto" rev-parse HEAD)
}

SREF=
SSHA=

build_server() {
  SREF=$(server_ref)

  log "building xserver $SREF"

  clone "$GH/xserver.git" "$SRC/xserver" "$SREF"

  SSHA=$(git -C "$SRC/xserver" rev-parse HEAD)

  if [[ $S_XP -eq 1 ]] || ! xp_ok; then
    build_xp
    xp_ok || die "xorgproto requirements still unmet"
  fi

  local pcin

  pkg-config --exists libseat ||
    die "libseat not found; install libseat-dev"

  cd "$SRC/xserver"

  for pcin in xlibre-server.pc.in xorg-server.pc.in; do
    [[ -f $pcin ]] || continue

    sed -i \
      -e 's#^input_drivers_dir=@moduledir@/drivers/input$#input_drivers_dir=@moduledir@/input#' \
      -e 's#^video_drivers_dir=@moduledir@/drivers/video$#video_drivers_dir=@moduledir@/drivers#' \
      "$pcin"
  done

  meson setup build \
    --prefix "$PREFIX" \
    --buildtype "$BUILDTYPE" \
    --sysconfdir /etc \
    --localstatedir /var \
    -Dxkb_dir=/usr/share/X11/xkb \
    -Dxkb_output_dir=/var/lib/xkb \
    -Dxkb_bin_dir=/usr/bin \
    -Dsystemd_logind=false \
    -Dseatd_libseat=true

  ninja -C build -j "$JOBS"

  $SUDO ninja -C build install

  meson_record xserver build

  $SUDO ldconfig || true
}

build_driver() {
  local name=$1 dir="$SRC/$1" stage

  clone "$GH/$name.git" "$dir" || return 1

  cd "$dir" || return 1

  if [[ -f meson.build ]]; then
    meson setup build \
      --prefix "$PREFIX" \
      --buildtype "$BUILDTYPE" ||
      return 1

    ninja -C build -j "$JOBS" || return 1

    $SUDO ninja -C build install || return 1

    meson_record "$name" build || return 1

  elif [[ -f autogen.sh ]]; then
    NOCONFIGURE=1 ./autogen.sh || return 1

    ./configure --prefix="$PREFIX" || return 1

    make -j "$JOBS" || return 1

    stage="$WORK/stage/$name"

    rm -rf "$stage"
    mkdir -p "$stage"

    make DESTDIR="$stage" install || return 1

    (
      cd "$stage"
      find . \( -type f -o -type l \) | sed 's#^\.##'
    ) | $SUDO tee "$MANI/$name.list" >/dev/null || return 1

    tar -C "$stage" -cf - . |
      $SUDO tar -C / -xf - --no-same-owner --no-overwrite-dir ||
      return 1
  else
    return 1
  fi
}

backup() {
  $SUDO mkdir -p "$ST/backups"

  BACKUP="$ST/backups/$(date +%Y%m%d-%H%M%S).tar.gz"

  local sysx=()

  for f in /usr/bin/Xorg /usr/bin/X /usr/bin/Xorg.xorg; do
    if [[ -e $f ]]; then
      sysx+=("$f")
    fi
  done

  {
    cat "$MANI"/*.list 2>/dev/null || true

    if [[ -d /etc/X11 ]]; then
      echo /etc/X11
    fi

    if [[ ${#sysx[@]} -gt 0 ]]; then
      printf '%s\n' "${sysx[@]}"
    fi
  } | $SUDO tar \
    -czPf "$BACKUP" \
    --files-from=- \
    --ignore-failed-read \
    2>/dev/null || true

  find "$ST/backups" -name '*.tar.gz' |
    sort |
    head -n -3 |
    xargs -r $SUDO rm -f

  if [[ ${#sysx[@]} -gt 0 ]]; then
    log "backup: $BACKUP (system Xorg: ${sysx[*]})"
  else
    log "backup: $BACKUP"
  fi
}

mkdir -p "$SRC"
$SUDO mkdir -p "$MANI"

IS_UPDATE=0

if compgen -G "$MANI/*.list" >/dev/null 2>&1; then
  IS_UPDATE=1
fi

backup
ARMED=1

if [[ $IS_UPDATE -eq 1 ]]; then
  $SUDO rm -rf "$MANI.prev"
  $SUDO cp -a "$MANI" "$MANI.prev"
  $SUDO rm -f "$MANI"/*.list

  if [[ -f $DRVF ]]; then
    $SUDO cp -a "$DRVF" "$DRVF.prev"
  fi
fi

build_server

NEWD=()
FAILED=()

for d in $DRIVERS; do
  log "building driver $d"

  if ( build_driver "$d" ); then
    NEWD+=("$d $(git -C "$SRC/$d" rev-parse HEAD) ok")
  else
    warn "driver $d failed"

    FAILED+=("$d")

    sha=$(remote_sha "$GH/$d.git" || true)

    NEWD+=("$d ${sha:-unknown} failed")

    if [[ $IS_UPDATE -eq 1 && $(drv_prev "$d" 3) == ok ]]; then
      die "driver $d worked before but fails with the new server"
    fi
  fi
done

$SUDO ldconfig || true

if [[ " $DRIVERS " == *" xf86-input-libinput "* ]]; then
  if ! find "$PREFIX" /etc/X11 -name '*libinput*.conf' 2>/dev/null | grep -q . &&
     [[ -f /usr/share/X11/xorg.conf.d/40-libinput.conf ]]; then

    $SUDO install \
      -Dm644 \
      /usr/share/X11/xorg.conf.d/40-libinput.conf \
      /etc/X11/xorg.conf.d/40-libinput.conf

    record /etc/X11/xorg.conf.d/40-libinput.conf
  fi
fi

XB=$PREFIX/bin/Xorg

[[ -x $XB ]] || XB=$PREFIX/bin/X

[[ -x $XB ]] || die "Xorg not found under $PREFIX/bin"

XV=$("$XB" -version 2>&1 || true)

grep -qi xlibre <<<"$XV" ||
  die "installed Xorg is not XLibre"

log "check: $XB -version"

printf '%s\n' "$XV" | sed 's/^/  /'

if [[ $IS_UPDATE -eq 1 ]]; then
  o=$(mktemp)
  n=$(mktemp)

  cat "$MANI.prev"/*.list 2>/dev/null | sort -u >"$o" || true
  cat "$MANI"/*.list 2>/dev/null | sort -u >"$n" || true

  drop < <(comm -23 "$o" "$n" | sort -r)

  rm -f "$o" "$n"

  $SUDO rm -rf "$MANI.prev"
  $SUDO rm -f "$DRVF.prev"
fi

ARMED=0

{
  echo "S_PREFIX='$PREFIX'"
  echo "S_PINNED='$PINNED'"
  echo "S_DRIVERS='$DRIVERS'"
  echo "S_BUILDTYPE='$BUILDTYPE'"
  echo "S_SERVER_REF='$SREF'"
  echo "S_SERVER_SHA='$SSHA'"
  echo "S_XP=$XP"
  echo "S_XP_REF='$XP_REF'"
  echo "S_XP_SHA='$XP_SHA'"
} | $SUDO tee "$STATE" >/dev/null

printf '%s\n' "${NEWD[@]:-}" |
  $SUDO tee "$DRVF" >/dev/null

install_self || true

if [[ $AUTO -eq 1 ]]; then
  auto_on
fi

log "installed XLibre $SREF in $PREFIX"
log "backups: $ST/backups (last 3 kept)"

set_default || true

if [[ $IS_UPDATE -eq 0 || -t 1 ]]; then
  is_default || hint
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  warn "failed drivers: ${FAILED[*]}"
fi

if [[ $IS_UPDATE -eq 1 ]]; then
  warn "restart the X session to use the new version"
fi

exit 0
