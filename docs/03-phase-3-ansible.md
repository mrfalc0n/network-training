# Phase 3 — Ansible: Roles, Templates, Inventory

**Days 13–18. Six sessions, ~2 hrs each, weekday afternoons.**
**Lab reused:** [`labs/02-underlay/`](../labs/02-underlay/) — same 2 spine × 4 leaf topology
**Ansible project:** [`ansible/`](../ansible/) — lives at the repo root, applies to all phases
**Exit:** destroy the lab, deploy with a minimal base config, run the playbook cold, `verify-phase2.sh` passes.

---

## The rule for this phase

**Hand-configuring is over.** From this point forward, every device config is generated
by Ansible. If you find yourself typing CLI commands on a switch to fix a problem, you are
working outside the system — the fix belongs in the playbook, not on the device.

**The target is known.** The `numbered-final/` configs you committed in Phase 2 are the
benchmark. Your Ansible templates must produce config that is functionally identical. When
the gate at the end of this phase runs `verify-phase2.sh` on a freshly deployed,
Ansible-configured fabric, it should pass clean.

---

## Concepts you will build, not just read

Ansible is not magic. Its execution model is:

1. Read an **inventory** — who are the managed nodes, what do we know about them?
2. Run a **playbook** — a list of roles and tasks to apply to those nodes.
3. Each **task** calls a **module** — a plugin that does one specific thing on the node.
4. **Roles** group related tasks and templates so you can reuse them.
5. **Templates** (Jinja2) render variables into text — in this case, EOS config blocks.

The analogy to what you already know: an inventory is your device list. A template is the
config template you would otherwise fill in by hand for each device. A role is a named
collection of "fill in this template and push it" steps. The playbook is the order you
run them.

The thing that makes this worth doing: once the templates exist, adding a new leaf means
adding one entry to the inventory and one file of variables. The playbook configures it.
No per-device typing. That is the Phase 4 payoff (EVPN overlay on a larger fabric).

---

## Connection method: eAPI over Management0

EOS exposes an HTTP API (`management api http-commands`). Your Phase 2 configs already
have it enabled. Ansible connects to each node's `Management0` address (the
`172.20.20.x` side, which is only reachable while the containerlab network is up) using
the `arista.eos.eos` network OS with `httpapi` transport. This is the standard approach
for EOS and does not require SSH keys.

---

# Session 1 (day 13) — Install, inventory, connectivity

## Whiteboard first (10 min, reference closed)

Answer on paper:

1. An Ansible playbook runs on a **control node** and manages **managed nodes** without
   installing any software on them. Draw the flow: control node → network → switches.
   What protocol does it use to reach an EOS switch?
2. What is an inventory? Name three things it can tell Ansible about a host.
3. What does "idempotent" mean? Give a one-sentence definition in your own words.

Check your answers against the concepts section above and the whiteboard self-check in
`docs/whiteboard/phase-3-ansible.md`. Do not skip this — Ansible's abstraction is
unfamiliar and the whiteboard questions surface the gaps before you hit them in config.

## Install Ansible and the EOS collection

In WSL:

```bash
pip install ansible ansible-pylibssh
ansible-galaxy collection install arista.eos ansible.netcommon
ansible --version
```

**You should see:** `ansible [core 2.x.x]` with a Python version line.

If `pip` installs to a user path that is not in `$PATH`, add it:

