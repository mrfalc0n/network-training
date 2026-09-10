# Lab Notes

Running log. What broke, what fixed it, what surprised me. Written as I go, not after.
This file is portfolio material — an interviewer reading it learns more about how I
troubleshoot than the configs ever show. Keep it honest, including the dead ends.

---

## Environment of record

Fill in during Phase 1:

| Item                     | Value                                                |
| ------------------------ | ---------------------------------------------------- |
| Host                     | Windows 11 / WSL2 (`arcwise`)                        |
| WSL distro               | Ubuntu 26.04 LTS                                     |
| Kernel                   | 6.6.114.1-microsoft-standard-WSL2                    |
| Docker flavor            | Docker Desktop integration / native Engine in distro |
| Docker version           | Docker version 29.7.2, build a7dcaa6                 |
| containerlab version     | 0.79                                                 |
| cEOS-lab version         | 4.36.2F-49692818.4362F                               |
| Repo path                | /home/mrfalc0n/life-os/repos/network-training        |
| 2-node deploy wall-clock | 30.929s -                                            |

---

## Phase 1 — Environment

**Started:** 2026-__-__

### Log

- _(entry)_

### What broke

- _(symptom → cause → fix. One line each. Include the ones that were my own mistake.)_

### Surprises

- _(anything that did not behave the way 25 years of hardware networking predicted)_

---

---

## Phase 2 — Underlay (eBGP, ECMP, MTU, BGP unnumbered)

**Started:** 2026-09-08

### Measurements of record

Fill in as you go. These are the facts an interviewer would ask you to recall.

| Item | Value |
| ---- | ----- |
| 6-node deploy wall-clock | |
| RAM free before deploy (`free -h`) | |
| veth MTU (measured, Session 6) | 9214 |
| EOS configured MTU | 9214 |
| DF-bit ping cliff — last passing size (bytes) | 9214 |
| DF-bit ping cliff — first failing size (bytes) | 9215 |
| Session 8 convergence — pings dropped on spine1 failure | 0 (local link event, sub-ms) |
| Session 8 convergence — pings dropped on spine1 restore | 0 (path addition, non-disruptive) |

---

### Session 1 — Design cold, stand it up

**Date:**

**Deploy time:**

**Whiteboard discrepancies** (what I drew wrong vs. the README):

- _(one line each — these are your actual gaps)_

**Cabling verify — leaf3 LLDP:**

```
(paste show lldp neighbors output here)
```

---

### Session 2 — Interfaces and loopbacks

**Date:**

