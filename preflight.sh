#!/usr/bin/env bash
# preflight.sh - check whether the static nginx binary can replace the nginx on this host,
# and optionally replace it.
#
# Without --upgrade/--rollback nothing is replaced, restarted or reloaded. Side effects:
# `nginx -t` (as any config test) may create missing log files and temp directories the
# config points to. The tarball and the extracted binary stay in --dir (not cleaned up).
#
# Usage: sudo ./preflight.sh [options]
#   --url URL        tarball to download (default: $DEFAULT_URL)
#   --dir DIR        where the tarball is downloaded and extracted (default: /tmp/static-nginx)
#   --binary PATH    use a local nginx binary instead of downloading
#   --sha256 HASH    expected tarball sha256 (default: pinned hash below); '' disables
#   --old PATH       current nginx binary (default: autodetect)
#   --conf PATH      nginx.conf to test (default: autodetect)
#   --unit NAME      systemd unit (default: nginx.service)
#   --keep PATH      after a successful check, copy the verified new binary to PATH
#   --upgrade        if there are no blockers: install to /usr/local/sbin/nginx, point the
#                    unit at it with a drop-in, restart nginx; auto-rollback if it fails
#   --rollback       remove the drop-in, restart nginx on the original binary, move the
#                    installed binary to /usr/local/sbin/nginx.rolled-back
#
# Exit codes: 0 GO, 1 GO with warnings (review them), 2 NO-GO (blockers), 3 script error,
# 4 upgrade failed (rolled back).

set -u
umask 077

DEFAULT_URL="https://github.com/vvrein/static-nginx/releases/download/v0.0.3/nginx-linux-amd64.tar.xz"
# nginx 1.31.9 / OpenSSL 4.1.0 build, commit a3b281f
DEFAULT_TAR_SHA256="a00026b849fb37cb80bb69d70cd5f6fbb16ca8a3ab5440d4d72b6ca4c8a410de"
NEW_BIN_SHA256="521ef78efee7356b987013c84a34f33ed251797a060da5232aa360228562cba7"

URL=$DEFAULT_URL
TAR_SHA256=$DEFAULT_TAR_SHA256
NEW_ARG="" OLD="" CONF="" KEEP="" UPGRADE=0 ROLLBACK=0
DL_DIR=/tmp/static-nginx
UNIT=nginx.service
NEW_SBIN=/usr/local/sbin/nginx

while [ $# -gt 0 ]; do
    case $1 in
        --url) URL=$2; shift 2 ;;
        --binary) NEW_ARG=$2; shift 2 ;;
        --sha256) TAR_SHA256=$2; shift 2 ;;
        --old) OLD=$2; shift 2 ;;
        --conf) CONF=$2; shift 2 ;;
        --keep) KEEP=$2; shift 2 ;;
        --dir) DL_DIR=${2%/}; shift 2 ;;
        --unit) UNIT=$2; shift 2 ;;
        --upgrade) UPGRADE=1; shift ;;
        --rollback) ROLLBACK=1; shift ;;
        -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 3 ;;
    esac
done

# ---------------------------------------------------------------- output
if [ -t 1 ]; then R=$'\e[31m' Y=$'\e[33m' G=$'\e[32m' B=$'\e[1m' N=$'\e[0m'; else R="" Y="" G="" B="" N=""; fi
NBLOCK=0 NWARN=0
section() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
ok()      { printf '  %s[ OK  ]%s %s\n' "$G" "$N" "$*"; }
info()    { printf '  [INFO ] %s\n' "$*"; }
warn()    { printf '  %s[WARN ]%s %s\n' "$Y" "$N" "$*"; NWARN=$((NWARN+1)); }
block()   { printf '  %s[BLOCK]%s %s\n' "$R" "$N" "$*"; NBLOCK=$((NBLOCK+1)); }
detail()  { sed 's/^/            /'; }
die()     { printf '%sERROR:%s %s\n' "$R" "$N" "$*" >&2; exit 3; }

