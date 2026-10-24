#!/usr/bin/env bash
# =============================================================================
# check-php2shell.sh - READ-ONLY exposure check for CVE-2026-109618 / CVE-2026-109619
# ("php2shell"). Run it on each VM that has PHP (API VM, any Docker host).
#
# Usage:  ./scripts/security/check-php2shell.sh [/path/to/laravel-app ...]
#         (no argument + /var/www/pmli-backend exists -> that path is used)
# Env:    WEB_USER=www-data   user whose processes/connections/crontab are inspected
#
# Does NOT install, restart or change anything. Commands needing root run via
# `sudo -n` when available (never prompts); otherwise the section prints
# "SKIP (butuh sudo)" and continues. Never prints .env contents; every output
# line is additionally passed through a redaction filter for password/token-like
# values. Process arguments are deliberately not shown.
# Output: screen + reports/php2shell-<hostname>-<YYYYmmdd-HHMM>.txt (git-ignored).
#
# Verdict uses the UPSTREAM version table supplied with the advisory:
#   8.5 <8.5.12 | 8.4 <8.4.27 | 8.3 <8.3.36 | 8.2 <8.2.35 -> VULNERABLE
#   <= 8.1 / 7.x / 5.x -> EOL-VULNERABLE.  Distro packages may backport fixes
#   without changing the version: confirm with `apt changelog <pkg> | grep CVE-2026-1096`.
# =============================================================================
set -u   # intentionally NOT -e: a failing probe must not stop the audit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WEB="${WEB_USER:-www-data}"
HOST="$(hostname)"
REPORT_DIR="${REPO_DIR}/reports"
umask 077
mkdir -p "${REPORT_DIR}" 2>/dev/null || REPORT_DIR="${TMPDIR:-/tmp}"
REPORT="${REPORT_DIR}/php2shell-${HOST}-$(date +%Y%m%d-%H%M).txt"

APPS=("$@")
if [ ${#APPS[@]} -eq 0 ] && [ -d /var/www/pmli-backend ]; then APPS=(/var/www/pmli-backend); fi

redact() {
  sed -E 's/([Pp][Aa][Ss][Ss][A-Za-z_]*|[Tt][Oo][Kk][Ee][Nn][A-Za-z_]*|[Ss][Ee][Cc][Rr][Ee][Tt][A-Za-z_]*|[Aa][Pp][Ii]_?[Kk][Ee][Yy][A-Za-z_]*|[Pp][Ww][Dd])([=:][[:space:]]*)[^[:space:]]+/\1\2***/g; s#(://[^:/@ ]+:)[^@ ]+@#\1***@#g'
}

# ---------------------------------------------------------------- helpers ---
sec()  { printf '\n==================== %s ====================\n' "$1"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
skip() { printf '[SKIP] %s (butuh sudo)\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# priv CMD... : run as root if already root, else via non-interactive sudo, else rc 126.
priv() {
  if [ "$(id -u)" -eq 0 ]; then "$@"
  elif have sudo && sudo -n true 2>/dev/null; then sudo -n "$@"
  else return 126; fi
}

# ver_of TEXT : first "PHP x.y.z" in TEXT -> x.y.z
ver_of() { printf '%s' "$1" | grep -oE 'PHP [0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | awk '{print $2}'; }

# verdict VERSION
verdict() {
  local v="${1%%[-+~ ]*}" mm min
  case "$v" in ""|"?") echo "UNKNOWN"; return;; esac
  mm="${v%.*}"
  case "$mm" in
    8.5) min=8.5.12;; 8.4) min=8.4.27;; 8.3) min=8.3.36;; 8.2) min=8.2.35;;
    8.0|8.1|7.*|5.*|4.*) echo "EOL-VULNERABLE"; return;;
    *) echo "UNKNOWN (di luar tabel)"; return;;
  esac
  if [ "$(printf '%s\n%s\n' "$min" "$v" | sort -V | head -n 1)" = "$min" ]; then echo "PATCHED"; else echo "VULNERABLE"; fi
}

RESULTS=""
SEEN=""
# add_result SAPI LOCATION VERSION
add_result() {
  local key="$1|$2"
  case "$SEEN" in *"|$key|"*) return;; esac
  SEEN="$SEEN|$key|"
  RESULTS="${RESULTS}$1|$2|${3:-?}|$(verdict "${3:-?}")"$'\n'
  info "$1 $2 -> PHP ${3:-?} => $(verdict "${3:-?}")"
}

FPM_VERS=""   # lines "MAJOR.MINOR FULLVERSION" for nginx mapping

