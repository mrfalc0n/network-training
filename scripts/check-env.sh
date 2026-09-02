#!/usr/bin/env bash
# check-env.sh — Phase 1 pre-flight. Reads the environment, changes nothing.
# Run from anywhere:  ./scripts/check-env.sh

set -u

pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
warn() { printf '  \033[0;33mWARN\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; }
info() { printf '  ----  %s\n' "$1"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

FAILURES=0
note_fail() { FAILURES=$((FAILURES + 1)); fail "$1"; }

hdr "1. Platform"
KERNEL=$(uname -r)
info "kernel: ${KERNEL}"
if grep -qi microsoft /proc/version 2>/dev/null; then
  pass "running under WSL2"
else
  warn "not detected as WSL2 — fine if this is a native Linux host"
fi

hdr "2. Filesystem location"
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
info "repo root: ${REPO_ROOT}"
case "$REPO_ROOT" in
  /mnt/c/*|/mnt/[a-z]/*)
    warn "repo lives on a Windows drive mount."
    warn "  Labs will be slow and cEOS bind-mount permissions may fail."
    warn "  Recommended: clone into the WSL filesystem, e.g. ~/github/network-training"
    ;;
  *) pass "repo is on the Linux filesystem" ;;
esac

hdr "3. cgroups"
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  info "cgroups v2 (unified) — requires cEOS-lab 4.32.0F or newer"
else
  info "cgroups v1 — older cEOS releases will also work"
fi

hdr "4. Docker"
if ! command -v docker >/dev/null 2>&1; then
  note_fail "docker client not found"
else
  pass "docker client: $(docker --version 2>/dev/null)"
  if docker info >/dev/null 2>&1; then
    pass "docker daemon reachable"
    # Distinguish Docker Desktop from a native Engine install inside this distro.
    SERVER_OS=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || echo unknown)
    info "daemon OS string: ${SERVER_OS}"
    if printf '%s' "$SERVER_OS" | grep -qi 'docker desktop'; then
      warn "Docker Desktop WSL integration detected."
      warn "  Usually works, but is the most common cause of 'lab deploys,"
      warn "  links do not pass traffic'. If the smoke test ping fails, see"
      warn "  docs/00-environment-setup.md section 5."
    else
      pass "native Docker Engine (what containerlab expects)"
    fi
  else
    note_fail "docker daemon not reachable — is it running, and are you in the docker group?"
  fi
fi

hdr "5. containerlab"
if command -v containerlab >/dev/null 2>&1; then
  pass "containerlab: $(containerlab version 2>/dev/null | grep -i -m1 version || echo installed)"
else
  warn "containerlab not installed yet — see docs/00-environment-setup.md section 4"
fi

hdr "6. cEOS image"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker image inspect ceos:lab >/dev/null 2>&1; then
    SIZE=$(docker image inspect ceos:lab --format '{{.Size}}' 2>/dev/null)
    pass "ceos:lab present ($((SIZE / 1024 / 1024)) MB)"
  else
    warn "ceos:lab not found — see docs/00-environment-setup.md section 6"
  fi
fi

hdr "7. Resources"
if command -v free >/dev/null 2>&1; then
  MEM_GB=$(free -g | awk '/^Mem:/{print $2}')
  info "RAM visible to this distro: ${MEM_GB} GB"
  if [ "${MEM_GB:-0}" -lt 8 ]; then
    warn "under 8 GB — cEOS wants roughly 2 GB per node; a 4-node spine-leaf will be tight"
  else
    pass "RAM sufficient for Phase 1 and Phase 2"
  fi
fi
AVAIL=$(df -h "$REPO_ROOT" 2>/dev/null | awk 'NR==2{print $4}')
info "free disk at repo root: ${AVAIL:-unknown} (need ~5 GB for the cEOS image)"

hdr "Summary"
if [ "$FAILURES" -eq 0 ]; then
  printf '  No blocking failures. Warnings above are informational.\n\n'
else
  printf '  %d blocking failure(s). Resolve before continuing.\n\n' "$FAILURES"
  exit 1
fi
