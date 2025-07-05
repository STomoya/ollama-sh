#!/bin/bash

# --------------------------------
#
# MIT License
#
# Copyright (c) 2025 Tomoya Sawada
#
# --------------------------------

set -euo pipefail

# --- Colors ---
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_CYAN=$'\033[0;36m'

# --- Default values ---
VERSION="0.1.0"
CONTAINER_NAME="ollama"
VOLUME_NAME="ollama"
IMAGE_NAME="docker.io/ollama/ollama"
PORT="11434"
CONTAINER_CMD=""
VERBOSE=""

# --- Ollama environment variable options ---
OLLAMA_DEBUG=""
OLLAMA_FLASH_ATTENTION="1"
OLLAMA_KEEP_ALIVE=""
OLLAMA_MAX_LOADED_MODELS="2"
OLLAMA_NUM_PARALLEL="1"

# --- Help function ---
usage() {
  # Use printf for better formatting and color handling
  local runtime_name=${CONTAINER_CMD^} # Capitalize first letter
  printf "${C_BOLD}Ollama Container Manager${C_RESET} v${VERSION} (using ${C_GREEN}${runtime_name}${C_RESET})\n"
  printf "\nManages the Ollama container lifecycle using ${runtime_name}.\n"
  printf "\n${C_BOLD}${C_YELLOW}USAGE:${C_RESET}\n"
  printf "  ${C_BOLD}%s${C_RESET} <command> [options]\n" "$0"
  printf "\n${C_BOLD}${C_YELLOW}COMMANDS:${C_RESET}\n"
  printf "  ${C_GREEN}%-10s${C_RESET} %s\n" "run" "Start the Ollama container with specified options."
  printf "  ${C_GREEN}%-10s${C_RESET} %s\n" "stop" "Stop and remove the Ollama container."
  printf "  ${C_GREEN}%-10s${C_RESET} %s\n" "restart" "Restart the Ollama container."
  printf "  ${C_GREEN}%-10s${C_RESET} %s\n" "pull" "Pull the latest ollama image."
  printf "  ${C_GREEN}%-10s${C_RESET} %s\n" "update" "Pull the latest image and prompt to re-create the container."
  printf "  ${C_GREEN}%-10s${C_RESET} %s\n" "recreate" "Re-create the container using the latest image and existing settings."
  printf "  ${C_GREEN}%-10s${C_RESET} %s\n" "logs" "View logs. Pass extra args like -f (e.g., '$0 logs -f')."
  printf "  ${C_GREEN}%-10s${C_RESET} %s\n" "ollama" "Run ollama CLI commands inside the container (e.g., '$0 ollama pull llama2')."
  printf "  ${C_GREEN}%-10s${C_RESET} %s\n" "shell" "Start an interactive shell inside the container."
  printf "  ${C_GREEN}%-10s${C_RESET} %s\n" "status" "Show the status of the container."
  printf "  ${C_GREEN}%-10s${C_RESET} %s\n" "help" "Show this help message."

  printf "\n${C_BOLD}${C_YELLOW}GLOBAL OPTIONS:${C_RESET}\n"
  printf "  ${C_GREEN}%-15s${C_RESET} %s\n" "-h, --help" "Show this help message."
  printf "  ${C_GREEN}%-15s${C_RESET} %s\n" "-v, --verbose" "Enable verbose output."
  printf "  ${C_GREEN}%-15s${C_RESET} %s\n" "--version" "Show script version."
  printf "  ${C_GREEN}%-15s${C_RESET} %s\n" "--no-color" "Disable color output."
}

