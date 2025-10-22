#!/usr/bin/env bash
# deploy.sh - Production-ready deploy script for HNG Stage 1
# Requirements: bash (not strictly POSIX), rsync, ssh client, git installed locally.
# Usage: ./deploy.sh      (interactive prompts)
#        ./deploy.sh --repo "https://github.com/..." --pat "ghp_..." --server "1.2.3.4" ...
# Flags: --dry-run, --cleanup, --verbose, --help
set -euo pipefail

### -------------------------
### Config / Defaults
### -------------------------
PROGNAME="$(basename "$0")"
TIMESTAMP="$(date +%F_%H%M%S)"
LOGFILE="deploy_${TIMESTAMP}.log"
DRY_RUN=false
CLEANUP=false
VERBOSE=false
DEFAULT_BRANCH="main"
RSYNC_EXCLUDES=(--exclude '.git' --exclude '*.log' --exclude 'node_modules')

# Exit codes (examples)
E_GENERIC=1
E_INVALID_INPUT=2
E_SSH_KEY=3
E_NO_DOCKERFILE=4
E_SSH_CONN=10
E_VALIDATE=20
E_REMOTE_INSTALL=30

# Colors for interactive use (if terminal)
if [ -t 1 ]; then
  RED=$(printf '\033[31m')
  GREEN=$(printf '\033[32m')
  YELLOW=$(printf '\033[33m')
  BLUE=$(printf '\033[34m')
  RESET=$(printf '\033[0m')
else
  RED="" ; GREEN="" ; YELLOW="" ; BLUE="" ; RESET=""
fi

### -------------------------
### Logging helpers
### -------------------------
exec > >(tee -a "$LOGFILE") 2>&1

log() {
  printf '%s %s\n' "$(date '+%F %T')" "[INFO]" "$*" | sed 's/^/ /'
}
log_info() { printf '%s %s\n' "$(date '+%F %T')" "[INFO] $*"; }
log_warn() { printf '%s %s\n' "$(date '+%F %T')" "[WARN] $*"; }
log_err() { printf '%s %s\n' "$(date '+%F %T')" "[ERROR] $*" >&2; }

on_exit() {
  code=$?
  if [ $code -ne 0 ]; then
    log_err "Script exited with code $code. Check $LOGFILE for details."
  else
    log_info "Script completed successfully."
  fi
}
trap on_exit EXIT
trap 'log_warn "Interrupted"; exit 130' INT TERM

### -------------------------
### Usage/help
### -------------------------
usage() {
  cat <<EOF
$PROGNAME - Deploy a Dockerized app to a remote Linux server

Options:
  --repo URL            Git repository HTTPS URL (required or will prompt)
  --pat TOKEN           Personal Access Token (recommended to be passed via env or prompt)
  --branch BRANCH       Branch to checkout (default: ${DEFAULT_BRANCH})
  --user USER           Remote SSH username
  --server IP           Remote server IP or hostname
  --ssh-key PATH        SSH private key path (default: ~/.ssh/id_rsa)
  --app-port PORT       Internal container port your app exposes (e.g., 3000)
  --remote-dir PATH     Remote directory to deploy into (default: /home/<user>/deployments/<repo>)
  --dry-run             Show what would run, do not execute remote changes
  --cleanup             Remove deployed resources (remote) instead of deploying
  --verbose             Extra verbose logging
  --help                Show this message

Example (interactive):
  ./deploy.sh

Example (flags):
  ./deploy.sh --repo "https://github.com/user/repo.git" --pat "ghp_..." --server "1.2.3.4" --user ubuntu --app-port 3000

Notes:
 - The script tries to be idempotent.
 - PAT is never printed to logs; it is stored temporarily and removed immediately after use.
EOF
  exit 0
}

### -------------------------
### Argument parsing (supports long flags)
### -------------------------
# Basic parser for long options
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_URL="$2"; shift 2;;
    --pat) PAT="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --user) SSH_USER="$2"; shift 2;;
    --server) SSH_HOST="$2"; shift 2;;
    --ssh-key) SSH_KEY="$2"; shift 2;;
    --app-port) APP_PORT="$2"; shift 2;;
    --remote-dir) REMOTE_DIR="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --cleanup) CLEANUP=true; shift;;
    --verbose) VERBOSE=true; shift;;
    --help) usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

