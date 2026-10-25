#!/usr/bin/env bash
# =============================================================================
# update-frontend.sh - build and atomically release the Vue/Vite frontend
# (Frontend VM). Static files served by Nginx from FRONTEND_DIR.
#
# Usage:  ./scripts/update-frontend.sh FRONTEND_REPO_DIR [--env PATH] [--reload-nginx]
#         ./scripts/update-frontend.sh --rollback [--env PATH]
#
# Paths: the web root is FRONTEND_DIR and the domain FRONTEND_DOMAIN from
# env/frontend.env - the same values scripts/06-update-frontend-nginx.sh uses.
# The frontend REPO path is not defined anywhere in this repo, so it is a required
# argument (or FRONTEND_REPO_DIR in env/frontend.env); nothing is guessed.
#
# git / node / npm run as the OWNER of the repo folder (never root); only the
# release copy, symlink swap, cleanup and Nginx steps use sudo.
# Layout after the first run:   <parent>/releases/<timestamp>/   (keeps newest 3)
#                               FRONTEND_DIR -> <parent>/releases/<active>
# Nginx needs no reload for a symlink swap; --reload-nginx runs `nginx -t` + reload
# (use it only after changing the Nginx config, e.g. via 06-update-frontend-nginx.sh).
# Until the swap step, the live web root is never touched. Never prints .env values.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_FILE="${REPO_DIR}/env/frontend.env"; FE_REPO=""; ROLLBACK=0; RELOAD=0; KEEP=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) [[ $# -ge 2 ]] || die "--env needs a path"; ENV_FILE="$2"; shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    --reload-nginx) RELOAD=1; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) [[ -z "${FE_REPO}" ]] || die "Only one repo path is accepted."; FE_REPO="${1%/}"; shift ;;
  esac
done

require_command sudo; require_command curl
load_env_file "${ENV_FILE}"
for v in FRONTEND_DIR FRONTEND_DOMAIN; do require_var "${v}"; done
WEB="${FRONTEND_DIR%/}"
[[ "${WEB}" != "" && "${WEB}" != "/" ]] || die "FRONTEND_DIR is unsafe: '${FRONTEND_DIR}'"
RELEASES="$(dirname "${WEB}")/releases"
if [[ "$(id -u)" -eq 0 ]]; then priv() { "$@"; }; else priv() { sudo "$@"; }; fi

