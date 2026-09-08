# Phase 2 — Underlay: eBGP Leaf-Spine, ECMP, MTU

**Days 4–12. Eight sessions, ~2 hrs each, weekday afternoons.**
**Topology:** [`labs/02-underlay/`](../labs/02-underlay/) — 2 spine × 4 leaf
**Reference:** keep [`labs/02-underlay/README.md`](../labs/02-underlay/README.md) open
**Exit:** `scripts/verify-phase2.sh` passes, and you can whiteboard the whole design cold.

---

## The rule for this phase

**Whiteboard it before you configure it.** Every session opens with a "draw this cold"
prompt. Do it on paper, with the reference file closed. Then configure, then verify,
then compare what you drew against what the device says.

That order is not ceremony. The diagnosed problem behind this whole plan is that your
BGP/EVPN hands-on window was 2018–2020 and interviews are being lost on hesitation at
the fundamentals. Hesitation comes from having configured something without ever having
had to produce it from memory. Configuring first and understanding after feels faster
and builds nothing you can defend under questioning.

**Hand-configuring is allowed in this phase and this phase only.** Phase 3 converts all
of it to Ansible, and after that the rule is absolute.

---

## Two notes before you start

**On EOS syntax.** Config below is written for EOS 4.36. EOS sometimes reorganizes what
you type — for example it may render your `neighbor` statements inside an
`address-family ipv4` block. That is normal. After each config block run
`show running-config section bgp` and read back what the device actually kept. Getting
in the habit of verifying the config the device holds, rather than the config you
believe you sent, is worth more than the config itself.

**On saving your work.** Everything you type dies with `containerlab destroy`. To keep a
snapshot:

```bash
containerlab save -t underlay.clab.yml
```

That writes each node's running-config under `clab-p2-underlay/<node>/`. Commit those to
git at the end of a session. They are your record of what you built — and in Phase 3 they
become the target output your Ansible templates must reproduce.

---

# Session 1 (day 4) — Design cold, then stand it up

## Whiteboard first (20 min, reference closed)

Draw:

1. Six boxes. Every link. Label every interface on both ends.
2. Every /31, both sides.
3. Every loopback.
4. Every ASN.
5. Mark how many BGP sessions exist in total.

Then open `labs/02-underlay/README.md` and diff it against your drawing. **Write down
every discrepancy in `LAB-NOTES.md`** — those are your actual gaps, and they are worth
more than the parts you got right.

Answer before moving on: how many BGP sessions does this fabric have, and why is it not
15? (Answer at the bottom of this file.)

## Deploy

```bash
cd ~/life-os/repos/network-training/labs/02-underlay
time containerlab deploy -t underlay.clab.yml
```

**You should see:** six nodes, State `running`, ~90s. Record the time in `LAB-NOTES.md`.

Six cEOS nodes want ~12 GB. Check headroom with `free -h` if the deploy stalls.

## Verify the cabling before you trust it

```bash
containerlab inspect -t underlay.clab.yml
docker exec clab-p2-underlay-spine1 Cli -p 15 -c 'show interfaces status'
```

**You should see:** spine1 with `Et1`–`Et4`. Leaves with `Et1`–`Et2`.

Confirm one link is really where you think it is — LLDP is the honest check:

```bash
docker exec clab-p2-underlay-leaf3 Cli -p 15 -c 'show lldp neighbors'
```

**You should see:** `Et1` → spine1, `Et2` → spine2. If a leaf's neighbors are crossed,
you misread the topology file — fix your mental model now, not after BGP won't come up.

**Session 1 deliverable:** your whiteboard drawing photographed into the repo or its
discrepancies written into `LAB-NOTES.md`.

---

# Session 2 (day 5) — Interfaces and loopbacks

## Whiteboard first (10 min)

From memory: what three things must be true before two directly-connected routers can
ping each other's /31 addresses? (Not BGP — layer 3 adjacency.)

## Configure

Get onto a node:

```bash
docker exec -it clab-p2-underlay-leaf1 Cli
```

**leaf1:**

```
enable
configure
ip routing
!
interface Loopback0
   ip address 10.0.0.1/32
!
interface Ethernet1
   description spine1
   no switchport
   ip address 10.1.0.1/31
!
interface Ethernet2
   description spine2
   no switchport
   ip address 10.1.0.9/31
!
end
```

