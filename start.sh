#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE="ghcr.io/wnn2025123/satan:v6.1"
ACCOUNTS_FILE="accounts.json"
COMPOSE_FILE="docker-compose.yml"
CONTAINER_PREFIX="satan-"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR ]${NC} $*" >&2; }

generate() {
    if [ ! -f "$ACCOUNTS_FILE" ]; then
        error "找不到 $ACCOUNTS_FILE"
        echo ""
        echo "请创建 accounts.json，格式如下："
        echo '{'
        echo '  "accounts": ['
        echo '    {"email": "user1@gmail.com", "refresh_token": "1//0fXXXX", "proxy": "http://host.docker.internal:7891"},'
        echo '    {"email": "user2@gmail.com", "refresh_token": "1//0fYYYY", "proxy": "http://host.docker.internal:7891"}'
        echo '  ]'
        echo '}'
        exit 1
    fi

    python3 - "$ACCOUNTS_FILE" "$IMAGE" "$CONTAINER_PREFIX" << 'PYEOF'
import json, os, sys

accounts_file = sys.argv[1]
image = sys.argv[2]
prefix = sys.argv[3]

with open(accounts_file) as f:
    data = json.load(f)

accounts = data.get("accounts", [])
global_proxy = data.get("proxy", "")

if not accounts:
    print("[ERR ] accounts.json 中没有账号", file=sys.stderr)
    sys.exit(1)

num = len(accounts)
print(f"[INFO]  检测到 {num} 个账号，生成 {num} Worker + Queen + Dashboard 配置...")

os.makedirs("accounts", exist_ok=True)
for i, acc in enumerate(accounts):
    idx = i + 1
    svc = f"account{idx}"
    account_proxy = acc.get("proxy", "") or global_proxy
    acc_data = {
        "proxy": account_proxy,
        "accounts": [{
            "email": acc["email"],
            "refresh_token": acc.get("refresh_token", ""),
        }],
        "active": acc["email"],
    }
    with open(f"accounts/{svc}.json", "w") as f:
        json.dump(acc_data, f, indent=2, ensure_ascii=False)
    print(f"[ OK ] 生成 accounts/{svc}.json ({acc['email']})")
    
    os.makedirs(f"ls_data/{svc}/.gemini", exist_ok=True)

env_file_exists = os.path.exists(".env")
workers = []
services = {}

for i, acc in enumerate(accounts):
    idx = i + 1
    svc = f"account{idx}"
    container = f"{prefix}{svc}"
    api_port = 8080 if idx == 1 else 8100 + idx
    account_proxy = acc.get("proxy", "") or global_proxy

    service = {
        "image": image,
        "container_name": container,
        "ports": [f"{api_port}:8080"],
        "volumes": [
            f"./accounts/{svc}.json:/app/accounts.json:ro",
            f"./ls_data/{svc}:/app/.ls_data",
            f"./ls_data/{svc}/.gemini:/root/.gemini",
        ],
        "environment": [
            "SATAN_LOG_LEVEL=warn",
            f"http_proxy={account_proxy}" if account_proxy else "http_proxy=",
            f"https_proxy={account_proxy}" if account_proxy else "https_proxy=",
            f"HTTP_PROXY={account_proxy}" if account_proxy else "HTTP_PROXY=",
            f"HTTPS_PROXY={account_proxy}" if account_proxy else "HTTPS_PROXY=",
        ],
        "extra_hosts": ["host.docker.internal:host-gateway"],
        "restart": "unless-stopped",
        "security_opt": ["no-new-privileges:true"],
        "cap_drop": ["ALL"],
        "deploy": {"resources": {"limits": {"memory": "512M"}}},
    }
    if env_file_exists:
        service["env_file"] = [".env"]
    
    services[svc] = service
    workers.append(f"http://{container}:8080")

first_proxy = accounts[0].get("proxy", "") or global_proxy
queen_env = [
    f"SATAN_WORKERS={','.join(workers)}",
    "SATAN_QUEEN_PORT=9000",
    "SATAN_LOG_LEVEL=warn",
]
if first_proxy:
    queen_env.extend([
        f"http_proxy={first_proxy}",
        f"https_proxy={first_proxy}",
        f"HTTP_PROXY={first_proxy}",
        f"HTTPS_PROXY={first_proxy}",
    ])
services["queen"] = {
    "image": image,
    "container_name": f"{prefix}queen",
    "entrypoint": ["/app/queen/satan-queen"],
    "ports": ["9090:9000"],
    "environment": queen_env,
    "extra_hosts": ["host.docker.internal:host-gateway"],
    "restart": "unless-stopped",
}

docker_install = (
    "export http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY=; "
    "which docker > /dev/null 2>&1 || "
    "(curl -fsSL https://download.docker.com/linux/static/stable/$(uname -m)/docker-27.5.1.tgz 2>/dev/null "
    "| tar xz --strip-components=1 -C /usr/local/bin docker/docker 2>/dev/null || true); "
    "/app/updater & "
    "exec /app/dashboard/auth_server"
)
services["dashboard"] = {
    "image": image,
    "container_name": f"{prefix}dashboard",
    "entrypoint": ["sh", "-c", docker_install],
    "ports": ["9091:9090"],
    "volumes": ["/var/run/docker.sock:/var/run/docker.sock"],
    "environment": [
        f"CONTAINER_PREFIX={prefix}",
        "http_proxy=",
        "https_proxy=",
        "HTTP_PROXY=",
        "HTTPS_PROXY=",
    ],
    "extra_hosts": ["host.docker.internal:host-gateway"],
    "restart": "unless-stopped",
}

compose = {"services": services}


def to_yaml(obj, indent=0):
    lines = []
    prefix_str = "  " * indent
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, (dict, list)):
                lines.append(f"{prefix_str}{k}:")
                lines.extend(to_yaml(v, indent + 1))
            else:
                lines.append(f"{prefix_str}{k}: {v}")
    elif isinstance(obj, list):
        for item in obj:
            if isinstance(item, dict):
                first = True
                for k, v in item.items():
                    if first:
                        lines.append(f"{prefix_str}- {k}: {v}")
                        first = False
                    else:
                        lines.append(f"{prefix_str}  {k}: {v}")
            else:
                lines.append(f"{prefix_str}- {item}")
    return lines