# ---------------------------------------------------------------- helpers
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }
is_patched() {  # fixed in 1.30.7 (stable) and 1.31.9 (mainline)
    case $1 in
        1.30.*) ver_ge "$1" 1.30.7 ;;
        *) ver_ge "$1" 1.31.9 ;;
    esac
}
# value of a configure option from `nginx -V` output
cfgopt() { printf '%s\n' "$1" | grep -oE -- "--$2=[^ ]+" | head -n1 | cut -d= -f2- | tr -d "'\""; }
# make a path absolute against a prefix
abspath() { case $2 in /*) printf '%s' "$2" ;; *) printf '%s/%s' "${1%/}" "$2" ;; esac; }
sed_esc() { printf '%s' "$1" | sed 's/[][\.*^$/#&]/\\&/g'; }
# first value of a directive anywhere in the stripped config dump
directive_val() { grep -oE "(^|[;{[:space:]])$1[[:space:]]+[^;]+" "$DUMP" | head -n1 | sed -E "s/^.*$1[[:space:]]+//; s/[[:space:]]+\$//"; }
has_directive() { grep -qE "(^|[;{[:space:]])$1([[:space:]]|;)" "$DUMP"; }
build_defaults() {  # $1 = nginx -V output; prints key=value lines with effective compiled defaults
    local v=$1 p
    p=$(cfgopt "$v" prefix); p=${p:-/usr/local/nginx}
    local x
    printf 'prefix=%s\n' "$p"
    x=$(cfgopt "$v" pid-path);       printf 'pid=%s\n' "$(abspath "$p" "${x:-logs/nginx.pid}")"
    x=$(cfgopt "$v" error-log-path); [ "$x" = stderr ] || x=$(abspath "$p" "${x:-logs/error.log}"); printf 'error_log=%s\n' "$x"
    x=$(cfgopt "$v" user);           printf 'user=%s\n' "${x:-nobody}"
    x=$(cfgopt "$v" http-client-body-temp-path); printf 'client_body_temp_path=%s\n' "$(abspath "$p" "${x:-client_body_temp}")"
    x=$(cfgopt "$v" http-proxy-temp-path);       printf 'proxy_temp_path=%s\n'       "$(abspath "$p" "${x:-proxy_temp}")"
    x=$(cfgopt "$v" http-fastcgi-temp-path);     printf 'fastcgi_temp_path=%s\n'     "$(abspath "$p" "${x:-fastcgi_temp}")"
    x=$(cfgopt "$v" http-uwsgi-temp-path);       printf 'uwsgi_temp_path=%s\n'       "$(abspath "$p" "${x:-uwsgi_temp}")"
    x=$(cfgopt "$v" http-scgi-temp-path);        printf 'scgi_temp_path=%s\n'        "$(abspath "$p" "${x:-scgi_temp}")"
}
bdef() { printf '%s\n' "$1" | grep "^$2=" | head -n1 | cut -d= -f2-; }

# ---------------------------------------------------------------- systemd helpers
[ $UPGRADE -eq 1 ] && [ $ROLLBACK -eq 1 ] && { echo "--upgrade and --rollback are mutually exclusive" >&2; exit 3; }
DROPIN_DIR=/etc/systemd/system/$UNIT.d
DROPIN=$DROPIN_DIR/static-nginx.conf
have_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null; }
main_exe() { local p; p=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null); [ "${p:-0}" -gt 0 ] && readlink "/proc/$p/exe"; }
wait_active() {  # up to 15s for the unit to become active with a running main process
    for _ in $(seq 15); do
        systemctl is-active -q "$UNIT" && [ -n "$(main_exe)" ] && return 0
        systemctl is-failed -q "$UNIT" && return 1
        sleep 1
    done
    return 1
}
restart_unit() { systemctl daemon-reload && systemctl restart "$UNIT" && wait_active; }

# ---------------------------------------------------------------- environment
[ "$(id -u)" -eq 0 ] || die "run as root: the config test must read certificates and resolve the worker user like the real nginx does"

if [ $ROLLBACK -eq 1 ]; then
    have_systemd || die "systemd is not running"
    [ -f "$DROPIN" ] || die "$DROPIN not found: nothing to roll back"
    was_active=0; systemctl is-active -q "$UNIT" && was_active=1
    rm -f "$DROPIN"; rmdir "$DROPIN_DIR" 2>/dev/null
    echo "removed $DROPIN"
    [ -f "$NEW_SBIN" ] && mv -f "$NEW_SBIN" "$NEW_SBIN.rolled-back" && echo "moved $NEW_SBIN to $NEW_SBIN.rolled-back"
    systemctl daemon-reload
    if [ $was_active -eq 1 ]; then
        if restart_unit; then echo "$UNIT restarted, running $(main_exe)"; exit 0
        else echo "ERROR: $UNIT failed to restart on the original binary, check: journalctl -u $UNIT" >&2; exit 4; fi
    fi
    echo "$UNIT was not running, not started"; exit 0
fi
for t in tar sha256sum grep sed awk sort; do command -v $t >/dev/null || die "missing tool: $t"; done

# pick a work dir where binaries can be executed (/tmp is often noexec)
W=""
for base in "${TMPDIR:-/tmp}" /var/tmp /root; do
    d=$(mktemp -d "$base/nginx-preflight.XXXXXX" 2>/dev/null) || continue
    printf '#!/bin/sh\nexit 0\n' > "$d/x" && chmod 700 "$d/x"
    if "$d/x" 2>/dev/null; then W=$d; rm -f "$d/x"; break; fi
    rm -rf "$d"
done
[ -n "$W" ] || die "no writable directory allows executing binaries (tried \$TMPDIR, /tmp, /var/tmp, /root)"
trap 'rm -rf "$W"' EXIT

printf '%snginx swap preflight%s  host=%s  %s\n' "$B" "$N" "$(hostname 2>/dev/null)" "$(date -u +%FT%TZ)"

# ---------------------------------------------------------------- new binary
section "New binary"
arch=$(uname -m)
[ "$arch" = x86_64 ] && ok "architecture $arch" || block "architecture is $arch, the binary is built for x86_64"

if [ -n "$NEW_ARG" ]; then
    [ -f "$NEW_ARG" ] || die "--binary $NEW_ARG: not a file"
    cp "$NEW_ARG" "$W/nginx-new" && chmod 700 "$W/nginx-new"
    info "using local binary $NEW_ARG"
else
    # the download dir usually lives in world-writable /tmp: refuse one another user could control
    if [ -L "$DL_DIR" ]; then die "$DL_DIR is a symlink, refusing to use it"
    elif [ -e "$DL_DIR" ]; then
        [ -d "$DL_DIR" ] || die "$DL_DIR exists and is not a directory"
        read -r o m <<<"$(stat -c '%u %a' "$DL_DIR")"
        [ "$o" = 0 ] && [ $(( 8#$m & 8#022 )) -eq 0 ] || die "$DL_DIR must be owned by root and not group/world-writable (is uid $o, mode $m)"
    else
        mkdir -m 755 "$DL_DIR" || die "cannot create $DL_DIR"
    fi
    TARBALL=$DL_DIR/${URL##*/}
    if [ -n "$TAR_SHA256" ] && [ -f "$TARBALL" ] && [ "$(sha256sum "$TARBALL" | cut -d' ' -f1)" = "$TAR_SHA256" ]; then
        ok "reusing $TARBALL, sha256 verified"
    else
        rm -f "$TARBALL.part"
        if command -v curl >/dev/null; then curl -fsSL --proto '=https' --tlsv1.2 -o "$TARBALL.part" "$URL" || die "download failed: $URL"
        elif command -v wget >/dev/null; then wget -q -O "$TARBALL.part" "$URL" || die "download failed: $URL"
        else die "need curl or wget to download $URL"; fi
        if [ -n "$TAR_SHA256" ]; then
            got=$(sha256sum "$TARBALL.part" | cut -d' ' -f1)
            [ "$got" = "$TAR_SHA256" ] || die "tarball sha256 mismatch: got $got, expected $TAR_SHA256 (kept as $TARBALL.part)"
            ok "downloaded $URL to $TARBALL, sha256 verified"
        else
            warn "downloaded $URL to $TARBALL WITHOUT checksum verification"
        fi
        mv -f "$TARBALL.part" "$TARBALL"
    fi
    rm -f "$DL_DIR/nginx"
    tar --no-same-owner --no-same-permissions -xJf "$TARBALL" -C "$DL_DIR" nginx 2>/dev/null \
        || die "cannot extract nginx from $TARBALL (is xz installed?)"
    chmod 755 "$DL_DIR/nginx"
    # run it from the private work dir: /tmp is often mounted noexec
    cp "$DL_DIR/nginx" "$W/nginx-new" && chmod 700 "$W/nginx-new"
