# Phase 1 — Environment Setup Runbook

**Goal:** containerlab installed, two nodes booted, link verified. Nothing else.
**Time:** 60–90 minutes, most of it waiting on a 2 GB download.
**Stop point:** when `scripts/verify-phase1.sh` passes for lab 01. Do not start Phase 2.

This runbook assumes you have never used Docker or containerlab. Every command is
explained before it is run. Read the explanation, then run the command, then compare
against the expected output. If output differs, stop and troubleshoot — do not push on.

---

## 0. Mental model (read this once, it saves an hour later)

Four layers, bottom to top:

| Layer | What it is | Your existing analogue |
|---|---|---|
| **WSL2** | A real Linux kernel running inside Windows | A VM, but with shared filesystem and no boot delay |
| **Docker** | Runs *containers*: isolated processes with their own filesystem and network namespace | A VRF plus a chroot, roughly |
| **containerlab** | An orchestrator. Reads a YAML topology, starts the containers, then wires them together with veth pairs | Your cabling contractor + patch panel, driven by a text file |
| **cEOS-lab** | Arista EOS packaged to run as a container instead of on a switch | The same EOS CLI you already know, minus the ASIC |

The one idea that matters: **containerlab does not simulate a network.** It creates
real Linux network namespaces and real veth pairs between them. When `leaf1:eth1`
connects to `leaf2:eth1`, that is an actual kernel-level virtual cable. Packets are
real packets. `tcpdump` works. This is why the lab is credible in an interview —
it is Linux networking, not a simulator's approximation of it.

**veth pair** = a virtual cable. Two ends, both are interfaces, whatever goes in one
end comes out the other. One end lands inside container A's namespace, one inside
container B's. That is the entire physical layer of this lab.

---

## 1. Open your WSL2 Ubuntu shell

Everything from here runs **inside WSL2**, not in PowerShell and not in CMD.

Open Windows Terminal and select the Ubuntu profile, or from PowerShell run:

```powershell
wsl -d Ubuntu
```

Confirm you are in the right place:

```bash
uname -a
```

**Expected:** a line containing `Linux` and `microsoft-standard-WSL2`. If it says
anything about Windows, you are in the wrong shell.

---

## 2. Decide where the repo lives — read this before cloning

> **This is the one decision in Phase 1 that will bite you later if you get it wrong.**

You said you want the repo at `C:\Github\network-training`. From inside WSL that path
is `/mnt/c/Github/network-training`. That works for editing files, but containerlab
labs run poorly there for two reasons:

1. **Permissions.** `/mnt/c` is a Windows filesystem bridged into Linux. It cannot
   represent Linux file ownership or the executable bit correctly. cEOS containers
   bind-mount their config directory from the lab folder and will fail or silently
   misbehave when those permissions can't be set.
2. **Speed.** Every file operation crosses the Windows/Linux boundary. Deploys that
   take 20 seconds in the Linux filesystem take minutes on `/mnt/c`.

**Recommendation:** clone into the WSL filesystem instead, at `~/github/network-training`.
You still get to it from Windows — File Explorer, VS Code, and any Windows app can open
`\\wsl.localhost\Ubuntu\home\<your-wsl-username>\github\network-training`. Pin that in
Explorer's Quick Access and it behaves like any other folder.

**If you insist on `C:\Github\network-training`**, the workable compromise is to keep the
repo there for editing and run labs from a copy in the Linux filesystem. That is two
copies to keep in sync, which is exactly the failure mode git exists to prevent. Don't.

### Clone it

```bash
mkdir -p ~/github
cd ~/github
git clone https://github.com/mrfalc0n/network-training.git
cd network-training
```

**Expected:** `Cloning into 'network-training'...` then a `done.` line. Then:

```bash
ls
```

**Expected:** `README.md  docs  labs  scripts  LAB-NOTES.md`

> **Git vocabulary, once.** `clone` = download the repo plus its full history and wire
> it to the GitHub copy (called `origin`). Later: `git add <file>` stages a change,
> `git commit -m "message"` records it locally, `git push` sends it to GitHub. That's
> the whole loop for now.

---

## 3. Pre-flight check

```bash
chmod +x scripts/*.sh
./scripts/check-env.sh
```

`chmod +x` marks the scripts executable — Linux won't run a file as a program unless
that bit is set, and git preserves it after the first commit.

`check-env.sh` reads your environment and reports. It changes nothing. It tells you:

- whether you're really on WSL2
- which **Docker flavor** you have (this matters — see below)
- your kernel version and cgroup version
- whether containerlab is already installed
- how much disk you have free (you need ~5 GB)

### On Docker flavor

There are two ways Docker gets into WSL2, and they behave differently:

- **Docker Desktop with WSL integration** — the daemon runs in Docker Desktop's own
  hidden distro; your Ubuntu just gets a client. It mostly works with containerlab,
  but it complicates network namespaces and iptables, and it is the single most common
  source of "my lab deployed but the links don't pass traffic."
