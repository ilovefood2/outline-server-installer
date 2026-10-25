# Pi security build

This is an in-place security migration for the existing ARM64 Pi deployment. It preserves the full Shadowbox Manager, its certificate and server identity, existing access keys and data limits, Prometheus history, public TCP/UDP port 80, the complete `?outline=1&prefix=POST%20` key, and the intentionally enabled LAN access.

The legacy installer is unchanged. **Do not rerun it to upgrade this deployment**: it creates pairing material and startup configuration. This migration instead keeps an untouched rollback container and original state directory, and runs the new server against a private state copy.

## Changes

- Node 24.22.1, Alpine 3.24, Go 1.27.3 and Prometheus 3.15.1; locked Node dependencies, including Restify 12.1.0. Unused npm, Yarn and Corepack are removed from the runtime image.
- Revoking a key closes its active TCP connections and rejects stale UDP sessions. Manager waits for the backend to acknowledge the exact applied configuration before reporting success. Other keys' established sessions survive ordinary reloads.
- Prometheus administrative mutations are disabled; Manager history and usage queries remain available. Loopback targets remain blocked by the VPN's destination policy.
- Network processes run as UID 31999 with only the low-port binding capability, no privilege escalation, a read-only root filesystem and bounded memory, processes, descriptors and logs. Watchtower cannot replace this local image.
- Manager binds to the Pi's LAN address. An owned nftables input table permits public TCP/UDP 80, preserves intended LAN services and IPv6 control traffic, and restricts management access to trusted sources. It does not change Docker forwarding tables.
- MediaMTX is removed. Its service, installation, dedicated account and firewall exceptions are retired; configuration and state are archived in the root-private removal backup. Recording files outside the installation directories are untouched. The build no longer includes MediaMTX.
- Debian security updates run automatically without an automatic reboot.

## Build

Python 3.11+, Git, npm, Go with toolchain downloads and a working ARM64 Docker builder are required. Set `DOCKER_CONTEXT` for the intended builder; do not change another workflow's global Docker context.

Use clean official source checkouts at the revisions checked by the scripts:

```sh
gh repo clone Jigsaw-Code/outline-server .build/outline-server -- --branch server-v1.12.3
python3 security/build.py --source-dir .build/outline-server --work-dir .build/secure-shadowbox
```

The build script exports the pinned commit into its own work directory, applies the compatibility and security patches, builds locked dependencies and runs Go tests. The Shadowbox builder also compiles all upstream TypeScript specifications and runs them under Linux/Node 24 in a disposable container. Prometheus's official ARM64 download is SHA-256 verified.

Run `govulncheck` built with Go 1.27.3 against the actual backend source, and scan the final Docker export with Trivy. Check findings and reachability rather than treating a successful scanner exit as an absence of all advisories. At the 2026-10-24 review, GO-2026-5932 affected the unused OpenPGP package in `x/crypto`; the VPN backend does not import the affected package. The production npm audit and Alpine/Node package image scan were clear.

The official Prometheus binary records its module as `v0.0.0-...+dirty`, so binary-only `govulncheck` incorrectly assigns older Prometheus advisories to it. Its embedded commit `bae3eced0a5369e050e83ea73bc381d7c4b1a719` matches the upstream v3.15.1 tag and is a descendant of the v3.11.3 fixes. Record that version evidence alongside the scan. The binary scan also lists module-only AWS S3 crypto advisories for packages absent from this binary.

## Checks

`integration.py` uses an isolated Docker network and fresh throwaway keys/certificate. Its probe rejects non-fixture server identities before any Manager writes. Build the probe against the same vendored Outline SDK as the backend:

```sh
cd .build/secure-shadowbox/backend
GOTOOLCHAIN=go1.27.3 GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -mod=vendor -trimpath -buildvcs=false -o ../probe ../../../security/probe.go
cd ../../..
python3 security/integration.py --work-dir .build/secure-shadowbox
python3 security/test_install.py
```

The host migration tests use the Python standard library. The image integration covers private TCP/UDP targets, complete POST-prefix transport, Manager over Outline, metrics APIs, body limits, explicit port 80 and IPv6 key formatting, active/new key revocation and unrelated connection preservation. Test all compiled upstream TypeScript specifications under Linux/Node 24; macOS's socket bind semantics cause three upstream port-reservation tests to fail there.