**Whiteboard answer** (what three things must be true before two routers can ping each other's /31?):

1.
2.
3.

**Result:** all 8 /31 links ping ✓ / loopback-to-loopback pings fail as expected ✓

---

### Session 3 — eBGP sessions

**Date:**

**`show ip bgp summary` — leaf1:**

```
(paste here)
```

**`show ip bgp summary` — spine1:**

```
(paste here)
```

**Sessions established:** ___ / 8

**EOS rendered config differently from what I typed?** (yes/no and what):

---

### Session 4 — Advertise loopbacks

**Date:**

**AS_PATH observed from leaf1 to leaf4 loopback (`10.0.0.4/32`):**

**Full loopback-to-loopback reachability:** ✓ / ✗

---

### Session 5 — ECMP

**Date:** 2026-09-08

**Next-hops for `10.0.0.4` from leaf1 (both spines, with and without `multipath-relax`):** 2 — via `10.1.0.0` (spine1 AS 65000) and `10.1.0.8` (spine2 AS 65005)

**Break/fix sequence:**

> Moved spine2 from AS 65000 to AS 65005. Updated all leaves' `remote-as` for spine2 to match.
> Sessions re-established. AS_PATHs to leaf4 became `65000 65004` (via spine1) and `65005 65004` (via spine2).
> Standard BGP multipath rule: AS_PATHs must be **identical** (not just equal length) for paths to be considered equal-cost.
> **Expected:** ECMP to break, one next-hop installed. **Actual:** EOS 4.36.2F installed both paths as ECMP without `multipath-relax` configured.
> Confirmed `multipath-relax` was absent from running-config. EOS 4.36.2F appears to have changed the default multipath comparison to length-only rather than exact AS_PATH match.
> Configured `bgp bestpath as-path multipath-relax` on all leaves anyway — it is correct production config and makes the behavior explicit regardless of EOS version defaults.

**Version note — unique spine ASNs:** Keeping spine2 on AS 65005 (unique per spine) rather than reverting to shared AS 65000. Unique spine ASNs make AS_PATH a useful troubleshooting handle at scale — a path through spine1 vs spine2 is distinguishable in `show ip bgp` output. Shared spine ASNs produce identical AS_PATHs and lose that signal. `multipath-relax` is required with unique spine ASNs; configured on all leaves.

---

### Session 6 — MTU

**Date:** 2026-09-08

**veth MTU from `ip -d link show eth1`:** 9214

**EOS `show interfaces Ethernet1 | include MTU`:** 9214

**Do they agree?** Yes — veth ceiling and EOS configured MTU are the same value. No silent drop risk on this build.

**DF-bit cliff:**

- `size 9214` → 5/5, `9194 bytes from` in responses (9214 − 20-byte IP header = 9194 ICMP bytes shown)
- `size 9215` → immediate local error: `message too long, mtu=9214` — packet rejected before it leaves the sending interface

**Mismatch failure signature** (interview-relevant pattern): when interface MTU is set below the configured EOS MTU, small pings succeed, large pings fail silently or return `message too long`, and BGP stays fully established throughout — the control plane looks healthy while the data plane is broken for jumbo frames. "Network is up but large transfers hang" is the symptom in production.

---

### Session 7 — BGP unnumbered

**Date:** 2026-09-08

**Syntax corrections vs. the runbook:**

- Runbook uses `neighbor interface Et1-2 peer-group SPINES remote-as 65000` range syntax — EOS 4.36.2F does not accept interface ranges for `neighbor interface`; each interface must be declared separately
- `ip address unnumbered Loopback0` is NOT needed and should not be on fabric interfaces — remove it
- `ipv6 unicast-routing` must be enabled globally on every node or ND does not populate the IPv6 neighbor table on Ethernet interfaces (sessions will not form)
- **Critical:** `neighbor SPINES next-hop address-family ipv6` alone is insufficient. The `originate` keyword is required: `neighbor SPINES next-hop address-family ipv6 originate`. Without it, the Extended Next-Hop capability is advertised and negotiated, but EOS does not actually encode outbound UPDATEs with IPv6 next-hops — it falls back to IPv4, fails with "IPv4 local address not available," and drops all outbound paths silently. Routes never reach the peer despite sessions showing Established and PfxAdv > 0.
- `bgp next-hop address-family ipv6` (global, without neighbor qualifier) under `address-family ipv4` is also required alongside the per-neighbor `originate` form

**Troubleshooting trail (worth keeping — this is what debugging BGP unnumbered actually looks like):**

Sessions came up but zero routes were exchanged. Extended Next-Hop Capability showed `advertised and received and negotiated` in `show bgp neighbors`. PfxAdv showed 1 on all nodes. `show ip bgp` only showed each node's own loopback. The outbound drop counter `IPv4 local address not available` was incrementing on every node. Tried in sequence: removing `ip address unnumbered`, adding `bgp next-hop address-family ipv6` globally, hard session resets, soft outbound resets — none fixed it. Root cause: `originate` keyword missing from the `next-hop address-family ipv6` command on all nodes. Adding it caused routes to flow immediately.

**What changed vs. numbered underlay:**

- No /31 addresses on Ethernet interfaces — fully unassigned
- BGP neighbors identified by interface (`neighbor interface Et1`) rather than IP address
- Sessions peer over IPv6 link-locals (`fe80::`) instead of /31 addresses
- `show ip bgp summary` shows link-local + interface as neighbor identifier
- Next-hops in the routing table are expressed as link-locals via interfaces rather than /31 IPs
- Required: `ipv6 unicast-routing`, `ipv6 enable` on interfaces, `bgp next-hop address-family ipv6 originate`

**What didn't change:**

- Same ASNs, same loopbacks, same `network` statements, same ECMP config
- Same `maximum-paths 4 ecmp 4` and `bgp bestpath as-path multipath-relax`
- Same MTU on all interfaces
- Full loopback-to-loopback reachability, same two next-hops per remote leaf loopback
- 16 IPv4 addresses eliminated from fabric link planning

---

### Session 8 — Break it, verify, publish

**Date:** 2026-09-10

**Convergence on spine1 failure:**

Test: 120-ping continuous sequence (1-second interval) from leaf1 loopback to leaf4 loopback. spine1:Ethernet1 (leaf1 uplink) shut during ping window. Result: **0 packets dropped**, 120/120 received, 0% loss.

Why: ECMP pre-installs two next-hops (via spine1 and spine2). A local link event causes EOS to detect the link-state change in hardware immediately (not via BGP hold-timer) and remove that next-hop from the ECMP group. Traffic hashing to spine2 was never interrupted; traffic hashing to spine1 shifted in sub-millisecond time. `bgp fast-external-fallover` (on by default) tears down the BGP session instantly on link-down, so the route withdrawal is also immediate. No packets were in flight long enough to be lost.

**Convergence on spine1 restore:**

**0 packets dropped.** Restoring the interface re-establishes the BGP session (typically 5–10s in cEOS) and adds spine1 back as a second ECMP next-hop. Path addition is non-disruptive — traffic via spine2 continues flowing while the second path is being added.

**`verify-phase2.sh` result:**

8/8 PASS — all nodes, CLI, loopbacks, BGP sessions, routes, ECMP (2 next-hops), reachability, 9000-byte MTU.

**Whiteboard self-check score (from `docs/whiteboard/phase-2-underlay.md`):**

Good — passed cold. Note: whiteboard self-checks should be revisited periodically as
later phases build on Phase 2 concepts. Hesitation on any Phase 2 question is a signal
to re-run the specific lab, not to move on.

**What would make convergence faster, and what would you deploy in a GPU fabric:**

In this test, convergence was already effectively instantaneous because it was a local link event — EOS detects the physical link-down in hardware and removes the next-hop without waiting for any timer. The 0-drop result is not typical of all failure modes:

- **Remote failure (link between spine and a far leaf):** leaf1 does not detect the link-down directly. Detection happens via BGP hold-timer expiry — 90 seconds by default on EOS. During those 90 seconds, spine1 continues advertising the failed leaf's routes with no indication they are unreachable. Traffic blackholes silently.

- **Fix: BFD** (Bidirectional Forwarding Detection). Sub-second detection independent of the physical layer. EOS default: 300 ms detection (100 ms interval × 3 multiplier). BFD signals BGP immediately when it loses hellos, triggering session tear-down and route withdrawal in milliseconds rather than 90 seconds.

- **Tradeoff:** aggressive BFD timers consume control-plane CPU. Under heavy load, a switch can fail BFD intervals without an actual forwarding failure, triggering false positives. You tune rather than minimize — 100 ms × 3 is a production-typical starting point.

**For a GPU fabric specifically (RoCEv2/RDMA):** the 0-drop-on-local-link result is necessary but not sufficient. A collective operation (AllReduce, AllGather) stalls the entire job on the slowest participant — even a single dropped packet forces a full go-back-N retransmit at the RDMA layer, which stalls all ranks. So the production answer is not just "fast convergence" but "lossless forwarding":

1. **PFC (Priority Flow Control):** pause a priority class before dropping, so RoCE traffic never sees loss from congestion. EOS supports per-priority PFC on the lossless class.
2. **ECN/WRED:** mark congestion early (ECN) so DCQCN throttles senders before queues fill to the PFC trigger point. PFC is the backstop, not the mechanism.
3. **DSCP-to-queue mapping:** RoCE traffic (DSCP 26 or similar) lands in the lossless class end-to-end.
4. **ECMP entropy:** RoCE flows are few, long, and high-bandwidth — standard 5-tuple hashing polarizes. UDP source-port entropy (Arista default in recent EOS) and adaptive routing address this.

None of this is verifiable in containerlab — no ASIC, no real buffer, no true backpressure. The lab proves the config is correct; only real hardware proves it behaves. That boundary should be stated before an interviewer finds it.

---

### What broke (Phase 2)

_(symptom → cause → fix, one line each. Include self-inflicted ones.)_

- 

---

## Phase 3 — Ansible (roles, Jinja2 templates, inventory)

**Started:** 2026-09-10

### Sessions

#### Session 1 — Install, inventory, connectivity

**Date:**

**Ansible version:**

**eAPI connectivity verified:** ✓ / ✗

**Any gotchas hitting the nodes:**

---

#### Session 2 — Variables (group_vars, host_vars)

**Date:**

**Variable design decisions:** (any choices you made about structure that aren't obvious)

---

#### Session 3 — eos_base and eos_interfaces roles

**Date:**

**changed= on first run:**

**changed= on second run (idempotency):**

**Any non-idempotent task and why:**

---

#### Session 4 — eos_bgp role

**Date:**

**Template approach chosen:**

**changed= on second run:**

**verify-phase2.sh result:**

---

#### Session 5 — Diff and validate

**Date:**

**Functional diffs between Ansible-gen and numbered-final:**

**check mode result:**

---

#### Session 6 — Gate: cold deploy + playbook

**Date:**

**Playbook run against fresh fabric:**

**verify-phase2.sh result:**

---

### What broke (Phase 3)

_(symptom → cause → fix)_

-

---

Author: Claude (Cowork) / Anthropic
Model: claude-opus-5
Created: 2026-09-02 ET
Lineage: original

---
