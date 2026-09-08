# Phase 2 Underlay — Design and Addressing Plan

2 spine × 4 leaf. Routed point-to-point links, eBGP underlay, ECMP across both spines.
The procedure is in [`../../docs/02-phase-2-underlay.md`](../../docs/02-phase-2-underlay.md).
This file is the reference you keep open while configuring.

---

## Physical

```
            spine1 (AS 65000)            spine2 (AS 65000)
            /    |    |    \             /    |    |    \
          Et1   Et2  Et3   Et4         Et1   Et2  Et3   Et4
           |     |    |     |           |     |    |     |
          Et1   Et1  Et1   Et1         Et2   Et2  Et2   Et2
         leaf1 leaf2 leaf3 leaf4      leaf1 leaf2 leaf3 leaf4
        (65001)(65002)(65003)(65004)
```

Rules that make this readable:

- **On any leaf:** `Ethernet1` faces spine1, `Ethernet2` faces spine2.
- **On any spine:** `Ethernet<N>` faces `leaf<N>`.
- No leaf-to-leaf links. No spine-to-spine links. Every leaf-to-leaf path is exactly
  two hops and there are exactly two of them.

---

## Loopbacks

`Loopback0` is the router's identity: the BGP router-id, the BGP source, and in Phase 4
the VXLAN tunnel source. It is the only address that must be reachable fabric-wide.

| Node | Loopback0 | ASN |
|---|---|---|
| spine1 | 10.0.0.11/32 | 65000 |
| spine2 | 10.0.0.12/32 | 65000 |
| leaf1 | 10.0.0.1/32 | 65001 |
| leaf2 | 10.0.0.2/32 | 65002 |
| leaf3 | 10.0.0.3/32 | 65003 |
| leaf4 | 10.0.0.4/32 | 65004 |

---

## Point-to-point links — `10.1.0.0/28`

/31s, per RFC 3021. A /30 wastes two addresses per link on a network address and a
broadcast address that a point-to-point link has no use for. At fabric scale that is
half your address space.

**Convention: spine takes the even address, leaf takes the odd.** Deviating from that
costs you an hour someday.

| Link | Subnet | Spine side | Leaf side |
|---|---|---|---|
| spine1 Et1 ↔ leaf1 Et1 | 10.1.0.0/31 | 10.1.0.0 | 10.1.0.1 |
| spine1 Et2 ↔ leaf2 Et1 | 10.1.0.2/31 | 10.1.0.2 | 10.1.0.3 |
| spine1 Et3 ↔ leaf3 Et1 | 10.1.0.4/31 | 10.1.0.4 | 10.1.0.5 |
| spine1 Et4 ↔ leaf4 Et1 | 10.1.0.6/31 | 10.1.0.6 | 10.1.0.7 |
| spine2 Et1 ↔ leaf1 Et2 | 10.1.0.8/31 | 10.1.0.8 | 10.1.0.9 |
| spine2 Et2 ↔ leaf2 Et2 | 10.1.0.10/31 | 10.1.0.10 | 10.1.0.11 |
| spine2 Et3 ↔ leaf3 Et2 | 10.1.0.12/31 | 10.1.0.12 | 10.1.0.13 |
| spine2 Et4 ↔ leaf4 Et2 | 10.1.0.14/31 | 10.1.0.14 | 10.1.0.15 |

Reading the table: spine1's links occupy `10.1.0.0`–`10.1.0.7`, spine2's occupy
`10.1.0.8`–`10.1.0.15`. Leaf *N* sits at `(N-1)*2 + 1` on spine1 and `+8` on spine2.

---

## AS numbering

Private ASN range 64512–65534, per RFC 7938 ("Use of BGP for Routing in Large-Scale
Data Centers").

- **Both spines share AS 65000.** RFC 7938's recommendation for a single pod. Spines
  never peer with each other, so a shared ASN costs nothing and it keeps AS_PATHs
  identical across the two paths — which is what makes ECMP work without extra config.
- **Each leaf gets a unique ASN**, 65001–65004. Unique per leaf is what prevents a
  route from looping back into the leaf that originated it: BGP's own AS_PATH loop
  prevention does the work, no filtering required.

**Why eBGP and not OSPF/IS-IS?** In a Clos fabric the topology is regular and known in
advance, so a link-state protocol's ability to compute arbitrary topologies buys you
nothing — and its flooding domain grows with the fabric. eBGP gives you explicit
per-hop policy control, trivial multi-vendor interop, one protocol for underlay and
overlay, and AS_PATH as a free loop-prevention and traffic-engineering handle. Every
hyperscaler landed here independently. Be ready to say this in an interview; it is
asked constantly.

---

## What "good" looks like when this is finished

From any leaf:

- 2 BGP sessions, both `Established`
- 5 remote loopbacks in the RIB (2 spines + 3 other leaves)
- Every remote **leaf** loopback installed with **two** next-hops (one per spine)
- Every **spine** loopback installed with one next-hop (directly connected)
- `ping <any remote loopback> source <own loopback>` succeeds
- A 9000-byte DF-bit ping succeeds once MTU is set (Session 6)

If a leaf loopback shows only one next-hop, ECMP is broken. Session 5 covers why, on
purpose.

---
Author: Claude (Cowork) / Anthropic
Model: claude-opus-5
Created: 2026-09-08 ET
Lineage: original
---