main() {
info "php2shell check | host=${HOST} | $(date '+%F %T %z') | user=$(id -un) | report=${REPORT}"

# ------------------------------------------------------------ 1. Sistem ---
sec "1. SISTEM"
echo "Hostname : ${HOST}"
if [ -r /etc/os-release ]; then ( . /etc/os-release; echo "OS       : ${PRETTY_NAME:-?} (ID=${ID:-?} VERSION_ID=${VERSION_ID:-?})" ); fi
echo "Kernel   : $(uname -r)"
echo "Uptime   : $(uptime -p 2>/dev/null || uptime)"

# ------------------------------------------------------- 2. Versi per SAPI ---
sec "2. VERSI PHP PER SAPI"
echo "--- CLI"
have php && php -v 2>&1 | head -n 2 || info "php (CLI) tidak ada di PATH"
for b in /usr/bin/php* /usr/local/bin/php*; do
  [ -x "$b" ] || continue
  case "$(basename "$b")" in php|php[0-9]*|php-cli*) ;; *) continue;; esac
  case "$(basename "$b")" in php-fpm*|phpize*|php-config*|phpdbg*) continue;; esac
  real="$(readlink -f "$b" 2>/dev/null || echo "$b")"
  v="$(ver_of "$("$b" -v 2>/dev/null)")"
  echo "  $b -> $real : PHP ${v:-?}"
  add_result "CLI" "$real" "$v"
done
echo "--- update-alternatives"
have update-alternatives && update-alternatives --display php 2>&1 | head -n 12 || info "update-alternatives tidak tersedia"

echo "--- FPM binaries"
for b in /usr/sbin/php-fpm* /usr/bin/php-fpm* /usr/local/sbin/php-fpm* /usr/local/bin/php-fpm*; do
  [ -x "$b" ] || continue
  real="$(readlink -f "$b" 2>/dev/null || echo "$b")"
  v="$(ver_of "$("$b" -v 2>/dev/null)")"
  echo "  $b : PHP ${v:-?}"
  add_result "FPM" "$real" "$v"
  [ -n "$v" ] && FPM_VERS="${FPM_VERS}${v%.*} ${v}"$'\n'
done
echo "--- FPM services (systemd)"
if have systemctl; then
  systemctl list-units 'php*-fpm*' --all --no-pager --no-legend 2>&1 | head -n 20
  for u in $(systemctl list-units 'php*-fpm*' --all --no-pager --no-legend 2>/dev/null | awk '{print $1}' | grep -E '\.service$'); do
    echo "  $u : active=$(systemctl is-active "$u" 2>&1) enabled=$(systemctl is-enabled "$u" 2>&1)"
  done
else info "systemctl tidak tersedia"; fi

echo "--- Apache / mod_php"
if have apache2 || have apache2ctl || have httpd; then
  info "Apache terpasang: $(command -v apache2 || command -v httpd)"
  ls /etc/apache2/mods-enabled/php*.load 2>/dev/null || info "tidak ada mod_php aktif di mods-enabled"
  for f in /etc/apache2/mods-enabled/php*.load; do
    [ -e "$f" ] || continue
    mm="$(basename "$f" .load | sed 's/^php//')"
    pv="$(dpkg-query -W -f='${Version}' "libapache2-mod-php${mm}" 2>/dev/null | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
    add_result "Apache-mod_php" "$f" "$pv"
  done
  out="$(priv apache2ctl -M 2>&1)"; rc=$?; if [ $rc -eq 126 ]; then skip "apache2ctl -M"; else printf "%s\n" "$out" | grep -i php || echo "  (tidak ada modul php di apache2ctl -M)"; fi
else info "Apache tidak terpasang"; fi

