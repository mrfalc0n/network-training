# Phase 1 — Environment Setup Runbook

**Goal:** containerlab installed, two Arista cEOS nodes booted, link verified. Nothing else.
**Time:** 60–90 minutes, most of it waiting on a 2 GB download.
**Stop point:** when `scripts/verify-phase1.sh` passes. Do not start Phase 2.

Every step below is labeled with **where** you do it. If you find yourself typing a
Linux command into PowerShell, the label will tell you you're in the wrong place.

---

## 0. Who does what

You have three pieces of software. Here is the entire division of labor:

| Where | What it does in this project | How much you touch it |
|---|---|---|
| **Windows** | Runs Docker Desktop. Runs your browser (to download the Arista image). Runs VS Code. | Almost nothing. Three tasks total. |
| **Docker Desktop** (Windows app) | Provides the Docker *engine* that WSL uses. You start it and leave it alone. | Start it. Confirm one setting. Never touch again. |
| **VS Code** (Windows app) | Your editor. It connects *into* WSL so it edits Linux files directly. | Open the folder once. |
| **WSL / Ubuntu terminal** | **Everything else.** containerlab, git, docker commands, the labs, all of it. | 95% of your time. |

**Your Windows-side to-do list, in full:**

1. Make sure Docker Desktop is running and its WSL integration is enabled for Ubuntu (Step 1).
2. Download the Arista cEOS image in your browser (Step 6).
3. Open the repo folder in VS Code (Step 9, optional but convenient).

That's it. Nothing gets installed on Windows. No files live on `C:\`. The repo, the
labs, the containers, and the network all live inside WSL.

> **Why:** containerlab builds networks out of Linux kernel objects — network namespaces
> and veth pairs. Those are Linux things. Windows has no equivalent and isn't involved.
> WSL2 is a real Linux kernel, which is why this works at all.

---

## 0b. Mental model (read once, saves an hour later)

Four layers, bottom to top:

| Layer | What it is | Your existing analogue |
|---|---|---|
| **WSL2** | A real Linux kernel running inside Windows | A VM, but with a shared filesystem and no boot delay |
| **Docker** | Runs *containers*: isolated processes with their own filesystem and network stack | A VRF plus a chroot, roughly |
| **containerlab** | An orchestrator. Reads a YAML topology, starts the containers, wires them together with virtual cables | Your cabling contractor + patch panel, driven by a text file |
| **cEOS-lab** | Arista EOS packaged to run as a container instead of on a switch | The same EOS CLI you know, minus the ASIC |

The one idea that matters: **containerlab does not simulate a network.** It creates real
Linux network namespaces and real veth pairs between them. When `leaf1:eth1` connects to
`leaf2:eth1`, that is an actual kernel-level virtual cable. Real packets. `tcpdump` works.

**veth pair** = a virtual patch cable. Two ends, both are interfaces, whatever goes in
one end comes out the other. One end goes inside container A, the other inside container
B. That is the entire physical layer of this lab.

---

# STEP 1 — Check Docker Desktop

**Where: Windows**

1. Launch Docker Desktop if it isn't already running. Wait for the whale icon in the
   system tray to stop animating — that means the engine is up.
2. Click the **gear icon** (Settings) → **Resources** → **WSL Integration**.
3. Confirm **"Enable integration with my default WSL distro"** is on, and that the
   toggle next to your **Ubuntu** distro is on.
4. If you changed anything, click **Apply & Restart**.

Leave Docker Desktop running for the rest of this runbook. Minimize it; you're done
with Windows for now.

> Docker Desktop runs the actual Docker engine inside its own hidden WSL distro and
> lends it to your Ubuntu. That mostly works for this lab. It is also the single most
> common cause of "the lab deployed but no traffic passes." Step 5 tests for exactly
> that in 60 seconds, and gives you the fix if it fails. Don't preemptively change
> anything — test first.

---

# STEP 2 — Open your WSL terminal

**Where: Windows → opens a WSL terminal**

Open Windows Terminal and pick the **Ubuntu** profile. (Or from PowerShell: `wsl`.)

Confirm you're in Linux:

```bash
uname -r
```

**You should see:** something ending in `microsoft-standard-WSL2`.

Confirm Docker reached you across the boundary:

```bash
docker version
```

**You should see:** both a `Client:` block and a `Server:` block, with no error about a
socket. If you get `Cannot connect to the Docker daemon`, Docker Desktop isn't running
or the WSL integration toggle from Step 1 is off.

Everything from here to the end of Step 10 happens **in this terminal**.

---

# STEP 3 — Clone the repo into your existing repos folder

**Where: WSL terminal**

You already keep every repo in `~/life-os/repos`. This one goes there too — same
pattern, nothing new to learn.

