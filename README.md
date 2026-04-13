# Easy No-Logs Remnanode Ubuntu Installer

Reusable Ubuntu setup script for installing and fixing a `remnawave/node`.

## What it does

- menu-based setup
- `Node installation -> No-Domain`
- Docker install
- `/opt/remnanode/docker-compose.yml` creation
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
1. No-Domain
```

On the first run, the script updates the server and asks for a reboot. After reboot, run it again and choose the same option to finish setup.
The installer will ask for the `SECRET_KEY` from your Remnawave panel before starting the node.