fi
NEW=$W/nginx-new
got=$(sha256sum "$NEW" | cut -d' ' -f1)
if [ "$got" = "$NEW_BIN_SHA256" ]; then ok "binary sha256 matches the pinned build"
else info "binary sha256 $got differs from the pinned build (expected if you built a newer one)"; fi

NEW_V=$("$NEW" -V 2>&1) || { block "new binary does not execute:"; printf '%s\n' "$NEW_V" | detail; }
NEW_VER=$(printf '%s\n' "$NEW_V" | sed -nE 's|^nginx version: [^/]+/([0-9.]+).*|\1|p')
if [ -n "$NEW_VER" ] && is_patched "$NEW_VER"; then ok "new version $NEW_VER includes the NGINX2Root fixes"
else block "new version '${NEW_VER:-unknown}' is NOT a fixed release (need >= 1.30.7 / 1.31.9)"; fi
NEW_DEF=$(build_defaults "$NEW_V")

# ---------------------------------------------------------------- current nginx
section "Current nginx"
MASTER=""
for d in /proc/[0-9]*; do
    case $(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) in "nginx: master process"*) MASTER=${d#/proc/}; break ;; esac
done
MASTER_CMD=""
if [ -n "$MASTER" ]; then
    MASTER_CMD=$(tr '\0' ' ' < "/proc/$MASTER/cmdline" 2>/dev/null)
    exe=$(readlink "/proc/$MASTER/exe" 2>/dev/null || true)
    info "running master pid $MASTER: $MASTER_CMD"
    case $exe in *" (deleted)") warn "running master's binary was replaced or deleted since start: $exe" ;; esac
    [ -z "$OLD" ] && [ -n "$exe" ] && OLD=${exe% (deleted)}
else
    info "no running nginx master found"
fi
[ -z "$OLD" ] && OLD=$(command -v nginx 2>/dev/null || true)
[ -z "$OLD" ] && [ -x /usr/sbin/nginx ] && OLD=/usr/sbin/nginx

OLD_V="" OLD_DEF=""
if [ -n "$OLD" ] && [ -x "$OLD" ]; then
    OLD_V=$("$OLD" -V 2>&1)
    OLD_VER=$(printf '%s\n' "$OLD_V" | sed -nE 's|^nginx version: [^/]+/([0-9.]+).*|\1|p')
    info "current binary $OLD, version ${OLD_VER:-unknown}"
    printf '%s\n' "$OLD_V" | grep -q 'nginx version: openresty\|nginx version: tengine\|nginx version: angie' \
        && warn "current binary is a fork ($(printf '%s\n' "$OLD_V" | head -n1)), not vanilla nginx: expect missing modules"
    if [ -n "$OLD_VER" ] && is_patched "$OLD_VER"; then
        info "current version $OLD_VER is already a fixed upstream release: the swap may not be needed"
    else
        pkg=""
        command -v dpkg-query >/dev/null && pkg=$(dpkg -S "$OLD" 2>/dev/null | cut -d: -f1 | head -n1)
        [ -n "$pkg" ] && pkg="$pkg $(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
        [ -z "$pkg" ] && command -v rpm >/dev/null && pkg=$(rpm -qf "$OLD" 2>/dev/null | grep -v 'not owned' || true)
        [ -z "$pkg" ] && command -v apk >/dev/null && pkg=$(apk info --who-owns "$OLD" 2>/dev/null | sed 's/.* owned by //')
        info "current version is in the affected range${pkg:+ (package: $pkg - check whether your distro backported the fix)}"
    fi
    OLD_DEF=$(build_defaults "$OLD_V")
