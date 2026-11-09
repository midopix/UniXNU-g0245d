#!/usr/bin/env bash
# Push today's G0245D work to GitHub.
#
#   bash push-now.sh <PAT>                 # push all three existing targets
#   bash push-now.sh <PAT> --with-fork     # also fork UniXNU/DarwinBoot and push
#   GITHUB_TOKEN=<PAT> bash push-now.sh
#   bash push-now.sh                       # falls back to ~/.workbuddy/github-token
#
# Put the token in ~/.workbuddy/github-token (chmod 600) once and it will be
# picked up automatically from then on -- it lives outside every git work tree,
# so it can never be committed by accident.
#
# The PAT needs `repo` scope (classic) or Contents:write + Administration:read
# (fine-grained). The GitHub *connector* (App installation token) cannot be used
# here -- it only has read access to midopix/*, so every write returns
# 403 "Resource not accessible by integration".
#
# The token is never written to disk and never echoed.
set -uo pipefail

TOKEN=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  TOKEN="$1"
  shift
fi
[[ -n "${TOKEN}" ]] || TOKEN="${GITHUB_TOKEN:-}"
TOKEN_FILE="${HOME}/.workbuddy/github-token"
if [[ -z "${TOKEN}" && -f "${TOKEN_FILE}" ]]; then
  TOKEN="$(tr -d '[:space:]' < "${TOKEN_FILE}")"
fi
WITH_FORK=0
for a in "$@"; do
  case "$a" in
    --with-fork) WITH_FORK=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
[[ -n "${TOKEN}" ]] || {
  echo "no token. Either pass it: bash push-now.sh <github-pat>" >&2
  echo "or store it once:  install -m600 /dev/stdin ${TOKEN_FILE} <<< '<PAT>'" >&2
  exit 1
}

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OWNER="midopix"
RC=0

# github.com is reachable directly here, but go through FlClash if the sandbox
# starts blocking it (the proxy is optional -- verify connectivity first).
if ! timeout 15 git ls-remote "https://github.com/${OWNER}/UniXNU-g0245d.git" >/dev/null 2>&1; then
  echo "direct git access failed, retrying via 127.0.0.1:7890"
  export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
fi

push_one () {
  local label="$1" dir="$2" refspec="$3" url="$4"
  printf '=== %s\n' "$label"
  if ! git -C "$dir" push "$url" "$refspec" 2>&1 | sed 's/^/    /'; then
    echo "    FAILED"
    RC=1
    return 1
  fi
  local remote_branch="${refspec#*:}"
  local head_sha
  head_sha="$(git -C "$dir" rev-parse HEAD)"
  sleep 1
  local want got
  want="$(git -C "$dir" rev-parse "HEAD")"
  got="$(timeout 20 git ls-remote "$url" "refs/heads/${remote_branch}" | awk '{print $1}')"
  if [[ "$want" == "$got" ]]; then
    echo "    OK  ${remote_branch} -> ${want:0:7}"
  else
    echo "    MISMATCH local ${want:0:7} remote ${got:0:7}"
    RC=1
  fi
  return 0
}

# 1. device repo: board.toml, patches/xnu/, docs/bringup/
push_one "UniXNU-g0245d (device: board.toml, early-boot patch, bringup docs)" \
  "$BASE/src/unixnu-g0245d/UniXNU-g0245d" "main:main" \
  "https://x-access-token:${TOKEN}@github.com/${OWNER}/UniXNU-g0245d.git"

# 2. UEFI overlay: EnglishDxe, PMIC key fix
push_one "uefi-g0245d (overlay: EnglishDxe, PMIC key DTEST fix)" \
  "$BASE/workspace/github/uefi-g0245d" "main:main" \
  "https://x-access-token:${TOKEN}@github.com/${OWNER}/uefi-g0245d.git"

# 3. kernel package fork: UniXNULib, payload.py, menu, DarwinBoot pointer
push_one "UniXNU fork (kernel pkg: device/g0245d-msm8996)" \
  "$BASE/src/unixnu-g0245d/unixnu-src" "device/g0245d-msm8996:device/g0245d-msm8996" \
  "https://x-access-token:${TOKEN}@github.com/${OWNER}/UniXNU.git"

# 4. DarwinBoot: no fork exists yet, so create one on demand
DB="$BASE/src/unixnu-g0245d/unixnu-src/drivers/DarwinBoot"
if timeout 15 git ls-remote "https://github.com/${OWNER}/DarwinBoot.git" >/dev/null 2>&1; then
  push_one "DarwinBoot fork (submodule: bring-up diagnostics)" \
    "$DB" "g0245d-bringup:g0245d-bringup" \
    "https://x-access-token:${TOKEN}@github.com/${OWNER}/DarwinBoot.git"
elif [[ "$WITH_FORK" == "1" ]]; then
  echo "=== forking UniXNU/DarwinBoot via API"
  code=$(curl -sS -o /tmp/fork-resp.json -w '%{http_code}' \
    -X POST -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/UniXNU/DarwinBoot/forks)
  echo "    HTTP $code"
  if [[ "$code" == "202" || "$code" == "200" ]]; then
    sleep 8
    push_one "DarwinBoot fork (created just now)" \
      "$DB" "g0245d-bringup:g0245d-bringup" \
      "https://x-access-token:${TOKEN}@github.com/${OWNER}/DarwinBoot.git"
  else
    echo "    fork failed, keep using docs/bringup/g0245d-darwinboot.patch instead"
    sed 's/^/    /' /tmp/fork-resp.json | head -5
  fi
else
  echo "=== DarwinBoot: no fork yet -- skipped"
  echo "    run with --with-fork to create it, or rely on docs/bringup/g0245d-darwinboot.patch"
fi

echo
if [[ "$RC" == "0" ]]; then
  echo "ALL PASS"
  echo "  https://github.com/${OWNER}/UniXNU-g0245d"
  echo "  https://github.com/${OWNER}/uefi-g0245d"
  echo "  https://github.com/${OWNER}/UniXNU/tree/device/g0245d-msm8996"
else
  echo "SOME TARGETS FAILED (rc=$RC)"
fi
exit "$RC"
