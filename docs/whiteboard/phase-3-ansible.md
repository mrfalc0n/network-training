# Whiteboard Self-Check — Phase 3: Ansible Automation

**Method:** cover the file. Answer out loud or on paper, cold, no notes and no lab.
Then uncover and compare. Anything you hedged on gets re-tested in the lab the same day.

---

## Q1. Draw Ansible's execution model. Where does it run? How does it reach an EOS switch?

<details><summary>answer</summary>

Ansible runs entirely on the **control node** (your WSL host). There is no agent on the
managed nodes — Ansible is agentless. It connects to each node via the network to execute
tasks.

For an EOS switch it uses **eAPI** (HTTP/S to the switch's Management interface, port
443) via the `httpapi` connection plugin. For Linux servers it typically uses SSH.

The flow:
1. Ansible reads the inventory and finds the target hosts.
2. For each host, it opens an eAPI connection using `ansible_user`/`ansible_password`.
3. It sends EOS commands via the API, receives JSON back, and interprets results.
4. No software is installed or left running on the switch.

**Why this matters for network engineers:** "agentless" is not a technical accident — it
means you can automate network devices (which cannot run arbitrary software) the same way
you automate servers.
</details>

---

## Q2. What is the Ansible variable precedence order? Where does a host_var sit relative to a group_var?

<details><summary>answer</summary>

In Ansible, **more specific wins**. The rough order (lowest to highest priority):

1. Defaults (role `defaults/main.yml`)
2. Inventory group_vars
3. Inventory host_vars
4. Playbook vars
5. Task vars / `set_fact`
6. Extra vars (`-e` on the command line)

**host_vars beats group_vars.** If `group_vars/leaves.yml` sets `bgp_max_paths: 4` and
`host_vars/leaf1.yml` also sets `bgp_max_paths: 2`, leaf1 gets 2.

**Why this matters:** it is the mechanism that lets you define a fabric-wide default once
and override it per device without duplicating the whole variable set. In a 128-leaf
fabric, one group var is better than 128 identical host vars.
</details>

---

## Q3. What is a Jinja2 template? Describe the three syntax forms you will use.

<details><summary>answer</summary>

A Jinja2 template is a text file with placeholders that are replaced at render time.
Ansible renders it by substituting the target host's variables.

Three forms:
- **`{{ variable }}`** — variable substitution. Replaced with the variable's value.
  `{{ bgp_asn }}` → `65001`.
- **`{% for item in list %} ... {% endfor %}`** — loop. Renders the block once per element.
  `{% for link in fabric_links %} neighbor {{ link.remote_ip }} ...{% endfor %}`.
- **`{% if condition %} ... {% endif %}`** — conditional. Renders the block only if true.
  `{% if node_type == 'leaf' %} bgp bestpath as-path multipath-relax {% endif %}`.

**Why this matters:** the BGP neighbor block is a loop — four entries on a spine, two on
a leaf, with different IPs per node. Without a loop you would write four separate tasks or
hardcode every neighbor. The template writes it once and loops.
</details>

---

## Q4. What is idempotency? What does `changed=0` mean on the second run?

<details><summary>answer</summary>

An operation is **idempotent** if running it multiple times produces the same result as
running it once. No harm from re-running.

`changed=0` on the second playbook run means the module compared what it was asked to
configure against what is already on the device, found no difference, and made no changes.
The fabric is already in the desired state.

**Why this matters operationally:** a non-idempotent playbook is dangerous. If every run
reports `changed=N`, you cannot tell whether the changes were needed or spurious. You also
cannot safely run it repeatedly to validate state. Production automation must be
idempotent — it is the same guarantee a declarative system (like Kubernetes) provides.

**Gotcha:** EOS sometimes renders config in a different canonical form than you sent it.
`eos_config` compares what the device has against what you sent, character by character.
If EOS changes the ordering or indentation, the module may always report `changed=1` even
though the config is correct. Fix it by matching the canonical EOS form in the template.
</details>

---

## Q5. What is the difference between `eos_config` and `eos_command`?

<details><summary>answer</summary>

- **`eos_config`**: pushes configuration to the device. Analogous to `configure terminal`
  then typing commands. Checks current state and only pushes if there is a difference
  (idempotent). Use it to change config.

- **`eos_command`**: runs exec-mode commands and returns the output. Analogous to
  `show` commands. Does not change config; used to gather state, check outputs, or verify.

In a role:
- `eos_config` pushes the BGP config.
- `eos_command` then runs `show ip bgp summary` to verify it took effect.

**Do not use `eos_command` to push config.** It does not check idempotency and does not
handle config-mode context.
</details>