else
    warn "current nginx binary not found (use --old); comparisons with the old build are skipped"
fi

if [ -z "$CONF" ]; then
    CONF=$(printf '%s\n' "$MASTER_CMD" | grep -oE -- '-c [^ ]+' | head -n1 | cut -c4-)
    [ -z "$CONF" ] && [ -n "$OLD_V" ] && CONF=$(abspath "$(bdef "$OLD_DEF" prefix)" "$(cfgopt "$OLD_V" conf-path)")
    [ -f "${CONF:-/nonexistent}" ] || CONF=/etc/nginx/nginx.conf
fi
[ -f "$CONF" ] || die "config $CONF not found (use --conf)"
CONFDIR=$(cd "$(dirname "$CONF")" && pwd)
info "config $CONF"

# prefix the old binary ran with: -p from the command line, else its compiled prefix
OLD_PREFIX=$(printf '%s\n' "$MASTER_CMD" | grep -oE -- '-p [^ ]+' | head -n1 | cut -c4-)
[ -z "$OLD_PREFIX" ] && [ -n "$OLD_DEF" ] && OLD_PREFIX=$(bdef "$OLD_DEF" prefix)
NEW_PREFIX=$(bdef "$NEW_DEF" prefix)
TEST_PREFIX=${OLD_PREFIX:-$NEW_PREFIX}

# ---------------------------------------------------------------- full config dump
DUMP=$W/dump.conf RAWDUMP=$W/dump.raw
if [ -n "$OLD_V" ] && "$OLD" -T -q -c "$CONF" > "$RAWDUMP" 2>"$W/oldt.err"; then
    :
else
    [ -n "$OLD_V" ] && { warn "current binary fails its own config test, results below may be incomplete:"; detail < "$W/oldt.err"; }
    : > "$RAWDUMP"
fi
if [ ! -s "$RAWDUMP" ]; then
    # no usable dump: fall back to the raw files under the config dir
    warn "config could not be dumped with 'nginx -T'; checks below read the raw files under $CONFDIR and may be approximate"
    { printf '# configuration file %s:\n' "$CONF"; cat "$CONF"
      find -L "$CONFDIR" -type f ! -path "$CONF" \( -name '*.conf' -o -path '*-enabled/*' -o -path '*/conf.d/*' \) \
          -exec sh -c 'for f; do printf "# configuration file %s:\n" "$f"; cat "$f"; done' sh {} +; } > "$RAWDUMP" 2>/dev/null
    for inc in $(sed -e 's/#.*$//' "$RAWDUMP" | grep -oE '(^|[[:space:]])include[[:space:]]+/[^;]+' | sed -E 's/.*include[[:space:]]+//; s/["'"'"']//g' | sort -u); do
        case $inc in "$CONFDIR"/*) continue ;; esac
        for f in $inc; do [ -f "$f" ] && { printf '# configuration file %s:\n' "$f"; cat "$f"; } >> "$RAWDUMP"; done
    done
fi
sed -e 's/#.*$//' "$RAWDUMP" > "$DUMP"

# ---------------------------------------------------------------- dynamic modules
section "Modules"
grep -oE '(^|[;{[:space:]])load_module[[:space:]]+[^;]+' "$DUMP" | sed -E 's/.*load_module[[:space:]]+//' | sort -u > "$W/loadmods"
if [ -s "$W/loadmods" ]; then
    block "config loads dynamic modules; the static binary cannot load .so files. Remove these load_module lines (or the include that pulls them in):"
    detail < "$W/loadmods"
    info "the config test below runs a second time with them removed, to see whether the built-in modules cover the config"
else
    ok "no load_module directives"
fi
if [ -n "$OLD_V" ]; then
    mods() { printf '%s\n' "$1" | grep -oE -- '--with-[a-z0-9_]+_module' | sed 's/--with-//' | sort -u; }
    missing=$(comm -23 <(mods "$OLD_V") <(mods "$NEW_V"))
    [ -n "$missing" ] && { info "built in the old binary but not the new one (only a problem if the config uses them - the config test catches that):"; printf '%s\n' "$missing" | detail; }
    third=$(printf '%s\n' "$OLD_V" | grep -oE -- '--add-(dynamic-)?module=[^ ]+' | sed -E 's|.*/||' | sort -u)
    [ -n "$third" ] && { info "third-party modules in the old build (new has: nginx-acme, njs, vts, echo, headers-more):"; printf '%s\n' "$third" | detail; }
fi

# ---------------------------------------------------------------- config test
section "Config test with the new binary"
test_hints() {  # explain common failures of the new binary
    printf '%s\n' "$1" | grep -q 'unknown directive' && info "an 'unknown directive' means the config uses a module this build does not include"
    printf '%s\n' "$1" | grep -qE 'getpwnam|getgrnam' && info "the static (musl) binary reads users/groups only from /etc/passwd and /etc/group, not LDAP/sssd/nss"
    printf '%s\n' "$1" | grep -qE 'mkdir\(\) "[^"]*" failed' && info "a compiled-in temp path's parent directory is missing: create it, or set *_temp_path in the config to the old paths (see the defaults section below)"
    printf '%s\n' "$1" | grep -q 'host not found' && info "the static (musl) binary resolves names only via /etc/hosts and /etc/resolv.conf, not nsswitch/systemd-resolved stubs"
    return 0
}
run_test() { "$NEW" -t -q -c "$1" -p "$TEST_PREFIX" -e stderr 2>&1; }
T_OUT=$(run_test "$CONF"); T_RC=$?
if [ $T_RC -eq 0 ]; then
    ok "nginx -t passes on $CONF (prefix $TEST_PREFIX)"
    [ -n "$T_OUT" ] && printf '%s\n' "$T_OUT" | detail
