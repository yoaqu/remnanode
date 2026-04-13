# Remnanode Ubuntu Setup Script

Reusable Ubuntu setup script for installing and fixing a `remnawave/node`.

## What it does

- menu-based setup
- `Node installation -> gRPC + RAW`
- Docker install
- `/opt/remnanode/docker-compose.yml` creation
- `xray x25519` private key generation
- `SECRET_KEY` update from your Remnawave panel
- container restart
- UFW firewall configuration
- basic repair tools in `Fix node`

## Run on Ubuntu

```bash
curl -fsSL -o remnanode-manager.sh https://raw.githubusercontent.com/yoaqu/remnanode/main/scripts/remnanode-manager.sh
chmod +x remnanode-manager.sh
sudo ./remnanode-manager.sh
```

Then choose:

```text
1. Node installation
1. gRPC + RAW
```

On the first run, the script updates the server and asks for a reboot. After reboot, run it again and choose the same option to finish setup.
