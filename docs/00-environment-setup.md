# Phase 1 — Environment Setup Runbook

**Goal:** containerlab installed, two Arista cEOS nodes booted, link verified. Nothing else.
**Time:** 60–90 minutes, most of it waiting on a 2 GB download.
**Stop point:** when `scripts/verify-phase1.sh` passes. Do not start Phase 2.

Every step is labeled with **where** you do it. If you find yourself typing a Linux
command into PowerShell, the label will tell you you're in the wrong place.

For the conceptual picture — what a container actually is, why containerlab isn't
"inside" Docker, what a veth pair does — read [`01-how-this-works.md`](01-how-this-works.md).
This file is the procedure; that one is the mental model.

---

## 0. Who does what

| Where | Role in this project | How much you touch it |
|---|---|---|
| **Windows** | Runs your browser (one download) and VS Code (editing). | Two tasks, total. |
| **WSL / Ubuntu terminal** | **Everything else.** Docker Engine, containerlab, git, the labs, the network. | 95% of your time. |
| **Docker Desktop** (if installed) | **Not used by this project.** Its WSL integration gets turned off for Ubuntu. | Disable one toggle, then ignore. |
| **VS Code** (Windows app) | Your editor. Connects *into* WSL and edits Linux files directly. | Open the folder once. |

**Your Windows-side to-do list, in full:**

1. Download the Arista cEOS image in your browser (Step 6).
2. Open the repo in VS Code (Step 9, optional but convenient).