yaml_lines = to_yaml(compose)
with open("docker-compose.yml", "w") as f:
    f.write("\n".join(yaml_lines) + "\n")

print(f"[ OK ] 生成 docker-compose.yml ({num} Workers + Queen:9090 + Dashboard:9091)")
PYEOF
}

do_start() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║      Satan Quick Start                 ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""

    generate

    echo ""
    info "拉取最新镜像..."
    docker pull "$IMAGE"

    echo ""
    info "启动容器..."
    docker compose up -d

    echo ""
    ok "所有容器已启动!"
    echo ""
    docker compose ps
    echo ""

    local count
    count=$(python3 -c "import json; print(len(json.load(open('$ACCOUNTS_FILE')).get('accounts',[])))")

    echo "┌────────────┬──────────────────────────────────────┐"
    echo "│  服务       │  地址                                │"
    echo "├────────────┼──────────────────────────────────────┤"
    for i in $(seq 1 "$count"); do
        local port
        if [ "$i" -eq 1 ]; then port=8080; else port=$((8100 + i)); fi
        printf "│  Worker %d   │  http://localhost:%-19s │\n" "$i" "${port}/v1"
    done
    printf "│  Queen LB   │  http://localhost:%-19s │\n" "9090/v1"
    printf "│  Dashboard  │  http://localhost:%-19s │\n" "9091"
    echo "└────────────┴──────────────────────────────────────┘"
    echo ""
    info "OpenAI API 入口: http://localhost:9090/v1/chat/completions"
    info "认证管理面板:     http://localhost:9091"
    info "查看日志:         ./start.sh logs"
}

do_stop() {
    info "停止所有容器..."
    docker compose down
    ok "已停止"
}

do_restart() {
    info "重启..."
    docker compose down
    generate
    docker compose up -d
    ok "重启完成!"
    docker compose ps
}

do_update() {
    info "拉取最新镜像..."
    docker pull "$IMAGE"
    info "重启容器..."
    docker compose down
    generate
    docker compose up -d
    ok "更新完成!"
    docker compose ps
}

do_logs() {
    docker compose logs -f
}

do_status() {
    docker compose ps
}

show_help() {
    echo "Satan Quick Start"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  start       启动所有容器（默认）"
    echo "  stop        停止所有容器"
    echo "  restart     重启"
    echo "  update      拉取最新镜像并重启"
    echo "  status      查看容器状态"
    echo "  logs        查看实时日志"
    echo "  help        显示帮助"
}

case "${1:-start}" in
    start)      do_start ;;
    stop)       do_stop ;;
    restart)    do_restart ;;
    update)     do_update ;;
    status)     do_status ;;
    logs)       do_logs ;;
    help|--help|-h) show_help ;;
    *)
        error "未知命令: $1"
        show_help
        exit 1
        ;;
esac
