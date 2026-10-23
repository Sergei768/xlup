#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR CDPATH ENV BASH_ENV
umask 022

GH=${XLUP_GITHUB_BASE:-https://github.com/X11Libre}
XPURL=${XORGPROTO_URL:-https://gitlab.freedesktop.org/xorg/proto/xorgproto.git}
ST=/var/lib/xlup
MANI=$ST/manifests
MANIFEST=$MANI/all.list
STATE=$ST/state.env
DRVF=$ST/drivers
ORIG=$ST/originals
TX=$ST/transaction
LOCK=$ST/.lock
SELF=/usr/local/sbin/xlup
CACHE=/var/cache/xlup
TAR_META=(--acls --xattrs --xattrs-include='*' --selinux)

ARMED=0
SCRIPT_SOURCE=$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)

log()  { printf 'xlup: %s\n' "$*"; }
warn() { printf 'xlup: warning: %s\n' "$*" >&2; }

rollback_tx() {
  local p
  [[ -f $TX/ACTIVE ]] || return 0
  warn "rolling back interrupted transaction"

  if [[ -f $TX/touched.list ]]; then
    while IFS= read -r p; do
      [[ -n $p ]] || continue
      validate_path "$p" || { warn "invalid path in transaction: $p"; return 1; }
      secure_parent_chain "$p" || return 1
      if [[ -d $p && ! -L $p ]]; then
        "${SUDO[@]}" rmdir -- "$p" 2>/dev/null || {
          warn "cannot remove directory that replaced managed path: $p"
          return 1
        }
      else
        "${SUDO[@]}" rm -f -- "$p" || return 1
      fi
    done < "$TX/touched.list"
  fi

  if [[ -f $TX/live.tar.gz ]]; then
    "${SUDO[@]}" tar "${TAR_META[@]}" -C / -xzpf "$TX/live.tar.gz" || return 1
  fi

  if [[ -f $TX/state.present ]]; then
    "${SUDO[@]}" cp -a -- "$TX/state.before" "$STATE" || return 1
  else
    "${SUDO[@]}" rm -f -- "$STATE" || return 1
  fi

  if [[ -f $TX/drivers.present ]]; then
    "${SUDO[@]}" cp -a -- "$TX/drivers.before" "$DRVF" || return 1
  else
    "${SUDO[@]}" rm -f -- "$DRVF" || return 1
  fi

  if [[ -f $TX/manifests.present ]]; then
    "${SUDO[@]}" rm -rf -- "$MANI" || return 1
    "${SUDO[@]}" cp -a -- "$TX/manifests.before" "$MANI" || return 1
  else
    "${SUDO[@]}" rm -rf -- "$MANI" || return 1
    "${SUDO[@]}" mkdir -p -- "$MANI" || return 1
  fi

  "${SUDO[@]}" ldconfig >/dev/null 2>&1 || return 1
  "${SUDO[@]}" rm -rf -- "$TX" || return 1
  warn "rollback complete"
}

die() {
  local msg=$*
  trap - ERR INT TERM
  set +e
  printf 'xlup: error: %s\n' "$msg" >&2
  if [[ $ARMED -eq 1 ]]; then
    rollback_tx || printf 'xlup: error: rollback failed; inspect %s manually\n' "$TX" >&2
  fi
  exit 1
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
  xlup -x     uninstall files managed by xlup and restore pre-existing files
  xlup -y     assume yes for build/install confirmation
  xlup -h     this help

Builds XLibre (xserver + selected drivers from github.com/X11Libre) with
meson/ninja and installs transactionally into /usr/local by default. Builds are
staged before privileged deployment. State, manifests, rollback metadata, and
pre-xlup copies of overwritten files are kept under /var/lib/xlup. The last
three pre-update transaction snapshots are kept under /var/lib/xlup/backups.
EOF
}

MODE=install
AUTO=0
ASSUME_YES=0
while getopts ':caxAdhy' o; do
  case $o in
    c) MODE=check ;;
    x) MODE=remove ;;
    A) MODE=autooff ;;
    d) MODE=hint ;;
    a) AUTO=1 ;;
    y) ASSUME_YES=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || { usage >&2; exit 1; }

SUDO=()
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "run as root or install sudo"
  SUDO=(sudo)
fi

if [[ $EUID -eq 0 && -n ${SUDO_USER:-} && ${SUDO_USER:-root} != root ]]; then
  CALLER_USER=$SUDO_USER
else
  CALLER_USER=$(id -un)
fi

validate_scalar() {
  local v=$1
  [[ $v != *$'\n'* && $v != *$'\r'* && $v != *$'\t'* ]]
}

validate_driver_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

validate_path() {
  local p=$1
  [[ $p == /* ]] || return 1
  validate_scalar "$p" || return 1
  [[ $p != *'/../'* && $p != */.. && $p != *'/./'* && $p != */. ]] || return 1
  [[ $p != '//' && $p != *'//'* ]] || return 1
}

