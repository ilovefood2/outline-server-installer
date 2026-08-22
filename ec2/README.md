# Outline Server on AWS EC2 x86_64

This installer builds the patched Outline Server image natively on an x86_64 EC2 instance. It defaults to:

- TCP and UDP port `80` for access keys
- `&prefix=POST%20` on every Manager-generated access URL
- TCP port `443` for the Outline Manager API
- Access from valid keys to private VPC/LAN targets reachable by the instance

## Supported EC2 hosts

- Architecture: `x86_64` / `amd64` (for example, t3, t3a, c5, m5, or m7i; do not use Graviton/t4g)
- OS: Ubuntu, Debian, Amazon Linux 2, or Amazon Linux 2023
- Memory: 4 GB or more recommended for an on-instance build
- Disk: at least 20 GB free

Use an Elastic IP or stable DNS hostname. An Elastic IP must be associated with an instance in a public subnet that has internet access: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/working-with-eips.html

The installer detects `apt-get`, `dnf`, or `yum`; on Amazon Linux it installs Docker using the AWS-supported package path.

## Security group

Before installation, create inbound rules appropriate for your deployment:

| Protocol | Port | Source | Purpose |
|---|---:|---|---|
| TCP | 22 | Your administration CIDR | SSH |
| TCP | 443 | Trusted Manager administrator CIDRs | Outline Manager API |
| TCP | 80 | Client CIDRs | Outline client traffic |
| UDP | 80 | Client CIDRs | Outline client traffic |

Do not expose TCP 443 more broadly than necessary. If you override `--api-port`, update the corresponding security-group rule.

For VPC targets, their security groups must also allow traffic from this EC2 instance or its security group. Enabling LAN access in Outline does not bypass AWS security groups or network ACLs.

## Install

For a new EC2 instance, use the version-pinned one-line installer:

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/ilovefood2/outline-server-installer/v1.12.3-r2/ec2/bootstrap.sh)" -- --hostname YOUR_ELASTIC_IP_OR_DNS
```

It downloads the tagged source to `/opt/outline-server-installer-v1.12.3-r2`, then starts the EC2 installer. Arguments after `--` are forwarded to `ec2/install.sh`.

Alternatively, copy the EC2 installer archive to the instance and run:

```bash
tar -xzf outline-server-ec2-x86_64-v1.12.3-r1.tar.gz
cd outline-server-ec2-x86_64-v1.12.3-r1
sudo ./ec2/install.sh --hostname YOUR_ELASTIC_IP_OR_DNS
```

The first build can take several minutes. When it finishes, paste the printed Manager JSON into Outline Manager, then create and share access keys.

## Operations

```bash
sudo ./scripts/status.sh
sudo docker logs -f shadowbox
sudo ./scripts/uninstall.sh            # retains keys/state
sudo ./scripts/uninstall.sh --remove-state --remove-image  # irreversible reset
```
