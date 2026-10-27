# vps-qemu-systemd

**A complete Debian 13 cloud desktop with REAL systemd as PID 1 — running on CranL.**

This repository deploys a **virtual machine** inside a Docker container.  The host
container is just a thin QEMU runner; the guest is a full Debian 13 system
with the same desktop stack we run on a real VPS:

| Layer | What runs there |
|-------|-----------------|
| **Host container** (this image) | `qemu-system-x86_64` (TCG, no KVM) + a tiny shell wrapper |
| **Guest VM** (the real system) | **systemd as PID 1**, `vnc.service`, `websockify.service`, `xfce.service`, `nginx.service`, `control.service` |

The guest is built **at Docker build time** from the exact same source tree
(`scripts/`, `web/`, `desktop/`, `vps/systemd/`) that is used by the
Supervisor-based images and the bare-metal `vps/install.sh` script.

---

## Why QEMU?

CranL's free tier gives you:
* 2 GiB RAM, 6 vCPU
* Debian 13 base image, root, `apt-get`
* **NO** `/dev/kvm`, **NO** `CAP_SYS_ADMIN`, **NO** writable cgroup hierarchy

That means **systemd cannot run as PID 1 inside the container** (it needs to
create the cgroup hierarchy and mount filesystems).  A Supervisor-based image
works, but it is not "real systemd".

The only way to get *real* systemd on CranL is to run it inside a VM.  QEMU's
TCG (software emulation) requires no special privileges and no `/dev/kvm` —
it just runs.  The trade-off is speed (≈ 1× native for single-threaded
integer, much slower for GUI), but the system is **genuine**: `systemctl`,
`journalctl`, `systemd-analyze` all work exactly as they do on bare metal.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  CranL platform (nginx proxy → container:3000)                       │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ hostfwd tcp::3000-:3000
┌──────────────────────────▼──────────────────────────────────────────┐
│  Host container (Debian 13 slim, ~120 MB)                            │
│    entrypoint-qemu.sh                                                │
│      gunzip guest artefacts                                          │
│      qemu-system-x86_64 -accel tcg -m 1024 -smp 2 …                 │
│                                                                     │
│    /opt/guest/disk.img    ← 4 GiB sparse ext4 (guest rootfs)         │
│    /opt/guest/vmlinuz      ← kernel                                  │
│    /opt/guest/initrd.img   ← initramfs (with virtio modules)         │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ virtio-blk / virtio-net
┌──────────────────────────▼──────────────────────────────────────────┐
│  Guest VM (Debian 13, REAL systemd)                                  │
│    PID 1 = /lib/systemd/systemd                                      │
│    multi-user.target → cloud-desktop.target                          │
│      ├── vnc.service        (Xtigervnc :1, RFB 127.0.0.1:5901)      │
│      ├── websockify.service (WS 127.0.0.1:6080 → RFB + noVNC files) │
│      ├── xfce.service       (xfwm4 + xfsettingsd + xfce4-panel)     │
│      ├── nginx.service      (public :3000, Basic Auth, WS upgrade)  │
│      └── control.service    (Python /healthz, /api/status, /status) │
│                                                                     │
│    systemctl status cloud-desktop.target  ← WORKS                    │
│    journalctl -u vnc -f                 ← WORKS                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Layout

```
Dockerfile                 multi-stage build: guest → runtime
scripts/
  build-guest-image.sh     build-time: tar rootfs → mkfs.ext4 -d → disk.img.gz
  entrypoint-qemu.sh       runtime: gunzip → boot QEMU → wait for /healthz
  guest-init.sh            runs INSIDE the VM (systemd unit guest-init.service)
  start-*.sh               TigerVNC / websockify / XFCE launchers
  control-server.py        /healthz, /api/status, /status (inside the VM)
  nginx.conf.template      nginx config (rendered at VM boot)
vps/
  systemd/
    *.service|.target      the REAL unit files (used on VPS and in the VM)
    guest-init.service     injects runtime config into the VM at boot
vps/install.sh             installs the same stack on a clean Debian 13 VPS
```