# list_releases - release names, newest first (sorted by the timestamp in the name).
list_releases() {
  local d n
  for d in "${RELEASES}"/*/; do
    [[ -d "${d}" ]] || continue
    n="$(basename "${d}")"; printf '%s %s\n' "${n#initial-}" "${n}"
  done | sort -r | awk '{print $2}'
}
current_release() { [[ -L "${WEB}" ]] && basename "$(readlink -f "${WEB}")" || true; }
# swap_to NAME - atomic: build a temp symlink, then rename over the live one.
swap_to() {
  priv ln -sfn "${RELEASES}/$1" "${WEB}.new"
  priv mv -Tf "${WEB}.new" "${WEB}"
}
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null || echo 000; }
summary() {
  local prev="" cur found=0 n
  cur="$(current_release)"
  while read -r n; do
    if (( found )); then prev="${n}"; break; fi
    [[ "${n}" == "${cur}" ]] && found=1
  done < <(list_releases)
  echo; log_info "=== update-frontend.sh summary ==="
  log_info "Commit:          ${1:-n/a}"
  log_info "Active release:  ${cur:-n/a}"
  log_info "Previous (for --rollback): ${prev:-none}"
  log_info "Main page:       http://127.0.0.1/ (Host ${FRONTEND_DOMAIN}) -> HTTP $(http_code -H "Host: ${FRONTEND_DOMAIN}" http://127.0.0.1/)  | https via --resolve -> HTTP $(http_code --resolve "${FRONTEND_DOMAIN}:443:127.0.0.1" "https://${FRONTEND_DOMAIN}/")"
}

# --- Rollback mode (no build) ----------------------------------------------
if (( ROLLBACK )); then
  [[ -L "${WEB}" ]] || die "${WEB} is not a symlink - no releases to roll back to."
  CUR="$(current_release)"; PREV=""; found=0
  while read -r n; do
    if (( found )); then PREV="${n}"; break; fi
    [[ "${n}" == "${CUR}" ]] && found=1
  done < <(list_releases)
  [[ -n "${PREV}" ]] || die "No release older than '${CUR}' in ${RELEASES}."
  [[ -f "${RELEASES}/${PREV}/index.html" ]] || die "Previous release ${PREV} has no index.html; refusing."
  swap_to "${PREV}"
  log_ok "Rolled back: ${CUR} -> ${PREV}"
  (( RELOAD )) && { priv nginx -t && priv systemctl reload nginx && log_ok "Nginx reloaded."; }
  summary "n/a (rollback)"; exit 0
fi

# --- Normal update ---------------------------------------------------------
[[ -n "${FE_REPO:-${FRONTEND_REPO_DIR:-}}" ]] || die "Frontend repo path required: pass it as an argument (or set FRONTEND_REPO_DIR in env/frontend.env)."
FE_REPO="${FE_REPO:-${FRONTEND_REPO_DIR}}"; FE_REPO="${FE_REPO%/}"
[[ -d "${FE_REPO}/.git" && -f "${FE_REPO}/package.json" ]] || die "${FE_REPO} is not a frontend git repo (.git/package.json missing)."
OWNER="$(stat -c '%U' "${FE_REPO}")"
[[ "${OWNER}" != "root" ]] || die "${FE_REPO} is owned by root; git/npm must not run as root. chown it to the deploy user first."
if [[ "$(id -un)" == "${OWNER}" ]]; then
  run_as() { "$@"; }
else
  # login shell so the owner's PATH (nvm/fnm) is loaded
  run_as() { sudo -H -u "${OWNER}" -- bash -lc 'cd "$1" && shift && exec "$@"' _ "${FE_REPO}" "$@"; }
fi
cd "${FE_REPO}" 2>/dev/null || true

# State for the failure trap
NEW_REL=""; CONVERTED=""; SWAPPED=0
on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    if [[ -n "${CONVERTED}" && -d "${RELEASES}/${CONVERTED}" ]] && (( ! SWAPPED )); then
      log_warn "Restoring the original web root directory ..."
      priv rm -f -- "${WEB}" "${WEB}.new" 2>/dev/null || true
      priv mv -- "${RELEASES}/${CONVERTED}" "${WEB}" && log_ok "Original web root restored."
    fi
    if [[ -n "${NEW_REL}" && "${NEW_REL}" == "${RELEASES}"/* && -d "${NEW_REL}" ]] && (( ! SWAPPED )); then
      priv rm -rf -- "${NEW_REL}" || true
    fi
    log_error "Update aborted (exit ${rc}). $( ((SWAPPED)) && echo 'The new release was already live - run --rollback if needed.' || echo 'The live web root was not changed.')"
  fi
}
trap on_exit EXIT

# 1. Node / npm vs package.json engines -------------------------------------
NODE_V="$(run_as node -v)"; NPM_V="$(run_as npm -v)"
log_info "node ${NODE_V} | npm ${NPM_V}"
ENG_NODE="$(run_as node -e 'try{const e=require("./package.json").engines||{};process.stdout.write(e.node||"")}catch(e){}')"
ENG_NPM="$(run_as node -e 'try{const e=require("./package.json").engines||{};process.stdout.write(e.npm||"")}catch(e){}')"
# Minimal semver range check (>=, >, <=, <, =, ^, ~, x-ranges, || and space-ANDed comparators).
sat_check() { # $1=version $2=range ; exit 0 ok, 1 mismatch, 2 unsupported syntax
  node -e '
    const p=v=>String(v).replace(/^[v=]+/,"").split(".").map(x=>parseInt(x,10)||0);
    const c=(a,b)=>{for(let i=0;i<3;i++){const d=(a[i]||0)-(b[i]||0);if(d)return d}return 0};
    const ver=p(process.argv[1]); const range=process.argv[2].trim(); if(!range||range==="*")process.exit(0);
    if(/ - /.test(range))process.exit(2);
    const comp=t=>{const m=t.match(/^(>=|<=|>|<|=|\^|~)?\s*v?(\d+)(?:\.(\d+|x|X|\*))?(?:\.(\d+|x|X|\*))?$/);if(!m)throw 2;
      const op=m[1]||"",M=+m[2],wild=s=>s===undefined||/[xX*]/.test(s),mi=wild(m[3])?0:+m[3],pa=wild(m[4])?0:+m[4];
      const lo=[M,mi,pa];
      if(op===">=")return c(ver,lo)>=0; if(op===">")return c(ver,lo)>0; if(op==="<=")return c(ver,lo)<=0; if(op==="<")return c(ver,lo)<0;
      if(op==="^")return c(ver,lo)>=0&&c(ver,M>0?[M+1,0,0]:[0,mi+1,0])<0;
      if(op==="~")return c(ver,lo)>=0&&c(ver,[M,mi+1,0])<0;
      if(wild(m[3]))return ver[0]===M; if(wild(m[4]))return ver[0]===M&&ver[1]===mi; return c(ver,lo)===0};
    try{process.exit(range.split("||").some(r=>r.trim().replace(/(>=|<=|>|<|=|\^|~)\s+/g,"$1").split(/\s+/).filter(Boolean).every(comp))?0:1)}catch(e){process.exit(2)}
  ' "$1" "$2"
}
check_engine() { # name version range
  local rc=0; [[ -n "$3" ]] || { log_info "package.json engines.$1: not set"; return 0; }
  sat_check "$2" "$3" || rc=$?
  case "${rc}" in
    0) log_ok "engines.$1 '$3' satisfied by $2" ;;
    2) log_warn "engines.$1 '$3' uses syntax this script cannot check - verify manually (have $2)" ;;
    *) die "engines.$1 requires '$3' but this host has $2." ;;
  esac
}
check_engine node "${NODE_V}" "${ENG_NODE}"; check_engine npm "${NPM_V}" "${ENG_NPM}"

# 2. git pull ---------------------------------------------------------------
BEFORE="$(run_as git rev-parse --short HEAD)"
log_info "git pull --ff-only (branch $(run_as git rev-parse --abbrev-ref HEAD)) ..."
run_as git pull --ff-only
AFTER="$(run_as git rev-parse --short HEAD)"
log_ok "Commit: ${BEFORE} -> ${AFTER}"

# 3. Build env file + VITE_* key NAMES only ------------------------------------
ENVS=()
for f in .env.production .env.production.local; do
  run_as test -f "${FE_REPO}/${f}" && ENVS+=("${f}")
done
(( ${#ENVS[@]} > 0 )) || die "No .env.production (or .env.production.local) in ${FE_REPO}; the build would use the wrong API URL."
log_info "Build env files: ${ENVS[*]}"
KEYS="$(run_as grep -hoE '^[[:space:]]*VITE_[A-Za-z0-9_]+' "${ENVS[@]}" | tr -d ' \t' | sort -u || true)"
if [[ -n "${KEYS}" ]]; then
  while read -r k; do
    if [[ "${k}" =~ (API|URL|BASE|ENDPOINT|HOST) ]]; then log_info "  ${k}   <-- API/URL key (value not shown)"; else log_info "  ${k}"; fi
  done <<<"${KEYS}"
  grep -Eq 'API|URL|BASE|ENDPOINT|HOST' <<<"${KEYS}" || log_warn "No VITE_* key looks like an API URL - confirm the build targets the right backend."
else
  log_warn "No VITE_* keys found in ${ENVS[*]}."
fi

# 4. Build ----------------------------------------------------------------------
[[ "${FE_REPO}/dist" == */dist ]] && run_as rm -rf -- "${FE_REPO}/dist"   # stale output must not pass validation
log_info "npm ci ..."; run_as npm ci
log_info "npm run build ..."; run_as npm run build