```bash
export PATH="$HOME/.local/bin:$PATH"
# add to ~/.bashrc so it persists
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

## Explore the project scaffold

The `ansible/` directory at the repo root is the Ansible project. Look at its structure:

```bash
ls -R ~/life-os/repos/network-training/ansible/
```

You will see empty skeletons. Your job this session is to fill in the inventory.

## Find the Management0 addresses

With the Phase 2 lab running:

```bash
cd ~/life-os/repos/network-training/labs/02-underlay
containerlab inspect -t underlay.clab.yml
```

**You should see:** the `IPv4/6 Address` column. Record all six `172.20.20.x` addresses.
Note which name maps to which IP — the order changes between deploys.

Alternatively:
```bash
docker inspect clab-p2-underlay-leaf1 | grep '"IPAddress"' | tail -1
```

## Write the inventory

Open `ansible/inventory/hosts.yml`. Fill in the actual Management0 IPs for each node.
The skeleton shows you the structure — you supply the values.

A few things to understand:
- `spines` and `leaves` are groups. The `fabric` group contains both.
- Variables in `group_vars/all.yml` apply to every host in the inventory.
- Variables in `group_vars/leaves.yml` apply only to the leaves group.
- Variables in `host_vars/leaf1.yml` apply only to leaf1. Host beats group when both define the same key.

## Verify connectivity

Before writing a single task or template, prove Ansible can reach every node:

```bash
cd ~/life-os/repos/network-training/ansible
ansible fabric -m arista.eos.eos_command -a "commands='show version'" -i inventory/hosts.yml
```

**You should see:** six JSON responses, each containing the EOS version string. If any
node returns an error, fix connectivity before moving on. Common failures:
- Wrong IP in hosts.yml — check `containerlab inspect`
- Wrong password — test with `curl -sk -u admin:<password> https://<IP>/command-api`
- eAPI returning HTTP instead of HTTPS — check `show management api http-commands` on the node

**Session 1 deliverable:** `ansible fabric -m arista.eos.eos_command ...` succeeds for all
six nodes. Record your admin password (wherever you keep credentials) — you will need it
every session.

---

# Session 2 (day 14) — Variables: group_vars and host_vars

## Whiteboard first (10 min)

From memory, using only the addressing plan in `labs/02-underlay/README.md`:

1. Write down leaf1's: loopback IP, ASN, Ethernet1 local IP, Ethernet1 remote IP, Ethernet1 remote ASN.
2. Write down spine1's: loopback IP, ASN, Ethernet3 local IP, Ethernet3 remote IP, Ethernet3 remote ASN.

This is what your variables must encode. If you cannot write it from memory, re-read the README
before continuing — the template cannot parametrize what you don't understand.

## Variable design

Before writing any file, design the variable schema. Ask:

- What is the same on every node? (MTU, max-paths, Ansible connection settings) → `group_vars/all.yml`
- What is the same on every leaf, different from spines? (multipath-relax, leaf peer-group name) → `group_vars/leaves.yml`
- What is the same on every spine? (spine peer-group name) → `group_vars/spines.yml`
- What is unique per node? (hostname, loopback IP, ASN, per-interface addresses, remote neighbor IPs and ASNs) → `host_vars/<node>.yml`

The per-interface neighbor data is the interesting part. Each leaf has two uplinks (one per
spine), each with a local IP, a remote IP, a remote ASN, and a description. Structure this
as a list of dicts so the template can loop over it:

```yaml
# host_vars/leaf1.yml (example structure — fill in the actual values)
bgp_asn: 65001
loopback_ip: "10.0.0.1"
fabric_links:
  - interface: Ethernet1
    description: spine1
    local_ip: "10.1.0.1/31"
    remote_ip: "10.1.0.0"
    remote_asn: 65000
  - interface: Ethernet2
    description: spine2
    local_ip: "10.1.0.9/31"
    remote_ip: "10.1.0.8"
    remote_asn: 65005
```

Do the same for spine host_vars — spines have four links, one per leaf.

## Write the variable files

Fill in all six host_vars files and the group_vars files. Use the addressing plan as the
source of truth. Values go in variables; logic (loops, conditionals) goes in templates later.

## Verify the variables load correctly

Ansible can dump the full variable set it sees for a given host:

```bash
ansible -i inventory/hosts.yml leaf1 -m debug -a "var=hostvars[inventory_hostname]"
```

**You should see:** all the variables you defined, merged from group_vars and host_vars.
Spot-check: does leaf1's `bgp_asn` read `65001`? Does it have both `fabric_links` entries?

**Session 2 deliverable:** `ansible-inventory -i inventory/hosts.yml --list` shows all six
nodes with correct variables. No hardcoded IPs appear in any template yet — only in host_vars.

---

# Session 3 (day 15) — Role: eos_base and eos_interfaces

## Whiteboard first (10 min)

Answer on paper:

1. What is an Ansible role? Draw its directory structure from memory: what goes in `tasks/`,
   `templates/`, `vars/`?
2. What does the `arista.eos.eos_config` module do? What does its `lines` parameter accept?
3. What is the difference between `eos_config` and `eos_command`? When would you use each?

## The eos_base role