else
    if [ ! -s "$W/loadmods" ] && printf '%s\n' "$T_OUT" | grep -q 'dlopen()'; then
        block "config loads dynamic modules (found by the config test); the static binary cannot load .so files:"
        printf '%s\n' "$T_OUT" | grep 'dlopen()' | detail
        echo dlopen > "$W/loadmods"
    fi
    if [ -s "$W/loadmods" ]; then
        # sanitized copy: config dir copied, load_module lines removed, absolute includes into
        # the config dir pointed at the copy, external includes containing load_module dropped
        # -L: dereference symlinks (Debian modules-enabled/*.conf are symlinks), so edits hit copies
        cp -rL "$CONFDIR" "$W/conf" 2>/dev/null
        SAN_CONF=$W/conf/$(basename "$CONF")
        ce=$(sed_esc "$CONFDIR/") we=$(sed_esc "$W/conf/")
        find "$W/conf" -type f -exec sed -E -i \
            -e 's/^([[:space:]]*)(load_module[[:space:]])/\1# preflight-removed \2/' \
            -e "s/(include[[:space:]]+[\"']?)$ce/\\1$we/" {} +
        grep -rhoE '(^|[[:space:]])include[[:space:]]+[^;]+;' "$W/conf" | sed -E 's/.*include[[:space:]]+//; s/;$//; s/["'"'"']//g' | sort -u |
        while read -r inc; do
            case $inc in /*) ;; *) continue ;; esac
            case $inc in "$W"/*) continue ;; esac
            for f in $inc; do
                [ -f "$f" ] && grep -qE '^[[:space:]]*load_module' "$f" || continue
                find "$W/conf" -type f | while read -r cf; do
                    awk -v s="$inc" '{ if (index($0, "include") && index($0, s)) print "# preflight-removed " $0; else print }' \
                        "$cf" > "$cf.pf" && cat "$cf.pf" > "$cf" && rm -f "$cf.pf"
                done
                break
            done
        done
        S_OUT=$(run_test "$SAN_CONF"); S_RC=$?
        S_OUT=$(printf '%s\n' "$S_OUT" | sed "s#$W/conf#$CONFDIR#g")
        if [ $S_RC -eq 0 ]; then
            ok "with load_module removed, nginx -t passes: the built-in modules cover this config (fix the BLOCK above and it is good to go)"
        else
            block "nginx -t fails even with load_module removed:"
            printf '%s\n' "$S_OUT" | detail
            test_hints "$S_OUT"
        fi
    else
        block "nginx -t fails:"
        printf '%s\n' "$T_OUT" | detail
        test_hints "$T_OUT"
    fi
fi

# ---------------------------------------------------------------- compiled defaults
section "Compiled-in defaults the config does not override"
if [ "$OLD_PREFIX" != "" ] && [ "$OLD_PREFIX" != "$NEW_PREFIX" ]; then
    warn "prefix differs: old $OLD_PREFIX, new $NEW_PREFIX. Relative paths in the config resolve against it; start the new binary with '-p $OLD_PREFIX'"
else
    ok "prefix $NEW_PREFIX"
fi
# main-context directives of the top-level file (for error_log, which is valid in many contexts)
MAIN_DIRS=$(awk -v f="$CONF" '
    /^# configuration file / { cur = $4; sub(/:$/, "", cur); next }
    cur == f { sub(/#.*/, ""); n = split($0, c, ""); for (i = 1; i <= n; i++) {
        ch = c[i]; if (ch == "{") { d++; w = "" } else if (ch == "}") { d--; w = "" }
        else if (ch ~ /[[:space:];]/) { if (w != "" && d == 0 && !seen) { print w; seen = 1 } if (ch == ";") seen = 0; w = "" }
        else w = w ch } }' "$RAWDUMP" | sort -u)

EFF_PID=$(directive_val pid)
if [ -n "$EFF_PID" ]; then EFF_PID=$(abspath "$TEST_PREFIX" "$EFF_PID"); ok "pid file set in config: $EFF_PID"
else
    EFF_PID=$(bdef "$NEW_DEF" pid)
    if [ -n "$OLD_DEF" ] && [ "$(bdef "$OLD_DEF" pid)" != "$EFF_PID" ]; then
        warn "no 'pid' directive: pid file moves from $(bdef "$OLD_DEF" pid) to $EFF_PID (add 'pid $(bdef "$OLD_DEF" pid);' to keep it)"
    else ok "pid file $EFF_PID"; fi
fi
if has_directive user; then ok "worker user set in config: $(directive_val user)"
elif [ -n "$OLD_DEF" ] && [ "$(bdef "$OLD_DEF" user)" != nobody ]; then
    warn "no 'user' directive: workers would run as 'nobody' instead of '$(bdef "$OLD_DEF" user)' (add 'user $(bdef "$OLD_DEF" user);')"