### -------------------------
### Interactive prompts (if missing)
### -------------------------
prompt_if_missing() {
  varname="$1"; prompt="$2"; default="${3:-}"
  if [ -z "${!varname:-}" ]; then
    if [ "$DRY_RUN" = true ]; then
      log_warn "Missing $varname and running in --dry-run; using placeholder."
      eval "$varname='$default'"
    else
      read -rp "$prompt " tmp
      if [ -z "$tmp" ]; then
        eval "$varname='$default'"
      else
        eval "$varname='$tmp'"
      fi
    fi
  fi
}

# defaults
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
APP_PORT="${APP_PORT:-}"
REMOTE_DIR="${REMOTE_DIR:-}"

prompt_if_missing REPO_URL "Enter Git repository HTTPS URL (e.g. https://github.com/user/repo.git):"
# If PAT not provided, prompt (no echo)
if [ -z "${PAT:-}" ]; then
  if [ -t 0 ]; then
    echo -n "Enter Personal Access Token (input hidden): "
    read -rs PAT
    echo
  else
    log_err "No PAT provided and input not a TTY. Provide --pat or set PAT env var."
    exit $E_INVALID_INPUT
  fi
fi

prompt_if_missing BRANCH "Enter branch (default: ${DEFAULT_BRANCH}):" "$DEFAULT_BRANCH"
prompt_if_missing SSH_USER "Enter remote SSH username:"
prompt_if_missing SSH_HOST "Enter remote server IP or hostname:"
prompt_if_missing SSH_KEY "Enter path to SSH private key (default: $SSH_KEY):" "$SSH_KEY"
prompt_if_missing APP_PORT "Enter container internal port (e.g. 3000):"
if [ -z "${REMOTE_DIR}" ]; then
  REPO_BASENAME="$(basename -s .git "$REPO_URL")"
  REMOTE_DIR="/home/${SSH_USER}/deployments/${REPO_BASENAME}"
fi

# Basic validation
if ! echo "$REPO_URL" | grep -qEi '^https?://'; then
  log_err "Repo URL must start with http(s)://"
  exit $E_INVALID_INPUT
fi
if [ -z "${PAT:-}" ]; then
  log_err "PAT is required"
  exit $E_INVALID_INPUT
fi
if [ ! -f "$SSH_KEY" ]; then
  log_err "SSH key not found at $SSH_KEY"
  exit $E_SSH_KEY
fi

log_info "Inputs collected. Repo: ${REPO_URL}, Branch: ${BRANCH}, Server: ${SSH_HOST}, Remote dir: ${REMOTE_DIR}"

### -------------------------
### Utility functions
### -------------------------
run_local() {
  if [ "$VERBOSE" = true ]; then log_info "[LOCAL] $*"; fi
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] local: $*"
  else
    eval "$@"
  fi
}

run_remote() {
  # Run commands on remote via SSH. Accepts a single string (commands), or here-doc style via stdin.
  local cmd="$1"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] ssh -i $SSH_KEY $SSH_USER@$SSH_HOST <<'REMOTE'\n$cmd\nREMOTE"
    return 0
  fi
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "bash -s" <<'REMOTE'
$(cat <<'INNER'
'"$cmd"'
INNER
)
REMOTE
}

ssh_exec() {
  # safer wrapper: pass a here-doc body
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] ssh -i $SSH_KEY $SSH_USER@$SSH_HOST <<'REMOTE'\n$1\nREMOTE"
    return 0
  fi
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "bash -se" <<'REMOTE'
'"$1"'
REMOTE
}

check_ssh_connectivity() {
  log_info "Checking SSH connectivity to $SSH_USER@$SSH_HOST ..."
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] skip SSH connectivity actual test"
    return 0
  fi
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" 'echo ok' >/dev/null 2>&1; then
    log_err "SSH connection test failed to $SSH_HOST as $SSH_USER"
    exit $E_SSH_CONN
  fi
  log_info "SSH connectivity OK."
}

create_temp_netrc() {
  NETRC_FILE="$(mktemp)"
  chmod 600 "$NETRC_FILE"
  # Use login as the PAT; github accepts machine github.com login <token> password x-oauth-basic for older clients.
  cat >"$NETRC_FILE" <<EOF
machine github.com
login ${PAT}
password x-oauth-basic
EOF
  # export var for git to use
  export GIT_NETRC="$NETRC_FILE"
  log_info "Temporary .netrc created."
}

