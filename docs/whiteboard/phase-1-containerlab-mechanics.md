# Whiteboard Self-Check — Phase 1: Lab Mechanics

**Method:** cover this file. Draw or say the answer out loud, cold, no notes. Then
uncover and compare. Anything you hedged on gets re-read and re-tested in the lab
today, not "later."

Why this matters for interviews: nobody asks "what is containerlab." They ask *"how did
you build your lab?"* and then follow the thread. If the answer is "I ran a tool," the
thread dies and so does the credibility. If the answer is namespaces, veth pairs, and
where the boundary between the container and the kernel sits, you've just demonstrated
Linux networking fluency — which is the actual job at a GPU cloud.

---

## Q1. What is a Linux network namespace, and what does a container have to do with it?

<details><summary>answer</summary>

A network namespace is a private copy of the kernel's entire network stack: its own
interfaces, routing table, ARP/neighbor table, iptables/nftables rules, and socket
space. Processes inside it can only see that stack.

A container is a process (or process tree) placed into a set of namespaces — network
being one of several (also PID, mount, UTS, IPC, user). "Container" is packaging; the
isolation is the namespaces.

**Map to what you know:** a network namespace is close to a VRF, but stronger. A VRF
partitions the routing/forwarding tables. A namespace partitions the interfaces, the
sockets, and the firewall state too. A VRF is L3 separation; a namespace is a whole
separate stack.
</details>

---

## Q2. What is a veth pair and why does containerlab need one per link?

<details><summary>answer</summary>

A veth (virtual ethernet) pair is two interfaces created together and permanently
bonded: a frame written into one end comes out the other. It is a virtual patch cable.

containerlab creates one veth pair per `links:` entry, then moves one end into each
node's network namespace and renames it to whatever the topology asked for
(`eth1`, `eth2`, …). That is the physical layer of the lab. There is no bridge, no
switch, and no packet inspection in the middle — kernel-to-kernel, point to point.

**Consequence worth stating in an interview:** because they're real kernel interfaces,
`tcpdump` works on them, MTU applies to them, and a mismatched MTU on one end breaks
things exactly the way it would on real fiber. The lab reproduces MTU bugs faithfully,
which is why Phase 2 uses it to prove MTU sizing rather than assert it.
</details>

---

## Q3. Trace what happens, in order, from `containerlab deploy -t two-node.clab.yml` to a booted lab.

<details><summary>answer</summary>

1. Parse the YAML; resolve `kinds` defaults into each node.
2. Verify each referenced image exists locally; pull it if the kind allows pulling
   (`ceos:lab` cannot be pulled — it must already be imported, which is why a tag typo
   fails here).
3. Create the lab's Docker network (`clab` bridge, default `172.20.20.0/24`) if absent.
4. Start each container, attached to that management bridge as `eth0`.
5. For each `links:` entry, create a veth pair and move one end into each container's
   namespace, renaming to the endpoint name.
6. Run any `exec:` commands inside the containers.
7. Write a runtime directory `clab-<labname>/` holding per-node config mounts, an
   inventory, and the topology export.
8. Print the summary table.

**The management/data split is the part people miss:** `eth0` is the Docker management
bridge — it is how you reach the node, and it is *not* part of the fabric you're
designing. Data-plane links are `eth1+`. In EOS those appear as `Management0` and
`Ethernet1+` respectively. Conflating them is how people accidentally "prove" a fabric
works when traffic was actually going out of band.
</details>

---

## Q4. `docker import` vs `docker load` vs `docker pull` — which does cEOS need, and why?

<details><summary>answer</summary>

- `docker pull` — fetch a built image from a registry. Not available for cEOS; Arista
  gates it behind login, not a public registry.
- `docker load` — read an archive that already contains image layers plus metadata
  (produced by `docker save`).
- `docker import` — read a **flat filesystem tarball** and wrap it as a single-layer
  image with no metadata.

Arista ships cEOS-lab as a flat filesystem tarball, so `docker import` is correct.
That is also why you must supply the tag yourself (`ceos:4.32.2F`) — there's no embedded
metadata to name it.