For the exact IPv4/IPv6 firewall packet test, build the disposable test image from an official Alpine image with `nftables`, `python3` and `iproute2`, tag it `outline-pi-guard-test:local`, then run `python3 security/test_guard.py`. It requires Docker and grants NET_ADMIN only inside the disposable server network namespace. The test removes its own containers and networks afterwards.

## Deployment and rollback

This installer is deliberately restricted to the verified Pi address `10.0.0.33`, its original state layout and its existing POST/LAN policy. It requires a private root-owned backup, a completed package upgrade receipt and a clean `dpkg --audit`. Install `nftables`, `rsync` and `unattended-upgrades` through the existing trusted Debian repositories first.

The state is copied online into an owned, marked staging directory, preserving Prometheus snapshot hard links. The server then stops for a final exact delta sync and cutover. Vanished source files are tolerated only during the online pass; any partial final transfer aborts. No links are shared between the original rollback state and the new live state.

Before cutover, a fresh consistent Prometheus snapshot supplies the new active database. The copied raw database remains in `prometheus/data-before-security`, and the original state is untouched. This preserves history while avoiding a long replay of accumulated recovery logs. Capture an anchored historical query before migration and compare it after restoration.

Transfer a root-private bundle over SSH containing the installer, firewall and service files, the Docker image export, and a manifest with `image_tag`, exact `image_id` and `image_config_id`, `backend_sha256`, and a `files` SHA-256 map for every payload file. The two IDs accommodate Docker's containerd and classic image stores; both must come from the same tested export. Verify the full bundle checksum before extraction. Never put production keys, environment files or pairing certificates in a distributable bundle or Git.

Run `python3 install_on_pi.py --backup /var/backups/VERIFIED_BACKUP` from that root-private bundle. Image migration failure restores the old container. MediaMTX removal archives its installation and unit files before retiring the dedicated service account. It does not reinstall the media server. Each successful stage records a root-private deployment receipt. Review that receipt before retrying a partial migration.

The old container is named `shadowbox-before-security` with restart disabled. Its original state remains at `/opt/outline/persisted-state`; the new container mounts `/opt/outline/persisted-state-security` at the original in-container path. To roll the application back, stop/remove only the new container, rename the saved old container to `shadowbox`, restore its saved restart policy, and start it. Changes made in Manager after migration exist only in the new state copy and must be reconciled before a later rollback. Do not run both against the same ports.

After deployment, verify retained identities without printing secrets, actual running executable hashes and UIDs, public/private listener behavior, the absence of MediaMTX listeners, the price monitor and YouTube service, and Watchtower's Docker API compatibility. Reboot once to activate the patched kernel, then verify boot persistence. Independent external WAN testing and sustained throughput testing are separate checks; a LAN probe does not establish them.

Check `docker info` for effective memory-controller support. On this Pi the firmware-injected command line disabled it; `cgroup_enable=memory` appended to the backed-up `/boot/firmware/cmdline.txt` enables it at the next boot. Reapply the container memory limits after that reboot if Docker discarded them while the controller was disabled, and verify the actual `memory.max` cgroup file.

`update_watchtower.py` separately installs the pinned, scanned Watchtower 1.23.2 image after memory control is active. Place its checksum-verified archive at `watchtower-image.tar` inside the private backup and run the script with `--backup`. It tests Docker API access in monitor-only mode, creates a stopped candidate before touching the old updater, preserves its command/environment/mounts, and retains a stopped rollback container. The updater uses a read-only filesystem, no added capabilities, no privilege escalation and a 256 MiB memory cap.

On-device validation on 2026-10-24 included a reboot into kernel 6.12.109, all five existing keys over TCP/UDP, the full POST prefix, retained certificate/server identity, and an exact comparison of 72 historical samples. Isolated untrusted IPv4/IPv6 sources successfully used authenticated port 80 while direct SSH/Manager connections were denied. Forwarding rules were unchanged, the price monitor and YouTube service remained active, and resource limits were verified through the actual cgroup files. Independent Internet-side tests and sustained load tests were not performed.

MediaMTX was subsequently removed at the user's request. The TCP ports 1935/8554/8888/8889 and UDP ports 8000/8001/8189/8890 are no longer permitted by the host input policy. VPN port 80, SSH, VNC, Manager LAN access and mDNS retain their existing rules. Applying an updated policy reloads an already active guard service.