# --- Help function for 'run' command ---
usage_run() {
  printf "${C_BOLD}${C_YELLOW}USAGE:${C_RESET}\n"
  printf "  ${C_BOLD}%s${C_RESET} run [OPTIONS]\n" "$0"
  printf "\n${C_BOLD}${C_YELLOW}OPTIONS for 'run' command:${C_RESET}\n"
  printf "  ${C_GREEN}%-32s${C_RESET} %s\n" "-p, --port <port>" "Set the host port to expose. (default: ${C_CYAN}${PORT}${C_RESET})"
  printf "  ${C_GREEN}%-32s${C_RESET} %s\n" "-d, --debug" "Enable debug mode by setting ${C_CYAN}OLLAMA_DEBUG=1${C_RESET}."
  printf "  ${C_GREEN}%-32s${C_RESET} %s\n" "-f, --flash-attention" "Enable flash attention via ${C_CYAN}OLLAMA_FLASH_ATTENTION=1${C_RESET}. (default: ${C_CYAN}enabled${C_RESET})"
  printf "  ${C_GREEN}%-32s${C_RESET} %s\n" "-k, --keep-alive <duration>" "Set ${C_CYAN}OLLAMA_KEEP_ALIVE${C_RESET}. (e.g., '5m', '-1')"
  printf "  ${C_GREEN}%-32s${C_RESET} %s\n" "-m, --max-loaded-models <count>" "Set ${C_CYAN}OLLAMA_MAX_LOADED_MODELS${C_RESET}. (default: ${C_CYAN}${OLLAMA_MAX_LOADED_MODELS}${C_RESET})"
  printf "  ${C_GREEN}%-32s${C_RESET} %s\n" "-n, --num-parallel <count>" "Set ${C_CYAN}OLLAMA_NUM_PARALLEL${C_RESET}. (default: ${C_CYAN}${OLLAMA_NUM_PARALLEL}${C_RESET})"
  printf "  ${C_GREEN}%-32s${C_RESET} %s\n" "-V, --volume-path <path>" "Bind mount a host path for models. (default: named volume '${C_CYAN}${VOLUME_NAME}${C_RESET}')"
  printf "  ${C_GREEN}%-32s${C_RESET} %s\n" "--force" "Force removal of an existing container before running."
  printf "  ${C_GREEN}%-32s${C_RESET} %s\n" "-h, --help" "Show this help message for the 'run' command."
}

# --- Color setup ---
disable_colors() {
  C_RESET=""
  C_BOLD=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
}

# --- Logging function ---
# Prints messages only when VERBOSE is set.
log() {
  if [[ -n "${VERBOSE}" ]]; then
    printf "${C_CYAN}==>${C_RESET} %s\n" "$@"
  fi
}

# --- Prerequisite check ---
check_dependencies() {
  if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
  elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
  else
    printf "${C_YELLOW}Error: Neither 'podman' nor 'docker' found in your PATH.${C_RESET}\n" >&2
    printf "Please install one of them to manage the Ollama container.\n" >&2
    exit 1
  fi
  log "Using '${CONTAINER_CMD}' as the container runtime."
}

# --- Helper Functions ---

# A compatible way to check if a container exists for both podman and docker
container_exists() {
  # We check for the container name passed as the first argument
  "${CONTAINER_CMD}" container inspect "$1" &>/dev/null
}

# Helper to ensure the container is running before executing a command
ensure_container_running() {
  if ! container_exists "${CONTAINER_NAME}"; then
    printf "Container ${C_YELLOW}%s${C_RESET} is not running. Use 'run' to start it.\n" "${CONTAINER_NAME}" >&2
    exit 1
  fi
}

# --- Command Functions ---