`ip routing` is global and required — without it EOS forwards nothing between L3
interfaces, and you will chase this for twenty minutes. `no switchport` converts the
port from L2 bridging to L3 routing.

Repeat for leaf2/3/4 with their addresses from the plan (`10.0.0.2` and `10.1.0.3` /
`10.1.0.11`, and so on).

**spine1:**

```
enable
configure
ip routing
!
interface Loopback0
   ip address 10.0.0.11/32
!
interface Ethernet1
   description leaf1
   no switchport
   ip address 10.1.0.0/31
!
interface Ethernet2
   description leaf2
   no switchport
   ip address 10.1.0.2/31
!
interface Ethernet3
   description leaf3
   no switchport
   ip address 10.1.0.4/31
!
interface Ethernet4
   description leaf4
   no switchport
   ip address 10.1.0.6/31
!
end
```

spine2 the same, with `10.0.0.12/32` and `10.1.0.8` / `.10` / `.12` / `.14`.

Type the descriptions. On a six-node fabric they feel like overhead; the first time you
troubleshoot at 2 a.m. they are the difference between thirty seconds and thirty minutes.

## Verify

```
show ip interface brief
```

**You should see:** every configured interface `up/up` with its address. `Management0`
also appears — ignore it, it is out of band.

```
ping 10.1.0.0
```

From leaf1, that reaches spine1 across the /31. **You should see:** 5/5.

Now the one that matters:

```
ping 10.0.0.11 source 10.0.0.1
```

**This should FAIL.** Loopbacks are not directly connected and nothing is advertising
them yet. If it succeeds, something is wrong with your understanding of the topology —
stop and find out what.

**Session 2 deliverable:** all 8 /31 links ping in both directions; every loopback ping
fails. Note both in `LAB-NOTES.md`.

---

# Session 3 (day 6) — eBGP sessions

## Whiteboard first (15 min)

Draw the BGP state machine from memory: Idle → Connect → Active → OpenSent →
OpenConfirm → Established. For each, name one reason a session gets stuck there.
Specifically: what does a session sitting in **Active** usually mean, versus **Idle**?

## Configure

**leaf1:**

```
configure
router bgp 65001
   router-id 10.0.0.1
   neighbor 10.1.0.0 remote-as 65000
   neighbor 10.1.0.0 description spine1
   neighbor 10.1.0.8 remote-as 65000
   neighbor 10.1.0.8 description spine2
end
```

**spine1:**

```
configure
router bgp 65000
   router-id 10.0.0.11
   neighbor 10.1.0.1 remote-as 65001
   neighbor 10.1.0.3 remote-as 65002
   neighbor 10.1.0.5 remote-as 65003
   neighbor 10.1.0.7 remote-as 65004
end
```

Note the shape: **spines peer with every leaf, leaves peer only with spines.** Leaves
never peer with each other. Peering is always to the directly-connected /31 address, not
the loopback — the underlay's job is to make loopbacks reachable, so it cannot depend on
them. (Overlay peering in Phase 4 *will* use loopbacks. That inversion is the point of
having two BGP layers.)

Set an explicit `router-id`. Left alone, EOS picks one, and a router-id that changes
across reboots is a class of bug you do not want to learn about the hard way.

## Verify

```
show ip bgp summary
```

**You should see, on a leaf:** two neighbors, State `Established`, uptime counting up,
`PfxRcd` currently 0 or blank — sessions are up but nobody is advertising anything yet.

Read the running config back:

```
show running-config section bgp
```

Compare against what you typed. If EOS moved your neighbors into an `address-family
ipv4` block, that is expected — note it in `LAB-NOTES.md` so it does not surprise you in
Phase 3 when Ansible generates it.

If a session is stuck:

```
show ip bgp neighbors 10.1.0.0 | include state|Last
show logging | include BGP
```

`Active` almost always means the TCP session cannot establish — check the /31 pings from
Session 2. `Idle` with an AS mismatch in the log means you typed the wrong `remote-as`.