- **Docker Engine installed natively inside Ubuntu** — the daemon runs in your distro.
  This is what containerlab expects and what the docs assume.

`check-env.sh` will tell you which you have. **If it reports Docker Desktop, keep going
anyway** — finish the smoke test in section 5. If the smoke test's ping fails, that's
your answer, and section 5 has the fix. Don't preemptively rip out a working Docker.

---

## 4. Install containerlab

One command. It adds the containerlab apt repository, installs the binary, creates a
`clab_admins` group, and adds you to it.

```bash
curl -sL https://containerlab.dev/setup | sudo -E bash -s "all"
```

Reading that line: `curl -sL <url>` downloads the setup script quietly and follows
redirects; the `|` pipes it into `sudo -E bash`, which runs it as root while keeping
your environment variables; `-s "all"` tells the script to do the full install.

> Piping a URL into `sudo bash` is normally a habit worth breaking. Here it is the
> upstream-documented method from the project's own domain. If you'd rather see it
> first: `curl -sL https://containerlab.dev/setup | less`, then run it.

Then pick up your new group membership without logging out:

```bash
newgrp clab_admins
```

Verify:

```bash
containerlab version
```

**Expected:** a version banner with a `version:` line (0.60-something or newer as of
Sept 2026). If you get `command not found`, close and reopen the shell first.

> `clab` is an alias for `containerlab`. Both work. This repo uses the long form in
> docs and the short form in scripts.

---

## 5. Smoke test — two Alpine containers, one virtual cable

**Why this step exists:** if you go straight to cEOS and it fails, you won't know
whether the problem is your environment or the cEOS image. This isolates the variable.
It takes 60 seconds.

Look at the topology first:

```bash
cat labs/00-smoke-test/smoke.clab.yml
```

