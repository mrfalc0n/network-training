# Whiteboard Self-Check — Phase 2: eBGP Underlay

**Method:** cover the file. Answer out loud or on paper, cold, no notes and no lab.
Then uncover and compare. Anything you hedged on gets re-tested in the lab the same day.

These are written the way they get asked in a screen. Answer them the way you would there
— out loud, in complete sentences, without trailing off.

---

## Q1. Draw a 2-spine, 4-leaf fabric. How many BGP sessions, and why isn't it 15?

<details><summary>answer</summary>

Eight. Every leaf peers with every spine: 4 × 2. Leaves never peer with leaves; spines
never peer with spines.

15 would be a full mesh of six nodes — n(n−1)/2. That is exactly what a Clos avoids.
Sessions grow as leaves × spines, not as nodes squared, which is why you can add leaves
linearly without touching the ones already there.
</details>

---

## Q2. Why eBGP for the underlay instead of OSPF or IS-IS?

<details><summary>answer</summary>

The topology is regular and known in advance, so a link-state protocol's ability to
compute arbitrary topologies buys nothing — and its flooding domain grows with the
fabric. eBGP gives:

- explicit per-hop policy control
- trivial multi-vendor interoperability
- AS_PATH as free loop prevention and a traffic-engineering handle
- **one protocol for underlay and overlay** — the overlay is EVPN, which is BGP anyway
- operational scale that is already proven at hundreds of thousands of routes

RFC 7938 is the reference. Every hyperscaler landed here independently, which is the
strongest argument available.

**Honest counterpoint, worth offering unprompted:** an IGP converges faster on link
failure and needs less configuration on a small fabric. In an enterprise pod of a dozen
switches, OSPF is a defensible choice. The eBGP case gets stronger as the fabric grows
and as the overlay arrives.
</details>

---

## Q3. Why a /31 instead of a /30 on point-to-point links?

<details><summary>answer</summary>

RFC 3021. A point-to-point link has exactly two endpoints and no need for a network
address or a broadcast address, so a /30 wastes half its space. A /31 gives you both
usable addresses.

At fabric scale this is not cosmetic: 1,024 point-to-point links is 4,096 addresses with
/30s versus 2,048 with /31s, plus a smaller, cleaner address plan to document.

And it is the setup for the better answer — with BGP unnumbered you provision **zero**
addresses on those links.
</details>

---

## Q4. Why does each leaf get a unique ASN while both spines can share one?

<details><summary>answer</summary>

**Unique per leaf** so BGP's own AS_PATH loop prevention does the work. A route that
originated on leaf1 and comes back toward leaf1 carries 65001 in its AS_PATH and is
dropped automatically. No filters, no route-maps, no maintenance.

**Shared across spines** is RFC 7938's recommendation within a pod: spines never peer
with each other, so there is no session for a shared ASN to break, and it prevents path
hunting during convergence.

The tradeoff: shared spine ASNs make AS_PATHs identical across paths, so ECMP works with
no extra config. Unique spine ASNs make troubleshooting far easier at scale — you can see
which spine a path traversed — but then you need `bestpath as-path multipath-relax` or
you silently lose half your capacity. Most production fabrics take unique spine ASNs and
accept the extra line.
</details>

---

## Q5. Why do underlay BGP sessions peer to interface addresses while overlay sessions peer to loopbacks?

<details><summary>answer</summary>

Ordering. The underlay's *job* is to make loopbacks reachable, so it cannot depend on
loopbacks being reachable — that is circular. It peers on directly-connected addresses,
which are up as soon as the link is up.

Once the underlay has done its job, every loopback is reachable over every available
path. The overlay then peers loopback-to-loopback, which makes those sessions
path-independent: a spine or a link can fail and the overlay session never notices,
because the underlay reroutes underneath it.

That separation of concerns is the whole reason the design has two BGP layers rather than
one.
</details>

---

## Q6. `maximum-paths` is set to 4 and both paths are in the BGP table, but only one is in the routing table. Why?

<details><summary>answer</summary>

The AS_PATHs differ. BGP's multipath rule requires the AS_PATHs be **identical**, not
merely the same length. `65000 65004` and `65005 65004` are both length 2 and are not
eligible for multipath.

Fix: `bgp bestpath as-path multipath-relax`, which relaxes the requirement to equal
length regardless of which ASNs are traversed.

**Why this matters operationally:** nothing logs an error. The fabric runs at half its
expected bandwidth and every `show` command looks healthy. You find it by noticing a
single next-hop where you expected two — which means you have to know what you expected.
</details>

---

## Q7. Interface MTU, IP MTU, TCP MSS — define each, and say what VXLAN does to your MTU budget.

<details><summary>answer</summary>

- **Interface MTU** — the largest L2 frame payload the port will transmit.
- **IP MTU** — the largest IP packet that can go out without fragmentation. Can be set
  below the interface MTU.
- **TCP MSS** — the largest TCP *segment*; negotiated per session, MTU minus IP and TCP
  headers (typically 40 bytes for IPv4).

**VXLAN adds roughly 50 bytes** — outer Ethernet (14) + outer IP (20) + UDP (8) + VXLAN
(8). So a tenant expecting a standard 1500-byte MTU needs at least 1550 in the underlay,
and a tenant expecting 9000 needs about 9050.

This is why fabrics are provisioned at 9214 rather than exactly what the workload asks
for: headroom absorbs the encapsulation without anyone having to compute it per tenant.

