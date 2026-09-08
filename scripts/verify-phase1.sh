#!/usr/bin/env bash
# verify-phase1.sh — Phase 1 acceptance assertions.
#
# Usage:
#   ./scripts/verify-phase1.sh smoke   # after deploying labs/00-smoke-test
#   ./scripts/verify-phase1.sh ceos    # after deploying labs/01-two-node-ceos
#   ./scripts/verify-phase1.sh         # runs whichever labs are currently up
#
# This asserts. It does not deploy or destroy anything.

set -u

pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
skip() { printf '  \033[0;33mSKIP\033[0m  %s\n' "$1"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

FAILURES=0
TARGET="${1:-auto}"

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

check_smoke() {
  hdr "Lab 00 — smoke test (2x alpine)"
  local ok=1
  for n in clab-smoke-n1 clab-smoke-n2; do
    if running "$n"; then pass "$n is running"; else fail "$n is not running"; ok=0; fi
  done
  [ "$ok" -eq 1 ] || return

  # eth1 is the containerlab-created veth end inside the namespace.
  if docker exec clab-smoke-n1 ip -br addr show eth1 2>/dev/null | grep -q '10.0.0.1/30'; then
    pass "n1 eth1 addressed 10.0.0.1/30"
  else
    fail "n1 eth1 missing its address — did the exec block run?"
  fi

  if docker exec clab-smoke-n1 ping -c 3 -W 2 10.0.0.2 >/dev/null 2>&1; then
    pass "n1 -> n2 ICMP across the veth pair"
  else
    fail "ping failed — see docs/00-environment-setup.md section 5 (Docker Desktop)"
  fi
}

check_ceos() {
  hdr "Lab 01 — two-node cEOS"
  local ok=1
  for n in clab-p1-ceos-leaf1 clab-p1-ceos-leaf2; do
    if running "$n"; then pass "$n is running"; else fail "$n is not running"; ok=0; fi
  done
  [ "$ok" -eq 1 ] || return

  # A booted cEOS answers the CLI. A crash-looping one does not.
  local ver
  ver=$(docker exec clab-p1-ceos-leaf1 Cli -p 15 -c 'show version | include Software image version' 2>/dev/null | tr -d '\r')
  if [ -n "$ver" ]; then
    pass "leaf1 EOS CLI responding — ${ver#*: }"
  else
    fail "leaf1 CLI not responding — EOS may still be booting (give it 120s) or crash-looping"
    return
  fi

  # The veth must be presented to EOS as a front-panel port.
  if docker exec clab-p1-ceos-leaf1 Cli -p 15 -c 'show interfaces status' 2>/dev/null | grep -q 'Et1'; then
    pass "leaf1 sees Ethernet1 (the containerlab veth)"
  else
    fail "leaf1 has no Ethernet1 — link definition or deploy problem"
  fi

  # Optional data-plane proof from section 8. Absent is not a failure.
  if docker exec clab-p1-ceos-leaf1 Cli -p 15 -c 'show ip interface brief' 2>/dev/null | grep -q '10.1.1.1'; then
    if docker exec clab-p1-ceos-leaf1 Cli -p 15 -c 'ping 10.1.1.2 repeat 3' 2>/dev/null | grep -q '0% packet loss\|3 received'; then
      pass "data plane verified: leaf1 -> leaf2 over Ethernet1"
    else
      fail "Ethernet1 addressed but ping failed"
    fi
  else
    skip "optional section 8 data-plane test not configured"
  fi
}

case "$TARGET" in
  smoke) check_smoke ;;
  ceos)  check_ceos ;;
  auto)
    running clab-smoke-n1 && check_smoke
    running clab-p1-ceos-leaf1 && check_ceos
    if ! running clab-smoke-n1 && ! running clab-p1-ceos-leaf1; then
      hdr "Nothing deployed"
      printf '  Deploy a lab first, then re-run.\n'
      exit 1
    fi
    ;;
  *) printf 'usage: %s [smoke|ceos]\n' "$0"; exit 2 ;;
esac

hdr "Result"
if [ "$FAILURES" -eq 0 ]; then
  printf '  \033[0;32mPhase 1 assertions passed.\033[0m\n'
  printf '  Next: docs/phase-1-acceptance.md, then the whiteboard self-check.\n\n'
else
  printf '  \033[0;31m%d assertion(s) failed.\033[0m Do not proceed to Phase 2.\n\n' "$FAILURES"
  exit 1
fi