echo "--- Nginx: site -> server_name -> fastcgi_pass -> versi FPM"
if have nginx || [ -d /etc/nginx ]; then
  for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [ -r "$f" ] || continue
    names="$(grep -hE '^\s*server_name' "$f" 2>/dev/null | sed -E 's/^\s*server_name\s+//; s/;.*//' | tr '\n' ' ')"
    for pass in $(grep -hE '^\s*fastcgi_pass' "$f" 2>/dev/null | sed -E 's/^\s*fastcgi_pass\s+//; s/;.*//' | sort -u); do
      mm="$(printf '%s' "$pass" | grep -oE 'php[0-9]+\.[0-9]+' | head -n 1 | sed 's/^php//')"
      full="$(printf '%s' "$FPM_VERS" | awk -v m="$mm" '$1==m {print $2; exit}')"
      if [ -n "$mm" ]; then fpm="php$mm${full:+ ($full)}"; else fpm="TCP/unknown - lihat listen pool di bawah"; fi
      echo "  $(basename "$f") | server_name: ${names:-?} | fastcgi_pass: $pass | FPM: $fpm"
    done
  done
  echo "  pool listen:"; grep -HE '^\s*listen\s*=' /etc/php/*/fpm/pool.d/*.conf 2>/dev/null | sed 's/^/    /'
else info "Nginx tidak terpasang"; fi

echo "--- Docker"
DK=""
if have docker; then
  if docker ps >/dev/null 2>&1; then DK="docker"; elif priv docker ps >/dev/null 2>&1; then DK="priv docker"; fi
  if [ -z "$DK" ]; then skip "docker ps"; else
    $DK ps --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>&1 | while IFS='|' read -r n img st; do
      pvt="$($DK exec "$n" php -r 'echo PHP_VERSION;' 2>/dev/null)"
      echo "  container=$n image=$img status=$st php=${pvt:-none}"
    done
    # add_result must run in this shell (not a pipe subshell)
    for n in $($DK ps --format '{{.Names}}' 2>/dev/null); do
      pvt="$($DK exec "$n" php -r 'echo PHP_VERSION;' 2>/dev/null)"
      [ -n "$pvt" ] && add_result "Docker" "$n ($($DK inspect --format '{{.Config.Image}}' "$n" 2>/dev/null))" "$pvt"
    done
  fi
else info "Docker tidak terpasang"; fi

echo "--- FrankenPHP / LiteSpeed"
if have frankenphp; then
  fo="$(frankenphp version 2>&1 | head -n 1)"; echo "  frankenphp: $fo"
  add_result "FrankenPHP" "$(command -v frankenphp)" "$(ver_of "$fo")"
else info "FrankenPHP tidak terdeteksi"; fi
if [ -d /usr/local/lsws ] || have lswsctrl || pgrep -x litespeed >/dev/null 2>&1; then
  info "LiteSpeed terdeteksi"
  for b in /usr/local/lsws/lsphp*/bin/lsphp; do
    [ -x "$b" ] || continue
    add_result "LiteSpeed-lsphp" "$b" "$(ver_of "$("$b" -v 2>/dev/null)")"
  done
else info "LiteSpeed tidak terdeteksi"; fi

# ------------------------------------------------------- 3. Sumber paket ---
sec "3. SUMBER PAKET (apt-cache policy)"
if have dpkg && have apt-cache; then
  pkgs="$(dpkg -l 'php*' 2>/dev/null | awk '/^ii/ && $2 ~ /^php[0-9.]*-(fpm|cli)$/ {print $2}')"
  if [ -z "$pkgs" ]; then info "tidak ada paket php*-fpm / php*-cli terpasang via dpkg"; fi
  for p in $pkgs; do
    echo "--- $p (dpkg $(dpkg-query -W -f='${Version}' "$p" 2>/dev/null))"
    apt-cache policy "$p" 2>/dev/null | awk 'NR<=3 {print "  " $0} /\*\*\*/ {getline; print "  origin: " $0}'
  done
else info "dpkg/apt-cache tidak tersedia (bukan Debian/Ubuntu?)"; fi
if [ -n "${DK:-}" ]; then
  echo "--- image Docker"
  $DK ps --format '{{.Image}}' 2>/dev/null | sort -u | while read -r img; do
    echo "  $img : $($DK image inspect --format '{{.Id}} created={{.Created}}' "$img" 2>/dev/null | cut -c1-90)"
  done
fi

# ------------------------------------------------------------ 5. Konfigurasi ---
sec "5. KONFIGURASI (memory_limit, php.ini)"
if have php; then
  echo "--- CLI"; php -i 2>/dev/null | grep -E '^(Loaded Configuration File|Scan this dir|memory_limit)' | sed 's/^/  /'
fi
for b in /usr/sbin/php-fpm* /usr/bin/php-fpm* /usr/local/sbin/php-fpm*; do
  [ -x "$b" ] || continue
  echo "--- FPM $b"; "$b" -i 2>/dev/null | grep -E '^(Loaded Configuration File|Scan this dir|memory_limit)' | sed 's/^/  /'
done
echo "--- override di pool FPM"
grep -HnE 'memory_limit|php_(admin_)?value' /etc/php/*/fpm/pool.d/*.conf 2>/dev/null | sed 's/^/  /' || true

# ------------------------------------------------------------ 6. Aplikasi ---
sec "6. APLIKASI"
if [ ${#APPS[@]} -eq 0 ]; then info "tidak ada path aplikasi (beri sebagai argumen)"; fi
for app in "${APPS[@]}"; do
  echo "--- $app"
  [ -d "$app" ] || { warn "bukan direktori"; continue; }
  echo "  owner dir : $(stat -c '%U:%G' "$app" 2>/dev/null || stat -f '%Su:%Sg' "$app")"
  echo "  composer 'php' constraint: $(grep -m1 -E '^\s*"php"\s*:' "$app/composer.json" 2>/dev/null | sed 's/^\s*//' || echo '?')"
  if [ -f "$app/artisan" ]; then
    echo "  artisan   : $(cd "$app" && timeout 20 php artisan --version 2>&1 | head -n 2 | tr '\n' ' ')"
  else warn "artisan tidak ditemukan"; fi