else ok "worker user nobody (unchanged)"; fi
if printf '%s\n' "$MAIN_DIRS" | grep -qx error_log; then ok "main error_log set in config"
elif [ -n "$OLD_DEF" ] && [ "$(bdef "$OLD_DEF" error_log)" != "$(bdef "$NEW_DEF" error_log)" ]; then
    warn "no top-level 'error_log': the new binary logs to $(bdef "$NEW_DEF" error_log) (journald under systemd) instead of $(bdef "$OLD_DEF" error_log)"
else ok "default error log $(bdef "$NEW_DEF" error_log) (unchanged)"; fi
if [ -n "$OLD_DEF" ]; then
    for tp in client_body_temp_path proxy_temp_path fastcgi_temp_path uwsgi_temp_path scgi_temp_path; do
        has_directive $tp && continue
        o=$(bdef "$OLD_DEF" $tp) n=$(bdef "$NEW_DEF" $tp)
        [ "$o" != "$n" ] && warn "$tp moves from $o to $n (owned by the worker user, check disk space there)"
    done
fi

# ---------------------------------------------------------------- TLS / OpenSSL 4.1
section "TLS (new binary uses OpenSSL 4.1)"
tls_issue=0
if grep -qE '(^|[;{[:space:]])ssl_engine[[:space:]]|ssl_certificate_key[[:space:]]+"?engine:' "$DUMP"; then
    block "config uses OpenSSL engines (ssl_engine / engine: keys); OpenSSL 4 has no ENGINE support"; tls_issue=1; fi
if grep -E '(^|[;{[:space:]])ssl_protocols[[:space:]]' "$DUMP" | grep -qE 'TLSv1([[:space:];]|$)|TLSv1\.1'; then
    warn "ssl_protocols enables TLSv1/TLSv1.1: OpenSSL 4.1 will not negotiate them at the default security level, old clients will fail"; tls_issue=1; fi
v=$(grep -oE '(proxy|grpc|uwsgi)_ssl_verify[[:space:]]+on|js_fetch_verify[[:space:]]+on' "$DUMP" | sort -u | tr '\n' ' ')
grep -qE '(^|[;{[:space:]])js_fetch_trusted_certificate[[:space:]]' "$DUMP" && v="$v js_fetch (verify on by default)"
if [ -n "$v" ]; then
    warn "upstream certificate verification in use ($v): upstream certs must carry a subjectAltName, OpenSSL 4.1 no longer matches the CN"; tls_issue=1; fi
if command -v openssl >/dev/null; then
    grep -oE '(^|[;{[:space:]])ssl_certificate[[:space:]]+[^;]+' "$DUMP" | sed -E 's/.*ssl_certificate[[:space:]]+//; s/["'"'"']//g' | sort -u |
    while read -r crt; do
        case $crt in *'$'*|data:*) continue ;; esac
        crt=$(abspath "$CONFDIR" "$crt")
        [ -r "$crt" ] || continue
        txt=$(openssl x509 -in "$crt" -noout -text 2>/dev/null) || continue
        printf '%s\n' "$txt" | grep -m1 'Signature Algorithm' | grep -qiE 'sha1|md5' && echo "W weak signature (SHA-1/MD5): $crt"
        bits=$(printf '%s\n' "$txt" | sed -nE 's/.*Public-Key: \(([0-9]+) bit\).*/\1/p' | head -n1)
        printf '%s\n' "$txt" | grep -q 'rsaEncryption' && [ -n "$bits" ] && [ "$bits" -lt 2048 ] && echo "W RSA key ${bits} bit (< 2048): $crt"
        openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1 || echo "I already expired: $crt"
    done > "$W/certs"
    while read -r lvl msg; do
        if [ "$lvl" = W ]; then warn "certificate rejected at the default security level: $msg"; tls_issue=1; else info "certificate $msg"; fi
    done < "$W/certs"
else
    info "no openssl CLI, certificate checks skipped"
fi
[ $tls_issue -eq 0 ] && ok "no TLS settings known to break with OpenSSL 4.1"

# ---------------------------------------------------------------- exposure / misc
section "Exposure (what this host was vulnerable to)"
exposed=0
grep -qE 'http2[[:space:]]+on|listen[^;]*[[:space:]]http2' "$DUMP" && { info "HTTP/2 enabled: exposed to CVE-2026-123007 / CVE-2026-123633 until swapped (stopgap: disable http2)"; exposed=1; }
grep -qE 'listen[^;]*[[:space:]]quic|http3[[:space:]]+on' "$DUMP" && { info "HTTP/3 enabled: exposed to CVE-2026-121810 until swapped"; exposed=1; }
grep -qE '(^|[;{[:space:]])resolver[[:space:]]' "$DUMP" && { info "resolver configured: exposed to CVE-2026-123634 until swapped"; exposed=1; }
grep -qE '(^|[;{[:space:]])mail[[:space:]]*\{' "$DUMP" && grep -qE 'auth_http[[:space:]]' "$DUMP" && { info "mail proxy with auth_http: exposed to CVE-2026-113425 until swapped"; exposed=1; }
[ $exposed -eq 0 ] && ok "no HTTP/2, HTTP/3, resolver or mail proxy found in config"
grep -qE '(^|[;{[:space:]])js_(import|include|path)[[:space:]]' "$DUMP" && warn "njs scripts in use: the njs version likely differs from the old build, exercise those handlers on a canary"