**Failure signature to be able to state:** MTU mismatch does not break the network. BGP
stays up, small pings work, ARP works. Only large transfers hang. If someone describes
"the network is fine but file transfers stall," MTU is the first thing to check —
with a DF-bit ping, since a normal ping fragments and hides the problem.
</details>

---

## Q8. BGP unnumbered — what address does the session actually use, and how does an IPv4 route resolve over it?

<details><summary>answer</summary>

The session runs over **IPv6 link-local** addresses (`fe80::/10`), which each interface
derives automatically — nothing is assigned or planned.

Neighbors are discovered by IPv6 Router Advertisement, so `neighbor interface Et1` is
enough: BGP finds whatever is on the far end.

IPv4 routes are carried over that IPv6 session using **RFC 5549** — advertising IPv4 NLRI
with an IPv6 next-hop. The receiving router resolves that next-hop to the link-local
address of the neighbor on that interface, which is directly connected and therefore
always resolvable. Forwarding is normal IPv4; only the control plane changed.

**The operational argument:** on a 1,024-node fabric you delete thousands of addresses
from planning, documentation, IPAM and drift risk. Configuration also becomes identical
on every leaf, which is what makes it templatable — the Phase 3 payoff.
</details>

---

## Q9. A leaf loses one uplink. Walk through what happens, in order.

<details><summary>answer</summary>

1. Link down is detected — physically, or by BFD, or on BGP hold-timer expiry (default 180s
   in EOS, which is far too slow to rely on).
2. The BGP session to that spine drops.
3. Every path learned via that spine is withdrawn from the leaf's BGP table.
4. Best-path selection reruns. The surviving spine's paths remain.
5. RIB and FIB update; ECMP for affected prefixes drops from two next-hops to one.
6. Traffic continues on the surviving spine at half the capacity.

**Convergence time depends entirely on step 1.** Physical link-down detection is
milliseconds. Hold-timer expiry is up to three minutes. In a GPU fabric that difference
is the difference between a hiccup and a failed training job, because a collective
operation stalls on the slowest participant.

**So you deploy BFD** — sub-second detection independent of the physical layer, which
matters because a link can be optically up while forwarding nothing. Tradeoff: aggressive
BFD timers cost CPU and can cause false positives under control-plane load, so you tune
rather than minimize.
</details>

---

## Q10. Why don't leaves peer directly with each other?

<details><summary>answer</summary>

Session count and blast radius. Direct leaf peering means n(n−1)/2 sessions — 6 for four
leaves, 4,950 for a hundred. Every new leaf would require touching every existing leaf,
which is the opposite of what a fabric is for.

The Clos property is that adding a leaf touches only the spines. Every leaf-to-leaf path
is exactly two hops, and there are as many equal-cost paths as there are spines. Uniform
latency, predictable capacity, linear growth.

The cost is that all traffic transits a spine, so spine capacity must be provisioned for
the aggregate — which is exactly the oversubscription-ratio conversation, and is why AI
fabrics are commonly built non-blocking (1:1) rather than the 3:1 an enterprise
tolerates.
</details>

---

## Q11. What in this underlay changes when it carries RoCEv2 instead of ordinary traffic?

<details><summary>answer</summary>

The topology and the routing do not change. What is added is **lossless behavior**, which
is Phase 5's subject:

- **PFC** on the priority handling RoCE, so congestion pauses that class rather than
  dropping it — RoCE's go-back-N recovery makes even slight loss catastrophic for
  throughput.
- **ECN/WRED thresholds** so switches mark congestion early and DCQCN throttles senders
  before queues fill and PFC has to trigger. PFC is the backstop, not the mechanism.
- **DSCP-to-queue mapping** so RoCE and CNP land in the right classes end to end.
- **ECMP entropy** — RoCE flows are few, long, and high-bandwidth, so standard 5-tuple
  hashing polarizes badly. That is what UDP source-port entropy and adaptive routing
  address.

**The honest caveat:** none of this is verifiable in containerlab. There is no ASIC, no
real buffer, no true backpressure. The lab proves the config is syntactically and
logically correct; only real hardware proves it behaves. Say that boundary out loud
before an interviewer finds it.
</details>

---

## Q12. Someone asks you to scale this design to 1,024 GPUs. What are the first three numbers you need?

<details><summary>answer</summary>

1. **GPUs per node and NICs per GPU.** 1,024 GPUs at 8 per node is 128 nodes; at one
   400G NIC per GPU that is 1,024 fabric ports before any uplinks. This sets everything
   downstream.
2. **Oversubscription target.** Non-blocking (1:1) is standard for AI training because a
   collective stalls on the slowest path. 1:1 means leaf uplink capacity equals leaf
   downlink capacity, which fixes your spine count.
3. **Radix of the switch you're allowed to buy.** Port count per box determines how many
   leaves a spine layer supports and whether you need a two-tier or three-tier Clos.

Then the design questions: rail-optimized versus standard Clos (which changes what
connects where entirely), InfiniBand versus Ethernet/RoCE, and the failure domain you are
willing to accept per spine.

Being able to name these three first — rather than starting from a product — is what
separates a fabric architect from someone who configures switches.
</details>

---

## Scoring

- **11–12 clean:** Phase 3 (Ansible). Your fundamentals are back.
- **8–10:** re-run the specific lab that covers each miss. Do not move on — this material
  is the actual moat, and hesitation here is what has been costing the interviews.
- **≤7:** repeat Sessions 3–6 from a destroyed lab, configuring from memory against the
  addressing plan only. The second build is where it becomes yours.

---
Author: Claude (Cowork) / Anthropic
Model: claude-opus-5
Created: 2026-09-08 ET
Lineage: original
---
