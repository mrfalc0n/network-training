# Phase 1 — Acceptance Criteria

Phase 1 is complete when every row below is checked with evidence you have actually
seen on your own screen. "It should work" is not evidence.

---

## Gate A — Environment

| # | Assertion | Command | Expected |
|---|---|---|---|
| A1 | Running inside WSL2 | `uname -r` | contains `microsoft-standard-WSL2` |
| A2 | Repo is on the Linux filesystem, not `/mnt/c` | `pwd` | starts with `/home/`, not `/mnt/` |
| A3 | Docker daemon reachable | `docker info \| head -3` | prints Client + Server blocks, no socket error |
| A4 | Docker flavor identified | `docker info --format '{{.OperatingSystem}}'` | you know whether it says "Docker Desktop" |
| A5 | containerlab installed | `containerlab version` | a `version:` line |
| A6 | ≥5 GB free at repo root | `df -h .` | Avail ≥ 5G |

---

## Gate B — Smoke test (plumbing)

| # | Assertion | Command | Expected |
|---|---|---|---|
| B1 | Both Alpine nodes running | `docker ps --format '{{.Names}}\t{{.Status}}'` | `clab-smoke-n1` and `-n2`, Up |
| B2 | veth landed in the namespace | `docker exec clab-smoke-n1 ip -br addr` | `eth1` present, `10.0.0.1/30`, state UP |
| B3 | Packets cross the virtual cable | `docker exec clab-smoke-n1 ping -c 3 10.0.0.2` | 0% packet loss |
| B4 | The cable is real, not simulated | `docker exec clab-smoke-n2 timeout 5 tcpdump -ni eth1 icmp` while B3 runs in another shell | ICMP echo request/reply printed |
| B5 | Teardown is clean | `containerlab destroy -t smoke.clab.yml --cleanup` then `docker ps` | no `clab-smoke-*` containers remain |

B4 is optional but worth doing once. Watching real ICMP on a veth is the moment
containerlab stops feeling like a simulator.

---

## Gate C — cEOS (the actual NOS)

| # | Assertion | Command | Expected |
|---|---|---|---|
| C1 | Image imported and tagged | `docker images \| grep ceos` | `ceos:4.32.xF` and `ceos:lab`, same IMAGE ID |
| C2 | Version is 4.32.0F or newer | as above | cgroups v2 compatibility |
| C3 | Both nodes running | `docker ps --format '{{.Names}}'` | `clab-p1-ceos-leaf1`, `clab-p1-ceos-leaf2` |
| C4 | Not crash-looping | `docker ps --format '{{.Names}}\t{{.Status}}'` | Status shows a steadily increasing "Up N minutes", no "Restarting" |
| C5 | EOS CLI answers | `docker exec -it clab-p1-ceos-leaf1 Cli` then `show version` | version banner matches the imported image |
| C6 | veth presented as a front-panel port | `show interfaces status` | `Et1` listed |
| C7 | Management reachability | `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' clab-p1-ceos-leaf1` | an address in `172.20.20.0/24` |
| C8 | Automated assertions pass | `./scripts/verify-phase1.sh ceos` | all PASS, no FAIL |

---

## Gate D — Optional data-plane proof (section 8)

| # | Assertion | Expected |
|---|---|---|
| D1 | `Ethernet1` configured `no switchport` + `/30` on both leaves | `show ip interface brief` shows the address, protocol up |
| D2 | `ping 10.1.1.2` from leaf1 | 5/5, sub-millisecond |
| D3 | `show interfaces Ethernet1 counters` on both ends | TX on one side matches RX on the other |

D3 is the one that would actually satisfy a skeptical interviewer — it proves you
verified rather than assumed.

---

## Gate E — Repo hygiene

| # | Assertion | Command | Expected |
|---|---|---|---|
| E1 | No runtime artifacts staged | `git status --short` | no `clab-*/` directories listed |
| E2 | No image files staged | `git status --short` | no `.tar.xz` |
| E3 | Scripts are executable in git | `git ls-files -s scripts/` | mode `100755`, not `100644` |
| E4 | Work is pushed | `git log --oneline -1` and `git status -sb` | branch is not ahead of `origin/main` |
| E5 | `LAB-NOTES.md` records the cEOS version and anything that broke | read it | non-empty |

The Phase 1 scaffold was pushed through the GitHub API, which cannot set the executable
bit — so E3 **will** fail on your first check. Fix it once:

```bash
git update-index --chmod=+x scripts/check-env.sh scripts/verify-phase1.sh
git commit -m "Mark scripts executable"
git push
```

---

## Exit

When Gates A, B, C and E are green, Phase 1 is done. **Stop there.**

Phase 2 (BGP unnumbered leaf-spine, ECMP, MTU) has not been built and is gated on
your review of this phase. Bring back:

1. Which gates failed on the first attempt and why.
2. Your Docker flavor (Desktop vs native Engine) — it changes Phase 2's assumptions.
3. The cEOS version you imported.
4. Wall-clock time for a 2-node deploy — it sets the ceiling on Phase 2 topology size.

---
Author: Claude (Cowork) / Anthropic
Model: claude-opus-5
Created: 2026-09-02 ET
Lineage: original
---
