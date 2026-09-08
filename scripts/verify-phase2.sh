#!/usr/bin/env bash
# verify-phase2.sh — Phase 2 underlay acceptance assertions.
#
# Run with labs/02-underlay deployed:
#   ./scripts/verify-phase2.sh
#
# Asserts only. Deploys nothing, destroys nothing, configures nothing.

set -u

pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  \033[0;33mWARN\033[0m  %s\n' "$1"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

FAILURES=0
P="clab-p2-underlay"
SPINES="spine1 spine2"
LEAVES="leaf1 leaf2 leaf3 leaf4"

# Loopback of each leaf: leaf1 -> 10.0.0.1 ... leaf4 -> 10.0.0.4
leaf_lo() { printf '10.0.0.%s' "${1#leaf}"; }

# Run an EOS command on a node. Usage: eos <node> '<command>'
eos() { docker exec "${P}-$1" Cli -p 15 -c "$2" 2>/dev/null | tr -d '\r'; }

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# ---------------------------------------------------------------------------
hdr "1. All six nodes running"
ALL_UP=1
for n in $SPINES $LEAVES; do
  if running "${P}-${n}"; then
    pass "${P}-${n}"
  else
    fail "${P}-${n} is not running"
    ALL_UP=0
  fi
done

if [ "$ALL_UP" -eq 0 ]; then
  hdr "Result"
  printf '  Deploy the lab first: containerlab deploy -t labs/02-underlay/underlay.clab.yml\n\n'
  exit 1
fi

# ---------------------------------------------------------------------------
hdr "2. EOS control plane responding"
for n in $SPINES $LEAVES; do
  if [ -n "$(eos "$n" 'show version | include Software image version')" ]; then
    pass "$n CLI responding"
  else
    fail "$n CLI not responding — still booting, or crash-looping"
  fi
done

# ---------------------------------------------------------------------------
hdr "3. Loopbacks configured"
for n in $SPINES $LEAVES; do
  case "$n" in
    spine1) want="10.0.0.11" ;;
    spine2) want="10.0.0.12" ;;
    *)      want=$(leaf_lo "$n") ;;
  esac
  if eos "$n" 'show ip interface brief' | grep -q "$want"; then
    pass "$n Loopback0 = $want"
  else
    fail "$n missing Loopback0 $want"
  fi
done

# ---------------------------------------------------------------------------
hdr "4. BGP sessions established (expect 2 per leaf, 4 per spine)"
for n in $LEAVES; do
  cnt=$(eos "$n" 'show ip bgp summary' | grep -c 'Estab')
  if [ "${cnt:-0}" -ge 2 ]; then
    pass "$n has $cnt established sessions"
  else
    fail "$n has ${cnt:-0} established sessions, expected 2"
  fi
done
for n in $SPINES; do
  cnt=$(eos "$n" 'show ip bgp summary' | grep -c 'Estab')
  if [ "${cnt:-0}" -ge 4 ]; then
    pass "$n has $cnt established sessions"
  else
    fail "$n has ${cnt:-0} established sessions, expected 4"
  fi
done

# ---------------------------------------------------------------------------
hdr "5. Every leaf learns every other leaf's loopback"
for n in $LEAVES; do
  missing=""
  for peer in $LEAVES; do
    [ "$peer" = "$n" ] && continue
    lo=$(leaf_lo "$peer")
    eos "$n" "show ip route ${lo}" | grep -q "$lo" || missing="$missing $lo"
  done
  if [ -z "$missing" ]; then
    pass "$n has all 3 remote leaf loopbacks"
  else
    fail "$n missing:$missing"
  fi
done

# ---------------------------------------------------------------------------
hdr "6. ECMP — two next-hops per remote leaf loopback"
for n in $LEAVES; do
  worst=99
  for peer in $LEAVES; do
    [ "$peer" = "$n" ] && continue
    lo=$(leaf_lo "$peer")
    # Count "via" lines in the route entry; two spines => two next-hops.
    paths=$(eos "$n" "show ip route ${lo}" | grep -c 'via ')
    [ "${paths:-0}" -lt "$worst" ] && worst=${paths:-0}
  done
  if [ "$worst" -ge 2 ]; then
    pass "$n installs $worst next-hops (minimum across remote leaves)"
  elif [ "$worst" -eq 1 ]; then
    fail "$n installs only 1 next-hop — ECMP not active (maximum-paths? multipath-relax?)"
  else
    fail "$n could not read next-hops"
  fi
done

# ---------------------------------------------------------------------------
hdr "7. Loopback-to-loopback reachability"
for n in $LEAVES; do
  src=$(leaf_lo "$n")
  ok=1
  for peer in $LEAVES; do
    [ "$peer" = "$n" ] && continue
    dst=$(leaf_lo "$peer")
    eos "$n" "ping ${dst} source ${src} repeat 2" | grep -q '0% packet loss' || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    pass "$n reaches all remote leaf loopbacks (sourced from $src)"
  else
    fail "$n cannot reach one or more remote leaf loopbacks"
  fi
done

# ---------------------------------------------------------------------------
hdr "8. MTU (informational — Session 6)"
VETH_MTU=$(docker exec "${P}-leaf1" ip -o link show eth1 2>/dev/null | sed -n 's/.*mtu \([0-9]*\).*/\1/p')
printf '  ----  leaf1 eth1 veth MTU: %s\n' "${VETH_MTU:-unknown}"
if eos leaf1 'ping 10.0.0.4 source 10.0.0.1 size 9000 df-bit repeat 2' | grep -q '0% packet loss'; then
  pass "9000-byte DF-bit ping leaf1 -> leaf4 succeeds"
else
  warn "9000-byte DF-bit ping fails — expected until Session 6 sets interface MTU"
fi

# ---------------------------------------------------------------------------
hdr "Result"
if [ "$FAILURES" -eq 0 ]; then
  printf '  \033[0;32mPhase 2 assertions passed.\033[0m\n'
  printf '  Next: docs/whiteboard/phase-2-underlay.md — 12 questions, cold.\n\n'
else
  printf '  \033[0;31m%d assertion(s) failed.\033[0m Do not proceed to Phase 3.\n\n' "$FAILURES"
  exit 1
fi