Nothing for this project installs on Windows. No project files live on `C:\`. The repo,
the Docker engine, the containers and the network all live inside WSL.

> **Why:** containerlab builds networks out of Linux kernel objects — network namespaces
> and veth pairs. Those are Linux things. WSL2 is a real Linux kernel, which is why this
> works at all.

---

# STEP 1 — Docker Engine, natively inside Ubuntu

**Where: WSL terminal**

This lab wants the Docker daemon running **in the same distro as your shell**.

If you already have Docker Desktop with WSL integration, it will appear to work — but
your shell is in one distro while the containers live in another, behind Desktop's own
NAT and iptables layer. It's a known source of "the lab deployed but nothing pings," and
more importantly every containerlab document, tutorial and error message assumes the
standard layout. Debugging a non-standard setup with no matching search results is a bad
trade in a learning environment.

## 1a. Check what you have

```bash
docker info --format '{{.OperatingSystem}}' 2>&1
```

- Prints something like `Ubuntu` → native engine already. Skip to Step 2.
- Prints `Docker Desktop` → continue below.
- Errors out → no daemon yet; continue below.

## 1b. Install the native engine

```bash
curl -fsSL https://get.docker.com | sudo sh
```

This is Docker's official install script. It adds Docker's apt repository and installs
`docker-ce` (the daemon), `docker-ce-cli` (the client) and `containerd`.

If Docker Desktop is installed, the script prints a warning that a `docker` command
already exists. **That is expected — let it run.** It's seeing Desktop's client shim, and
replacing it is the point. The script cannot touch Docker Desktop itself; that's a
Windows application and this runs inside Ubuntu.

Give yourself socket access without `sudo`:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

`usermod -aG` appends your account to the `docker` group, which owns
`/var/run/docker.sock`. Group membership is normally read only at login, so `newgrp`
starts a subshell that picks it up immediately. New terminals get it automatically.

## 1c. Turn off Docker Desktop's WSL integration

**Where: Windows** — skip if you don't have Docker Desktop.

Docker Desktop → gear icon → **Resources** → **WSL Integration** → toggle **Ubuntu OFF**
→ **Apply & Restart**.

Then, from **PowerShell**:

```powershell
wsl --shutdown
```

That fully stops the distro so no stale socket survives. Wait ~10 seconds, then open a
fresh Ubuntu terminal.

> Docker Desktop stays installed and keeps working for anything else you use it for.
> You're only telling it to stop lending its engine to this distro. If it later pops up
> saying "WSL integration unexpectedly stopped — restart it?", choose **Skip**.

## 1d. Make the daemon survive reboots

WSL doesn't run systemd unless you ask it to. Check:

```bash
grep -s systemd /etc/wsl.conf || echo "systemd not enabled"
```

If it says not enabled:

```bash
printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf
```

Then `wsl --shutdown` from PowerShell again and reopen Ubuntu.

With systemd on, enable and start Docker permanently:

```bash
sudo systemctl enable --now docker
docker version
```

**You should see:** a `Client:` block and a `Server:` block. In the Server block, look
for `Docker Engine - Community` and — importantly — **no mention of Docker Desktop**.

> Without systemd you'd start it by hand with `sudo service docker start` every session.
> Enabling systemd once is worth it.

---

# STEP 2 — Confirm you're in the right place

**Where: WSL terminal**

Open Windows Terminal and pick the **Ubuntu** profile. (Or from PowerShell: `wsl`.)

```bash
uname -r
```

**You should see:** something ending in `microsoft-standard-WSL2`.

Everything through Step 8 happens in this terminal.

---

# STEP 3 — Clone the repo

**Where: WSL terminal**

Repos live in the Linux filesystem. On this machine that's `~/life-os/repos`, alongside
everything else.

```bash
cd ~/life-os/repos
git clone https://github.com/mrfalc0n/network-training.git
cd network-training
```

**You should see:** `Cloning into 'network-training'...` then `done.` Then `ls` shows
`LAB-NOTES.md  README.md  docs  labs  scripts`.

> **Don't put this on `C:\`.** WSL sees Windows drives as `/mnt/c`, which can't represent
> Linux file permissions and is slow across the boundary. cEOS bind-mounts its config
> directory and misbehaves there.

---

# STEP 4 — Pre-flight check

**Where: WSL terminal**

```bash
chmod +x scripts/*.sh
./scripts/check-env.sh
```

`chmod +x` marks the scripts executable. Linux won't run a file as a program without that
permission bit, and GitHub's API can't set it — so you set it once here. Step 10 records
it in git permanently.

`check-env.sh` only reads your system; it changes nothing.

**You should see:** PASS on platform, filesystem and Docker, with section 4 reading
`native Docker Engine (what containerlab expects)`. WARN lines about containerlab and
`ceos:lab` are correct at this stage — those are Steps 5 and 6. Only FAIL blocks you.

---

# STEP 5 — Install containerlab, then smoke-test it

**Where: WSL terminal**

## 5a. Install

```bash
curl -sL https://containerlab.dev/setup | sudo -E bash -s "all"
```

Reading that line: `curl -sL <url>` downloads the setup script quietly and follows
redirects. The `|` pipes it into `sudo -E bash`, which runs it as root while keeping your
environment variables. `-s "all"` requests the full install.

> Piping a URL into `sudo bash` is normally a habit worth breaking. Here it's the method
> the project documents on its own domain. To read it first:
> `curl -sL https://containerlab.dev/setup | less`, then run the real command.

The installer creates a `clab_admins` group and adds you to it:

```bash
newgrp clab_admins
containerlab version
```

**You should see:** a banner with a `version:` line. If you get `command not found`, open
a fresh Ubuntu terminal — the PATH needs a new shell.

## 5b. Smoke test — two containers, one virtual cable

**Why this exists:** if you jump straight to cEOS and it fails, you won't know whether the
problem is your environment or the Arista image. This isolates the variable in 60 seconds
using a 5 MB image instead of a 2 GB one.

Read the topology before running it:

```bash
cd ~/life-os/repos/network-training/labs/00-smoke-test
cat smoke.clab.yml
```

`nodes:` declares two Alpine Linux containers, `n1` and `n2`. `links:` declares one veth
pair between `n1:eth1` and `n2:eth1`. The `exec:` blocks put an IP on each end after boot
(Alpine has no config engine; cEOS won't need this).

```bash
containerlab deploy -t smoke.clab.yml
```

`deploy` means: read the topology, pull missing images, start the containers, create the
veth pairs, run the `exec` commands. `-t` points at the topology file.

**You should see:** an `alpine:3` pull on first run, then a table with `clab-smoke-n1`
and `clab-smoke-n2`, State `running`.

```bash
docker exec clab-smoke-n1 ping -c 3 10.0.0.2
```

`docker exec <container> <command>` runs a command inside a container — the container
equivalent of SSHing to a device, without SSH.

**You should see:** `3 packets transmitted, 3 packets received, 0% packet loss`.

That packet was forwarded by the actual Linux kernel between two network namespaces over
a real veth pair. Not a simulation.

### If the ping fails on a native engine

Rare. Work through, in order:

```bash
docker ps                                    # are both containers actually running?
docker exec clab-smoke-n1 ip -br addr        # did eth1 get 10.0.0.1/30?
docker logs clab-smoke-n1                    # did the exec commands error?
```

If `eth1` has no address, the `exec:` block didn't run — destroy and redeploy. If `eth1`
is missing entirely, the veth didn't attach, which points at a containerlab install
problem. Paste the output rather than guessing.

## 5c. Tear it down

```bash
containerlab destroy -t smoke.clab.yml --cleanup
cd ~/life-os/repos/network-training
```

`--cleanup` also removes the `clab-smoke/` runtime directory. `destroy` doesn't touch the
topology file — redeploy any time. Containers are disposable; the YAML persists.

---

# STEP 6 — Get the Arista cEOS image

**Where: Windows (browser), then WSL terminal**

The only step that needs a browser. Arista gives cEOS-lab away free but gates it behind a
login.

## 6a. Download (Windows)

1. Create a free account at <https://www.arista.com/en/login>. Use a **personal email** —
   you want this account to outlive any employer.
2. **Support → Software Download**.
3. Expand **cEOS-lab** and pick a release. **It must be 4.32.0F or newer.** Older releases
   need cgroups v1; WSL2 provides cgroups v2, and the container will silently crash-loop
   rather than give a useful error.
4. Download the 64-bit file, named like `cEOS64-lab-4.32.2F.tar.xz`. About 2 GB.

## 6b. Move it into WSL (WSL terminal)

Don't import from `/mnt/c` — slow, and large files occasionally corrupt across the
boundary.

```bash
mkdir -p ~/images
mv /mnt/c/Users/<your-windows-username>/Downloads/cEOS64-lab-*.tar.xz ~/images/
ls -lh ~/images/
```

If you're unsure of your Windows account folder name, run `ls /mnt/c/Users/` and look.

**You should see:** one file, roughly 1.8–2.2 GB.

## 6c. Import it into Docker (WSL terminal)

```bash
cd ~/images
docker import cEOS64-lab-4.32.2F.tar.xz ceos:4.32.2F
```

Substitute your actual version in **both** places.

> **Why `import` and not `load` or `pull`?** `docker pull` fetches from a public registry —
> Arista doesn't publish there. `docker load` expects an archive that already contains
> Docker image layers and metadata. `docker import` takes a **plain filesystem tarball**
> and wraps it into an image. Arista ships a plain filesystem tarball, which is also why
> you have to supply the name and tag yourself.

**You should see:** a `sha256:...` line after 30–90 seconds.

Add a stable alias so topology files never need editing on upgrade:

```bash
docker tag ceos:4.32.2F ceos:lab
docker images | grep ceos
```

**You should see:** two rows — `ceos 4.32.2F` and `ceos lab` — with the **same IMAGE ID**
and about 2 GB. A tag is a pointer; there's still one copy on disk. Every lab in this repo
references `ceos:lab`, so upgrading later is one `docker tag` instead of editing files.

Record the exact version in `LAB-NOTES.md`.

---

# STEP 7 — Boot two cEOS nodes

**Where: WSL terminal**

```bash
cd ~/life-os/repos/network-training/labs/01-two-node-ceos
cat two-node.clab.yml
containerlab deploy -t two-node.clab.yml
```

**You should see:** 60–120 seconds of silence while EOS boots — a full network OS init,
not a hello-world container — then a table with `clab-p1-ceos-leaf1` and
`clab-p1-ceos-leaf2`, kind `arista_ceos`, State `running`, each with a management IP in
`172.20.20.0/24`.

Time that deploy. You'll report it back; it sets the ceiling on Phase 2's topology size.

```bash
docker exec -it clab-p1-ceos-leaf1 Cli
```

`-it` attaches your terminal interactively. `Cli` — capital C — is the EOS shell:

```
leaf1>enable
leaf1#show version
leaf1#show interfaces status
```

**You should see:** the cEOS version you imported, and `Et1` in the interface list —
that's the containerlab veth, presented to EOS as an ordinary front-panel port.

Exit with `exit` twice, or `Ctrl-D`.

> **Management vs data plane.** Each node also has `eth0`, which EOS shows as
> `Management0`. That's Docker's management bridge and it is **not** part of the fabric
> you're designing. Data links are `eth1`+ (`Ethernet1`+). Confusing the two is how people
> "prove" a fabric works when traffic was going out of band.

---

# STEP 8 — Prove the data plane (optional, recommended, 10 min)

**Where: WSL terminal → EOS CLI**

Phase 1's bar is "two nodes boot." Confirming a packet crosses the veth *inside EOS* is
what makes the environment trustworthy before Phase 2's BGP work.

This is the **last time you configure anything by hand** in this repo. Phase 3 converts
everything to Ansible and the rule after that is absolute.

leaf1 (`docker exec -it clab-p1-ceos-leaf1 Cli`):

```
enable
configure
interface Ethernet1
   no switchport
   ip address 10.1.1.1/30
end
```

leaf2 (`docker exec -it clab-p1-ceos-leaf2 Cli`):

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
show interfaces Ethernet1 counters
```

**You should see:** 5/5 replies, sub-millisecond, and TX on one side matching RX on the
other. If the line protocol is down, the veth didn't attach — destroy and redeploy.

> `no switchport` moves the port from L2 bridging to L3 routing: it gets its own IP and
> participates in the routing table directly instead of belonging to a VLAN. Phase 2's
> leaf-spine underlay is nothing but routed point-to-point links like this one.

---

# STEP 9 — Editing files (VS Code)

**Where: WSL terminal → opens VS Code on Windows**

From inside the repo:

```bash
code .
```

First run installs a small server component inside WSL. A VS Code window opens on Windows
and edits the Linux files directly. Bottom-left shows a green **WSL: Ubuntu** badge —
that's how you know you're on the Linux copy.

If `code` isn't found: open VS Code on Windows, `Ctrl+Shift+X`, install the **WSL**
extension (Microsoft), reopen your terminal, try again.

> Don't reach the files through Windows File Explorer. Use `code .` from inside WSL.
> Editing through the Windows path can mangle line endings and permissions.

---

# STEP 10 — Tear down, record, commit

**Where: WSL terminal**

```bash
cd ~/life-os/repos/network-training/labs/01-two-node-ceos
containerlab destroy -t two-node.clab.yml --cleanup
cd ~/life-os/repos/network-training
```

Fill in `LAB-NOTES.md` — cEOS version, Docker flavor, deploy time, what broke, what fixed
it. Then:

```bash
git update-index --chmod=+x scripts/check-env.sh scripts/verify-phase1.sh
git add .
git commit -m "Phase 1: environment verified, two cEOS nodes booting"
git push
```

`git update-index --chmod=+x` records the executable bit in git permanently, so the
`chmod` from Step 4 never has to be repeated on another machine.

If `git push` prompts for a password: GitHub stopped accepting account passwords. You need
a personal access token or the `gh` CLI. Flag it and we'll set it up.

---

# STEP 11 — Acceptance, then stop

**Where: WSL terminal**

```bash
cd labs/01-two-node-ceos && containerlab deploy -t two-node.clab.yml
cd ~/life-os/repos/network-training && ./scripts/verify-phase1.sh
```

Then work through [`phase-1-acceptance.md`](phase-1-acceptance.md) and take the cold
self-check in [`whiteboard/phase-1-containerlab-mechanics.md`](whiteboard/phase-1-containerlab-mechanics.md).

When those pass, **stop.** Phase 2 (BGP unnumbered leaf-spine, ECMP, MTU) isn't built yet
and is gated on your review.

**Report back four things:**

1. Which steps failed on the first attempt, and why.
2. Docker engine confirmation from `check-env.sh` section 4.
3. cEOS version imported.
4. Wall-clock seconds for the 2-node deploy.

---

## Troubleshooting index

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot connect to the Docker daemon` | Daemon not started | `sudo systemctl enable --now docker` (or `sudo service docker start` without systemd) |
| `permission denied` on the docker socket | Not in the `docker` group | `sudo usermod -aG docker $USER` then `newgrp docker` |
| `docker info` says "Docker Desktop" | Desktop's WSL integration still on | Step 1c |
| Daemon gone after a reboot | systemd not enabled | Step 1d |
| `containerlab: command not found` | PATH not refreshed | Open a fresh Ubuntu terminal |
| Smoke-test ping fails | See the ordered checks in Step 5b | |
| cEOS container keeps restarting | Image older than 4.32.0F on cgroups v2 | Download 4.32.0F or newer |
| `no such image` on deploy | Tag mismatch | `docker images` — confirm `ceos:lab` exists |
| Deploy hangs at "Creating container" | Out of RAM (~2 GB per cEOS node) | Close other apps; `free -h` |
| Everything slow | Lab running under `/mnt/c` | Move the repo into `~/life-os/repos` |
| `code .` not found | VS Code WSL extension missing | Step 9 |

---
Author: Claude (Cowork) / Anthropic
Model: claude-opus-5
Created: 2026-09-02 ET
Lineage: revised from prior AI draft — rewritten for beginner cadence, then again after
verification on arcwise to make native Docker Engine the documented path
---