**Session 3 deliverable:** 8 sessions Established (2 per leaf × 4 leaves). Paste
`show ip bgp summary` from one leaf and one spine into `LAB-NOTES.md`.

---

# Session 4 (day 7) — Advertise the loopbacks

## Whiteboard first (10 min)

Two ways to get a loopback into BGP: a `network` statement, or `redistribute connected`
with a route-map. Write the tradeoff before reading on. Which one can leak something you
did not intend, and why?

## Configure

On **every** node, add its own loopback:

```
configure
router bgp <asn>
   network <own loopback>/32
end
```

leaf1: `network 10.0.0.1/32` · spine1: `network 10.0.0.11/32` · and so on.

`network` is explicit — it advertises exactly what you name and nothing else. It requires
an exactly-matching route in the RIB, which the `/32` on `Loopback0` provides.
`redistribute connected` is fewer lines and will happily also advertise your /31s, your
management network, and anything else that appears later. Explicit beats convenient in a
fabric.

## Verify

From leaf1:

```
show ip bgp summary
```

**You should see:** `PfxRcd` now non-zero on both sessions.

```
show ip route bgp
```

**You should see:** five BGP-learned /32s — `10.0.0.2`, `.3`, `.4` (other leaves) and
`10.0.0.11`, `.12` (spines).

Look closely at one other leaf's route:

```
show ip route 10.0.0.4
```

**Right now it probably shows ONE next-hop.** That is expected and is Session 5's whole
subject. Do not fix it yet.

```
ping 10.0.0.4 source 10.0.0.1
```

**You should see:** 5/5. Full fabric reachability, loopback to loopback.

The `source` keyword matters. Without it EOS sources from the egress interface, so you'd
be testing /31 reachability, not loopback reachability. Sourcing from the loopback is
what proves the fabric actually does its job.

## Read the path

```
show ip bgp 10.0.0.4/32
```

**You should see:** the AS_PATH. From leaf1, leaf4's loopback arrives as `65000 65004` —
through a spine, then originated by leaf4. Two entries, one per spine, identical
AS_PATH.

**Session 4 deliverable:** full loopback-to-loopback reachability from every leaf to
every other leaf. Record the AS_PATH you observed.

---

# Session 5 (day 8) — ECMP, broken on purpose

## Whiteboard first (15 min)

Before configuring: BGP installs exactly **one** best path by default. Write down why —
what is BGP's origin and design goal, and how does that differ from an IGP's? Then: what
must be true about two paths before they can be installed as equal cost?

## Configure

On every node:

```
configure
router bgp <asn>
   maximum-paths 4 ecmp 4
end
```

`maximum-paths` sets how many equal-cost paths get installed into the RIB;
`ecmp` sets how many the forwarding hardware will use. On cEOS there is no hardware, but
configure both — on a real switch they are separate limits and conflating them is a
common miss.

## Verify

```
show ip route 10.0.0.4
```

**You should see:** two next-hops — one via `10.1.0.0` (spine1), one via `10.1.0.8`
(spine2). If you still see one, BGP is not treating them as equal — read on.

```
show ip bgp 10.0.0.4/32
```

**You should see:** both paths, one marked best, the other marked as an ECMP/multipath
member.

## Now break it deliberately

Change **spine2** to a different ASN:

```
configure
router bgp 65000
   shutdown
!
no router bgp 65000
router bgp 65005
   router-id 10.0.0.12
   maximum-paths 4 ecmp 4
   neighbor 10.1.0.9 remote-as 65001
   neighbor 10.1.0.11 remote-as 65002
   neighbor 10.1.0.13 remote-as 65003
   neighbor 10.1.0.15 remote-as 65004
   network 10.0.0.12/32
end
```

And on every leaf, update spine2's `remote-as` to `65005`.

Wait for the sessions to re-establish, then from leaf1:

```
show ip route 10.0.0.4
show ip bgp 10.0.0.4/32
```

**You should see:** back to **one** next-hop, even though `maximum-paths` is still 4.

**Why:** the two AS_PATHs are now `65000 65004` and `65005 65004`. Same *length*,
different *content*. BGP's multipath rule requires the AS_PATHs be identical, not merely
equal length. Half your fabric capacity just disappeared with no error message anywhere.

## Fix it