---

## Q6. Your playbook shows `changed=2` on the second run. Name three possible root causes.

<details><summary>answer</summary>

1. **Non-idempotent task:** EOS renders the config differently from what you sent, so the
   module always sees a difference. Example: you send `neighbor 10.1.0.0 remote-as 65000`
   but EOS stores it inside `address-family ipv4` — the comparison always fails.

2. **Template generates non-deterministic output:** a variable that changes between runs
   (timestamp, random ID) appears in the rendered template. The device config changes
   every run because the template output changes.

3. **External change on the device:** someone (or something) modified the running config
   outside Ansible between runs. The device is no longer in the desired state, so Ansible
   correctly reports `changed` and fixes it. This is actually the intended behavior — but
   it tells you someone is configuring outside the system.
</details>

---

## Q7. What is an Ansible role? Draw the directory structure.

<details><summary>answer</summary>

A role is a reusable, self-contained unit of automation. It groups related tasks,
templates, and variables so you can call them by name from a playbook and reuse them
across projects.

Directory structure:

```
roles/
  eos_bgp/
    tasks/
      main.yml      ← entry point; list of tasks for this role
    templates/
      leaf.j2       ← Jinja2 templates rendered by tasks
      spine.j2
    defaults/
      main.yml      ← default variable values (lowest priority)
    vars/
      main.yml      ← role-specific vars (higher priority than defaults)
    README.md       ← what the role does, what variables it needs
```

Ansible automatically finds `tasks/main.yml` when you include the role. Everything else
is optional — use what you need.

**Analogy:** a role is a Python function with its own namespace. You call it by name, pass
it variables (via the inventory), and it does a defined thing. The playbook is the script
that calls those functions in order.
</details>

---

## Q8. Why are the underlay BGP sessions configured in a role rather than inline in the playbook?

<details><summary>answer</summary>

Two reasons:

1. **Reuse.** Phase 4 (EVPN overlay) will configure additional BGP address-families on
   the same nodes. A role can be extended without touching the playbook. If BGP config
   were inline, you would either duplicate it or restructure the whole playbook.

2. **Blast-radius containment.** A role can be tagged and run independently
   (`--tags bgp`). If you change the BGP template and only want to push BGP changes, you
   do not have to re-run the interface role. In production, you run only what changed.

**The deeper principle:** roles enforce the separation of concerns that makes automation
maintainable at scale. An operator on call at 2 a.m. can find and fix a BGP issue in
`roles/eos_bgp/` without understanding the full playbook.
</details>

---

## Q9. You want to add leaf5 to the fabric. What files do you touch?

<details><summary>answer</summary>

Three files:

1. **`inventory/hosts.yml`** — add leaf5 under the `leaves` group with its Management0 IP.
2. **`host_vars/leaf5.yml`** — add leaf5's specific variables: `bgp_asn: 65005`,
   `loopback_ip: 10.0.0.5`, and the `fabric_links` list with its two uplink entries.
3. **`underlay.clab.yml`** — add a leaf5 node and its eth1/eth2 links to the topology.

Then run `ansible-playbook site.yml --limit leaf5` to configure only leaf5. Existing nodes
are not touched.

**This is the payoff.** Without automation, adding a leaf means manually configuring the
leaf and updating the two spines (adding neighbor statements). With Ansible and the right
variable design, it is three file edits and one command.
</details>

---

## Q10. What is Ansible Vault and when would you use it?

<details><summary>answer</summary>

Ansible Vault encrypts sensitive values (passwords, API keys, certificates) so they can
be committed to git without exposing secrets.

Usage:
```bash
ansible-vault encrypt_string 'mypassword' --name 'ansible_password'
```

This outputs an encrypted blob you paste into a vars file. Ansible decrypts it at run
time using a vault password (stored separately, never committed).

When to use it: any credential that lives in a variables file. In this lab, the EOS admin
password. In production, every credential in the inventory.

**Why it matters for the portfolio:** a repo with plaintext passwords fails a security
review instantly. A reviewer who sees vault-encrypted values knows you understand
credential hygiene.
</details>

---

## Scoring

- **9–10 clean:** Phase 4 (VXLAN/EVPN). Your automation fundamentals are solid.
- **6–8:** Re-run the specific sessions that cover each miss. The templates and tasks are
  where it becomes real — reading is not enough.
- **≤5:** Repeat Sessions 2–4 from a clean playbook, writing each file from memory
  against the spec only. The second build is where it becomes yours.

---
Author: Claude (Cowork) / Anthropic
Model: claude-sonnet-4-6
Created: 2026-09-10 ET
Lineage: original
---