cleanup_temp_netrc() {
  if [ -n "${NETRC_FILE:-}" ] && [ -f "$NETRC_FILE" ]; then
    shred -u "$NETRC_FILE" 2>/dev/null || rm -f "$NETRC_FILE"
    unset NETRC_FILE
    log_info "Temporary .netrc removed."
  fi
}

git_clone_or_update() {
  local repo="$1"
  local branch="$2"
  local local_dir
  local_dir="$(basename -s .git "$repo")"
  if [ -d "$local_dir/.git" ]; then
    log_info "Local repo exists. Fetching latest..."
    (cd "$local_dir" && git fetch --all --prune && git checkout "$branch" && git pull origin "$branch")
  else
    log_info "Cloning repo $repo (branch $branch) ..."
    create_temp_netrc
    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY-RUN] git clone -b $branch $repo"
    else
      # Use GIT_TERMINAL_PROMPT=0 to prevent interactive prompts.
      GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c core.askPass= -c http.sslVerify=true clone -b "$branch" "$repo"
    fi
    cleanup_temp_netrc
  fi
  echo "$local_dir"
}

remote_detect_distro_and_pkgmgr() {
  cat <<'REMOTE_CMD'
set -e
if command -v apt-get >/dev/null 2>&1; then
  echo "apt"
elif command -v yum >/dev/null 2>&1; then
  echo "yum"
elif command -v dnf >/dev/null 2>&1; then
  echo "dnf"
else
  echo "unknown"
fi
REMOTE_CMD
}

remote_prepare_environment() {
  log_info "Preparing remote environment (install Docker, docker compose plugin, nginx) ..."

  local install_script
  install_script=$(cat <<'REMOTE'
set -e
PKG=""
if command -v apt-get >/dev/null 2>&1; then
  PKG="apt"
  sudo apt-get update -y
  # install basic utils if missing
  sudo apt-get install -y ca-certificates curl gnupg lsb-release rsync
elif command -v yum >/dev/null 2>&1; then
  PKG="yum"
  sudo yum makecache -y || true
  sudo yum install -y curl rsync
elif command -v dnf >/dev/null 2>&1; then
  PKG="dnf"
  sudo dnf makecache -y || true
  sudo dnf install -y curl rsync
else
  echo "unsupported"
  exit 2
fi

# Install Docker (using convenience script ensures idempotent check)
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o get-docker.sh
  sudo sh get-docker.sh
  rm -f get-docker.sh
fi

# Ensure docker group exists and user is added
sudo groupadd -f docker || true
sudo usermod -aG docker "$USER" || true

# Enable and start docker
sudo systemctl enable --now docker || true

# Install docker compose plugin if docker compose not found
if ! docker compose version >/dev/null 2>&1; then
  # Try package method first for apt
  if [ "$PKG" = "apt" ]; then
    sudo apt-get install -y docker-compose-plugin || true
  else
    # fallback to curl plugin install
    mkdir -p ~/.docker/cli-plugins
    COMPOSE_VER="v2.20.2" # reasonable default; adapt if needed
    curl -SL "https://github.com/docker/compose/releases/download/${COMPOSE_VER}/docker-compose-$(uname -s)-$(uname -m)" -o ~/.docker/cli-plugins/docker-compose
    chmod +x ~/.docker/cli-plugins/docker-compose || true
  fi
fi

# Install nginx if missing
if ! command -v nginx >/dev/null 2>&1; then
  if [ "$PKG" = "apt" ]; then
    sudo apt-get install -y nginx
  else
    sudo yum install -y nginx || sudo dnf install -y nginx || true
  fi
fi

sudo systemctl enable --now nginx || true

# show versions
echo "docker: $(docker --version || true)"
echo "docker-compose: $(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || true)"
echo "nginx: $(nginx -v 2>&1 || true)"
REMOTE
)
  ssh_exec "$install_script" || { log_err "Remote install failed"; exit $E_REMOTE_INSTALL; }
  log_info "Remote environment prepared."
}