cmd_run() {
  # --- Argument Parsing for 'run' using getopt ---
  local VOLUME_PATH=""
  local FORCE_RUN=""

  # Manual and safer argument parsing loop.
  # This avoids `eval` and the dependency on GNU getopt.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage_run
        exit 0
        ;;
      -p|--port)
        [[ -n "${2-}" ]] || { printf "Error: Missing argument for %s\n" "$1" >&2; exit 1; }
        PORT="$2"; shift 2 ;;
      -d|--debug)
        OLLAMA_DEBUG="1"; shift ;;
      -f|--flash-attention)
        OLLAMA_FLASH_ATTENTION="1"; shift ;;
      -k|--keep-alive)
        [[ -n "${2-}" ]] || { printf "Error: Missing argument for %s\n" "$1" >&2; exit 1; }
        OLLAMA_KEEP_ALIVE="$2"; shift 2 ;;
      -m|--max-loaded-models)
        [[ -n "${2-}" ]] || { printf "Error: Missing argument for %s\n" "$1" >&2; exit 1; }
        OLLAMA_MAX_LOADED_MODELS="$2"; shift 2 ;;
      -n|--num-parallel)
        [[ -n "${2-}" ]] || { printf "Error: Missing argument for %s\n" "$1" >&2; exit 1; }
        OLLAMA_NUM_PARALLEL="$2"; shift 2 ;;
      -V|--volume-path)
        [[ -n "${2-}" ]] || { printf "Error: Missing argument for %s\n" "$1" >&2; exit 1; }
        VOLUME_PATH="$2"; shift 2 ;;
      --force)
        FORCE_RUN="true"; shift ;;
      --) shift; break ;; # Explicit end of options
      -*) printf "Error: Unknown option '%s'\n" "$1" >&2; usage_run; exit 1 ;;
      *) break ;; # End of options
    esac
  done

  # Check for existing container
  if container_exists "${CONTAINER_NAME}"; then
    if [[ -n "${FORCE_RUN}" ]]; then
      log "Container '${CONTAINER_NAME}' exists. --force is set, removing it."
      "${CONTAINER_CMD}" rm --force "${CONTAINER_NAME}" > /dev/null
    else
      printf "Error: Container '${C_YELLOW}%s${C_RESET}' already exists.\n" "${CONTAINER_NAME}" >&2
      printf "Use the ${C_GREEN}'--force'${C_RESET} flag to remove it and start a new one, or use the ${C_GREEN}'stop'${C_RESET} command first.\n" >&2
      exit 1
    fi
  fi

  # Determine volume argument
  local volume_arg
  if [[ -n "${VOLUME_PATH}" ]]; then
    # Ensure the host path exists and is a directory
    if [[ -e "${VOLUME_PATH}" && ! -d "${VOLUME_PATH}" ]]; then
      printf "Error: Volume path '%s' exists but is not a directory.\n" "${VOLUME_PATH}" >&2
      exit 1
    elif [[ ! -d "${VOLUME_PATH}" ]]; then
      log "Volume path '${VOLUME_PATH}' does not exist. Creating it."
      if ! mkdir -p "${VOLUME_PATH}"; then
        printf "Error: Failed to create volume path '%s'.\n" "${VOLUME_PATH}" >&2
        exit 1
      fi
    fi

    log "Using host path for volume: ${VOLUME_PATH}"
    volume_arg="${VOLUME_PATH}:/root/.ollama"
  else
    log "Using named volume: ${VOLUME_NAME}"
    volume_arg="${VOLUME_NAME}:/root/.ollama"
  fi

  # Base arguments for podman run
  local RUN_ARGS=(
    --detach
    --volume="${volume_arg}"
    --publish="${PORT}:11434"
    --name="${CONTAINER_NAME}"
  )

  # Check for NVIDIA GPU and add the appropriate flag for the runtime
  if command -v nvidia-smi &> /dev/null; then
    log "NVIDIA GPU detected. Enabling GPU acceleration."
    if [[ "${CONTAINER_CMD}" == "podman" ]]; then
      RUN_ARGS+=(--device=nvidia.com/gpu=all)
    else # docker
      RUN_ARGS+=(--gpus=all)
    fi
  else
    log "No NVIDIA GPU detected or nvidia-smi not in PATH. Running in CPU-only mode."
  fi

  # Add Ollama environment variables if they are set. This is more maintainable than repeated 'if' statements.
  local ollama_env_vars=(
    "OLLAMA_DEBUG"
    "OLLAMA_FLASH_ATTENTION"
    "OLLAMA_KEEP_ALIVE"
    "OLLAMA_MAX_LOADED_MODELS"
    "OLLAMA_NUM_PARALLEL"
  )
  for var_name in "${ollama_env_vars[@]}"; do
    # Use indirect parameter expansion to get the value of the variable named by var_name
    if [[ -n "${!var_name-}" ]]; then # Use - to avoid unbound variable error with 'set -u'
      RUN_ARGS+=("--env" "${var_name}=${!var_name}")
    fi
  done

  # Run the Ollama container
  log "Starting Ollama container..."
  if [[ -n "${VERBOSE}" ]]; then
    printf "${C_YELLOW}RUNNING:${C_RESET} ${CONTAINER_CMD} run %s %s\n" "${RUN_ARGS[*]}" "${IMAGE_NAME}"
  fi
  "${CONTAINER_CMD}" run "${RUN_ARGS[@]}" "${IMAGE_NAME}" > /dev/null

  # Show the running container
  printf "Container ${C_GREEN}%s${C_RESET} started.\n" "${CONTAINER_NAME}"
  if [[ -n "${VERBOSE}" ]]; then
    cmd_status
  fi
}

