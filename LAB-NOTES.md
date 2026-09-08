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
| Session 8 convergence — pings dropped on spine1 failure | |
| Session 8 convergence — pings dropped on spine1 restore | |

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

**Date:**

**Syntax I had to correct vs. the runbook** (EOS version/release quirks):

- _(one line each)_

**What changed vs. numbered underlay:**

**What didn't change:**

---

### Session 8 — Break it, verify, publish

**Date:**

**Convergence on spine1 failure:**

**Convergence on spine1 restore:**

**`verify-phase2.sh` result:**

**Whiteboard self-check score (from `docs/whiteboard/phase-2-underlay.md`):**

**What would make convergence faster, and what would you deploy in a GPU fabric:**

---

### What broke (Phase 2)

_(symptom → cause → fix, one line each. Include self-inflicted ones.)_

- 

---

Author: Claude (Cowork) / Anthropic
Model: claude-opus-5
Created: 2026-09-02 ET
Lineage: original

---