rsync_to_remote() {
  local local_dir="$1"
  local remote_dir="$2"
  log_info "Syncing local \"$local_dir/\" to \"$SSH_USER@$SSH_HOST:$remote_dir/\""
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] rsync -az ${RSYNC_EXCLUDES[*]} -e \"ssh -i $SSH_KEY\" \"$local_dir/\" \"$SSH_USER@$SSH_HOST:$remote_dir/\""
    return 0
  fi
  # ensure remote dir exists and ownership is correct
  ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "mkdir -p '$remote_dir' && chown -R '$SSH_USER':'$SSH_USER' '$remote_dir' || true"
  rsync -az "${RSYNC_EXCLUDES[@]}" -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" "$local_dir/" "$SSH_USER@$SSH_HOST:$remote_dir/"
}

deploy_remote_app() {
  local remote_dir="$1"
  log_info "Deploying app on remote in $remote_dir"

  # remote deploy script body
  read -r -d '' REMOTE_DEPLOY <<'REMOTE'
set -e
cd "$REMOTE_DIR"

# Determine if docker-compose.yml exists
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  COMPOSE_CMD="docker compose"
  if ! $COMPOSE_CMD version >/dev/null 2>&1; then
    # fallback to docker-compose binary name
    COMPOSE_CMD="docker-compose"
  fi

  # pull images, bring down old, then up new
  $COMPOSE_CMD pull || true
  $COMPOSE_CMD down --remove-orphans || true
  $COMPOSE_CMD up -d --build
else
  # fallback single Dockerfile scenario
  IMAGE_NAME="app_image_$(date +%s)"
  CONTAINER_NAME="app_container"

  # build
  docker build -t "$IMAGE_NAME" .

  # stop + remove existing container (if exists)
  if docker ps -a --format '{{.Names}}' | grep -x "$CONTAINER_NAME" >/dev/null 2>&1; then
    docker rm -f "$CONTAINER_NAME" || true
  fi

  # run new container mapping to host port if provided via env (HOST_PORT env expected)
  if [ -n "${HOST_PORT:-}" ]; then
    docker run -d --name "$CONTAINER_NAME" --restart unless-stopped -p "127.0.0.1:${HOST_PORT}:${APP_PORT}" "$IMAGE_NAME"
  else
    docker run -d --name "$CONTAINER_NAME" --restart unless-stopped -p "127.0.0.1:${APP_PORT}:${APP_PORT}" "$IMAGE_NAME"
  fi
fi

# Basic health check: if container has HEALTHCHECK, inspect; otherwise try curl to localhost
sleep 3
# attempt a curl to nginx reverse-proxied port 80 (if nginx configured)
if command -v curl >/dev/null 2>&1; then
  curl -sS --fail http://127.0.0.1/ || echo "curl failed or app not responding on /"
fi
REMOTE

  # Replace placeholders with values using a heredoc
  REMOTE_DEPLOY="${REMOTE_DEPLOY//\$REMOTE_DIR/$remote_dir}"
  REMOTE_DEPLOY="${REMOTE_DEPLOY//\$HOST_PORT/${HOST_PORT:-}}"
  REMOTE_DEPLOY="${REMOTE_DEPLOY//\$APP_PORT/$APP_PORT}"

  # Execute remote deploy script
  ssh_exec "$REMOTE_DEPLOY"
}

create_nginx_config_remote() {
  local remote_dir="$1"
  local app_port="$2"
  local nginx_conf_name="hng_deployed_app"
  log_info "Configuring Nginx reverse proxy to forward 80 -> 127.0.0.1:${app_port}"

  read -r -d '' NGINX_CONF <<'NGINX'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
}
NGINX
  NGINX="${NGINX//APP_PORT/$app_port}"

  tmpfile="/tmp/${nginx_conf_name}.conf"
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Upload Nginx conf to $tmpfile with contents:"
    printf '%s\n' "$NGINX"
    return 0
  fi

  # push config via ssh
  ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "bash -se" <<EOF
cat > "$tmpfile" <<'EOFCONF'
$NGINX
EOFCONF
sudo mv -f "$tmpfile" /etc/nginx/sites-available/${nginx_conf_name}.conf
sudo ln -sf /etc/nginx/sites-available/${nginx_conf_name}.conf /etc/nginx/sites-enabled/${nginx_conf_name}.conf
sudo nginx -t
sudo systemctl reload nginx
EOF
  log_info "Nginx reverse proxy configured and reloaded."
}