# 5. Validate dist ----------------------------------------------------------------
DIST="${FE_REPO}/dist"
run_as test -f "${DIST}/index.html" || die "Build produced no ${DIST}/index.html."
[[ -n "$(run_as find "${DIST}/assets" -mindepth 1 -type f -print -quit 2>/dev/null)" ]] || die "${DIST}/assets is missing or empty."
log_ok "dist validated (index.html + assets)."

# 6. Atomic release ---------------------------------------------------------------
STAMP="$(timestamp)"; NEW_REL="${RELEASES}/${STAMP}"
priv install -d -m 0755 "${RELEASES}"
priv install -d -m 0755 "${NEW_REL}"
priv cp -a -- "${DIST}/." "${NEW_REL}/"
priv chown -R root:root "${NEW_REL}"
priv chmod -R u=rwX,go=rX "${NEW_REL}"
[[ -f "${NEW_REL}/index.html" ]] || die "Copy to ${NEW_REL} failed (no index.html)."
log_ok "Release prepared: ${NEW_REL}"

if [[ -e "${WEB}" && ! -L "${WEB}" ]]; then
  [[ -d "${WEB}" ]] || die "${WEB} exists but is neither a directory nor a symlink."
  log_warn "ONE-TIME CONVERSION: ${WEB} is a real directory. It will be moved to ${RELEASES}/initial-${STAMP} and replaced by a symlink."
  log_warn "There is a gap of milliseconds between the two steps (a directory cannot be atomically replaced by a symlink); later releases are fully atomic."
  CONVERTED="initial-${STAMP}"
  priv mv -- "${WEB}" "${RELEASES}/${CONVERTED}"
  priv ln -s "${RELEASES}/${STAMP}" "${WEB}"
  SWAPPED=1
