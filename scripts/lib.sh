# Общие переменные и функции для cluster.sh и deploy.sh (подключается через source)
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# соседние репозитории: invest-api, invest-gateway, invest-api-ui
PROJECTS_DIR="$(dirname "$DEPLOY_DIR")"
CLUSTER=invest
CONTEXT="k3d-$CLUSTER"
NAMESPACE=invest
# порт стенда на localhost Windows. 80 Docker Desktop на Windows не пробрасывает; при смене поправить
# KC_HOSTNAME и порт сервиса в k8s/keycloak.yaml, issuer в config/invest-gateway, redirect URI в keycloak/invest-realm.json
HTTP_PORT=8088

# kubectl всегда в контексте стенда, даже если текущий контекст другой (например minikube)
kc() { kubectl --context "$CONTEXT" -n "$NAMESPACE" "$@"; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

cluster_exists() { k3d cluster get "$CLUSTER" >/dev/null 2>&1; }
cluster_running() { [[ "$(docker inspect -f '{{.State.Running}}' "k3d-$CLUSTER-server-0" 2>/dev/null)" == true ]]; }