validate_deploy() {
  log_info "Validating deployment..."

  # check docker active
  ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "systemctl is-active --quiet docker" || { log_err "Docker service not active on remote"; exit $E_VALIDATE; }
  log_info "Docker service active."

  # check container running (best-effort)
  # look for docker-compose services or container named app_container
  CONTAINERS_OUT=$(ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "docker ps --format '{{.Names}} {{.Status}}' || true")
  log_info "Remote containers: $CONTAINERS_OUT"

  # check nginx status
  ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "sudo nginx -t" >/dev/null 2>&1 || { log_err "Nginx config test failed"; exit $E_VALIDATE; }
  log_info "Nginx config OK."

  # remote curl to localhost:80
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] skip final curl validation"
  else
    if ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$SSH_HOST" "curl -sS --fail http://127.0.0.1/ >/dev/null"; then
      log_info "Remote HTTP OK (127.0.0.1:80 responded)."
    else
      log_warn "Remote HTTP check failed on 127.0.0.1:80. App might not be responding yet."
    fi
    # local curl to server public IP
    if curl -sS --fail "http://$SSH_HOST/" >/dev/null 2>&1; then
      log_info "External HTTP OK: http://$SSH_HOST/ is reachable."
    else
      log_warn "External HTTP check failed for http://$SSH_HOST/. This may be due to firewall or port blocking."
    fi
  fi
}

cleanup_remote_resources() {
  log_info "Running cleanup on remote: stopping containers, removing images, cleaning deploy dir and nginx config."

  read -r -d '' CLEANUP_SCRIPT <<'REMOTE'
set -e
REMOTE_DIR_ESC="$REMOTE_DIR"
# Try docker-compose down, then remove a possible container named app_container
cd "$REMOTE_DIR_ESC" || true
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  docker compose down --remove-orphans || docker-compose down --remove-orphans || true
fi
if docker ps -a --format '{{.Names}}' | grep -x "app_container" >/dev/null 2>&1; then
  docker rm -f app_container || true
fi
# remove images built with "app_image_" prefix
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | awk '/app_image_/{print $2}' | xargs -r docker rmi -f || true

# remove remote deploy dir
rm -rf "$REMOTE_DIR_ESC" || true

# remove nginx conf (name used by script)
sudo rm -f /etc/nginx/sites-enabled/hng_deployed_app.conf /etc/nginx/sites-available/hng_deployed_app.conf || true
sudo nginx -t || true
sudo systemctl reload nginx || true
REMOTE

  CLEANUP_SCRIPT="${CLEANUP_SCRIPT//\$REMOTE_DIR/$REMOTE_DIR}"
  ssh_exec "$CLEANUP_SCRIPT"
  log_info "Remote cleanup completed."
}

### -------------------------
### Main flow
### -------------------------
main() {
  # 1) Basic SSH check
  check_ssh_connectivity

  # 2) Clone/pull repo locally
  LOCAL_DIR="$(git_clone_or_update "$REPO_URL" "$BRANCH")"
  if [ ! -d "$LOCAL_DIR" ]; then
    log_err "Local repo directory not found after clone: $LOCAL_DIR"
    exit $E_GENERIC
  fi

  # 3) Validate presence of Dockerfile or docker-compose
  if [ ! -f "${LOCAL_DIR}/Dockerfile" ] && [ ! -f "${LOCAL_DIR}/docker-compose.yml" ] && [ ! -f "${LOCAL_DIR}/docker-compose.yaml" ]; then
    log_warn "No Dockerfile or docker-compose found in $LOCAL_DIR. The script expects a Dockerized project."
    # we let it proceed but mark a warning (some projects might build in other ways)
  fi

  # 4) If cleanup requested, run cleanup and exit
  if [ "$CLEANUP" = true ]; then
    cleanup_remote_resources
    exit 0
  fi

  # 5) Prepare remote environment
  remote_prepare_environment

  # 6) rsync files to remote
  rsync_to_remote "$LOCAL_DIR" "$REMOTE_DIR"

  # 7) Deploy on remote
  # Allow optional HOST_PORT env for mapping host port (will be used for docker run fallback)
  HOST_PORT="${HOST_PORT:-}"
  deploy_remote_app "$REMOTE_DIR"

  # 8) Configure nginx reverse proxy
  create_nginx_config_remote "$REMOTE_DIR" "$APP_PORT"

  # 9) Validate deployment
  validate_deploy

  log_info "Deployment finished. Log file: $LOGFILE"
}

# Run main
main "$@"