else
  swap_to "${STAMP}"; SWAPPED=1
fi
log_ok "Web root ${WEB} -> ${NEW_REL}"

# Keep only the newest ${KEEP} releases (never the active one).
ACTIVE="$(current_release)"
while read -r n; do
  d="${RELEASES}/${n}"
  [[ -n "${n}" && "${n}" != "${ACTIVE}" && "${d}" == "${RELEASES}"/* && -d "${d}" ]] && { priv rm -rf -- "${d}"; log_info "Removed old release ${n}"; }
done < <(list_releases | tail -n +$((KEEP + 1)))

# 7. Nginx (only on request) ----------------------------------------------------------
if (( RELOAD )); then
  priv nginx -t
  priv systemctl reload nginx
  log_ok "Nginx tested and reloaded."
else
  log_info "Nginx not reloaded (not needed for a symlink swap). Use --reload-nginx after config changes."
fi
SITE="/etc/nginx/sites-available/${FRONTEND_DOMAIN}.conf"
if [[ -r "${SITE}" ]] && ! grep -Eq "^[[:space:]]*root[[:space:]]+${WEB}/?;" "${SITE}"; then
  log_warn "Installed Nginx config does not use 'root ${WEB};' - run scripts/06-update-frontend-nginx.sh, otherwise this release is not what gets served."
fi

# 9. Summary -----------------------------------------------------------------------------
summary "${BEFORE} -> ${AFTER}"
CODE="$(http_code -H "Host: ${FRONTEND_DOMAIN}" http://127.0.0.1/)"
[[ "${CODE}" =~ ^[23] ]] || log_warn "Main page returned HTTP ${CODE}. Roll back with: ./scripts/update-frontend.sh --rollback"
log_ok "Frontend update finished."
