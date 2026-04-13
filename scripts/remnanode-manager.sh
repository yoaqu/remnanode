#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/remnanode"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
NODE_NAME="remnanode"
STATE_DIR="/var/lib/remnanode-manager"
INSTALL_STATE_FILE="$STATE_DIR/install-grpc-raw.pending"
DEFAULT_SECRET_KEY="supersecretkey"
NODE_PORT="2222"
X25519_MAX_ATTEMPTS="60"
X25519_RETRY_SECONDS="5"

on_error() {
  local exit_code=$?
  echo
  echo "The script stopped because a command failed."
  echo "Failed command: ${BASH_COMMAND}"
  echo "Exit code: ${exit_code}"
  echo "Review the message above, fix the problem, and run the script again."
  exit "${exit_code}"
}

trap on_error ERR

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Run this script with sudo, for example:"
    echo "sudo bash $0"
    exit 1
  fi
}

ensure_ubuntu() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
      echo "This script is intended for Ubuntu servers."
      read -r -p "Continue anyway? [y/N]: " answer
      if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        exit 0
      fi
    fi
  fi
}

pause_for_user() {
  read -r -p "Press Enter to continue..." _
}

docker_installed() {
  command -v docker >/dev/null 2>&1
}

compose_file_exists() {
  [[ -f "${COMPOSE_FILE}" ]]
}

container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${NODE_NAME}"
}

container_status() {
  docker inspect -f '{{.State.Status}}' "${NODE_NAME}" 2>/dev/null || echo "missing"
}

extract_secret_key() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    return 0
  fi

  local line value
  line="$(grep -E 'SECRET_KEY[:=]' "${COMPOSE_FILE}" | head -n 1 || true)"
  if [[ -z "${line}" ]]; then
    return 0
  fi

  if [[ "${line}" == *"SECRET_KEY:"* ]]; then
    value="${line#*:}"
  else
    value="${line#*=}"
  fi

  value="$(printf '%s' "${value}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "${value}"
}

write_compose_file() {
  local secret_key escaped_secret
  secret_key="${1}"
  escaped_secret="$(printf "%s" "${secret_key}" | sed "s/'/''/g")"

  mkdir -p "${APP_DIR}"

  cat > "${COMPOSE_FILE}" <<EOF
services:
  remnanode:
    container_name: ${NODE_NAME}
    image: remnawave/node:latest
    restart: always
    network_mode: host
    logging:
      driver: "none"
    environment:
      NODE_PORT: "${NODE_PORT}"
      SECRET_KEY: '${escaped_secret}'
EOF
}

run_compose_up() {
  (
    cd "${APP_DIR}"
    docker compose up -d
  )
}

run_compose_down() {
  if [[ -f "${COMPOSE_FILE}" ]]; then
    (
      cd "${APP_DIR}"
      docker compose down
    )
  fi
}