```bash
cd ~/life-os/repos
git clone https://github.com/mrfalc0n/network-training.git
cd network-training
```

**You should see:** `Cloning into 'network-training'...` then `done.`

Confirm what landed:

```bash
ls
```

**You should see:** `LAB-NOTES.md  README.md  docs  labs  scripts`

Your working directory for the rest of this runbook is:

```
~/life-os/repos/network-training
```

> **Ignore any earlier advice about `C:\Github`.** Your existing setup — repos in the
> Linux filesystem under `~/life-os/repos` — is already the correct pattern, and it's
> what containerlab needs. Repos stored on `C:\` (which WSL sees as `/mnt/c`) can't
> represent Linux file permissions and are slow across the Windows boundary; cEOS
> bind-mounts its config directory and misbehaves there. You were already doing this
> right. Nothing changes.

---

# STEP 4 — Run the pre-flight check

**Where: WSL terminal**

```bash
chmod +x scripts/*.sh
./scripts/check-env.sh
```

`chmod +x` marks the two scripts as executable. Linux won't run a file as a program
unless that permission bit is set, and GitHub's web API can't set it — so you set it
once here.

`check-env.sh` only *reads* your system. It changes nothing. It reports: whether you're
on WSL2, whether the repo is in the Linux filesystem, your cgroup version, which Docker
flavor you have, whether containerlab is installed, and your RAM and free disk.

**You should see:** PASS on platform, filesystem, and Docker; a WARN that containerlab
isn't installed yet (correct — that's Step 5) and a WARN that `ceos:lab` isn't found
(correct — that's Step 6). WARN lines are informational. Only FAIL blocks you.

Note down what it says under **4. Docker** — whether it detected Docker Desktop or a
native engine. You'll report that back at the end.

---

# STEP 5 — Install containerlab, then smoke-test it

**Where: WSL terminal**

## 5a. Install

```bash
curl -sL https://containerlab.dev/setup | sudo -E bash -s "all"
```

Reading that line: `curl -sL <url>` downloads the setup script quietly and follows
redirects. The `|` pipes it into `sudo -E bash`, which runs it as root while keeping
your environment variables. `-s "all"` tells it to do the full install.

> Piping a URL into `sudo bash` is normally a habit worth breaking. Here it's the
> method the project documents on its own domain. To read it first:
> `curl -sL https://containerlab.dev/setup | less`, then run the real command.

The installer creates a group called `clab_admins` and adds you to it. Pick that up
without logging out:

```bash
newgrp clab_admins
```

Verify:

```bash
containerlab version
```

**You should see:** a banner with a `version:` line. If you get `command not found`,
close the terminal, open a new Ubuntu terminal, and try again.

> `clab` is a built-in shorthand for `containerlab`. Both work.

## 5b. Smoke test — two tiny Linux containers and one virtual cable

**Why this exists:** if you jump straight to cEOS and it fails, you won't know whether
the problem is your environment or the Arista image. This isolates the variable. It
takes 60 seconds and uses a 5 MB image instead of a 2 GB one.

Look at the topology before you run it:

```bash
cd ~/life-os/repos/network-training/labs/00-smoke-test
cat smoke.clab.yml
```

Read it: `nodes:` declares two Alpine Linux containers named `n1` and `n2`. `links:`
declares one veth pair between `n1:eth1` and `n2:eth1`. The `exec:` blocks put an IP
address on each end after boot (Alpine has no config engine, so it's done by hand;
cEOS won't need this).

Deploy it:

```bash
containerlab deploy -t smoke.clab.yml
```

`deploy` means: read the topology, pull any missing images, start the containers,
create the veth pairs, run the `exec` commands. `-t` points at the topology file.

**You should see:** a pull of `alpine:3` the first time, then a summary table with
`clab-smoke-n1` and `clab-smoke-n2`, State `running`.

Now prove the virtual cable carries traffic:

```bash
docker exec clab-smoke-n1 ping -c 3 10.0.0.2
```

`docker exec <container> <command>` runs a command inside a container — the container
equivalent of SSHing to a device, without SSH.

**You should see:**

```
3 packets transmitted, 3 packets received, 0% packet loss
```

### If the ping fails

This is the Docker Desktop problem. The fix is to install Docker Engine natively inside
Ubuntu and stop using Docker Desktop's engine for this distro:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
```

Then **on Windows**: Docker Desktop → Settings → Resources → WSL Integration → turn the
**Ubuntu toggle off** → Apply & Restart. Then from PowerShell run `wsl --shutdown`,
reopen your Ubuntu terminal, and re-run the deploy and ping.

> Docker Desktop and a native engine can coexist on the machine; you're just choosing
> which one this distro talks to. Your other projects that use Docker Desktop are
> unaffected.

## 5c. Tear the smoke test down

```bash
containerlab destroy -t smoke.clab.yml --cleanup
cd ~/life-os/repos/network-training
```

`--cleanup` also removes the `clab-smoke/` runtime directory containerlab created.
Leaving labs running eats RAM.

---

# STEP 6 — Download the Arista cEOS image

**Where: Windows (browser), then WSL terminal**

This is the only step that needs a browser. Arista gives cEOS-lab away free but puts it
behind a login.

## 6a. Download it (Windows)

1. Create a free account at <https://www.arista.com/en/login>. Use a **personal email** —
   you want this account to outlive any employer.
2. Go to **Support → Software Download**.
3. Expand **cEOS-lab** and pick a release. **It must be 4.32.0F or newer.** Older
   releases need cgroups v1; WSL2 provides cgroups v2, and the container will silently
   crash-loop instead of giving you a useful error.
4. Download the 64-bit file, named like `cEOS64-lab-4.32.2F.tar.xz`. About 2 GB.

It lands in your Windows `Downloads` folder.

## 6b. Move it into WSL (WSL terminal)

Don't import it from `/mnt/c` — it's slow and large files occasionally corrupt across
the boundary. Move it into the Linux filesystem first.

```bash
mkdir -p ~/images
mv /mnt/c/Users/<your-windows-username>/Downloads/cEOS64-lab-*.tar.xz ~/images/
ls -lh ~/images/
```

Replace `<your-windows-username>` with your actual Windows account folder name. If
you're unsure of it, run `ls /mnt/c/Users/` and look.

**You should see:** one file, roughly 1.8–2.2 GB.

## 6c. Import it into Docker (WSL terminal)

```bash
cd ~/images
docker import cEOS64-lab-4.32.2F.tar.xz ceos:4.32.2F
```

Substitute your actual version number in **both** places on that line.

> **Why `import` and not `load` or `pull`?** `docker pull` fetches from a public
> registry — Arista doesn't publish there. `docker load` expects an archive that already
> contains Docker image layers and metadata. `docker import` takes a **plain filesystem
> tarball** and wraps it into an image. Arista ships a plain filesystem tarball, so
> `import` is the right verb — and it's why you have to supply the name and tag
> yourself.

**You should see:** a `sha256:...` line after 30–90 seconds.

Now add a second, stable name so topology files never need editing when you upgrade:

```bash
docker tag ceos:4.32.2F ceos:lab
docker images | grep ceos
```

**You should see:** two rows — `ceos 4.32.2F` and `ceos lab` — with the **same IMAGE ID**
and about 2 GB. A tag is just a label pointing at an image; there's still only one copy
on disk. Every lab in this repo references `ceos:lab`, so upgrading later is one
`docker tag` instead of editing every file.

Write the exact version into `LAB-NOTES.md`. Future-you and any interviewer will ask.

---

# STEP 7 — Boot two cEOS nodes

**Where: WSL terminal**

```bash
cd ~/life-os/repos/network-training/labs/01-two-node-ceos
cat two-node.clab.yml
containerlab deploy -t two-node.clab.yml
```

**You should see:** 60–120 seconds of silence while EOS boots — it's a full network OS
init, not a hello-world container — then a table with `clab-p1-ceos-leaf1` and
`clab-p1-ceos-leaf2`, kind `arista_ceos`, State `running`, each with a management IP in
`172.20.20.0/24`.

Get onto the CLI:

```bash
docker exec -it clab-p1-ceos-leaf1 Cli
```

`-it` attaches your terminal interactively. `Cli` — capital C — is the EOS shell. From
here it's the EOS you already know:

```
leaf1>enable
leaf1#show version
leaf1#show interfaces status
```

**You should see:** `show version` reporting the cEOS version you imported, and
`show interfaces status` listing `Et1` — that's the containerlab veth, presented to EOS
as an ordinary front-panel port.

Leave the CLI with `exit`, twice, or `Ctrl-D`.

> **Management vs data plane — the part people get wrong.** Each node also has `eth0`,
> which EOS shows as `Management0`. That's Docker's management bridge and it is *not*
> part of the fabric you're designing. Data links are `eth1` and up (`Ethernet1`+).
> Confusing the two is how people "prove" a fabric works when traffic was actually
> going out of band.

---

# STEP 8 — Prove the data plane (optional, 10 minutes, recommended)

**Where: WSL terminal → EOS CLI**

Phase 1's bar is "two nodes boot." But confirming a packet actually crosses the veth
*inside EOS* is what makes the environment trustworthy before Phase 2's BGP work.

This is the **last time you configure anything by hand** in this repo. Phase 3 converts
everything to Ansible and the rule after that is absolute.

On leaf1 (`docker exec -it clab-p1-ceos-leaf1 Cli`):

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

Back on leaf1:

```
ping 10.1.1.2
```

**You should see:** 5/5 replies, sub-millisecond.

If `show interfaces Ethernet1` reports the line protocol down, the veth didn't attach —
destroy and redeploy the lab.

> `no switchport` moves the port from L2 bridging to L3 routing: it gets its own IP and
> participates in the routing table directly instead of belonging to a VLAN. Same concept
> you know from EXOS; this is the Arista dialect you'll be writing for the rest of the
> repo. Phase 2's leaf-spine underlay is nothing but routed point-to-point links like
> this one.

---

# STEP 9 — Editing files (VS Code)

**Where: WSL terminal → opens VS Code on Windows**

From inside the repo directory:

```bash
code .
```

The first time you run this, VS Code installs a small server component inside WSL. Then
a VS Code window opens on Windows, editing the Linux files directly. The bottom-left
corner will show a green badge reading **WSL: Ubuntu** — that's how you know you're
editing the Linux copy and not a Windows one.

If `code` isn't found, open VS Code on Windows, press `Ctrl+Shift+X`, and install the
**WSL** extension (published by Microsoft). Then reopen your terminal and try again.

> Don't browse to the files through Windows File Explorer and open them that way. Use
> `code .` from inside WSL, or VS Code's **WSL: Connect to WSL** command. Editing
> through the Windows path can mangle line endings and permissions.

---

# STEP 10 — Tear down, record, commit

**Where: WSL terminal**

```bash
cd ~/life-os/repos/network-training/labs/01-two-node-ceos
containerlab destroy -t two-node.clab.yml --cleanup
cd ~/life-os/repos/network-training
```

Fill in `LAB-NOTES.md` — cEOS version, Docker flavor, what broke, what fixed it. Then:

```bash
git update-index --chmod=+x scripts/check-env.sh scripts/verify-phase1.sh
git add .
git commit -m "Phase 1: environment verified, two cEOS nodes booting"
git push
```

The `git update-index` line permanently records the executable bit in git, so the
`chmod` from Step 4 never has to be repeated on another machine.

**You should see:** `git push` reporting objects written to
`github.com/mrfalc0n/network-training`.

If it prompts for a password, note that GitHub stopped accepting account passwords —
you need a personal access token or the `gh` CLI. Tell me and we'll set it up.

---

# STEP 11 — Acceptance, then stop

**Where: WSL terminal**

Redeploy the cEOS lab, then run the assertions:

```bash
cd labs/01-two-node-ceos && containerlab deploy -t two-node.clab.yml
cd ~/life-os/repos/network-training && ./scripts/verify-phase1.sh
```

Then work through [`phase-1-acceptance.md`](phase-1-acceptance.md) and take the cold
self-check in [`whiteboard/phase-1-containerlab-mechanics.md`](whiteboard/phase-1-containerlab-mechanics.md).

When those pass, **stop.** Phase 2 (BGP unnumbered leaf-spine, ECMP, MTU) isn't built
yet and is gated on your review.

**Report back four things:**

1. Which steps failed on the first attempt, and why.
2. Docker flavor — Desktop integration or native engine (from Step 4).
3. cEOS version you imported.
4. Wall-clock seconds for the 2-node deploy — it sets the ceiling on Phase 2's topology size.

---

## Troubleshooting index

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot connect to the Docker daemon` | Docker Desktop not running, or WSL integration off | Step 1 |
| `containerlab: command not found` | PATH not refreshed after install | Close and reopen the Ubuntu terminal |
| `permission denied` on the docker socket | Not in the `docker` group | `sudo usermod -aG docker $USER` then `newgrp docker` |
| Smoke-test ping fails | Docker Desktop networking | Step 5b, "If the ping fails" |
| cEOS container keeps restarting | Image older than 4.32.0F on cgroups v2 | Download 4.32.0F or newer |
| `no such image` on deploy | Tag mismatch | `docker images` — confirm `ceos:lab` exists |
| Deploy hangs at "Creating container" | Out of RAM (cEOS wants ~2 GB per node) | Close other apps; check `free -h` |
| Everything is slow | Lab running under `/mnt/c` | Move the repo into `~/life-os/repos` |
| `code .` not found | VS Code WSL extension missing | Step 9 |

---
Author: Claude (Cowork) / Anthropic
Model: claude-opus-5
Created: 2026-09-02 ET
Lineage: revised from prior AI draft (rewritten for beginner cadence and Chris's actual WSL layout)
---