cmd_stop() {
  if container_exists "${CONTAINER_NAME}"; then
    printf "${C_CYAN}==>${C_RESET} Stopping and removing container: %s\n" "${CONTAINER_NAME}"
    log "Executing: ${CONTAINER_CMD} rm --force ${CONTAINER_NAME}"
    "${CONTAINER_CMD}" rm --force "${CONTAINER_NAME}" >/dev/null
    printf "Container ${C_GREEN}%s${C_RESET} stopped and removed.\n" "${CONTAINER_NAME}"
  else
    printf "Container ${C_YELLOW}%s${C_RESET} is not running. Nothing to do.\n" "${CONTAINER_NAME}"
  fi
}

cmd_restart() {
  printf "${C_CYAN}==>${C_RESET} Restarting container: %s\n" "${CONTAINER_NAME}"
  ensure_container_running
  log "Executing: ${CONTAINER_CMD} restart ${CONTAINER_NAME}"
  "${CONTAINER_CMD}" restart "${CONTAINER_NAME}" >/dev/null
  printf "Container ${C_GREEN}%s${C_RESET} restarted.\n" "${CONTAINER_NAME}"
}

cmd_pull() {
  printf "${C_CYAN}==>${C_RESET} Pulling latest image: %s\n" "${IMAGE_NAME}"
  log "Executing: ${CONTAINER_CMD} pull ${IMAGE_NAME}"
  "${CONTAINER_CMD}" pull "${IMAGE_NAME}"
}

cmd_update() {
  printf "${C_CYAN}==>${C_RESET} Checking for new version of %s...\n" "${IMAGE_NAME}"

  local old_image_id
  old_image_id=$("${CONTAINER_CMD}" image inspect "${IMAGE_NAME}" --format '{{.Id}}' 2>/dev/null || echo "")

  # Pull the latest image first
  "${CONTAINER_CMD}" pull "${IMAGE_NAME}"

  local new_image_id
  new_image_id=$("${CONTAINER_CMD}" image inspect "${IMAGE_NAME}" --format '{{.Id}}' 2>/dev/null || {
    printf "Error: Failed to inspect image after pull.\n" >&2
    exit 1
  })

  if [[ "${old_image_id}" == "${new_image_id}" ]]; then
    printf "Image is already up to date.\n"
    return
  fi

  printf "${C_GREEN}Image updated successfully.${C_RESET}\n"

  # If the container isn't running, we don't need to do anything else.
  if ! container_exists "${CONTAINER_NAME}"; then
    printf "Container ${C_YELLOW}%s${C_RESET} is not running. Use 'run' to start it with the new image.\n" "${CONTAINER_NAME}"
    return
  fi

  # Prompt the user to recreate
  printf "A new image has been downloaded. "
  read -p "Re-create the container now to apply it? (y/N) " -r response
  echo # Add a newline for better formatting
  if [[ "${response,,}" =~ ^(yes|y)$ ]]; then
    cmd_recreate
  else
    printf "Update downloaded. Run '${C_BOLD}%s recreate${C_RESET}' later to apply the changes.\n" "$0"
  fi
}