The `vps/systemd/` unit files are **byte-identical** to the ones that run on
a real VPS (`debian-systemd-desktop` repo).  The only difference: the VM does
*not* need the PAMName= overrides because it has a healthy `logind` + session
bus.

---

## Run it

### Docker (local, requires qemu-system-x86 + libvirt if you want KVM)

```bash
docker build -t vps-qemu-systemd .
docker run -d --name cloud-desktop \
    -p 3000:3000 \
    -e VNC_PW='a-strong-password' \
    -e DESKTOP_PW='a-strong-password' \
    -e ROOT_PW='a-strong-password' \
    vps-qemu-systemd
```

### CranL (free tier, no local build)

```bash
# 1. Push this repo to GitHub (already done: roplizeramr-blip/vps-qemu-systemd)
# 2. Create the app via CranL CLI or dashboard:
#    cranl deploy --name vps-qemu-systemd --repo roplizeramr-blip/vps-qemu-systemd \
#        --build dockerfile --env VNC_PW=... DESKTOP_PW=... ROOT_PW=...
```

The build takes ~3-5 min (full apt install + disk image creation).  The first
runtime boot under TCG takes **60-120 seconds** before `/healthz` returns 200.
Give it 3 min on first deploy.

---

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `VNC_PW` | *(required)* | HTTP Basic-Auth password for the public URL (min 6 chars) |
| `DESKTOP_PW` | – | password of the Linux `desktop` user inside the VM |
| `ROOT_PW` | – | root password inside the VM |
| `VNC_USER` | `admin` | Basic-Auth user name |
| `VNC_RESOLUTION` | `1280x720` | desktop geometry |
| `PORT` | `3000` | public port (hostfwd target) |
| `VM_RAM` | `1024` | guest RAM in MiB (max ~1400 on free tier) |
| `VM_SMP` | `2` | guest vCPUs |
| `DESKTOP_HOSTNAME` | `docker-desktop` | hostname inside the VM |

**Never commit `.env` or any password.** The image never bakes a password in:
`VNC_PW` is turned into an nginx apr1 hash *inside the VM* at boot time and
then discarded.

---

## URLs

| Path | What |
|---|---|
| `/` | the desktop (noVNC, Basic Auth) |
| `/status` | status page (no password) |
| `/api/status` | JSON status (no password) |
| `/healthz` | `200 ok` when the desktop is reachable, `503` while starting |

---

## Performance & Limits

| Aspect | Value | Notes |
|---|---|---|
| **RAM** | 1024 MiB guest + ~100 MiB host | Fits in CranL 2 GiB limit |
| **CPU** | 2 emulated vCPUs (MTTCG) | Host has 6 cores |
| **Disk** | 4 GiB virtual, ~1.5 GiB used | Sparse file, gzipped to ~600 MiB |
| **Boot time** | 60-120 s to /healthz | First deploy; warm boots are faster |
| **GUI speed** | sluggish (TCG) | No KVM; XFCE usable, Chrome very slow |
| **Network** | SLIRP user-mode | `hostfwd` gives the public port |

**Tip:** disable Chrome autostart (`CHROME_AUTOSTART=0`) to save guest RAM.

---

## Real VPS deployment

The same stack runs natively on a clean Debian 13 VPS (no container, no VM):

```bash
git clone https://github.com/roplizeramr-blip/vps-qemu-systemd.git
cd vps-qemu-systemd
VNC_PW='a-strong-password' ./vps/install.sh
```

This is the reference deployment path — real hardware, real systemd, no TCG.

---

## Credits

The desktop stack (TigerVNC + noVNC + XFCE behind nginx with Basic Auth) was
developed in the `debian-systemd-desktop` and `ubuntu-systemd-desktop`
repositories and is reused here unchanged.  The QEMU wrapper is new.