The `eos_base` role sets the node's identity and turns on the routing engine. It covers:
- `hostname`
- `ip routing`
- `service routing protocols model multi-agent`
- `spanning-tree mode mstp`

Look at the `ansible/roles/eos_base/tasks/main.yml` skeleton. Fill it in using
`arista.eos.eos_config` tasks with the `lines` parameter. Use variables for the values
that differ per host (`inventory_hostname` gives you the node's name from the inventory).

Example structure (you write the actual tasks):

```yaml
- name: set hostname
  arista.eos.eos_config:
    lines:
      - "hostname {{ inventory_hostname }}"

- name: enable ip routing and routing model
  arista.eos.eos_config:
    lines:
      - ...
      - ...
```

Note: `service routing protocols model multi-agent` requires a process restart to take
effect on a live node. In the gate (deploy fresh, then run playbook), the node boots with
this already in the base config, so you will not hit this. If you run the role on a live
node that does not already have it, you will need to `docker restart` the container after.
Document this limitation in your role's README.

## The eos_interfaces role

The `eos_interfaces` role configures all Ethernet interfaces and Loopback0.

For the loopback — a single task with a hardcoded parent context:
```yaml
arista.eos.eos_config:
  parents: "interface Loopback0"
  lines:
    - "ip address {{ loopback_ip }}/32"
```

For the Ethernet interfaces — this is where Jinja2 earns its keep. You have a list
(`fabric_links`) and need to configure each entry. The `loop` directive in Ansible iterates
a task over a list:

```yaml
- name: configure fabric link
  arista.eos.eos_config:
    parents: "interface {{ item.interface }}"
    lines:
      - "description {{ item.description }}"
      - "mtu {{ fabric_mtu }}"
      - "no switchport"
      - "ip address {{ item.local_ip }}"
  loop: "{{ fabric_links }}"
```

`item` inside the loop refers to the current element of `fabric_links`.
`fabric_mtu` is a group-level variable (same on every node).

Write the full `tasks/main.yml` for this role. Then run it:

```bash
cd ~/life-os/repos/network-training/ansible
ansible-playbook -i inventory/hosts.yml site.yml --tags base,interfaces
```

**You should see:** a play recap with `changed=N` (non-zero on first run since these tasks
are changing config), then `failed=0`. On a second run you should see `changed=0` —
that is idempotency. If the count does not drop to 0 on the second run, investigate which
task is not idempotent and why.

## Verify on the device

After the role runs, SSH into a node and check:

```bash
docker exec -it clab-p2-underlay-leaf1 Cli -p 15 -c "show ip interface brief"
docker exec -it clab-p2-underlay-leaf1 Cli -p 15 -c "show interfaces Ethernet1 | include MTU"
```

**You should see:** the same output you got at the end of Phase 2 Sessions 2 and 6.

**Session 3 deliverable:** eos_base and eos_interfaces run idempotently. All interfaces show
correct IPs and MTU. Second playbook run shows `changed=0` for these two roles.

---

# Session 4 (day 16) — Role: eos_bgp

## Whiteboard first (15 min, reference closed)

Write the full BGP config for leaf1 from memory, using only the addressing plan. Include:
- `router bgp <ASN>`
- `router-id`
- `maximum-paths`
- `bgp bestpath as-path multipath-relax`
- All neighbor statements with correct remote-as
- `network` statement for the loopback

Then do the same for spine1.

Compare against `labs/02-underlay/configs/numbered-final/leaf1.cfg` and
`spine1.cfg`. Every discrepancy is a gap in your BGP mental model, not a template problem.
Fix the mental model first.

## Design the template

The BGP role uses a Jinja2 template rather than raw `lines` tasks because the neighbor
block is a loop — the same structure repeats for each entry in `fabric_links`. Templates
handle this more cleanly than looped tasks.

Look at `ansible/roles/eos_bgp/templates/`. You will write two templates: `leaf.j2` and
`spine.j2`. The task will choose which to render based on `node_type` (a group variable
you define: `leaves.yml` sets it to `'leaf'`, `spines.yml` sets it to `'spine'`).

A Jinja2 loop looks like this:

```jinja2
{% for link in fabric_links %}
   neighbor {{ link.remote_ip }} remote-as {{ link.remote_asn }}
{% endfor %}
```

`{% %}` is a control block (logic). `{{ }}` is a variable substitution.

Write the templates. The target output is the BGP stanza in the numbered-final configs —
that is your spec. The template must reproduce it exactly, variable substitution aside.

## The eos_bgp task

The task renders the template and pushes it:

```yaml
- name: configure BGP
  arista.eos.eos_config:
    src: "{{ 'leaf.j2' if node_type == 'leaf' else 'spine.j2' }}"
```

When `src` is a `.j2` file, Ansible looks for it in the role's `templates/` directory,
renders it with the host's variables, and passes the result to `eos_config` as a config
block to apply.

## Run and verify

```bash
ansible-playbook -i inventory/hosts.yml site.yml --tags bgp
```

Then on leaf1:
```bash
docker exec clab-p2-underlay-leaf1 Cli -p 15 -c "show ip bgp summary"
```

**You should see:** two sessions, both Established, same prefix counts as Phase 2.

Run the full `verify-phase2.sh` to confirm the fabric is healthy end to end:

```bash
cd ~/life-os/repos/network-training
./scripts/verify-phase2.sh
```

**You should see:** 8/8 PASS.

Run the playbook a second time:

```bash
ansible-playbook -i inventory/hosts.yml site.yml
```

**You should see:** `changed=0` across all tasks. If any task is not idempotent, fix it
before moving on — a playbook that makes spurious changes is not safe to run in production.

**Session 4 deliverable:** all three roles run idempotently. `verify-phase2.sh` passes.
No diff between the running config and what Phase 2 produced by hand.

---

# Session 5 (day 17) — Diff and validate

## Whiteboard first (10 min)

Answer on paper:

1. What does `--check` mode do in Ansible? Why would you use it before running a playbook
   in production?
2. A playbook has `changed=3` on the second run. Name two possible root causes.
3. What is an Ansible vault, and what problem does it solve? (You do not need to implement
   one this session — just be able to explain it.)

## Config diff: Ansible vs numbered-final

Your Ansible-generated config should match the hand-written configs from Phase 2.
Confirm this with a diff.

First, save the Ansible-generated running config from each node:

```bash
for node in spine1 spine2 leaf1 leaf2 leaf3 leaf4; do
  docker exec clab-p2-underlay-$node Cli -p 15 -c "show running-config" \
    > /tmp/ansible-gen-$node.txt
done
```

Then diff leaf1 against the numbered-final:

```bash
diff /tmp/ansible-gen-leaf1.txt \
  ~/life-os/repos/network-training/labs/02-underlay/configs/numbered-final/leaf1.cfg
```

**Expected:** a few cosmetic differences (timestamp, Management0 address, EOS-generated
boilerplate). No differences in Loopback0, Ethernet interfaces, or `router bgp` stanzas.
If there are functional differences, trace them back to the template and fix.

Note any legitimate differences in LAB-NOTES.md Session 5 — for example, if Ansible
pushes config in a different order than EOS stores it, explain why that is not a problem.

## check mode

Run the playbook in check mode against the currently-configured fabric:

```bash
ansible-playbook -i inventory/hosts.yml site.yml --check
```

**You should see:** `changed=0` everywhere. If anything shows as "would change," investigate.
A `changed=0` in check mode on a correctly configured fabric means the templates exactly
match the live state — your automation is self-consistent.

## Save and commit

```bash
cd ~/life-os/repos/network-training
git add ansible/
git add LAB-NOTES.md
git commit -m "Phase 3: Ansible roles eos_base, eos_interfaces, eos_bgp — idempotent"
git push
```

**Session 5 deliverable:** diff shows no functional differences. Check mode shows
`changed=0`. Code committed.

---

# Session 6 (day 18) — Gate: cold deploy + playbook

This session proves the automation is real. You are not verifying that Ansible matches a
hand-configured fabric — you are verifying that Ansible can configure a fresh fabric from
scratch.

## Whiteboard first (15 min)

Answer cold:

1. Draw the full 2-spine × 4-leaf topology. All interfaces, all /31s, all ASNs, all
   loopbacks. No notes.
2. Write the BGP stanza for leaf3 from memory.
3. What is the formula for leaf N's Ethernet1 address (spine1 side)?
4. Which EOS command shows you whether BGP has installed ECMP routes in the RIB?

These are the things you should be able to say in an interview the moment someone asks
about your automation work. The automation is the artifact; the understanding is what
they are testing.

## Create minimal base configs

The gate requires starting from a fresh node, not an already-configured one. Create
minimal startup configs that give Ansible a foothold but nothing more:

```
labs/02-underlay/configs/minimal/<node>.cfg
```

Each file should contain:
- `no aaa root`
- `username admin privilege 15 role network-admin secret sha512 <same hash as numbered-final>`
- `management api http-commands` / `no shutdown`
- `service routing protocols model multi-agent`
- `interface Management0` / `ip address <management IP>/24`
- `ip route 0.0.0.0/0 172.20.20.1`

Nothing else. No `ip routing`. No Ethernet config. No BGP.

## Update the topology to use minimal configs

Edit `labs/02-underlay/underlay.clab.yml` — change `startup-config` to point to
`configs/minimal/<node>.cfg` for each node.

## Destroy, deploy fresh, run the playbook

```bash
cd ~/life-os/repos/network-training/labs/02-underlay
containerlab destroy -t underlay.clab.yml --cleanup
time containerlab deploy -t underlay.clab.yml
```

Wait for all six nodes to boot (~90s). Then, **without touching any switch CLI**:

```bash
cd ~/life-os/repos/network-training/ansible
ansible-playbook -i inventory/hosts.yml site.yml
```

**You should see:** `changed=N` (non-zero — the fabric was bare). All tasks succeed.
`failed=0`.

## Run the acceptance check

```bash
cd ~/life-os/repos/network-training
./scripts/verify-phase2.sh
```

**You should see:** 8/8 PASS. If anything fails, debug through the playbook — not through
the CLI. Fix the role, re-run the playbook, re-run the verify script.

## Commit and finalize

Restore `underlay.clab.yml` to point at `numbered-final/` (the comfortable default for
ongoing sessions), save the minimal configs, and commit:

```bash
cd ~/life-os/repos/network-training
git add labs/02-underlay/configs/minimal/ labs/02-underlay/underlay.clab.yml
git add ansible/ LAB-NOTES.md
git commit -m "Phase 3 complete: Ansible roles configure fabric from minimal base"
git push
```

**Session 6 deliverable:** `verify-phase2.sh` passes on a Ansible-only deployment.
You did not type a single config command on any switch this session.

---

## Phase 3 exit gates

Both must be true before Phase 4:

1. `verify-phase2.sh` passes on a fresh, Ansible-configured fabric.
2. You can answer the Phase 3 whiteboard questions cold.

**Report back:** which sessions ran over two hours, any template gotchas you hit, and your
whiteboard self-check score.

---

## Appendix: common Ansible/EOS traps

**eos_config pushes to running-config, not startup-config.**
Changes are live but do not survive a `docker restart`. For the lab this is fine — you
redeploy rather than reboot. For production, either push to startup explicitly or add a
save task at the end of the playbook.

**EOS may render the config differently than you typed it.**
`eos_config` checks idempotency by comparing what you sent against what the device has.
If EOS reorganizes your config (e.g. puts `neighbor` statements inside `address-family ipv4`),
the module may report `changed=1` on every run even though the config is correct. Fix:
either match the canonical EOS form in your template, or use `eos_config` with `match: none`
to suppress the comparison (last resort — it loses idempotency checking).

**Management0 is configured by containerlab, not by Ansible.**
Do not manage Management0 in your roles. If Ansible overwrites it, you lose the connection
mid-playbook. Leave it to containerlab and the minimal base config.

**`service routing protocols model multi-agent` requires a process restart.**
The minimal base config already includes it, so a fresh deploy will have it. If you ever
run the eos_base role on a live node that does not have it, the BGP process will not start
until the node restarts. Document this in the role README.

**eAPI returns `HTTP 401` if the password is wrong, `HTTP 404` if eAPI is not enabled.**
Test with curl before blaming Ansible:
```bash
curl -sk -u admin:<password> \
  -X POST https://<mgmt-ip>/command-api \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"runCmds","params":{"version":1,"cmds":["show version"]},"id":1}'
```

---
Author: Claude (Cowork) / Anthropic
Model: claude-sonnet-4-6
Created: 2026-09-10 ET
Lineage: original
---