**Why the second tag:** `docker tag ceos:4.32.2F ceos:lab` creates an alias. Topology
files reference `ceos:lab` so that upgrading the image is one `docker tag`, not a
find-and-replace across every lab in the repo. A tag is a pointer; there's still only
one ~2 GB copy on disk.
</details>

---

## Q5. Why does cEOS-lab older than 4.32.0F fail on WSL2?

<details><summary>answer</summary>

cEOS's init expects **cgroups v1**. WSL2's modern kernel presents **cgroups v2**
(unified hierarchy). The container starts, init can't find the v1 hierarchy it wants,
and it exits — which Docker's restart policy turns into a visible crash loop.

4.32.0F and later detect the cgroup version and adapt.

**Diagnostic value:** "container is Restarting in a loop" almost always means the
process inside is exiting during init. `docker logs <name>` is the first move, not
`docker inspect`.
</details>

---

## Q6. Why is Docker Desktop's WSL integration a risk for this lab, when a plain web app wouldn't care?

<details><summary>answer</summary>

With Docker Desktop, the daemon runs in its own hidden WSL distro, not in your Ubuntu.
Containers therefore live in *that* distro's network namespaces, behind Docker Desktop's
own NAT and iptables layer. For a normal container that only needs outbound internet and
a published port, this is invisible.

This lab is different: it manipulates namespaces and veth pairs directly and cares about
L2 adjacency between containers. Extra NAT/filtering hops in that path, and the split
between where the daemon runs and where your shell runs, are where "deployed fine but no
traffic" comes from.

Native Docker Engine inside your Ubuntu distro puts the daemon, the namespaces, and your
shell in one place. That is what upstream containerlab documentation assumes.
</details>

---

## Q7. `no switchport` — what actually changes on the interface?

<details><summary>answer</summary>

It moves the port from L2 bridging to L3 routing. As a switchport, the interface belongs
to a VLAN and frames are bridged by MAC; the port has no IP of its own. With
`no switchport`, it becomes a routed interface: it gets its own IP, participates in the
routing table directly, and MAC learning on it stops mattering.

**Where this goes in Phase 2:** a leaf-spine underlay is all routed point-to-point links
— every spine-facing port on every leaf is `no switchport`. That's what makes ECMP work
at L3 instead of relying on L2 loop-prevention. It is also the setup for BGP unnumbered,
where those routed links carry BGP sessions over IPv6 link-local addresses and never get
an IPv4 /30 at all.
</details>

---

## Q8. Someone says "your containerlab work isn't real networking, it's simulated." Answer in 30 seconds.

<details><summary>answer</summary>

It isn't simulated — it's the actual Linux kernel forwarding actual packets between
actual network namespaces over veth pairs, and for the cEOS nodes it's the shipping EOS
control plane, the same image and same CLI as the hardware, running its real BGP and
EVPN implementations.

What's absent is the ASIC: no real line-rate forwarding, no hardware buffers, no real
PFC backpressure or ECN marking under load. So the lab is authoritative for **control
plane and configuration correctness** — BGP state machines, EVPN route types, RD/RT
handling, config generation — and it is *not* authoritative for **performance or
congestion behavior**. That's exactly why Phase 6 rents real H100 nodes with InfiniBand
to get the congestion-side data.

**Say the limitation before they find it.** Knowing precisely what your lab does and does
not prove is a stronger signal than the lab itself.
</details>

---

## Scoring

- **8/8 clean:** proceed to Phase 2.
- **6–7:** re-read the misses, then re-run the failing verification in the lab today.
- **≤5:** the environment is up but the mechanics aren't yours yet. Redo the smoke test
  and watch `ip -br addr`, `docker logs`, and `tcpdump` on the veth while it runs. The
  understanding comes from watching it, not from reading this file again.

---
Author: Claude (Cowork) / Anthropic
Model: claude-opus-5
Created: 2026-09-02 ET
Lineage: original
---