On every leaf:

```
configure
router bgp <asn>
   bgp bestpath as-path multipath-relax
end
```

```
show ip route 10.0.0.4
```

**You should see:** two next-hops again.

`multipath-relax` tells BGP to accept paths of equal length regardless of which ASNs
they traverse. It is required in any fabric where spines have distinct ASNs — which is
most real designs, because unique spine ASNs make troubleshooting AS_PATHs far easier at
scale.

**This is prime interview material.** "How would you troubleshoot a leaf-spine fabric
running at half its expected bandwidth with no errors logged?" You have now seen it, made
it happen, and fixed it. Write the whole sequence into `LAB-NOTES.md` while it is fresh.

Leave spine2 on 65005 and `multipath-relax` in place — it is the more realistic design.
Update `labs/02-underlay/README.md` to match, and say why in the commit message.

**Session 5 deliverable:** two next-hops per remote leaf loopback; the break/fix written
up.

---

# Session 6 (day 9) — MTU, measured not assumed

## Whiteboard first (10 min)

Define, without notes: interface MTU vs IP MTU vs TCP MSS. Then: on a VXLAN fabric, how
many bytes does the encapsulation add, and what does that do to the MTU you must
provision in the underlay? (Phase 4 depends on getting this right.)

## Measure the real MTU

Do not assume. containerlab does not document a default veth MTU, so find out:

```bash
docker exec clab-p2-underlay-leaf1 ip -d link show eth1
```

**You should see:** an `mtu <N>` value. Whatever it says is your ceiling. Record it in
`LAB-NOTES.md`.

Then check what EOS believes:

```
show interfaces Ethernet1 | include MTU
```

These can disagree. The container's veth is the physical truth; the EOS setting is a
software limit on top of it. **An EOS MTU above the veth MTU will be accepted and will
silently drop oversized packets** — exactly the failure mode that eats days in production.

## Configure

Set the interface MTU on every fabric-facing port, up to but not above the veth ceiling:

```
configure
interface Ethernet1-2
   mtu 9214
end
```

(On spines, `interface Ethernet1-4`.) If the veth ceiling is below 9214, use the ceiling
and note the discrepancy — an honest lab note beats a config that looks right.

## Prove it

```
ping 10.0.0.4 source 10.0.0.1 size 9000 df-bit repeat 5
```

`df-bit` sets Don't Fragment, so an oversized packet is dropped rather than quietly
fragmented — the only way to actually test a path MTU.

**You should see:** 5/5.

Now find the exact cliff:

```
ping 10.0.0.4 source 10.0.0.1 size 9200 df-bit repeat 2
```

Walk the size up until it fails. The last success is your real end-to-end path MTU.
Record the number.

Then break it on one end and watch the asymmetry:

```
configure
interface Ethernet1
   mtu 1500
end
```

Re-run the 9000-byte ping. Observe which direction fails and how it presents — small
pings still work, large ones do not, and BGP stays up the entire time. That signature —
"the network is up but large transfers hang" — is one of the most-asked troubleshooting
scenarios in data center interviews. Then set it back.

**Session 6 deliverable:** measured veth MTU, configured MTU, the exact size at which
DF-bit pings start failing, and a description of the mismatch signature.

---

# Session 7 (days 10–11) — Convert to BGP unnumbered

## Whiteboard first (20 min)

Before touching anything, answer from memory:

1. If a link has no IPv4 address, what address does the BGP session actually use?
2. Where does that address come from — who assigns it?
3. What has to happen for a next-hop learned over such a session to be usable for IPv4
   forwarding?
4. What operational problem is this solving? Count the addresses you had to plan,
   assign, document and keep unique in Session 2, then multiply by a 1,024-GPU pod.

## Save your work first

```bash
cd ~/life-os/repos/network-training/labs/02-underlay
containerlab save -t underlay.clab.yml
cd ~/life-os/repos/network-training
git add . && git commit -m "Phase 2: numbered eBGP underlay with ECMP and MTU verified"
git push
```

That snapshot is your before-picture. The commit history showing numbered → unnumbered
is itself portfolio material.

## Convert

Same cabling, same loopbacks, same ASNs. What changes: the /31s disappear and BGP peers
over IPv6 link-local addresses discovered by RFC 5549 / router advertisement.