cmd_recreate() {
  ensure_container_running
  printf "Re-creating container with previous settings to apply latest image...\n"

  # Reconstruct the run arguments from the container's current configuration
  # using the --format flag, which avoids the need for 'jq'.
  local RUN_ARGS=(
    --detach
    --name="${CONTAINER_NAME}"
  )

  # Extract port bindings
  # Format: '{{(index .HostConfig.PortBindings "11434/tcp" 0).HostPort}}'
  local host_port
  host_port=$("${CONTAINER_CMD}" inspect --format '{{(index .HostConfig.PortBindings "11434/tcp" 0).HostPort}}' "${CONTAINER_NAME}")
  log "Re-creating with host port: ${host_port}"
  RUN_ARGS+=(--publish="${host_port}:11434")

  # Extract volume source (name for named volumes, path for bind mounts).
  # The destination path inside the container is always /root/.ollama.
  local volume_source
  volume_source=$("${CONTAINER_CMD}" inspect --format '{{with (index .Mounts 0)}}{{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}' "${CONTAINER_NAME}")
  log "Re-creating with volume source: ${volume_source}"
  local volume_mount="${volume_source}:/root/.ollama"
  RUN_ARGS+=(--volume="${volume_mount}")

  # Extract all OLLAMA_* environment variables
  log "Re-creating with the following environment variables:"
  # We extract all env vars and then use grep to filter for the ones we need.
  while IFS= read -r env_var; do
    # Skip empty lines that grep might produce
    if [[ -n "${env_var}" ]]; then
      log "  - ${env_var}"
      RUN_ARGS+=("--env" "${env_var}")
    fi
  done < <("${CONTAINER_CMD}" inspect --format '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "${CONTAINER_NAME}" | grep '^OLLAMA_')

  # Re-add GPU flags if applicable (safer to detect from host than parse from inspect)
  if command -v nvidia-smi &> /dev/null; then
    [[ "${CONTAINER_CMD}" == "podman" ]] && RUN_ARGS+=(--device=nvidia.com/gpu=all) || RUN_ARGS+=(--gpus=all)
  fi

  # Stop the old container and start the new one
  cmd_stop
  if [[ -n "${VERBOSE}" ]]; then
    printf "${C_YELLOW}RUNNING:${C_RESET} ${CONTAINER_CMD} run %s %s\n" "${RUN_ARGS[*]}" "${IMAGE_NAME}"
  fi
  "${CONTAINER_CMD}" run "${RUN_ARGS[@]}" "${IMAGE_NAME}" > /dev/null
  printf "Container ${C_GREEN}%s${C_RESET} has been updated and restarted with its previous configuration.\n" "${CONTAINER_NAME}"
}

cmd_logs() {
  ensure_container_running
  # Pass all extra arguments to podman logs (e.g., -f, --tail, --since)
  # We pipe the output to sed to add a prefix, similar to 'docker compose up'.
  # The -u flag ensures sed is unbuffered, which is crucial for following logs (-f).
  local prefix="${C_GREEN}[${CONTAINER_NAME}]${C_RESET} | "
  "${CONTAINER_CMD}" logs "$@" "${CONTAINER_NAME}" | sed -u "s/^/${prefix}/"
}

cmd_ollama() {
  ensure_container_running

  log "Executing: ${CONTAINER_CMD} exec -it ${CONTAINER_NAME} ollama $*"
  # -it for interactive commands (e.g., ollama run)
  "${CONTAINER_CMD}" exec -it "${CONTAINER_NAME}" ollama "$@"
}

cmd_shell() {
  ensure_container_running
  log "Opening an interactive shell in container: ${CONTAINER_NAME}"
  "${CONTAINER_CMD}" exec -it "${CONTAINER_NAME}" /bin/bash
}

cmd_status() {
  if container_exists "${CONTAINER_NAME}"; then
    printf "${C_CYAN}==>${C_RESET} Status for container: %s\n" "${CONTAINER_NAME}"
    "${CONTAINER_CMD}" ps --filter "name=${CONTAINER_NAME}"
  else
    printf "Container ${C_YELLOW}%s${C_RESET} is not running.\n" "${CONTAINER_NAME}"
  fi
}

# --- Script Entrypoint ---

# First, check for our container runtime dependency
check_dependencies

# Disable colors if stdout is not a TTY (and --no-color wasn't already passed)
if [[ ! -t 1 ]]; then
  disable_colors
fi

# Pre-process arguments for global flags like --verbose or --help.
# This allows flags to be placed before the command, e.g., `./run_ollama.sh --verbose run`
new_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --version)
      printf "ollama.sh version %s\n" "${VERSION}"
      exit 0
      ;;
    -v|--verbose)
      VERBOSE="true"
      shift # consume flag
      ;;
    --no-color)
      disable_colors
      shift # consume flag
      ;;
    *)
      # First non-flag argument marks the end of global options.
      # Add it and all subsequent arguments to new_args and stop parsing.
      new_args+=("$@")
      break
      ;;
  esac
done

# Overwrite the script's positional parameters with the filtered list
set -- "${new_args[@]}"

# --- Main Dispatch ---
COMMAND="${1:-help}"
shift || true # Avoid error if no args are present
log "Dispatching command '${COMMAND}' with arguments: $*"

case "${COMMAND}" in
  run)
    cmd_run "$@"
    ;;
  stop)
    cmd_stop
    ;;
  restart)
    cmd_restart
    ;;
  pull)
    cmd_pull
    ;;
  update)
    cmd_update
    ;;
  recreate)
    cmd_recreate
    ;;
  logs)
    cmd_logs "$@"
    ;;
  ollama)
    cmd_ollama "$@"
    ;;
  shell)
    cmd_shell
    ;;
  help)
    usage
    exit 0
    ;;
  status)
    cmd_status
    ;;
  *)
    printf "Error: Unknown command '%s'\n\n" "${COMMAND}" >&2
    usage
    exit 1
    ;;
esac