# ---------------------------------------------------------------- host integration
section "Host integration"
if [ -n "$OLD" ]; then
    owner=""
    command -v dpkg >/dev/null && owner=$(dpkg -S "$OLD" 2>/dev/null | cut -d: -f1 | head -n1)
    [ -z "$owner" ] && command -v rpm >/dev/null && owner=$(rpm -qf "$OLD" 2>/dev/null | grep -v 'not owned' || true)
    [ -z "$owner" ] && command -v apk >/dev/null && owner=$(apk info --who-owns "$OLD" 2>/dev/null | sed -n 's/.* owned by //p')
    [ -n "$owner" ] && info "$OLD belongs to package '$owner': overwriting it breaks package verification and the next update reverts it; prefer /usr/local/sbin/nginx + a service override (or dpkg-divert)"
fi
if command -v getenforce >/dev/null && [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
    ctx=$(ls -Z "$OLD" 2>/dev/null | awk '{print $1}')
    warn "SELinux enforcing: install the binary with 'install -m 755' and run 'restorecon' on it (current binary context: ${ctx:-unknown}), a copied file keeps a wrong label"
fi
if command -v systemctl >/dev/null && systemctl cat nginx.service >/dev/null 2>&1; then
    upid=$(systemctl show -p PIDFile --value nginx.service 2>/dev/null)
    uexec=$(systemctl show -p ExecStart --value nginx.service 2>/dev/null | sed -nE 's/.*path=([^ ;]+).*/\1/p' | head -n1)
    info "systemd unit nginx.service: ExecStart ${uexec:-?}, PIDFile ${upid:-none}"
    if [ -n "$upid" ] && [ "$upid" != "$EFF_PID" ] && [ "$(readlink -f "$upid" 2>/dev/null)" != "$(readlink -f "$EFF_PID" 2>/dev/null)" ]; then
        block "unit PIDFile=$upid but the new binary writes $EFF_PID: systemd will time out on start. Add 'pid $upid;' to nginx.conf"
    fi
    grep -qE -- "(^| )-p " <<<"$(systemctl show -p ExecStart --value nginx.service)" || \
        { [ -n "$OLD_PREFIX" ] && [ "$OLD_PREFIX" != "$NEW_PREFIX" ] && info "the unit has no '-p': add '-p $OLD_PREFIX' to ExecStart/ExecStartPre/ExecReload in a drop-in"; }
elif [ -f /etc/init.d/nginx ]; then
    info "init script /etc/init.d/nginx: check its pidfile matches $EFF_PID"
fi
for lr in /etc/logrotate.d/nginx*; do
    [ -f "$lr" ] || continue
    for p in $(grep -oE '/[^ )`"]+\.pid' "$lr" | sort -u); do
        [ "$p" = "$EFF_PID" ] || warn "$lr signals pid file $p, the new binary writes $EFF_PID: log reopen would break"
    done
done

section "Kernel SCTP (root escalation step of the chain, not fixed by the swap)"
if lsmod 2>/dev/null | grep -qw '^sctp'; then
    warn "sctp module is loaded; if nothing needs SCTP, blacklist it and reboot or 'rmmod sctp'"
elif modprobe -n -v sctp 2>/dev/null | grep -qE 'install /bin/(false|true)'; then
    ok "sctp module is blocked from loading"
elif modprobe -n sctp >/dev/null 2>&1; then
    warn "sctp module can be autoloaded: echo 'install sctp /bin/false' > /etc/modprobe.d/no-sctp.conf"
else
    ok "sctp module not available on this kernel"
fi

# ---------------------------------------------------------------- verdict
section "Verdict"
if [ $NBLOCK -gt 0 ]; then
    printf '  %sNO-GO%s: %d blocker(s), %d warning(s)\n' "$R" "$N" $NBLOCK $NWARN; rc=2
elif [ $NWARN -gt 0 ]; then
    printf '  %sGO WITH WARNINGS%s: %d warning(s), review them before swapping\n' "$Y" "$N" $NWARN; rc=1
else
    printf '  %sGO%s: no blockers or warnings\n' "$G" "$N"; rc=0
fi
if [ -n "$KEEP" ] && [ $rc -lt 2 ]; then
    install -m 755 "$NEW" "$KEEP" && printf '  verified new binary saved to %s\n' "$KEEP"
    command -v restorecon >/dev/null && restorecon "$KEEP" 2>/dev/null
elif [ -n "$KEEP" ]; then
    printf '  --keep ignored because of blockers\n'
fi
[ $UPGRADE -eq 1 ] || exit $rc

# ---------------------------------------------------------------- upgrade
section "Upgrade"
if [ $rc -ge 2 ]; then printf '  not upgrading: fix the blockers above first\n'; exit 2; fi
have_systemd || { printf '  not upgrading: systemd is not running (only systemd hosts are supported)\n'; exit 2; }
systemctl cat "$UNIT" >/dev/null 2>&1 || { printf '  not upgrading: unit %s not found (use --unit)\n' "$UNIT"; exit 2; }

# effective Exec* lines of the unit, without our own drop-in; an empty assignment resets a list
systemctl cat "$UNIT" 2>/dev/null | awk -v own="$DROPIN" '
    /^# \// { skip = (substr($0, 3) == own); next }
    skip { next }
    /^\[/ { sec = $0; next }
    sec == "[Service]" && /^(ExecStartPre|ExecStart|ExecStartPost|ExecReload|ExecStop|ExecStopPost)=/ {
        k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1)
        if (!(k in n)) order[++no] = k
        if (v == "") n[k] = 0; else val[k, ++n[k]] = v
    }
    END { for (i = 1; i <= no; i++) { k = order[i]; for (j = 1; j <= n[k]; j++) print k "\t" val[k, j] } }
' > "$W/execs"
execs_of() { awk -F'\t' -v k="$1" '$1 == k { print substr($0, length(k) + 2) }' "$W/execs"; }
ORIG_BIN=$(awk -F'\t' '$1 == "ExecStart" { sub(/^[-@:+!]+/, "", $2); split($2, a, " "); print a[1]; exit }' "$W/execs")
case $ORIG_BIN in
    */nginx) ;;
    *) printf '  not upgrading: cannot tell the nginx binary from the unit ExecStart (%s); write the drop-in by hand\n' "${ORIG_BIN:-none}"; exit 2 ;;