On **leaf1**:

```
configure
interface Ethernet1-2
   no ip address
   ipv6 enable
!
router bgp 65001
   no neighbor 10.1.0.0
   no neighbor 10.1.0.8
   neighbor interface Et1-2 peer-group SPINES remote-as 65000
end
```

On **spine1**:

```
configure
interface Ethernet1-4
   no ip address
   ipv6 enable
!
router bgp 65000
   no neighbor 10.1.0.1
   no neighbor 10.1.0.3
   no neighbor 10.1.0.5
   no neighbor 10.1.0.7
   neighbor interface Et1-4 peer-group LEAVES remote-as 65001-65004
end
```

> **Verify this syntax against your build.** `neighbor interface` and the ASN-range form
> vary across EOS releases. If it is rejected, check `show running-config section bgp`
> after a partial attempt and consult
> `docker exec clab-p2-underlay-leaf1 Cli -p 15 -c 'show version'` against Arista's
> configuration guide for that train. Working out the correct syntax for the version in
> front of you is part of the exercise — do not paste past an error.

## Verify

```
show ip bgp summary
```

**You should see:** neighbors identified by *interface* rather than IP, State
Established.

```
show ip route 10.0.0.4
```

**You should see:** the same two next-hops — but expressed via interfaces and
link-local addresses rather than /31s. Same forwarding outcome, zero addresses planned.

```
ping 10.0.0.4 source 10.0.0.1
```

**You should see:** 5/5. Reachability is unchanged; only the underlay's addressing
disappeared.

## The point

You just deleted 16 IPv4 addresses of planning, documentation and drift risk from a
six-node fabric. Scale that to 1,024 GPUs and the argument makes itself. That is the
answer when someone asks why unnumbered — not "it's modern," but "here is the operational
cost it removes, and here is how the next-hop still resolves."

**Session 7 deliverable:** working unnumbered underlay, plus a written comparison in
`LAB-NOTES.md`: what changed, what didn't, and what you had to correct in the syntax.

---

# Session 8 (day 12) — Break it, verify, publish

## Failure injection

With the fabric up, from leaf1 run a continuous ping to leaf4's loopback. In another
terminal:

```bash
docker exec clab-p2-underlay-spine1 Cli -p 15 -c 'configure' -c 'interface Ethernet1' -c 'shutdown'
```

**Observe:** how many pings drop before traffic reroutes via spine2. Then `no shutdown`
and watch it restore. Record the loss in `LAB-NOTES.md`.

Then ask yourself — and write the answer — what would make that convergence faster, and
what would you actually deploy in a GPU fabric where a collective operation stalls the
whole job on packet loss? (BFD, timers, and their tradeoffs. This is a real interview
question.)

## Final verification

```bash
cd ~/life-os/repos/network-training
./scripts/verify-phase2.sh
```

Then the whiteboard self-check: [`whiteboard/phase-2-underlay.md`](whiteboard/phase-2-underlay.md).

## Publish

```bash
cd labs/02-underlay && containerlab save -t underlay.clab.yml
cd ~/life-os/repos/network-training
git add . && git commit -m "Phase 2: BGP unnumbered underlay, ECMP verified, MTU measured"
git push
```

Per the retention track in your brief: one of Sessions 5, 6 or 7 becomes a short
LinkedIn technical post. The ECMP break/fix is the strongest of the three — it is a real
failure mode, it has a crisp before/after, and most people who list "BGP" on a résumé
cannot explain it.

**Report back before Phase 3:** which sessions ran over 2 hours, what syntax you had to
correct, the convergence time you measured, and your whiteboard self-check score.

---

## Answer to Session 1

**Eight BGP sessions**, not 15. Every leaf peers with every spine (4 × 2 = 8). Leaves do
not peer with each other and spines do not peer with each other — that is the defining
property of a Clos fabric and the reason it scales linearly instead of quadratically.
15 would be a full mesh of six nodes (n(n−1)/2), which is what you are specifically
avoiding.

---
Author: Claude (Cowork) / Anthropic
Model: claude-opus-5
Created: 2026-09-08 ET
Lineage: original
---