path_domain_root() {
  local p=$1 d

  if [[ -f $TX/domains.list ]]; then
    while IFS= read -r d; do
      [[ -n $d ]] || continue
      case $p in "$d"/*) printf '%s\n' "$d"; return 0 ;; esac
    done < "$TX/domains.list"
  fi

  if [[ -n ${PREFIX:-} ]]; then
    case $p in "${PREFIX}"/*) printf '%s\n' "$PREFIX"; return 0 ;; esac
  fi
  case $p in
    /etc/X11/*) printf '%s\n' /etc/X11; return 0 ;;
    /var/lib/xkb/*) printf '%s\n' /var/lib/xkb; return 0 ;;
  esac
  if [[ -n ${S_PREFIX:-} ]]; then
    case $p in "${S_PREFIX}"/*) printf '%s\n' "$S_PREFIX"; return 0 ;; esac
  fi
  return 1
}

path_allowed() {
  path_domain_root "$1" >/dev/null 2>&1
}

path_within_domain() {
  local p=$1 domain realp reald
  domain=$(path_domain_root "$p") || return 1
  realp=$(realpath -m -- "$p") || return 1
  reald=$(realpath -m -- "$domain") || return 1
  [[ $realp == "$reald" || $realp == "$reald"/* ]]
}

secure_parent_chain() {
  local p=$1 parent cur=/ comp uid mode resolved
  local -a parts=()
  path_allowed "$p" || die "destination path is outside allowed roots: $p"
  parent=$(dirname -- "$p")
  path_within_domain "$parent/.xlup-parent-check" || die "destination parent escapes allowed root: $parent"

  IFS='/' read -r -a parts <<< "${parent#/}"
  for comp in "${parts[@]}"; do
    [[ -n $comp ]] || continue
    cur=${cur%/}/$comp
    if [[ -e $cur || -L $cur ]]; then
      uid=$(stat -Lc '%u' -- "$cur") || die "cannot stat destination parent: $cur"
      [[ $uid -eq 0 ]] || die "unsafe non-root-owned destination parent: $cur"
      if [[ -L $cur ]]; then
        resolved=$(readlink -f -- "$cur") || die "broken destination symlink: $cur"
        [[ -d $resolved ]] || die "destination parent symlink is not a directory: $cur"
        path_within_domain "$parent/.xlup-parent-check" || die "destination symlink escapes allowed root: $cur"
        mode=$(stat -Lc '%a' -- "$cur") || die "cannot stat destination parent: $cur"
      else
        [[ -d $cur ]] || die "destination parent is not a directory: $cur"
        mode=$(stat -c '%a' -- "$cur") || die "cannot stat destination parent: $cur"
      fi
      if (( (8#$mode & 8#022) != 0 )); then
        die "group/world-writable destination parent is unsafe: $cur"
      fi
    fi
  done
}


state_reset() {
  S_PREFIX=''
  S_PINNED=''
  S_DRIVERS=''
  S_BUILDTYPE=''
  S_SERVER_REF=''
  S_SERVER_SHA=''
  S_XP=0
  S_XP_REF=''
  S_XP_SHA=''
  S_TARGET_USER=''
  S_SEAT_BACKEND=''
}

legacy_unquote() {
  local v=$1
  if [[ $v == \'*\' && ${#v} -ge 2 ]]; then
    v=${v:1:${#v}-2}
  fi
  printf '%s\n' "$v"
}

load_state() {
  state_reset
  [[ -f $STATE ]] || return 1

  local first line key val
  IFS= read -r first < "$STATE" || true
  if [[ $first == $'XLUP_STATE_V2\t1' ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -n $line ]] || continue
      [[ $line == *$'\t'* ]] || die "malformed state line"
      key=${line%%$'\t'*}
      val=${line#*$'\t'}
      validate_scalar "$val" || die "unsafe value in state file"
      case $key in
        S_PREFIX) S_PREFIX=$val ;;
        S_PINNED) S_PINNED=$val ;;
        S_DRIVERS) S_DRIVERS=$val ;;
        S_BUILDTYPE) S_BUILDTYPE=$val ;;
        S_SERVER_REF) S_SERVER_REF=$val ;;
        S_SERVER_SHA) S_SERVER_SHA=$val ;;
        S_XP) [[ $val == 0 || $val == 1 ]] || die "invalid S_XP"; S_XP=$val ;;
        S_XP_REF) S_XP_REF=$val ;;
        S_XP_SHA) S_XP_SHA=$val ;;
        S_TARGET_USER) S_TARGET_USER=$val ;;
        S_SEAT_BACKEND) S_SEAT_BACKEND=$val ;;
      esac
    done < <(tail -n +2 "$STATE")
  else
    while IFS= read -r line || [[ -n $line ]]; do
      key=${line%%=*}
      [[ $line == *=* ]] || continue
      val=${line#*=}
      val=$(legacy_unquote "$val")
      validate_scalar "$val" || die "unsafe value in legacy state file"
      case $key in
        S_PREFIX) S_PREFIX=$val ;;
        S_PINNED) S_PINNED=$val ;;
        S_DRIVERS) S_DRIVERS=$val ;;
        S_BUILDTYPE) S_BUILDTYPE=$val ;;
        S_SERVER_REF) S_SERVER_REF=$val ;;
        S_SERVER_SHA) S_SERVER_SHA=$val ;;
        S_XP) [[ $val == 0 || $val == 1 ]] || val=0; S_XP=$val ;;
        S_XP_REF) S_XP_REF=$val ;;
        S_XP_SHA) S_XP_SHA=$val ;;
        S_TARGET_USER) S_TARGET_USER=$val ;;
        S_SEAT_BACKEND) S_SEAT_BACKEND=$val ;;
      esac
    done < "$STATE"
  fi
  return 0
}

state_write_file() {
  local out=$1
  {
    printf 'XLUP_STATE_V2\t1\n'
    printf 'S_PREFIX\t%s\n' "$PREFIX"
    printf 'S_PINNED\t%s\n' "$PINNED"
    printf 'S_DRIVERS\t%s\n' "$DRIVERS"
    printf 'S_BUILDTYPE\t%s\n' "$BUILDTYPE"
    printf 'S_SERVER_REF\t%s\n' "$SREF"
    printf 'S_SERVER_SHA\t%s\n' "$SSHA"
    printf 'S_XP\t%s\n' "$XP"
    printf 'S_XP_REF\t%s\n' "$XP_REF"
    printf 'S_XP_SHA\t%s\n' "$XP_SHA"
    printf 'S_TARGET_USER\t%s\n' "$TARGET_USER"
    printf 'S_SEAT_BACKEND\t%s\n' "$SEAT_BACKEND"
  } > "$out"
}

check_state_dir_security() {
  [[ -d $ST ]] || return 0
  local uid mode
  uid=$(stat -c '%u' "$ST") || return 1
  mode=$(stat -c '%a' "$ST") || return 1
  [[ $uid -eq 0 ]] || die "$ST must be owned by root"
  if (( (8#$mode & 8#022) != 0 )); then
    die "$ST must not be group/world writable"
  fi
}

ensure_state_dir() {
  "${SUDO[@]}" install -d -m 0755 "$ST" "$MANI"
  if [[ ! -e $LOCK ]]; then
    "${SUDO[@]}" touch "$LOCK"
    "${SUDO[@]}" chmod 0644 "$LOCK"
  fi
  check_state_dir_security
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 || die "flock is required (util-linux)"
  [[ -r $LOCK ]] || die "cannot read lock file $LOCK"
  exec 9<"$LOCK"
  flock -n -x 9 || die "another xlup process is running"
}

recover_pending() {
  if [[ -d $TX && ! -f $TX/ACTIVE ]]; then
    "${SUDO[@]}" rm -rf -- "$TX"
    return 0
  fi
  [[ -f $TX/ACTIVE ]] || return 0
  log "recovering interrupted previous transaction"
  if ! rollback_tx; then
    die "automatic recovery failed; inspect $TX"
  fi
}

if [[ -d $ST ]]; then
  check_state_dir_security
  [[ -e $LOCK ]] || "${SUDO[@]}" sh -c 'umask 022; : > "$1"; chmod 0644 "$1"' sh "$LOCK"
  acquire_lock
  recover_pending
elif [[ $MODE == install ]]; then
  ensure_state_dir
  acquire_lock
else
  die "not installed"
fi

HAVE=0
if load_state; then HAVE=1; fi
if [[ $HAVE -eq 1 ]]; then
  [[ -n $S_PREFIX && -n $S_SERVER_REF && -n $S_SERVER_SHA ]] || die "incomplete/corrupt state file: $STATE"
  validate_scalar "$S_PREFIX" || die "invalid prefix in state file"
  [[ $S_SERVER_SHA =~ ^[0-9a-fA-F]{40}$ ]] || die "invalid server SHA in state file"
  [[ $S_XP == 0 || $S_XP == 1 ]] || die "invalid xorgproto state"
  if [[ $S_XP -eq 1 ]]; then
    [[ $S_XP_SHA =~ ^[0-9a-fA-F]{40}$ ]] || die "invalid xorgproto SHA in state file"
  fi
fi

TARGET_USER=${S_TARGET_USER:-$CALLER_USER}
TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)
[[ -n $TARGET_HOME && -d $TARGET_HOME ]] || TARGET_HOME=''

PREFIX=${XLUP_PREFIX:-${S_PREFIX:-/usr/local}}
PINNED=${XLUP_PINNED:-$S_PINNED}
DRIVERS=${XLUP_DRIVERS:-${S_DRIVERS:-xf86-input-libinput}}
BUILDTYPE=${XLUP_BUILDTYPE:-${S_BUILDTYPE:-release}}

validate_scalar "$PREFIX" || die "invalid PREFIX"
validate_scalar "$PINNED" || die "invalid pinned ref"
validate_scalar "$DRIVERS" || die "invalid driver list"
validate_scalar "$BUILDTYPE" || die "invalid build type"
[[ $BUILDTYPE =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid build type"
PREFIX=$(realpath -m -- "$PREFIX")
[[ $PREFIX == /* && $PREFIX != / ]] || die "PREFIX must be an absolute non-root path"
[[ $PREFIX != *:* ]] || die "PREFIX must not contain ':'"
case $PREFIX in
  /usr) die "PREFIX=/usr is not supported; use /usr/local or /opt/xlibre" ;;
  /etc|/etc/*|/var|/var/*|/run|/run/*|/tmp|/tmp/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/home|/home/*)
    die "unsafe installation PREFIX: $PREFIX" ;;
esac

for d in $DRIVERS; do
  validate_driver_name "$d" || die "invalid driver repository name: $d"
done

JOBS=$(nproc 2>/dev/null || echo 2)
MEM=$(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo 2>/dev/null || echo 2)
[[ $MEM -ge 1 ]] || MEM=1
[[ $JOBS -le $MEM ]] || JOBS=$MEM

WORK=$CACHE
[[ $WORK != *:* ]] || die "build path must not contain ':'"
validate_scalar "$WORK" || die "invalid build path"
SRC=$WORK/src
STAGE_ROOT=$WORK/stage-root
COMP_ROOT=$WORK/components
OVERLAY_ROOT=$WORK/pkgconfig-overlay
TMPROOT=$WORK/tmp
BUILD_HOME=$WORK/build-home
BUILD_USER=xlup-build
BUILD_GROUP=''
CONTROL_USER=$(id -un)
CONTROL_GROUP=$(id -gn)
BUILD_PATH=/usr/local/bin:/usr/bin:/bin

setup_build_identity() {
  local home shell uid marked
  command -v runuser >/dev/null 2>&1 || die "runuser is required (util-linux)"

  if id "$BUILD_USER" >/dev/null 2>&1; then
    home=$(getent passwd "$BUILD_USER" | cut -d: -f6)
    shell=$(getent passwd "$BUILD_USER" | cut -d: -f7)
    uid=$(id -u "$BUILD_USER")
    [[ -f $ST/build-user-created ]] || die "account '$BUILD_USER' exists but xlup ownership marker is missing"
    [[ $home == /nonexistent && $shell == /usr/sbin/nologin ]] \
      || die "build account '$BUILD_USER' has unexpected properties; refusing to use it"
    marked=$(cat "$ST/build-user-created" 2>/dev/null || true)
    if [[ -n $marked ]]; then
      [[ $marked =~ ^[0-9]+$ && $marked == "$uid" ]] \
        || die "build account '$BUILD_USER' UID does not match xlup marker"
    else
      printf '%s\n' "$uid" | "${SUDO[@]}" tee "$ST/build-user-created" >/dev/null
      "${SUDO[@]}" chmod 0644 "$ST/build-user-created"
    fi
  else
    command -v useradd >/dev/null 2>&1 || die "useradd is required (passwd package)"
    "${SUDO[@]}" useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$BUILD_USER"
    uid=$(id -u "$BUILD_USER") || die "created build account cannot be resolved"
    printf '%s\n' "$uid" | "${SUDO[@]}" tee "$ST/build-user-created" >/dev/null
    "${SUDO[@]}" chmod 0644 "$ST/build-user-created"
  fi
  BUILD_GROUP=$(id -gn "$BUILD_USER") || die "cannot determine build group for $BUILD_USER"
}

build_env() {
  BUILD_ENV=(env -i
    "HOME=$BUILD_HOME"
    "XDG_CACHE_HOME=$BUILD_HOME/.cache"
    "LC_ALL=C"
    "PATH=$BUILD_PATH"
    "PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}"
  )
  local n
  for n in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    [[ -n ${!n:-} ]] && BUILD_ENV+=("$n=${!n}")
  done
}

as_build() {
  build_env
  "${SUDO[@]}" runuser -u "$BUILD_USER" -- "${BUILD_ENV[@]}" "$@"
}

as_build_in() {
  local dir=$1
  shift
  build_env
  "${SUDO[@]}" runuser -u "$BUILD_USER" -- "${BUILD_ENV[@]}" bash -c 'cd -- "$1"; shift; exec "$@"' bash "$dir" "$@"
}

reset_build_dir() {
  local dir=$1
  "${SUDO[@]}" rm -rf -- "$dir"
  "${SUDO[@]}" install -d -m 0755 -o "$BUILD_USER" -g "$BUILD_GROUP" "$dir"
}

prepare_work_dirs() {
  "${SUDO[@]}" install -d -m 0755 "$WORK"
  "${SUDO[@]}" rm -rf "$SRC" "$STAGE_ROOT" "$COMP_ROOT" "$OVERLAY_ROOT" "$TMPROOT" "$BUILD_HOME"
  "${SUDO[@]}" install -d -m 0755 -o "$BUILD_USER" -g "$BUILD_GROUP" "$SRC" "$STAGE_ROOT" "$COMP_ROOT" "$BUILD_HOME"
  "${SUDO[@]}" install -d -m 0755 -o "$CONTROL_USER" -g "$CONTROL_GROUP" "$OVERLAY_ROOT" "$TMPROOT"
}

freeze_stage() {
  local uid pid
  uid=$(id -u "$BUILD_USER") || die "cannot determine build uid"
  if command -v ps >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n $pid ]] || continue
      "${SUDO[@]}" kill -KILL "$pid" 2>/dev/null || true
    done < <(ps -eo pid=,uid= | awk -v u="$uid" '$2==u {print $1}')
  else
    die "ps is required to terminate stray build processes"
  fi
  "${SUDO[@]}" chown -R root:root "$STAGE_ROOT"
  "${SUDO[@]}" find "$STAGE_ROOT" -type d -exec chmod go-w {} +
}

latest_tag() {
  local url=$1 pattern=$2 out
  out=$(git ls-remote --tags --refs "$url" "$pattern") || return 1
  printf '%s\n' "$out" | awk '{print $2}' | sed 's#refs/tags/##' \
    | grep -E -- '-[0-9]+(\.[0-9]+)+$' | sort -V | tail -n1
}

remote_sha() {
  local url=$1 ref=${2:-} out
  if [[ -z $ref ]]; then
    git ls-remote "$url" HEAD | awk 'NR==1{print $1}'
    return
  fi
  if [[ $ref =~ ^[0-9a-fA-F]{40}$ ]]; then
    printf '%s\n' "${ref,,}"
    return
  fi
  out=$(git ls-remote "$url" "refs/tags/$ref^{}" "refs/tags/$ref" "refs/heads/$ref") || return 1
  printf '%s\n' "$out" | awk '
    $2 ~ /\^\{\}$/ { peeled=$1 }
    $2 ~ /^refs\/tags\// && $2 !~ /\^\{\}$/ { tag=$1 }
    $2 ~ /^refs\/heads\// { branch=$1 }
    END { if (peeled) print peeled; else if (tag) print tag; else if (branch) print branch }
  '
}

clone_ref() {
  local url=$1 dir=$2 ref=${3:-HEAD}
  reset_build_dir "$dir"
  as_build git -C "$dir" init -q
  as_build git -C "$dir" remote add origin "$url"
  as_build git -C "$dir" -c advice.detachedHead=false fetch -q --depth 1 origin "$ref"
  as_build git -C "$dir" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
}

server_ref() {
  if [[ -n $PINNED ]]; then
    printf '%s\n' "$PINNED"
    return 0
  fi
  local t
  t=$(latest_tag "$GH/xserver.git" 'xlibre-xserver-*') || die "cannot query XLibre release tags"
  [[ -n $t ]] || die "no XLibre release tag found"
  printf '%s\n' "$t"
}

drv_prev() {
  local name=$1 field=$2
  [[ -f $DRVF ]] || return 0
  awk -v n="$name" -v f="$field" '$1==n {print $f; exit}' "$DRVF"
}

current_manifest() {
  if compgen -G "$MANI/*.list" >/dev/null 2>&1; then
    cat "$MANI"/*.list 2>/dev/null | sed '/^$/d' | sort -u
  fi
}

libs_broken_prefix() {
  local prefix=$1 f
  for f in "$prefix/bin/Xorg" "$prefix/bin/X"; do
    [[ -e $f ]] || continue
    ldd "$f" 2>/dev/null | grep -q 'not found' && return 0
  done
  if [[ -d $prefix/lib ]]; then
    while IFS= read -r -d '' f; do
      ldd "$f" 2>/dev/null | grep -q 'not found' && return 0
    done < <(find "$prefix/lib" -type f -name '*_drv.so*' -print0 2>/dev/null)
  fi
  return 1
}

managed_missing() {
  local p
  compgen -G "$MANI/*.list" >/dev/null 2>&1 || return 0
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    [[ -e $p || -L $p ]] || return 0
  done < <(current_manifest)
  return 1
}

CHANGES=()
changes() {
  CHANGES=()
  local ref sha t d prevsha prevst

  [[ $S_PREFIX == "$PREFIX" ]] || CHANGES+=("prefix ${S_PREFIX:-?} -> $PREFIX")
  [[ $S_DRIVERS == "$DRIVERS" ]] || CHANGES+=("driver set changed")
  [[ $S_BUILDTYPE == "$BUILDTYPE" ]] || CHANGES+=("build type ${S_BUILDTYPE:-?} -> $BUILDTYPE")
  [[ $S_PINNED == "$PINNED" ]] || CHANGES+=("pinned ref changed")

  ref=$(server_ref)
  sha=$(remote_sha "$GH/xserver.git" "$ref") || die "cannot query $GH/xserver.git"
  [[ -n $sha ]] || die "cannot resolve XLibre ref $ref"
  if [[ $S_SERVER_SHA != "$sha" ]]; then
    CHANGES+=("xserver ${S_SERVER_REF:-?} (${S_SERVER_SHA:0:8}) -> $ref (${sha:0:8})")
  fi

  if [[ $S_XP -eq 1 ]]; then
    t=$(latest_tag "$XPURL" 'xorgproto-*') || die "cannot query $XPURL"
    [[ -n $t ]] || die "cannot find xorgproto release tag"
    sha=$(remote_sha "$XPURL" "$t") || die "cannot query xorgproto ref $t"
    [[ $S_XP_SHA == "$sha" ]] || CHANGES+=("xorgproto ${S_XP_REF:-?} (${S_XP_SHA:0:8}) -> $t (${sha:0:8})")
  fi

  for d in $DRIVERS; do
    sha=$(remote_sha "$GH/$d.git") || die "cannot query $GH/$d.git"
    [[ -n $sha ]] || die "cannot resolve HEAD for $d"
    prevsha=$(drv_prev "$d" 2)
    prevst=$(drv_prev "$d" 3)
    if [[ $prevsha != "$sha" || $prevst != ok ]]; then
      CHANGES+=("$d ${prevst:-new} ${prevsha:0:8} -> ${sha:0:8}")
    fi
  done

  if libs_broken_prefix "$S_PREFIX"; then
    CHANGES+=("installed binaries have missing libraries")
  fi
  if managed_missing; then
    CHANGES+=("one or more managed files are missing")
  fi
}

detect_init() {
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    echo systemd
  elif [[ -d /run/openrc ]] \
       || { command -v rc-status >/dev/null 2>&1 && rc-status --runlevel >/dev/null 2>&1; }; then
    echo openrc
  else
    echo other
  fi
}

auto_off() {
  if command -v systemctl >/dev/null 2>&1; then
    "${SUDO[@]}" systemctl disable --now xlup.timer >/dev/null 2>&1 || true
  fi
  "${SUDO[@]}" rm -f \
    /etc/systemd/system/xlup.timer \
    /etc/systemd/system/xlup.service \
    /etc/periodic/weekly/xlup \
    /etc/cron.weekly/xlup \
    /etc/cron.d/xlup
  if command -v systemctl >/dev/null 2>&1; then
    "${SUDO[@]}" systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

install_self() {
  local src=$SCRIPT_SOURCE
  [[ -n $src && -f $src ]] || {
    warn "cannot determine script path; $SELF not installed"
    return 1
  }
  case $src in /dev/fd/*|/proc/*/fd/*) warn "running from stdin/pipe; $SELF not installed"; return 1 ;; esac
  if [[ $src == "$(readlink -f -- "$SELF" 2>/dev/null || true)" ]]; then return 0; fi
  "${SUDO[@]}" install -Dm755 -- "$src" "$SELF" || return 1
  [[ -x $SELF ]]
}

auto_on_systemd() {
  local cmd=$1
  "${SUDO[@]}" tee /etc/systemd/system/xlup.service >/dev/null <<EOF
[Unit]
Description=XLibre source update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Nice=10
ExecStart=$cmd
EOF
  "${SUDO[@]}" tee /etc/systemd/system/xlup.timer >/dev/null <<'EOF'
[Unit]
Description=Weekly XLibre source update

[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  "${SUDO[@]}" systemctl daemon-reload
  "${SUDO[@]}" systemctl enable --now xlup.timer
}

find_openrc_cron_service() {
  local s
  for s in cron cronie crond; do
    [[ -x /etc/init.d/$s ]] && { printf '%s\n' "$s"; return 0; }
  done
  return 1
}

auto_on_openrc() {
  local cmd=$1 svc
  command -v rc-service >/dev/null 2>&1 || return 1
  command -v rc-update >/dev/null 2>&1 || return 1

  svc=$(find_openrc_cron_service || true)
  if [[ -z $svc && -x /usr/bin/apt-get ]]; then
    log "openrc: installing cron scheduler"
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends cron
    svc=$(find_openrc_cron_service || true)
  fi
  [[ -n $svc ]] || { warn "OpenRC detected but no supported cron service was found"; return 1; }

  if [[ $svc == crond ]] && command -v crond >/dev/null 2>&1      && crond --help 2>&1 | grep -qi busybox; then
    warn "BusyBox crond does not reliably consume /etc/cron.d on Debian-family systems"
    return 1
  fi

  "${SUDO[@]}" rc-update add "$svc" default >/dev/null
  rc-service "$svc" status >/dev/null 2>&1 || "${SUDO[@]}" rc-service "$svc" start >/dev/null

  "${SUDO[@]}" install -d -m 0755 /etc/cron.d
  "${SUDO[@]}" rm -f /etc/periodic/weekly/xlup /etc/cron.weekly/xlup
  "${SUDO[@]}" tee /etc/cron.d/xlup >/dev/null <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * 0 root $cmd >>/var/log/xlup.log 2>&1
EOF
  "${SUDO[@]}" chmod 0644 /etc/cron.d/xlup
  log "openrc: weekly job installed in /etc/cron.d/xlup (service: $svc)"
}

auto_on_manual() {
  local cmd=$1
  if { command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; }; then
    if command -v crond >/dev/null 2>&1 && ! command -v cron >/dev/null 2>&1        && crond --help 2>&1 | grep -qi busybox; then
      warn "BusyBox crond is not configured here because /etc/cron.d support is not portable"
      return 1
    fi
    "${SUDO[@]}" install -d -m 0755 /etc/cron.d
    "${SUDO[@]}" tee /etc/cron.d/xlup >/dev/null <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * 0 root $cmd >>/var/log/xlup.log 2>&1
EOF
    "${SUDO[@]}" chmod 0644 /etc/cron.d/xlup
    warn "unknown init system: installed cron job, but verify that cron is enabled"
    return 0
  fi
  warn "unrecognized init system and no usable cron scheduler found"
  warn "schedule this command weekly with your system scheduler: $cmd"
  return 1
}

auto_on() {
  install_self || die "auto-update requires the script to be run from a regular file"
  local cmd="$SELF -y" init
  init=$(detect_init)
  case $init in
    systemd) auto_on_systemd "$cmd" || die "systemd timer setup failed"; log "weekly auto-update enabled (systemd)" ;;
    openrc) auto_on_openrc "$cmd" || die "OpenRC auto-update setup failed"; log "weekly auto-update enabled (OpenRC + cron)" ;;
    *) auto_on_manual "$cmd" || die "automatic scheduler setup failed" ;;
  esac
}

divert_off() {
  command -v dpkg-divert >/dev/null 2>&1 || return 0
  if dpkg-divert --list /usr/bin/Xorg 2>/dev/null | grep -q ' by xlup$'; then
    "${SUDO[@]}" rm -f /usr/bin/Xorg
    "${SUDO[@]}" dpkg-divert --package xlup --remove --rename /usr/bin/Xorg >/dev/null || true
  fi
}

xserverrc_flags() {
  if [[ ${SEAT_BACKEND:-${S_SEAT_BACKEND:-}} == libseat ]]; then
    printf '%s\n' '-keeptty -nolisten tcp'
  else
    printf '%s\n' '-nolisten tcp'
  fi
}

is_default() {
  local x=$PREFIX/bin/Xorg
  [[ -n $TARGET_HOME && -f $TARGET_HOME/.xserverrc ]] || return 1
  grep -Fqs -- "exec $x " "$TARGET_HOME/.xserverrc"
}

note() {
  is_default || log "note: XLibre is not the default startx server; run 'xlup -d' for instructions"
}

set_default() {
  local x=$PREFIX/bin/Xorg rc bak grp ans flags expected
  [[ -x $x ]] || return 0
  [[ -n $TARGET_HOME ]] || { warn "cannot determine home directory for $TARGET_USER"; return 1; }
  rc=$TARGET_HOME/.xserverrc
  bak=$TARGET_HOME/.xserverrc.xlup.bak
  flags=$(xserverrc_flags)
  expected=$(printf '#!/bin/sh\n# managed by xlup\nexec %s %s "$@"\n' "$x" "$flags")

  if [[ -f $rc && ! -L $rc && "$(cat -- "$rc")" == "$expected" ]]; then
    log "already configured: $rc"
    return 0
  fi

  [[ -t 0 ]] || { warn "no tty; skipping $rc"; return 1; }
  [[ ! -L $rc ]] || { warn "$rc is a symlink; refusing to overwrite it"; return 1; }

  if [[ $ASSUME_YES -eq 0 ]]; then
    if [[ -e $rc ]]; then
      read -r -p "xlup: $rc exists, replace it with XLibre config? [y/N] " ans
    else
      read -r -p "xlup: create $rc so startx uses XLibre? [y/N] " ans
    fi
    [[ $ans =~ ^[Yy]$ ]] || { log "keeping existing configuration"; return 1; }
  fi

  if [[ -e $rc ]] && ! grep -qs '^# managed by xlup$' "$rc" && [[ ! -e $bak ]]; then
    "${SUDO[@]}" cp -a -- "$rc" "$bak"
  fi

  printf '%s' "$expected" | "${SUDO[@]}" tee "$rc" >/dev/null
  grp=$(id -gn "$TARGET_USER" 2>/dev/null) || { warn "cannot determine group for $TARGET_USER"; return 1; }
  "${SUDO[@]}" chown "$TARGET_USER:$grp" "$rc"
  "${SUDO[@]}" chmod 0755 "$rc"
  log "startx: $rc configured to use $x"
}

restore_xserverrc() {
  [[ -n $TARGET_HOME ]] || return 0
  local rc=$TARGET_HOME/.xserverrc bak=$TARGET_HOME/.xserverrc.xlup.bak
  if [[ -f $rc && ! -L $rc ]] && grep -qs '^# managed by xlup$' "$rc"; then
    if [[ -e $bak || -L $bak ]]; then
      "${SUDO[@]}" rm -f -- "$rc"
      "${SUDO[@]}" mv -f -- "$bak" "$rc"
    else
      "${SUDO[@]}" rm -f -- "$rc"
    fi
  fi
}

hint() {
  local x=$PREFIX/bin/Xorg flags
  flags=$(xserverrc_flags)
  log "test XLibre first: sudo $x :1 vt8"
  log "startx (run as $TARGET_USER, not with sudo):"
  printf '  printf '\''#!/bin/sh\\nexec %s %s "$@"\\n'\'' > ~/.xserverrc && chmod +x ~/.xserverrc\n' "$x" "$flags"
  log "verify: pgrep -a Xorg  (should show $x)"
}

baseline_index_init() {
  "${SUDO[@]}" install -d -m 0755 "$ORIG"
  "${SUDO[@]}" install -d -m 0700 "$ORIG/data"
  if [[ ! -e $ORIG/index.tsv ]]; then
    "${SUDO[@]}" install -m 0644 /dev/null "$ORIG/index.tsv"
  fi
}

baseline_lookup() {
  local p=$1
  [[ -f $ORIG/index.tsv ]] || return 1
  awk -F '\t' -v p="$p" '$3==p {print $1 "\t" $2; found=1; exit} END{exit !found}' "$ORIG/index.tsv"
}

baseline_append() {
  local status=$1 hash=$2 p=$3 tmp=$TMPROOT/orig-index.$$
  mkdir -p "$TMPROOT"
  cat "$ORIG/index.tsv" > "$tmp"
  printf '%s\t%s\t%s\n' "$status" "$hash" "$p" >> "$tmp"
  "${SUDO[@]}" install -m 0644 "$tmp" "$ORIG/index.tsv.new.$$"
  "${SUDO[@]}" mv -f "$ORIG/index.tsv.new.$$" "$ORIG/index.tsv"
  rm -f "$tmp"
}

baseline_capture() {
  local p=$1 hash rel tmp
  baseline_index_init
  baseline_lookup "$p" >/dev/null 2>&1 && return 0
  hash=$(printf '%s' "$p" | sha256sum | awk '{print $1}')
  if [[ -e $p || -L $p ]]; then
    [[ -f $p || -L $p ]] || die "refusing to replace non-file path: $p"
    rel=${p#/}
    tmp=$ORIG/data/$hash.tar.new.$$
    "${SUDO[@]}" tar "${TAR_META[@]}" -C / -cpf "$tmp" -- "$rel"
    "${SUDO[@]}" chmod 0600 "$tmp"
    "${SUDO[@]}" mv -f "$tmp" "$ORIG/data/$hash.tar"
    baseline_append P "$hash" "$p"
  else
    baseline_append A "$hash" "$p"
  fi
}

baseline_mark_legacy_absent() {
  local p=$1 hash
  baseline_index_init
  baseline_lookup "$p" >/dev/null 2>&1 && return 0
  hash=$(printf '%s' "$p" | sha256sum | awk '{print $1}')
  baseline_append A "$hash" "$p"
}

remove_live_path() {
  local p=$1
  if [[ -d $p && ! -L $p ]]; then
    "${SUDO[@]}" rmdir -- "$p" 2>/dev/null || die "managed file path became a non-empty directory: $p"
  else
    "${SUDO[@]}" rm -f -- "$p"
  fi
}

baseline_restore() {
  local p=$1 rec status hash
  secure_parent_chain "$p"
  rec=$(baseline_lookup "$p" || true)
  [[ -n $rec ]] || die "missing baseline metadata for $p"
  status=${rec%%$'\t'*}
  hash=${rec#*$'\t'}
  remove_live_path "$p"
  if [[ $status == P ]]; then
    [[ -f $ORIG/data/$hash.tar ]] || die "missing original backup for $p"
    "${SUDO[@]}" mkdir -p -- "$(dirname -- "$p")"
    "${SUDO[@]}" tar "${TAR_META[@]}" -C / -xpf "$ORIG/data/$hash.tar"
  fi
}


stage_source_safe() {
  local p=$1 src=$STAGE_ROOT$p parent cur=$STAGE_ROOT comp
  local -a parts=()
  [[ -f $src || -L $src ]] || die "staged source missing for $p"
  parent=${p%/*}
  IFS='/' read -r -a parts <<< "${parent#/}"
  for comp in "${parts[@]}"; do
    [[ -n $comp ]] || continue
    cur=${cur%/}/$comp
    [[ ! -L $cur ]] || die "staged source has symlink parent: $p"
    [[ ! -e $cur || -d $cur ]] || die "invalid staged parent for $p"
  done
}

validate_staged_symlink() {
  local p=$1 target=$2 resolved
  validate_scalar "$target" || die "unsafe symlink target for $p"
  [[ -n $target ]] || die "empty symlink target for $p"
  if [[ $target == /* ]]; then
    resolved=$(realpath -m -- "$target") || die "cannot resolve symlink target for $p"
  else
    resolved=$(realpath -m -- "$(dirname -- "$p")/$target") || die "cannot resolve symlink target for $p"
  fi
  path_within_domain "$resolved" || die "staged symlink escapes allowed root: $p -> $target"
}

manifest_validate() {
  local file=$1 p prev=''
  [[ -f $file ]] || die "manifest not found: $file"
  while IFS= read -r p || [[ -n $p ]]; do
    [[ -n $p ]] || continue
    validate_path "$p" || die "unsafe path in manifest: $p"
    path_allowed "$p" || die "staged install attempted unexpected path: $p"
    [[ $p != "$prev" ]] || die "duplicate path in manifest: $p"
    prev=$p
  done < "$file"
}

stage_manifest() {
  local root=$1 out=$2 p
  : > "$out"
  while IFS= read -r -d '' p; do
    p=${p#"$root"}
    validate_path "$p" || die "unsupported staged path"
    printf '%s\n' "$p" >> "$out"
  done < <(find "$root" \( -type f -o -type l \) -print0)
  sort -u -o "$out" "$out"
  manifest_validate "$out"
}

preflight_stage_manifest() {
  local file=$1 p src target mode mode_dec
  manifest_validate "$file"
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    src=$STAGE_ROOT$p
    stage_source_safe "$p"
    if [[ -L $src ]]; then
      target=$(readlink -- "$src")
      validate_staged_symlink "$p" "$target"
    else
      mode=$(stat -c '%a' -- "$src") || die "cannot read staged mode for $p"
      mode_dec=$((8#$mode))
      (( (mode_dec & 06000) == 0 )) || die "refusing staged setuid/setgid file: $p"
      (( (mode_dec & 0022) == 0 )) || die "refusing group/world-writable staged file: $p"
    fi
  done < "$file"
}

begin_tx() {
  local touched=$1 p rel existing=$TMPROOT/existing.$$
  manifest_validate "$touched"
  mkdir -p "$TMPROOT"
  : > "$existing"

  "${SUDO[@]}" rm -rf -- "$TX"
  "${SUDO[@]}" install -d -m 0755 "$TX"
  "${SUDO[@]}" install -m 0644 "$touched" "$TX/touched.list"

  local domains=$TMPROOT/domains.$$
  {
    printf '%s\n' "$PREFIX" /etc/X11 /var/lib/xkb
    [[ -n ${S_PREFIX:-} ]] && printf '%s\n' "$S_PREFIX"
  } | sed '/^$/d' | sort -u > "$domains"
  "${SUDO[@]}" install -m 0644 "$domains" "$TX/domains.list"
  rm -f "$domains"

  while IFS= read -r p; do
    [[ -n $p ]] || continue
    secure_parent_chain "$p"
    if [[ -e $p || -L $p ]]; then
      [[ -f $p || -L $p ]] || die "refusing to transact non-file path: $p"
      rel=${p#/}
      printf '%s\n' "$rel" >> "$existing"
    fi
  done < "$touched"
  "${SUDO[@]}" install -m 0644 "$existing" "$TX/existing.rel"

  if [[ -s $existing ]]; then
    "${SUDO[@]}" tar "${TAR_META[@]}" -C / --verbatim-files-from --no-recursion -czpf "$TX/live.tar.gz" -T "$existing"
  else
    "${SUDO[@]}" tar "${TAR_META[@]}" -C / -czpf "$TX/live.tar.gz" -T /dev/null
  fi
  "${SUDO[@]}" chmod 0600 "$TX/live.tar.gz"

  if [[ -f $STATE ]]; then "${SUDO[@]}" cp -a "$STATE" "$TX/state.before"; "${SUDO[@]}" touch "$TX/state.present"; fi
  if [[ -f $DRVF ]]; then "${SUDO[@]}" cp -a "$DRVF" "$TX/drivers.before"; "${SUDO[@]}" touch "$TX/drivers.present"; fi
  if [[ -d $MANI ]]; then "${SUDO[@]}" cp -a "$MANI" "$TX/manifests.before"; "${SUDO[@]}" touch "$TX/manifests.present"; fi

  "${SUDO[@]}" touch "$TX/ACTIVE"
  ARMED=1
  rm -f "$existing"
}

save_tx_backup() {
  local base=$ST/backups stamp tmp dst
  stamp=$(date +%Y%m%d-%H%M%S)-$$
  tmp=$base/.tmp-$stamp
  dst=$base/$stamp
  "${SUDO[@]}" install -d -m 0700 "$base" "$tmp"
  "${SUDO[@]}" cp -a "$TX/live.tar.gz" "$TX/touched.list" "$TX/existing.rel" "$TX/domains.list" "$tmp/"
  [[ -f $TX/state.before ]] && "${SUDO[@]}" cp -a "$TX/state.before" "$tmp/" || true
  [[ -f $TX/drivers.before ]] && "${SUDO[@]}" cp -a "$TX/drivers.before" "$tmp/" || true
  [[ -d $TX/manifests.before ]] && "${SUDO[@]}" cp -a "$TX/manifests.before" "$tmp/" || true
  "${SUDO[@]}" mv "$tmp" "$dst"

  local -a old=()
  mapfile -t old < <("${SUDO[@]}" find "$base" -mindepth 1 -maxdepth 1 -type d ! -name '.tmp-*' -printf '%f\n' | sort)
  while ((${#old[@]} > 3)); do
    "${SUDO[@]}" rm -rf -- "$base/${old[0]}"
    old=("${old[@]:1}")
  done
  log "backup: $dst"
}

install_stage_path() {
  local p=$1 src=$STAGE_ROOT$p parent mode mode_dec clean_mode target
  stage_source_safe "$p"
  secure_parent_chain "$p"
  parent=$(dirname -- "$p")
  "${SUDO[@]}" mkdir -p -- "$parent"
  secure_parent_chain "$p"
  remove_live_path "$p"
  if [[ -L $src ]]; then
    target=$(readlink -- "$src")
    validate_staged_symlink "$p" "$target"
    "${SUDO[@]}" ln -s -- "$target" "$p"
  else
    mode=$(stat -c '%a' -- "$src") || die "cannot read staged mode for $p"
    mode_dec=$((8#$mode))
    (( (mode_dec & 06000) == 0 )) || die "refusing staged setuid/setgid file: $p"
    (( (mode_dec & 0022) == 0 )) || die "refusing group/world-writable staged file: $p"
    printf -v clean_mode '%04o' "$((mode_dec & 0777))"
    "${SUDO[@]}" install -m "$clean_mode" -- "$src" "$p"
  fi
}

atomic_install_file() {
  local src=$1 dst=$2 mode=${3:-0644} tmp=$dst.new.$$
  "${SUDO[@]}" install -m "$mode" "$src" "$tmp"
  "${SUDO[@]}" mv -f "$tmp" "$dst"
}

commit_metadata() {
  local state_new=$TMPROOT/state.new drivers_new=$TMPROOT/drivers.new manifest_new=$TMPROOT/manifest.new
  state_write_file "$state_new"
  cp "$NEW_DRIVERS_FILE" "$drivers_new"
  cp "$NEW_MANIFEST" "$manifest_new"

  "${SUDO[@]}" install -d -m 0755 "$MANI"
  atomic_install_file "$state_new" "$STATE" 0644
  atomic_install_file "$drivers_new" "$DRVF" 0644
  atomic_install_file "$manifest_new" "$MANIFEST" 0644
  "${SUDO[@]}" find "$MANI" -maxdepth 1 -type f -name '*.list' ! -name 'all.list' -delete
}

apply_staged_transaction() {
  local old=$TMPROOT/old.list touched=$TMPROOT/touched.list p
  mkdir -p "$TMPROOT"
  current_manifest > "$old" || true
  sort -u -o "$old" "$old"
  cat "$old" "$NEW_MANIFEST" | sed '/^$/d' | sort -u > "$touched"
  manifest_validate "$NEW_MANIFEST"
  manifest_validate "$touched"
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    secure_parent_chain "$p"
  done < "$touched"

  if [[ -s $old && ! -f $ORIG/index.tsv ]]; then
    warn "migrating legacy manifests: pre-xlup originals for already managed paths are unavailable"
  fi
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    baseline_mark_legacy_absent "$p"
  done < "$old"

  while IFS= read -r p; do
    [[ -n $p ]] || continue
    if ! grep -qxF -- "$p" "$old"; then
      baseline_capture "$p"
    fi
  done < "$NEW_MANIFEST"

  begin_tx "$touched"

  while IFS= read -r p; do
    [[ -n $p ]] || continue
    grep -qxF -- "$p" "$NEW_MANIFEST" && continue
    baseline_restore "$p"
  done < "$old"

  while IFS= read -r p; do
    [[ -n $p ]] || continue
    install_stage_path "$p"
  done < "$NEW_MANIFEST"

  "${SUDO[@]}" ldconfig || die "ldconfig failed after deployment"
  verify_live
  save_tx_backup
  commit_metadata
  "${SUDO[@]}" rm -rf -- "$TX"
  ARMED=0
}

uninstall_managed() {
  local list=$TMPROOT/remove.list p
  mkdir -p "$TMPROOT"
  current_manifest > "$list" || true
  sort -u -o "$list" "$list"
  if [[ -s $list ]]; then manifest_validate "$list"; fi
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    if baseline_lookup "$p" >/dev/null 2>&1; then
      baseline_restore "$p"
    else
      secure_parent_chain "$p"
      remove_live_path "$p"
    fi
  done < "$list"
  "${SUDO[@]}" ldconfig || true
}

case $MODE in
  remove)
    [[ -d $ST ]] || die "nothing to remove"
    auto_off
    divert_off
    restore_xserverrc
    uninstall_managed
    "${SUDO[@]}" rm -f "$SELF"
    if [[ -f $ST/build-user-created ]] && id xlup-build >/dev/null 2>&1; then
      "${SUDO[@]}" userdel xlup-build >/dev/null 2>&1 || warn "could not remove xlup-build user"
    fi
    "${SUDO[@]}" rm -rf "$CACHE"
    "${SUDO[@]}" rm -rf "$ST"
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
    if [[ ${#CHANGES[@]} -eq 0 ]]; then log "up to date"; exit 0; fi
    printf '  %s\n' "${CHANGES[@]}"
    exit 10
    ;;
  install)
    if [[ $HAVE -eq 1 && $AUTO -eq 1 ]]; then
      auto_on
      exit 0
    fi
    if [[ $HAVE -eq 1 ]]; then
      changes
      if [[ ${#CHANGES[@]} -eq 0 ]]; then
        log "up to date ($S_SERVER_REF)"
        if [[ -t 0 ]]; then set_default || true; fi
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
command -v apt-get >/dev/null 2>&1 || die "apt-get not found"

log "system: ${PRETTY_NAME:-unknown}"
log "prefix: $PREFIX  drivers: $DRIVERS  jobs: $JOBS"

if [[ $ASSUME_YES -eq 0 ]]; then
  [[ -t 0 ]] || die "no tty for confirmation; pass -y"
  read -r -p "xlup: proceed with build and transactional install into $PREFIX? [y/N] " ans
  [[ $ans =~ ^[Yy]$ ]] || die "aborted"
fi

setup_build_identity
prepare_work_dirs

AVAIL=$(df -Pk "$WORK" | awk 'NR==2{print $4}')
[[ ${AVAIL:-0} -ge 1048576 ]] || die "less than 1 GB free in $WORK"

REQ=(
  git ca-certificates build-essential meson ninja-build pkg-config procps
  autoconf automake libtool xutils-dev
  x11proto-dev xtrans-dev libpixman-1-dev libxkbcommon-x11-dev libxfont-dev
  libxcvt-dev libdrm-dev libepoxy-dev libxkbfile-dev libxshmfence-dev
  libbsd-dev libgl-dev libglu1-mesa-dev mesa-common-dev libgbm-dev
  libxcb-shape0-dev libxcb-util-dev libxcb-icccm4-dev
  nettle-dev libpciaccess-dev libx11-dev libxau-dev libxdmcp-dev libxext-dev
  libinput-dev libevdev-dev libmtdev-dev libdbus-1-dev
  xkb-data x11-xkb-utils xinit
)
OPT=(
  libseat-dev seatd
  libssl-dev libselinux1-dev libaudit-dev libunwind-dev
  libxcb-keysyms1-dev libxcb-image0-dev libxcb-render-util0-dev libxcb-randr0-dev
  libxcb-xkb-dev libxcb-xv0-dev libxcb-glx0-dev libxcb-xf86dri0-dev libxcb-render0-dev
  libxcb-composite0-dev libxcb-xinput-dev libxcb-ewmh-dev libxcb-present-dev
  libxcb-dri2-0-dev libxcb-dri3-0-dev libxcb-res0-dev libxcb-shm0-dev libxcb-sync-dev
  libxcb-xfixes0-dev libxcb-xinerama0-dev libx11-xcb-dev
  libxmu-dev libxrender-dev libxi-dev libxres-dev libxtst-dev libxrandr-dev
  libxfixes-dev libxv-dev libxvmc-dev libxinerama-dev libxcursor-dev libxdamage-dev
  libxxf86vm-dev libxaw7-dev libxt-dev libxpm-dev libxss-dev
  x11-xserver-utils xfonts-base
)

log "refreshing package indexes"
"${SUDO[@]}" apt-get -o DPkg::Lock::Timeout=300 update || warn "apt-get update failed; using existing indexes"

AV=()
MISS=()
for p in "${REQ[@]}"; do
  if apt-cache show "$p" >/dev/null 2>&1; then AV+=("$p"); else MISS+=("$p"); fi
done

if apt-cache show libudev-dev >/dev/null 2>&1; then
  AV+=(libudev-dev)
elif apt-cache show libeudev-dev >/dev/null 2>&1; then
  AV+=(libeudev-dev)
else
  MISS+=("libudev-dev/libeudev-dev")
fi

[[ ${#MISS[@]} -eq 0 ]] || die "missing apt packages: ${MISS[*]}"
for p in "${OPT[@]}"; do
  apt-cache show "$p" >/dev/null 2>&1 && AV+=("$p") || true
done
mapfile -t AV < <(printf '%s\n' "${AV[@]}" | sort -u)

log "installing build dependencies"
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "${AV[@]}"

command -v meson >/dev/null 2>&1 || die "meson not found"
MV=$(meson --version)
[[ $(printf '%s\n0.61.0\n' "$MV" | sort -V | head -n1) == 0.61.0 ]] || die "meson >= 0.61 required (found $MV)"

MA=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)
BASE_PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig"
[[ -n $MA ]] && BASE_PKG_CONFIG_PATH="$PREFIX/lib/$MA/pkgconfig:$BASE_PKG_CONFIG_PATH"
export PKG_CONFIG_PATH=$BASE_PKG_CONFIG_PATH

SEAT_BACKEND=''
LOGIND_OPT=false
LIBSEAT_OPT=false
choose_seat_backend() {
  local init
  init=$(detect_init)
  case $init in
    systemd)
      pkg-config --exists dbus-1 || die "dbus-1 development files are required for logind"
      SEAT_BACKEND=logind
      LOGIND_OPT=true
      LIBSEAT_OPT=false
      ;;
    openrc)
      if pkg-config --atleast-version=0.9.1 libseat 2>/dev/null; then
        SEAT_BACKEND=libseat
        LOGIND_OPT=false
        LIBSEAT_OPT=true
        if command -v rc-service >/dev/null 2>&1 && rc-service elogind status >/dev/null 2>&1; then
          log "openrc: libseat will use the active elogind backend"
        elif [[ -x /etc/init.d/seatd ]]; then
          command -v rc-update >/dev/null 2>&1 || die "rc-update not found"
          "${SUDO[@]}" rc-update add seatd default >/dev/null
          rc-service seatd status >/dev/null 2>&1 || "${SUDO[@]}" rc-service seatd start >/dev/null
          log "openrc: seatd is active"
        else
          die "libseat >= 0.9.1 is present but neither elogind nor seatd is active"
        fi
      elif command -v rc-service >/dev/null 2>&1 && rc-service elogind status >/dev/null 2>&1; then
        pkg-config --exists dbus-1 || die "dbus-1 is required for elogind integration"
        SEAT_BACKEND=logind
        LOGIND_OPT=true
        LIBSEAT_OPT=false
        log "openrc: using elogind through the logind interface"
      else
        die "OpenRC needs libseat >= 0.9.1 with seatd/elogind, or an active elogind service"
      fi
      ;;
    *)
      if pkg-config --atleast-version=0.9.1 libseat 2>/dev/null; then
        SEAT_BACKEND=libseat
        LOGIND_OPT=false
        LIBSEAT_OPT=true
      else
        die "unsupported init without libseat >= 0.9.1"
      fi
      ;;
  esac
}
choose_seat_backend

proto_requirements_ok() {
  local item name ver
  local reqs=(
    'xproto 7.0.31' 'randrproto 1.6.0' 'renderproto 0.11'
    'xextproto 7.2.99.901' 'inputproto 2.3.99.1' 'kbproto 1.0.3'
    'fontsproto 2.1.3' 'fixesproto 6.1' 'damageproto 1.1'
    'xcmiscproto 1.2.0' 'bigreqsproto 1.1.0' 'presentproto 1.4'
    'compositeproto 0.4' 'recordproto 1.13.99.1' 'scrnsaverproto 1.1'
    'resourceproto 1.2.0' 'xf86driproto 2.1.0' 'dri2proto 2.8'
    'dri3proto 1.4' 'xf86vidmodeproto 2.2.99.1' 'dpmsproto 1.2'
  )
  for item in "${reqs[@]}"; do
    name=${item%% *}; ver=${item#* }
    pkg-config --atleast-version="$ver" "$name" 2>/dev/null || return 1
  done
  for name in videoproto xineramaproto; do pkg-config --exists "$name" 2>/dev/null || return 1; done
}

merge_component() {
  local comp=$1
  [[ -d $comp ]] || die "component stage missing: $comp"
  as_build cp -a "$comp/." "$STAGE_ROOT/"
}

rewrite_pc_var() {
  local file=$1 key=$2 value=$3 tmp=$file.tmp.$$
  XLUP_PC_VALUE="$value" awk -v k="$key" 'index($0,k "=")==1 {print k "=" ENVIRON["XLUP_PC_VALUE"]; next} {print}' "$file" > "$tmp"
  mv -f "$tmp" "$file"
}

make_proto_overlay() {
  local comp=$1 overlay=$OVERLAY_ROOT/proto pc dst
  rm -rf "$overlay"; mkdir -p "$overlay"
  while IFS= read -r -d '' pc; do
    dst=$overlay/$(basename "$pc")
    cp "$pc" "$dst"
    rewrite_pc_var "$dst" prefix "$comp$PREFIX"
  done < <(find "$comp$PREFIX" -type f -path '*/pkgconfig/*.pc' -print0 2>/dev/null)
  PROTO_OVERLAY=$overlay
}

XP=0
XP_REF=''
XP_SHA=''
build_xp() {
  local ref comp=$COMP_ROOT/xorgproto
  ref=$(latest_tag "$XPURL" 'xorgproto-*') || die "cannot query $XPURL"
  [[ -n $ref ]] || die "cannot find xorgproto release tag"
  log "building xorgproto $ref"
  clone_ref "$XPURL" "$SRC/xorgproto" "$ref"
  reset_build_dir "$comp"
  as_build rm -rf "$SRC/xorgproto/build"
  as_build_in "$SRC/xorgproto" meson setup build --prefix "$PREFIX" --buildtype "$BUILDTYPE"
  as_build_in "$SRC/xorgproto" ninja -C build -j "$JOBS"
  as_build_in "$SRC/xorgproto" env "DESTDIR=$comp" ninja -C build install
  make_proto_overlay "$comp"
  merge_component "$comp"
  XP=1
  XP_REF=$ref
  XP_SHA=$(as_build git -C "$SRC/xorgproto" rev-parse HEAD)
  export PKG_CONFIG_PATH="$PROTO_OVERLAY:$BASE_PKG_CONFIG_PATH"
}

SREF=''
SSHA=''
SERVER_STAGE=''
XORG_MODULEDIR=''
XORG_LIBDIR=''
XORG_SDKDIR=''
SERVER_OVERLAY=''

server_setup() {
  as_build_in "$SRC/xserver" meson setup build \
    --prefix "$PREFIX" \
    --buildtype "$BUILDTYPE" \
    --sysconfdir /etc \
    --localstatedir /var \
    -Dxkb_dir=/usr/share/X11/xkb \
    -Dxkb_output_dir=/var/lib/xkb \
    -Dxkb_bin_dir=/usr/bin \
    -Dsystemd_logind="$LOGIND_OPT" \
    -Dseatd_libseat="$LIBSEAT_OPT"
}
prepare_server_overlay() {
  local pc pcdir overlay=$OVERLAY_ROOT/server qpath
  rm -rf "$overlay"; mkdir -p "$overlay"
  pc=$(find "$SERVER_STAGE$PREFIX" -type f -name xorg-server.pc -print -quit)
  [[ -n $pc ]] || die "xorg-server.pc missing from staged server"
  pcdir=$(dirname "$pc")
  qpath="$pcdir:$BASE_PKG_CONFIG_PATH"
  [[ -n ${PROTO_OVERLAY:-} ]] && qpath="$pcdir:$PROTO_OVERLAY:$BASE_PKG_CONFIG_PATH"
  XORG_MODULEDIR=$(PKG_CONFIG_PATH="$qpath" pkg-config --variable=moduledir xorg-server)
  XORG_LIBDIR=$(PKG_CONFIG_PATH="$qpath" pkg-config --variable=libdir xorg-server)
  XORG_SDKDIR=$(PKG_CONFIG_PATH="$qpath" pkg-config --variable=sdkdir xorg-server)
  [[ $XORG_MODULEDIR == /* && $XORG_LIBDIR == /* && $XORG_SDKDIR == /* ]] || die "invalid directories in xorg-server.pc"

  while IFS= read -r -d '' pc; do
    cp "$pc" "$overlay/$(basename "$pc")"
  done < <(find "$SERVER_STAGE$PREFIX" -type f \( -name 'xorg-server.pc' -o -name 'xlibre-server.pc' \) -print0)
  for pc in "$overlay"/*.pc; do
    [[ -f $pc ]] || continue
    grep -q '^sdkdir=' "$pc" && rewrite_pc_var "$pc" sdkdir "$SERVER_STAGE$XORG_SDKDIR"
  done
  SERVER_OVERLAY=$overlay
}

build_server() {
  local pcin comp=$COMP_ROOT/xserver builddir
  SREF=$(server_ref)
  log "building xserver $SREF"
  clone_ref "$GH/xserver.git" "$SRC/xserver" "$SREF"
  SSHA=$(as_build git -C "$SRC/xserver" rev-parse HEAD)

  if [[ $S_XP -eq 1 ]] || ! proto_requirements_ok; then
    build_xp
  fi

  for pcin in xlibre-server.pc.in xorg-server.pc.in; do
    [[ -f $SRC/xserver/$pcin ]] || continue
    as_build sed -i \
      -e 's#^input_drivers_dir=@moduledir@/drivers/input$#input_drivers_dir=@moduledir@/input#' \
      -e 's#^video_drivers_dir=@moduledir@/drivers/video$#video_drivers_dir=@moduledir@/drivers#' \
      "$SRC/xserver/$pcin"
  done

  reset_build_dir "$comp"
  builddir=$SRC/xserver/build
  as_build rm -rf "$builddir"
  if ! server_setup; then
    if [[ $XP -eq 0 ]]; then
      warn "initial xserver configure failed; retrying once with current xorgproto"
      build_xp
      as_build rm -rf "$builddir"
      server_setup
    else
      die "xserver meson configuration failed"
    fi
  fi
  as_build_in "$SRC/xserver" ninja -C build -j "$JOBS"
  as_build_in "$SRC/xserver" env "DESTDIR=$comp" ninja -C build install
  SERVER_STAGE=$comp
  prepare_server_overlay
  merge_component "$comp"

  if [[ -n ${PROTO_OVERLAY:-} ]]; then
    export PKG_CONFIG_PATH="$SERVER_OVERLAY:$PROTO_OVERLAY:$BASE_PKG_CONFIG_PATH"
  else
    export PKG_CONFIG_PATH="$SERVER_OVERLAY:$BASE_PKG_CONFIG_PATH"
  fi
}

DRIVER_MODULES_FILE=$TMPROOT/driver-modules.new
NEW_DRIVERS_FILE=$TMPROOT/drivers.new
: > "$DRIVER_MODULES_FILE"
: > "$NEW_DRIVERS_FILE"

meson_has_option() {
  local dir=$1 opt=$2
  grep -RqsE "option\(['\"]$opt['\"]" "$dir/meson_options.txt" "$dir/meson.options" 2>/dev/null
}

normalize_driver_modules() {
  local name=$1 comp=$2 kind desired f base found=0
  case $name in
    xf86-input-*) kind=input; desired=$comp$XORG_MODULEDIR/input ;;
    xf86-video-*) kind=video; desired=$comp$XORG_MODULEDIR/drivers ;;
    *) kind=other; desired='' ;;
  esac
  [[ -n $desired ]] || return 0
  as_build mkdir -p "$desired"
  while IFS= read -r -d '' f; do
    found=1
    base=$(basename "$f")
    if [[ $(dirname "$f") != "$desired" ]]; then
      as_build mv -f -- "$f" "$desired/$base"
    fi
    printf '%s\t%s\n' "$name" "${desired#"$comp"}/$base" >> "$DRIVER_MODULES_FILE"
  done < <(find "$comp" \( -type f -o -type l \) -name '*_drv.so*' -print0)
  [[ $found -eq 1 ]] || die "driver $name installed no *_drv.so module"
}

build_driver() {
  local name=$1 dir=$SRC/$1 comp=$COMP_ROOT/$1 stage sha relmod opt
  clone_ref "$GH/$name.git" "$dir" HEAD
  reset_build_dir "$comp"

  if [[ -f $dir/meson.build ]]; then
    local args=(--prefix "$PREFIX" --buildtype "$BUILDTYPE")
    if [[ $XORG_MODULEDIR == "$XORG_LIBDIR"/* ]]; then
      relmod=${XORG_MODULEDIR#"$XORG_LIBDIR"/}
    else
      relmod=$XORG_MODULEDIR
    fi
    if meson_has_option "$dir" moduledir; then
      args+=("-Dmoduledir=$relmod")
    fi
    if meson_has_option "$dir" xorg-module-dir; then
      case $name in
        xf86-input-*) args+=("-Dxorg-module-dir=$XORG_MODULEDIR/input") ;;
        xf86-video-*) args+=("-Dxorg-module-dir=$XORG_MODULEDIR/drivers") ;;
        *) args+=("-Dxorg-module-dir=$XORG_MODULEDIR") ;;
      esac
    fi
    as_build rm -rf "$dir/build"
    as_build_in "$dir" meson setup build "${args[@]}"
    as_build_in "$dir" ninja -C build -j "$JOBS"
    as_build_in "$dir" env "DESTDIR=$comp" ninja -C build install
  elif [[ -f $dir/autogen.sh || -f $dir/configure.ac ]]; then
    if [[ -f $dir/autogen.sh ]]; then
      as_build_in "$dir" env NOCONFIGURE=1 ./autogen.sh
    else
      as_build_in "$dir" autoreconf -fi
    fi
    as_build_in "$dir" ./configure --prefix="$PREFIX"
    as_build_in "$dir" make -j "$JOBS"
    as_build_in "$dir" make "DESTDIR=$comp" install
  else
    die "unsupported build system for driver $name"
  fi

  normalize_driver_modules "$name" "$comp"
  merge_component "$comp"
  sha=$(as_build git -C "$dir" rev-parse HEAD)
  printf '%s %s ok\n' "$name" "$sha" >> "$NEW_DRIVERS_FILE"
}

stage_libinput_fallback() {
  local dst=/etc/X11/xorg.conf.d/40-libinput.conf src=/usr/share/X11/xorg.conf.d/40-libinput.conf
  [[ " $DRIVERS " == *" xf86-input-libinput "* ]] || return 0
  if find "$STAGE_ROOT$PREFIX" -type f -iname '*libinput*.conf' -print -quit 2>/dev/null | grep -q .; then return 0; fi

  if current_manifest | grep -qxF -- "$dst"; then
    as_build install -d -m 0755 "$STAGE_ROOT/etc/X11/xorg.conf.d"
    if [[ -f $src ]]; then
      as_build install -m 0644 "$src" "$STAGE_ROOT$dst"
    elif [[ -f $dst && ! -L $dst ]]; then
      as_build install -m 0644 "$dst" "$STAGE_ROOT$dst"
    else
      die "managed libinput fallback disappeared and no replacement is available"
    fi
    return 0
  fi

  if find /etc/X11 -type f -iname '*libinput*.conf' -print -quit 2>/dev/null | grep -q .; then return 0; fi
  if [[ -f $src ]]; then
    as_build install -d -m 0755 "$STAGE_ROOT/etc/X11/xorg.conf.d"
    as_build install -m 0644 "$src" "$STAGE_ROOT$dst"
  fi
}

verify_stage() {
  local xb=$STAGE_ROOT$PREFIX/bin/Xorg xv p
  [[ -x $xb ]] || xb=$STAGE_ROOT$PREFIX/bin/X
  [[ -x $xb ]] || die "staged Xorg not found under $PREFIX/bin"
  xv=$(as_build "$xb" -version 2>&1 || true)
  grep -qi xlibre <<< "$xv" || die "staged Xorg does not identify as XLibre"
  while IFS=$'\t' read -r _ p; do
    [[ -e $STAGE_ROOT$p || -L $STAGE_ROOT$p ]] || die "staged driver module missing: $p"
  done < "$DRIVER_MODULES_FILE"
}

verify_live() {
  local xb=$PREFIX/bin/Xorg xv p
  [[ -x $xb ]] || xb=$PREFIX/bin/X
  [[ -x $xb ]] || die "Xorg not found under $PREFIX/bin after deployment"
  xv=$(as_build "$xb" -version 2>&1 || true)
  grep -qi xlibre <<< "$xv" || die "installed Xorg is not XLibre"
  while IFS=$'\t' read -r _ p; do
    [[ -e $p || -L $p ]] || die "installed driver module missing: $p"
  done < "$DRIVER_MODULES_FILE"
  libs_broken_prefix "$PREFIX" && die "installed binaries have unresolved libraries"
  log "check: $xb -version"
  printf '%s\n' "$xv" | sed 's/^/  /'
}

build_server
for d in $DRIVERS; do
  log "building driver $d"
  build_driver "$d"
done
stage_libinput_fallback
verify_stage
freeze_stage

NEW_MANIFEST=$TMPROOT/new-manifest.list
stage_manifest "$STAGE_ROOT" "$NEW_MANIFEST"
[[ -s $NEW_MANIFEST ]] || die "staged manifest is empty"
preflight_stage_manifest "$NEW_MANIFEST"

apply_staged_transaction
install_self || warn "could not refresh $SELF"

log "installed XLibre $SREF in $PREFIX"
log "backups: $ST/backups (last 3 kept)"

if [[ -t 0 ]]; then
  set_default || true
fi
note

if [[ $AUTO -eq 1 ]]; then auto_on; fi
[[ $HAVE -eq 1 ]] && warn "restart the X session to use the new version"
exit 0