Read it line by line — `nodes:` declares two Alpine Linux containers, `links:`
declares one veth pair between `n1:eth1` and `n2:eth1`, and the `exec:` blocks put an
IP on each end after boot (Alpine has no config engine, so this is done by hand;
cEOS won't need it).

Deploy:

```bash
cd labs/00-smoke-test
containerlab deploy -t smoke.clab.yml
```

`deploy` = read the topology, pull any missing images, start the containers, create the
veth pairs, run the `exec` commands. `-t` is the topology file.

**Expected:** a pull of `alpine:3` on first run, then a summary table listing
`clab-smoke-n1` and `clab-smoke-n2` with State `running`.

Now prove the wire carries traffic:

```bash
docker exec clab-smoke-n1 ping -c 3 10.0.0.2
```

`docker exec <container> <command>` runs a command inside a container — the container
equivalent of SSHing to a device, minus SSH.

**Expected:**

```
PING 10.0.0.2 (10.0.0.2): 56 data bytes
64 bytes from 10.0.0.2: seq=0 ttl=64 time=0.0xx ms
...
3 packets transmitted, 3 packets received, 0% packet loss
```

**If the ping fails**, this is the Docker Desktop problem described in section 3. Fix by
installing Docker Engine natively in Ubuntu and disabling WSL integration in Docker
Desktop settings:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
```

Then in Docker Desktop → Settings → Resources → WSL Integration, turn **off** the
toggle for your Ubuntu distro, and restart the distro from PowerShell with
`wsl --shutdown`. Reopen Ubuntu and re-run the deploy.

Tear the smoke test down — leaving labs running eats RAM:

```bash
containerlab destroy -t smoke.clab.yml --cleanup
cd ../..
```

`--cleanup` also deletes the `clab-smoke/` runtime directory it created.

---

## 6. Get the cEOS-lab image

This is the only step that requires a browser and an account. Arista gives cEOS-lab away
free but gates it behind registration.

1. Create a free account at <https://www.arista.com/en/login> (use a personal email —
   you want this account to outlive any employer).
2. Go to **Support → Software Download**.
3. Expand **cEOS-lab** and pick a release. **Choose 4.32.0F or newer.** Releases older
   than 4.32.0F require cgroups v1, and WSL2 runs cgroups v2 — they will not boot.
4. Download the file named like `cEOS64-lab-4.32.2F.tar.xz` (64-bit, ~2 GB).

The file lands in your Windows `Downloads`. Move it into WSL — importing from `/mnt/c`
is slow and occasionally corrupts on large files:

```bash
mkdir -p ~/images
mv /mnt/c/Users/<your-windows-username>/Downloads/cEOS64-lab-*.tar.xz ~/images/
ls -lh ~/images/
```

**Expected:** one file, roughly 1.8–2.2 GB.

### Import it into Docker

```bash
cd ~/images
docker import cEOS64-lab-4.32.2F.tar.xz ceos:4.32.2F
```

Substitute your actual version in **both** places. `docker import` takes a filesystem
tarball and turns it into a Docker image — this is different from `docker load`, which
expects an already-built image archive. Arista ships a filesystem tarball, so `import`
is correct.

**Expected:** a `sha256:...` digest printed after 30–90 seconds.

Now give it a stable name so topology files never need editing when you upgrade:

```bash
docker tag ceos:4.32.2F ceos:lab
docker images | grep ceos
```

**Expected:** two rows, `ceos 4.32.2F` and `ceos lab`, sharing the same IMAGE ID and
showing ~2 GB. A tag is just a label pointing at an image — two names, one copy on disk.

Record the exact version you used in `LAB-NOTES.md`. Future-you and any interviewer
will ask.

---

## 7. Boot the real thing — two cEOS nodes

```bash
cd ~/github/network-training/labs/01-two-node-ceos
cat two-node.clab.yml
containerlab deploy -t two-node.clab.yml
```

**Expected:** roughly 60–120 seconds of silence while EOS boots (it is a full network OS
init, not a hello-world container), then a table with `clab-p1-ceos-leaf1` and
`clab-p1-ceos-leaf2`, kind `arista_ceos`, State `running`, each with a management IPv4
in the `172.20.20.0/24` range.

Get onto the CLI:

```bash
docker exec -it clab-p1-ceos-leaf1 Cli
```

`-it` attaches your terminal interactively. `Cli` (capital C) is the EOS shell. From
here it is the EOS you already know:

```
leaf1>enable
leaf1#show version
leaf1#show interfaces status
```

**Expected:** `show version` reports the cEOS-lab version you imported.
`show interfaces status` lists `Et1` — that is the containerlab veth, presented to EOS
as a normal front-panel port. Exit with `exit` twice, or `Ctrl-D`.

---

## 8. Optional but recommended — prove the data plane (10 minutes)

Phase 1's bar is "two nodes boot." But confirming that a packet actually crosses the
veth *inside EOS* is what makes the environment trustworthy before Phase 2's BGP work.

This is the **last time you configure anything by hand** in this repo. Phase 3 converts
everything to Ansible and the rule after that is absolute.

On leaf1:

```
enable
configure
interface Ethernet1
   no switchport
   ip address 10.1.1.1/30
end
```

On leaf2 (`docker exec -it clab-p1-ceos-leaf2 Cli`):

```
enable
configure
interface Ethernet1
   no switchport
   ip address 10.1.1.2/30
end
```

Then from leaf1:

```
ping 10.1.1.2
```

**Expected:** 5/5 replies, sub-millisecond. If `show interfaces Ethernet1` reports the
line protocol down, the veth didn't attach — destroy and redeploy the lab.

> `no switchport` moves the port from L2 to L3 — a routed port instead of a switchport.
> Same concept as EXOS/other platforms; the syntax is the Arista dialect you'll be
> writing for the rest of this repo.

---

## 9. Tear down and commit

```bash
containerlab destroy -t two-node.clab.yml --cleanup
cd ~/github/network-training
```

Write up what happened in `LAB-NOTES.md` — cEOS version, anything that broke, what
fixed it. Then commit:

```bash
git add .
git commit -m "Phase 1: environment verified, two cEOS nodes booting"
git push
```

**Expected:** `git push` reports objects written to `github.com/mrfalc0n/network-training`.
If it asks for a password, GitHub no longer accepts one — you need a personal access
token or the `gh` CLI. Flag it and we'll set that up.

---

## 10. Acceptance — then stop

Run the assertions:

```bash
./scripts/verify-phase1.sh
```

Then work through [`phase-1-acceptance.md`](phase-1-acceptance.md) and
[`whiteboard/phase-1-containerlab-mechanics.md`](whiteboard/phase-1-containerlab-mechanics.md).

When both pass, **stop.** Phase 2 (BGP unnumbered leaf-spine) is not built yet and is
gated on your review of this phase.

---

## Troubleshooting index

| Symptom | Cause | Fix |
|---|---|---|
| `containerlab: command not found` | PATH not refreshed | Close and reopen the WSL shell |
| `permission denied` on docker socket | Not in the `docker` group | `sudo usermod -aG docker $USER` then `newgrp docker` |
| Smoke-test ping fails | Docker Desktop WSL integration | Section 5 — install native Docker Engine |
| cEOS container restarts in a loop | Image older than 4.32.0F on cgroups v2 | Download 4.32.0F or newer |
| `Error response from daemon: no such image` | Tag mismatch | `docker images` and confirm `ceos:lab` exists |
| Deploy hangs at "Creating container" | Out of RAM — cEOS wants ~2 GB per node | Close other apps; check `free -h` |
| Everything slow, deploys take minutes | Lab is running under `/mnt/c` | Move the repo into the WSL filesystem (section 2) |

---
Author: Claude (Cowork) / Anthropic
Model: claude-opus-5
Created: 2026-09-02 ET
Lineage: original
---