wait_for_container() {
  local attempt
  for attempt in {1..15}; do
    if [[ "$(container_status)" == "running" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "The remnanode container did not reach the running state in time."
  return 1
}

ensure_docker() {
  if docker_installed; then
    echo "Docker is already installed."
    return 0
  fi

  echo "Installing Docker..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y ca-certificates curl
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  docker compose version >/dev/null
}

run_x25519_command() {
  local output

  output="$(docker exec "${NODE_NAME}" /usr/local/bin/xray x25519 2>&1)" && {
    printf '%s' "${output}"
    return 0
  }

  output="$(docker exec "${NODE_NAME}" xray x25519 2>&1)" && {
    printf '%s' "${output}"
    return 0
  }

  output="$(docker exec "${NODE_NAME}" rw-core x25519 2>&1)" && {
    printf '%s' "${output}"
    return 0
  }

  printf '%s' "${output}"
  return 1
}

generate_private_key() {
  local output private_key attempt

  echo "Waiting for Xray to become ready..." >&2

  for ((attempt = 1; attempt <= X25519_MAX_ATTEMPTS; attempt++)); do
    output="$(run_x25519_command)" || true
    private_key="$(printf '%s\n' "${output}" | awk -F': ' '/Private key/ { print $2; exit }')"
    if [[ -n "${private_key}" ]]; then
      printf '%s' "${private_key}"
      return 0
    fi

    if (( attempt < X25519_MAX_ATTEMPTS )); then
      echo "Xray is not ready yet. Waiting ${X25519_RETRY_SECONDS}s before retry ${attempt}/${X25519_MAX_ATTEMPTS}..." >&2
      sleep "${X25519_RETRY_SECONDS}"
    fi
  done

  echo "Could not extract the private key automatically."
  echo "Last x25519 output:"
  printf '%s\n' "${output}"
  echo
  echo "You can also try these commands manually:"
  echo "sudo docker exec ${NODE_NAME} /usr/local/bin/xray x25519"
  echo "sudo docker exec ${NODE_NAME} xray x25519"
  echo "sudo docker exec ${NODE_NAME} rw-core x25519"
  return 1
}

prompt_for_panel_secret_key() {
  local secret_key
  while true; do
    echo
    read -r -p "Paste SECRET_KEY from your Remnawave panel: " secret_key
    if [[ -z "${secret_key}" ]]; then
      echo "SECRET_KEY cannot be empty."
      continue
    fi
    if [[ "${secret_key}" == "${DEFAULT_SECRET_KEY}" ]]; then
      echo "Paste the real key from the panel, not the placeholder value."
      continue
    fi
    printf '%s' "${secret_key}"
    return 0
  done
}

prompt_for_private_key() {
  local private_key
  while true; do
    echo
    read -r -p "Paste the private key manually, or leave empty to stop: " private_key
    if [[ -z "${private_key}" ]]; then
      return 1
    fi
    printf '%s' "${private_key}"
    return 0
  done
}

configure_firewall() {
  echo "Configuring UFW..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y ufw

  ufw allow 22/tcp comment 'SSH'
  ufw allow 2222/tcp comment 'Remnanode API'
  ufw allow 443/tcp comment 'VLESS gRPC Reality'
  ufw allow 443/udp comment 'QUIC'
  ufw allow 8443/tcp comment 'VLESS Raw Reality'
  ufw allow 10000:60000/udp comment 'Ephemeral UDP'
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
  ufw status verbose
}

run_system_upgrade() {
  echo "Updating Ubuntu packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y
  apt-get autoremove -y
  mkdir -p "${STATE_DIR}"
  touch "${INSTALL_STATE_FILE}"
}

continue_grpc_raw_install() {
  local private_key panel_secret_key

  echo
  echo "Step 2: Install Docker"
  ensure_docker

  echo
  echo "Step 3: Create ${APP_DIR}"
  mkdir -p "${APP_DIR}"

  echo
  echo "Step 4: Create docker-compose.yml with a temporary SECRET_KEY"
  write_compose_file "${DEFAULT_SECRET_KEY}"

  echo
  echo "Step 5: Start remnanode"
  run_compose_up
  wait_for_container

  echo
  echo "Step 6: Generate Xray x25519 keys"
  if ! private_key="$(generate_private_key)"; then
    echo
    echo "Automatic private key extraction failed."
    private_key="$(prompt_for_private_key)" || return 1
  fi
  echo "Private key:"
  echo "${private_key}"

  echo
  echo "Step 7: Update docker-compose.yml with the real panel SECRET_KEY"
  panel_secret_key="$(prompt_for_panel_secret_key)"
  write_compose_file "${panel_secret_key}"
  run_compose_down
  run_compose_up
  wait_for_container

  echo
  echo "Step 8: Configure firewall"
  configure_firewall

  rm -f "${INSTALL_STATE_FILE}"
  echo
  echo "Installation finished."
  echo "Container status: $(container_status)"
}

install_grpc_raw() {
  if [[ -f "${INSTALL_STATE_FILE}" ]]; then
    if [[ -f /var/run/reboot-required ]]; then
      echo
      echo "Ubuntu is still asking for a reboot."
      echo "Reboot the server first, then run this script again and choose:"
      echo "Node installation -> gRPC + RAW"
      return 0
    fi

    echo
    echo "The package update step was already completed."
    echo "Continuing with Docker and remnanode setup..."
    continue_grpc_raw_install
    return 0
  fi

  echo
  echo "Step 1: System update and cleanup"
  run_system_upgrade

  echo
  echo "The server now needs to reboot before the installation can continue."
  echo "After reboot, run this script again and choose:"
  echo "Node installation -> gRPC + RAW"
  read -r -p "Reboot now? [Y/n]: " answer
  if [[ "${answer}" =~ ^[Nn]$ ]]; then
    echo "Reboot the server manually, then run the script again."
    return 0
  fi

  reboot
}

update_secret_key_and_restart() {
  local panel_secret_key
  panel_secret_key="$(prompt_for_panel_secret_key)"
  write_compose_file "${panel_secret_key}"
  run_compose_down
  run_compose_up
  wait_for_container
  echo "SECRET_KEY updated and remnanode restarted."
}

recreate_remnanode() {
  local current_secret_key

  ensure_docker
  current_secret_key="$(extract_secret_key || true)"
  if [[ -z "${current_secret_key}" ]]; then
    current_secret_key="${DEFAULT_SECRET_KEY}"
  fi

  write_compose_file "${current_secret_key}"
  run_compose_down || true
  run_compose_up
  wait_for_container
  echo "remnanode was recreated."
}

show_private_key_again() {
  local private_key

  ensure_docker
  if ! container_exists; then
    echo "The remnanode container does not exist yet."
    return 0
  fi

  if [[ "$(container_status)" != "running" ]]; then
    echo "The remnanode container is not running, so the key cannot be generated right now."
    return 0
  fi

  if ! private_key="$(generate_private_key)"; then
    echo "Automatic private key extraction failed."
    return 1
  fi
  echo "Private key:"
  echo "${private_key}"
}

show_fix_diagnostics() {
  local current_secret_key

  echo
  echo "Detected state:"
  if docker_installed; then
    echo "- Docker: installed"
  else
    echo "- Docker: missing"
  fi

  if compose_file_exists; then
    echo "- Compose file: ${COMPOSE_FILE}"
  else
    echo "- Compose file: missing"
  fi

  current_secret_key="$(extract_secret_key || true)"
  if [[ -z "${current_secret_key}" ]]; then
    echo "- SECRET_KEY: missing"
  elif [[ "${current_secret_key}" == "${DEFAULT_SECRET_KEY}" ]]; then
    echo "- SECRET_KEY: placeholder value detected"
  else
    echo "- SECRET_KEY: configured"
  fi

  if docker_installed && container_exists; then
    echo "- Container: $(container_status)"
  else
    echo "- Container: missing"
  fi
}

fix_node_menu() {
  local choice

  while true; do
    show_fix_diagnostics

    echo
    echo "Fix node:"
    echo "1. Update SECRET_KEY and restart node"
    echo "2. Recreate remnanode"
    echo "3. Show x25519 private key again"
    echo "4. Reconfigure firewall"
    echo "0. Back"
    read -r -p "Choose option: " choice

    case "${choice}" in
      1)
        update_secret_key_and_restart
        pause_for_user
        ;;
      2)
        recreate_remnanode
        pause_for_user
        ;;
      3)
        show_private_key_again
        pause_for_user
        ;;
      4)
        configure_firewall
        pause_for_user
        ;;
      0)
        return 0
        ;;
      *)
        echo "Invalid option."
        ;;
    esac
  done
}

installation_menu() {
  local choice

  while true; do
    echo
    echo "Node installation:"
    echo "1. gRPC + RAW"
    echo "2. Will be available soon"
    echo "0. Back"
    read -r -p "Choose option: " choice

    case "${choice}" in
      1)
        install_grpc_raw
        return 0
        ;;
      2)
        echo "This option will be available soon."
        pause_for_user
        ;;
      0)
        return 0
        ;;
      *)
        echo "Invalid option."
        ;;
    esac
  done
}

main_menu() {
  local choice

  while true; do
    echo
    echo "Choose option:"
    echo "1. Node installation"
    echo "2. Fix node"
    echo "0. Exit"
    read -r -p "Choose option: " choice

    case "${choice}" in
      1)
        installation_menu
        ;;
      2)
        fix_node_menu
        ;;
      0)
        exit 0
        ;;
      *)
        echo "Invalid option."
        ;;
    esac
  done
}

require_root
ensure_ubuntu
main_menu