esac
grep -q '\\$' "$W/execs" && { printf '  not upgrading: the unit uses line continuations, write the drop-in by hand\n'; exit 2; }

# extra arguments so the new binary behaves like the old one
EXTRA=""
[ -n "$OLD_PREFIX" ] && [ "$OLD_PREFIX" != "$NEW_PREFIX" ] && EXTRA="$EXTRA -p $OLD_PREFIX"
[ "$CONF" != "$(cfgopt "$NEW_V" conf-path)" ] && EXTRA="$EXTRA -c $CONF"
ob=$(sed_esc "$ORIG_BIN")
{
    echo "# Generated by static-nginx preflight.sh on $(date -u +%FT%TZ): run $NEW_SBIN instead of $ORIG_BIN."
    echo "# Undo: preflight.sh --rollback (or delete this file, systemctl daemon-reload, systemctl restart $UNIT)"
    echo "[Service]"
    for k in $(cut -f1 "$W/execs" | awk '!s[$0]++'); do
        execs_of "$k" | grep -qE "(^|[-@:+!\ ])$ob( |\$)" || continue
        echo "$k="
        execs_of "$k" | while IFS= read -r v; do
            # add -p/-c only where the line does not set them already
            case " $v " in *" -p "*) ex=$(printf '%s' "$EXTRA" | sed -E 's/ -p [^ ]+//') ;; *) ex=$EXTRA ;; esac
            case " $v " in *" -c "*) ex=$(printf '%s' "$ex" | sed -E 's/ -c [^ ]+//') ;; esac
            printf '%s=%s\n' "$k" "$(printf '%s' "$v" | sed -E "s#(^|[-@:+! ])$ob( |\$)#\1$(sed_esc "$NEW_SBIN$ex")\2#g")"
        done
    done
} > "$W/dropin.conf"

if [ -f "$DROPIN" ] && [ -f "$NEW_SBIN" ] && cmp -s "$NEW" "$NEW_SBIN" \
    && diff -q <(grep -v '^# Generated' "$DROPIN") <(grep -v '^# Generated' "$W/dropin.conf") >/dev/null \
    && [ "$(main_exe)" = "$NEW_SBIN" ]; then
    ok "already upgraded: $UNIT runs $NEW_SBIN with this build, nothing to do"
    exit $rc
fi

info "drop-in $DROPIN:"
detail < "$W/dropin.conf"

# keep the previous state for an automatic rollback
had_bin=0 had_dropin=0
[ -f "$NEW_SBIN" ] && { cp -p "$NEW_SBIN" "$W/prev-bin"; had_bin=1; }
[ -f "$DROPIN" ] && { cp -p "$DROPIN" "$W/prev-dropin"; had_dropin=1; }
was_active=0; systemctl is-active -q "$UNIT" && was_active=1

install -d -m 755 "$(dirname "$NEW_SBIN")" "$DROPIN_DIR"
install -m 755 "$NEW" "$NEW_SBIN.new" && mv -f "$NEW_SBIN.new" "$NEW_SBIN" || die "cannot install $NEW_SBIN"
command -v restorecon >/dev/null && restorecon "$NEW_SBIN" 2>/dev/null
install -m 644 "$W/dropin.conf" "$DROPIN" || die "cannot write $DROPIN"
ok "installed $NEW_SBIN ($NEW_VER) and $DROPIN"

if [ $was_active -eq 0 ]; then
    systemctl daemon-reload
    info "$UNIT is not running: not started. It will use $NEW_SBIN on the next start"
    exit $rc
fi

info "restarting $UNIT (connections are dropped for about a second)"
if restart_unit && [ "$(main_exe)" = "$NEW_SBIN" ]; then
    ok "$UNIT is active, master runs $NEW_SBIN: $("$NEW_SBIN" -v 2>&1)"
    info "the original binary $ORIG_BIN is untouched; undo with: $0 --rollback"
    exit $rc
fi

printf '  %s[FAIL ]%s %s did not come up on %s, rolling back\n' "$R" "$N" "$UNIT" "$NEW_SBIN"
systemctl status --no-pager -n 20 "$UNIT" 2>&1 | detail
if [ $had_bin -eq 1 ]; then cp -p "$W/prev-bin" "$NEW_SBIN"; else rm -f "$NEW_SBIN"; fi
if [ $had_dropin -eq 1 ]; then cp -p "$W/prev-dropin" "$DROPIN"; else rm -f "$DROPIN"; rmdir "$DROPIN_DIR" 2>/dev/null; fi
if restart_unit; then
    printf '  rolled back: %s is active again, running %s\n' "$UNIT" "$(main_exe)"
else
    printf '  %sROLLBACK FAILED%s: %s is not running, check: journalctl -u %s\n' "$R" "$N" "$UNIT" "$UNIT"
fi
exit 4
