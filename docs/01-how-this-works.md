# How This Lab Actually Works

Written after Phase 1 came up, while the confusion was still fresh. If you are coming
from hardware networking and containers are new, read this once — it prevents a whole
class of wrong assumptions later.

---

## The stack

```
Windows 11
  └─ WSL2 .............. ONE real Linux kernel, shared by everything below
       ├─ dockerd ....... the container engine; creates containers on request
       ├─ containerlab .. an ordinary program; tells dockerd what to build
       └─ your shell .... where you type
```

**containerlab does not run inside Docker.** It sits beside Docker and gives it orders.
You run `containerlab deploy`, it reads the YAML topology, instructs the Docker engine
to create the containers, wires them together with virtual cables, and then **exits**.
It is not running while your lab is up. The containers just run. containerlab comes back
only when you ask it to inspect or destroy.

The useful analogy: containerlab is the cabling contractor. It arrives with a floor plan
(the `.clab.yml`), racks the gear, runs the patch cables, and leaves. The network keeps
running without it.

---

## Containers are not VMs

This is the assumption most worth correcting, and it is what makes the lab credible.

| | Virtual machine | Container |
|---|---|---|
| Kernel | Its own | **Shares the host's** |
| Boot | Full boot sequence | None — processes just start |
| Virtual hardware | Emulated CPU, NIC, disk | None |
| Startup | Tens of seconds | Milliseconds |
| Isolation mechanism | Hypervisor | Kernel **namespaces** |

A container is a set of processes running on the host kernel that have been handed a
private view of certain resources. Namespaces are the kernel feature that does the
partitioning:

| Namespace | What it partitions | Closest analogue from enterprise networking |
|---|---|---|
| **network** | Interfaces, routing table, ARP/neighbor table, firewall rules, sockets | A VRF — but stronger. A VRF partitions routing/forwarding. A namespace also partitions interfaces, sockets and firewall state. |
| mount | Which filesystem the processes see | — |
| PID | Which processes are visible | — |
| UTS | Hostname | — |

So `clab-smoke-n1` was: a couple of processes running on the WSL2 kernel, with their own
network stack and their own filesystem view. "Alpine" is just the filesystem contents —
a stripped-down Linux distribution, about 5 MB. No second kernel. No boot.

---

## The physical layer: veth pairs

A **veth pair** is a virtual patch cable. Two interfaces created together and permanently
bonded — whatever enters one end exits the other.

For each entry under `links:` in a topology, containerlab:

1. creates a veth pair,
2. moves one end into node A's network namespace,
3. moves the other end into node B's network namespace,
4. renames both to whatever the topology asked for (`eth1`, `eth2`, …).

That is the entire physical layer of the lab. No bridge, no virtual switch, nothing
inspecting packets in between. Kernel to kernel, point to point.

**Why this matters:** when the smoke test pinged `10.0.0.2`, that packet was forwarded by
the actual Linux kernel between two actual network namespaces over an actual veth pair.
Not a simulator approximating a network — the same kernel code path that moves packets on
a real Linux router.

Consequences worth being able to state out loud:

- `tcpdump` works on these interfaces, because they are real interfaces.
- MTU applies. A mismatch breaks things exactly the way it does on fiber — which is why
  Phase 2 can *prove* MTU sizing rather than assert it.
- Anything the Linux kernel can do to a packet, this lab can do to a packet.

---

## Naming conventions

containerlab names every container `clab-<labname>-<nodename>`:

| Topology | Lab name | Nodes | Containers |
|---|---|---|---|
| `labs/00-smoke-test/smoke.clab.yml` | `smoke` | `n1`, `n2` | `clab-smoke-n1`, `clab-smoke-n2` |
| `labs/01-two-node-ceos/two-node.clab.yml` | `p1-ceos` | `leaf1`, `leaf2` | `clab-p1-ceos-leaf1`, `clab-p1-ceos-leaf2` |

The smoke test was **one lab with two nodes and one link** — not two labs.

---

## Management plane vs data plane

Every containerlab node gets **two kinds of interface**, and confusing them is a classic
self-inflicted wound:

| Interface | Purpose | In EOS |
|---|---|---|
| `eth0` | Docker's management bridge (`172.20.20.0/24`) — how you reach the node | `Management0` |
| `eth1`, `eth2`, … | The veth ends — the fabric you are actually designing | `Ethernet1`, `Ethernet2`, … |

`eth0` is **out of band**. It is not part of your topology. People "prove" a fabric works
and later discover traffic was going out the management bridge the whole time. When
verifying reachability in Phase 2 and beyond, confirm the path, not just the reply.

---

## Deploy and destroy

```bash
containerlab deploy  -t <file>.clab.yml            # build it
containerlab destroy -t <file>.clab.yml --cleanup  # tear it down
```

`destroy` stops the containers and removes the `clab-<labname>/` runtime directory. It
does **not** touch the topology file. Redeploy and you get an identical lab in seconds.

**Containers are disposable. The YAML is what persists.** That inversion is the whole
point of the repo: the lab is defined by text under version control, so it is
reproducible by anyone, on any machine, from a clean checkout. Expect to destroy and
redeploy constantly. Never treat a running container as something you are protecting.

---

## Where cEOS fits

Identical mechanism, bigger container. Instead of 5 MB of Alpine, the filesystem holds
the full Arista EOS userland — the same software that ships on their hardware. It starts
its real control plane: the actual BGP daemon, the actual EVPN implementation, the actual
CLI. Still no kernel of its own. Still receives its interfaces as veth ends.

What is missing is the **ASIC**: no hardware forwarding, no real packet buffers, no true
PFC backpressure or ECN marking under load.

So this lab is authoritative for:

- **control plane correctness** — BGP state machines, EVPN route types 1–5, RD/RT
  handling, symmetric vs asymmetric IRB behavior
- **configuration correctness** — what the generated config does, and whether it converges

and it is **not** authoritative for:

- **performance** — throughput, latency, buffer occupancy
- **congestion behavior** — how PFC and ECN actually respond under load

That second list is precisely why the Phase 6 capstone rents real H100 nodes with
InfiniBand. Being able to name that boundary unprompted is a stronger signal in an
interview than the lab itself.

---
Author: Claude (Cowork) / Anthropic
Model: claude-opus-5
Created: 2026-09-02 ET
Lineage: original
---
