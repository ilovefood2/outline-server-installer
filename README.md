# Outline Server for Raspberry Pi

A **Raspberry Pi / ARM64** packaging of [Outline Server](https://github.com/OutlineFoundation/outline-server) (Jigsaw / Outline Foundation).

For an AWS EC2 x86_64 deployment, see [ec2/README.md](ec2/README.md) and use `sudo ./ec2/install.sh`.

The public EC2 bootstrap command is:

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/ilovefood2/outline-server-installer/v1.12.3-r2/ec2/bootstrap.sh)" -- --hostname YOUR_ELASTIC_IP_OR_DNS
```

Official `quay.io/outline/shadowbox` images are **x86_64 only**, and the official installer refuses non-x86 hosts. This project:

1. **Builds** Outline Server (`shadowbox`) natively for `aarch64` / `arm64`
2. **Installs** it with an ARM-patched copy of the official `install_server.sh`
3. **Defaults every new key to port 80** and makes every API-returned access URL end in `&prefix=POST%20`
4. **Allows authenticated clients to reach the Pi's private LAN** (upstream Shadowbox blocks private targets)
5. Stays **compatible with Outline Manager** and Outline Client apps

Pinned to Outline Server **v1.12.3** and `outline-ss-server` **v1.7.3**. Upgrading either version requires rebasing the files under `patches/`; the build stops if they do not apply cleanly.

---

## Requirements

| Item | Detail |
|------|--------|
| Hardware | Raspberry Pi **3 / 4 / 5** (or other aarch64 board). Pi 4/5 recommended. |
| OS | **64-bit** Raspberry Pi OS, Ubuntu, or Debian (`uname -m` → `aarch64`) |
| RAM | 2 GB minimum; **4 GB+** preferred for building on-device |
| Disk | ~4 GB free for build + image |
| Network | Public IP **or** router port-forward + optional Dynamic DNS |
| Software | Docker (installer can install it); build needs Node 18 + Go |

**32-bit Raspberry Pi OS (`armv7l`) is not supported.**

Check:

```bash
uname -m          # must be aarch64
getconf LONG_BIT  # must be 64
```

---

## Quick start (on the Pi)

Copy this folder to the Pi (USB, `scp`, `git clone`, etc.), then:

```bash
cd outline_server
chmod +x install.sh raspberrypi/install.sh scripts/*.sh

# Pi-optimized: port 80 + HTTP POST prefix
sudo ./raspberrypi/install.sh --hostname YOUR_PUBLIC_IP_OR_DDNS

# The main installer now has the same defaults: port 80, POST prefix, LAN access
sudo ./install.sh --hostname YOUR_PUBLIC_IP_OR_DDNS
```

Examples:

```bash
# Auto-detect public IP, use Pi defaults (port 80, POST prefix)
sudo ./raspberrypi/install.sh

# Fixed hostname, custom prefix (TLS ClientHello on port 443)
sudo ./install.sh --hostname vpn.example.com --keys-port 443 --prefix "%16%03%01%00%C2%A8%01%01"

# Image already built/loaded, skip build
sudo ./install.sh --skip-build --hostname 203.0.113.10 --keys-port 80 --prefix POST%20
```

First run **builds from source** and can take **20-60+ minutes** on a Pi. Later runs reuse the image.

When finished, the installer prints:

- **Manager JSON** — paste into Outline Manager to manage the server
- **Access key URL** — share with Outline Client users (ends in `&prefix=POST%20` by default)

### Connect Outline Manager

1. Install [Outline Manager](https://getoutline.org/get-started/) on a laptop
2. Choose **Set up Outline somewhere else**
3. Paste the full JSON line printed at install time
4. Create access keys and share them with [Outline Client](https://getoutline.org/get-started/) apps

Show the JSON again anytime:

```bash
sudo ./scripts/status.sh
```

---

## Traffic disguise with prefixes

Outline supports **connection prefixes** to bypass DPI (deep packet inspection) firewalls. A prefix is prepended to Shadowsocks traffic to make it look like a common protocol.

The custom ARM image adds the configured URL-encoded prefix whenever the management API creates, gets, or lists access keys. This means keys copied from Outline Manager receive the prefix too, rather than only the first installer-created key. **Use a port that matches your prefix:**

| Port | Prefix | Looks like |
|------|--------|-----------|
| 80 | `POST%20` | HTTP POST request |
| 80 | `HTTP%2F1.1%20` | HTTP response |
| 443 | `%16%03%01%00%C2%A8%01%01` | TLS ClientHello |
| 443 | `%17%03%03` | TLS Application Data |
| 22 | `SSH-2.0%0D%0A` | SSH handshake |

```bash
# Example: HTTP disguise on port 80 (recommended for restrictive networks)
sudo ./install.sh --hostname mypi.example.com --keys-port 80 --prefix POST%20
```

For non-printable bytes (TLS, DNS), use percent-encoded hex values (`%XX`). Bash requires quoting them: `--prefix "%16%03%01"`. If you skip quotes, `%` characters may be interpreted by your shell.

See the full table: https://developer.getoutline.org/vpn/advanced/prefixing/

---

## LAN access — reach local network devices through the VPN

Upstream Shadowbox rejects RFC1918 and IPv6 ULA destinations. This project patches `outline-ss-server` with an opt-in private-target policy, enables it in the container, and uses host networking so the proxy can route to devices reachable by the Pi. Loopback, multicast, and other non-unicast targets remain blocked.

The remaining requirement is client-side routing: Outline clients commonly exclude private IPs from their tunnel. Desktop clients can add a route; mobile clients can use the included per-service port proxy.

LAN access is enabled by default in both installers and automatically:

- Starts the patched proxy with private RFC1918/ULA targets allowed
- Configures kernel settings on the Pi for smooth UDP handling
- Installs `socat` for mobile device proxying
- Prints platform-specific client commands at the end of install

```bash
# Lan access is on by default:
sudo ./raspberrypi/install.sh --hostname mypi.example.com

# Without LAN access:
sudo ./raspberrypi/install.sh --no-lan-access
# or: sudo ./install.sh --no-lan-access
```

**For desktop clients (macOS/Windows/Linux):** Run the one-liner shown at install time to add a route through the VPN. Example for macOS:

```bash
sudo route add -net 10.0.0.0/24 -interface utun10
```

**For mobile clients (iOS/Android):** Can't add routes. Instead, proxy LAN devices through the Pi (always reachable):

```bash
sudo ./scripts/lan_proxy.sh install
sudo ./scripts/lan_proxy.sh add 8080 10.0.0.1:80
# Connect to http://<pi-ip>:8080 from any client
```

Show instructions again anytime:

```bash
./scripts/client_lan_route.sh          # client route commands
./scripts/lan_proxy.sh list            # active port forwards
```

---

## Open firewall / router ports

Outline needs **two** ports (printed at install time):

| Port | Protocol | Purpose |
|------|----------|---------|
| Management API port | TCP | Outline Manager |
| Access key port | TCP **and** UDP | Client VPN traffic |

With `ufw` on the Pi:

```bash
sudo ufw allow <API_PORT>/tcp
sudo ufw allow <KEYS_PORT>/tcp
sudo ufw allow <KEYS_PORT>/udp
sudo ufw reload
```

On your home router, forward those ports to the Pi's **LAN IP** (give the Pi a DHCP reservation).

---

## What gets installed

| Piece | Role |
|-------|------|
| `shadowbox` container | Outline Server + Shadowsocks (`outline-ss-server`) + management API |
| `watchtower` container | Pulls newer images when the tag changes (optional updates) |
| `/opt/outline/` | Persistent state, TLS cert, `access.txt` |
| `localhost/outline/shadowbox:stable` | Your locally built ARM image |

---

## Build on another machine, run on the Pi

Useful if the Pi is slow or low on RAM (e.g. build on an Apple Silicon Mac or another arm64 box).

**On the build machine (must produce linux/arm64):**

```bash
./scripts/setup_docker.sh          # if needed
./scripts/setup_build_deps.sh      # Node 18 + Go
./scripts/build_image.sh           # builds for $(uname -m)
./scripts/export_image.sh          # -> outline-shadowbox-aarch64.tar.gz
scp outline-shadowbox-aarch64.tar.gz pi@raspberrypi:~/
```

> Building on an **Intel Mac/PC** produces `amd64`, which will **not** run on a Pi. Use an arm64 builder, or run the build **on the Pi**.

**On the Pi:**

```bash
curl -fsSL https://get.docker.com | sudo sh
gunzip -c outline-shadowbox-aarch64.tar.gz | sudo docker load
cd outline_server
sudo ./install.sh --skip-build --hostname YOUR_PUBLIC_IP --keys-port 80 --prefix POST%20
```

---

## Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | All-in-one: deps → build → install |
| `raspberrypi/install.sh` | Pi-optimized wrapper (port 80, POST prefix, LAN access) |
| `scripts/build_image.sh` | Clone official source, apply project patches, and build Docker image |
| `scripts/apply_outline_patches.sh` | Apply all-key prefix and private-LAN target patches idempotently |
| `scripts/install_server.sh` | ARM-patched installer; defaults to port 80 and `POST%20` |
| `scripts/setup_docker.sh` | Install Docker |
| `scripts/setup_build_deps.sh` | Install Node 18, Go, git, build tools |
| `scripts/install_socat.sh` | Install socat on Debian/Ubuntu or Amazon Linux |
| `scripts/setup_lan_access.sh` | Configure Pi kernel for LAN proxying |
| `scripts/client_lan_route.sh` | Print client-side route commands per platform |
| `scripts/lan_proxy.sh` | Port-forward LAN devices through Pi (for iOS/Android) |
| `scripts/status.sh` | Containers + Manager JSON + LAN status |
| `scripts/test.sh` | Validate Bash defaults and the pinned TypeScript/Go patches |
| `scripts/uninstall.sh` | Remove containers (`--remove-state`, `--remove-image`) |
| `scripts/export_image.sh` | `docker save` tarball for `scp` |
| `scripts/install_server.upstream.sh` | Unmodified upstream (reference) |

---

## Operations

```bash
# Logs
sudo docker logs -f shadowbox

# Restart
sudo docker restart shadowbox

# Status / Manager JSON
sudo ./scripts/status.sh

# Uninstall (keep keys/config)
sudo ./scripts/uninstall.sh

# Uninstall and wipe state
sudo ./scripts/uninstall.sh --remove-state --remove-image
```

Rebuild after upgrading this repo or bumping Outline version:

```bash
./scripts/build_image.sh --clean --version server-v1.12.3
sudo SB_IMAGE=localhost/outline/shadowbox:stable ./scripts/install_server.sh --hostname YOUR_HOST
```

---

## Performance notes

- Outline on a Pi is fine for **a few users** / light-moderate traffic
- Prefer **Ethernet** over Wi-Fi
- Crypto is CPU-bound; Pi 5 ≫ Pi 4 ≫ Pi 3
- During **on-device builds**, the installer may add a temporary 2G swapfile if RAM &lt; ~3.5G

---

## Security notes

- Treat the management API URL (and `certSha256`) like a **password**
- Every access key can reach services on the Pi's LAN while LAN access is enabled; share keys only with trusted users
- Only expose the two required ports
- Keep Raspberry Pi OS and Docker updated
- Rotate access keys if a device is lost
- This is a **Shadowsocks** proxy (Outline), not a full corporate VPN product

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Unsupported machine type` | You ran upstream installer; use **this** `install.sh` / `scripts/install_server.sh` |
| `exec format error` | Image is amd64 on an ARM Pi — rebuild/load an **arm64** image |
| `Image not found: localhost/outline/shadowbox` | Run `./scripts/build_image.sh` or `docker load` a tarball |
| Manager can't connect | Port-forward API port; check `sudo ufw status`; confirm public IP/hostname |
| Clients connect but no traffic | Forward **UDP and TCP** on the keys port |
| Build OOM / frozen Pi | Add swap, close other apps, or build elsewhere and `docker load` |
| Stuck "Waiting for Outline server to be healthy" | `sudo docker logs shadowbox` — usually wrong-arch image or missing certs |
| Prefix not working | Ensure prefix is URL-encoded; use quotes in bash (`"%16%03"`) |

```bash
# Confirm container arch
docker image inspect localhost/outline/shadowbox:stable \
  --format '{{.Architecture}}'    # expect arm64 on Pi
```

---

## Layout

```
outline_server/
├── install.sh                   # main installer
├── raspberrypi/
│   └── install.sh               # Pi-optimized wrapper (port 80, POST prefix)
├── README.md
├── docker-compose.yml
├── config/
│   └── outline.env.example
├── ec2/
│   ├── README.md
│   └── install.sh               # AWS EC2 x86_64 wrapper
├── patches/
│   ├── outline-server-v1.12.3.patch
│   └── outline-ss-server-v1.7.3.patch
└── scripts/
    ├── apply_outline_patches.sh
    ├── build_image.sh
    ├── install_server.sh        # ARM fork with --prefix support
    ├── install_server.upstream.sh
    ├── install_socat.sh
    ├── setup_docker.sh
    ├── setup_build_deps.sh
    ├── status.sh
    ├── uninstall.sh
    └── export_image.sh
```

---

## License / attribution

- Upstream Outline Server: [Apache 2.0](https://github.com/OutlineFoundation/outline-server/blob/master/LICENSE) — © The Outline Authors
- This repository adds install/build wrappers for Raspberry Pi; upstream code is cloned at build time from GitHub and is not vendored here by default

Not affiliated with Google, Jigsaw, or Outline Foundation.