done

# ------------------------------------------------------------- 7. Eksposur ---
sec "7. EKSPOSUR"
echo "--- port listening"
if have ss; then
  out="$(priv ss -tlnp 2>&1)"; rc=$?
  if [ $rc -eq 126 ]; then skip "ss -tlnp (nama proses)"; ss -tln 2>&1 | sed 's/^/  /'; else printf '%s\n' "$out" | sed 's/^/  /'; fi
else info "ss tidak tersedia"; fi
echo "--- server_name nginx (sites-enabled / conf.d)"
grep -RhE '^\s*server_name' /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | sed -E 's/^\s*//' | sort -u | sed 's/^/  /'

# --------------------------------------------------- 8. Indikasi kompromi ---
sec "8. INDIKASI KOMPROMI RINGAN (heuristik, bukan bukti)"
for app in "${APPS[@]}"; do
  [ -d "$app" ] || continue
  echo "--- $app : .php diubah <= 7 hari di public/ & storage/ (tanpa compiled views; maks 50)"
  find "$app/public" "$app/storage" -type f -name '*.php' -mtime -7 -not -path '*/storage/framework/views/*' \
    -printf '%TY-%Tm-%Td %TH:%TM %u %p\n' 2>/dev/null | sort -r | head -n 50 | sed 's/^/  /'
  echo "--- $app : .php selain public/index.php di public/ (maks 50)"
  find "$app/public" -type f \( -iname '*.php' -o -iname '*.phtml' -o -iname '*.phar' \) ! -path "$app/public/index.php" 2>/dev/null | head -n 50 | sed 's/^/  /'
  echo "--- $app : file executable-PHP di folder upload/storage (seharusnya TIDAK ADA; maks 50)"
  find -L "$app/storage/app" "$app/public/storage" "$app/public/uploads" "$app/public/upload" -type f \
    \( -iname '*.php' -o -iname '*.phtml' -o -iname '*.phar' -o -iname '*.php[0-9]' \) 2>/dev/null | head -n 50 | sed 's/^/  /'
done
echo "--- proses shell/curl/wget/nc/python dgn parent php* atau milik '${WEB}' (argumen disembunyikan)"
ps -eo pid=,ppid=,user=,comm= 2>/dev/null | awk -v web="$WEB" '
  { pid=$1; c[pid]=$4; pp[pid]=$2; u[pid]=$3; n++; ord[n]=pid }
  END { for (i=1;i<=n;i++) { p=ord[i]
    if (c[p] ~ /^(sh|bash|dash|zsh|ash|curl|wget|nc|ncat|netcat|socat|perl|python[0-9.]*)$/ && (c[pp[p]] ~ /^php/ || u[p]==web))
      printf "  pid=%s user=%s proc=%s parent=%s(%s)\n", p, u[p], c[p], c[pp[p]], pp[p] } }' | head -n 50
echo "  (selesai; baris kosong = tidak ada temuan)"
echo "--- koneksi keluar ESTABLISHED milik '${WEB}'"
out="$(priv ss -H -tnp state established 2>&1)"; rc=$?
if [ $rc -eq 126 ]; then skip "ss -tnp (pid pemilik koneksi)"; else
  printf '%s\n' "$out" | while read -r _ _ loc peer proc; do
    pid="$(printf '%s' "$proc" | grep -oE 'pid=[0-9]+' | head -n 1 | cut -d= -f2)"
    [ -n "$pid" ] || continue
    [ "$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')" = "$WEB" ] && echo "  $loc -> $peer  $(printf '%s' "$proc" | grep -oE '\(\("[^"]+"' | tr -d '("')"
  done | head -n 50
fi
echo "--- crontab '${WEB}'"
out="$(priv crontab -l -u "$WEB" 2>&1)"; rc=$?
if [ $rc -eq 126 ]; then skip "crontab -l -u ${WEB}"; else printf '%s\n' "${out:-  (kosong)}" | sed 's/^/  /'; fi
grep -Hs "$WEB" /etc/cron.d/* 2>/dev/null | sed 's/^/  \/etc\/cron.d: /' | head -n 20

# ------------------------------------------------------------ 9. Ringkasan ---
sec "9. RINGKASAN"
{
  echo "SAPI|LOKASI|VERSI|VERDICT"
  printf '%s' "$RESULTS"
} | { have column && column -t -s'|' || tr '|' '\t'; }
[ -z "$RESULTS" ] && warn "tidak ada instalasi PHP terdeteksi"
echo
echo "Catatan: verdict = tabel versi upstream. Paket distro bisa membawa patch backport tanpa mengubah nomor versi."
echo "Laporan: ${REPORT}"
}

main 2>&1 | redact | tee "${REPORT}"
