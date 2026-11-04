#!/usr/bin/env bash
# Локальный кластер k3d.
#   cluster.sh up       создать (или запустить остановленный) кластер и базовые ресурсы: namespace, DNS, секреты, ingress
#   cluster.sh stop     остановить, данные сохраняются
#   cluster.sh down     удалить кластер вместе с данными Postgres
#   cluster.sh status   поды, сервисы, адреса
#   cluster.sh logs <api|gateway|ui|keycloak|postgres>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

up() {
  [[ -f "$DEPLOY_DIR/.env" ]] || die "нет $DEPLOY_DIR/.env: скопируйте .env.example в .env и заполните"

  if ! cluster_exists; then
    log "Создаю кластер $CLUSTER"
    # порт балансировщика доступен с Windows как localhost:$HTTP_PORT
    k3d cluster create "$CLUSTER" --servers 1 --agents 0 \
      --port "$HTTP_PORT:80@loadbalancer" \
      --wait
  elif ! cluster_running; then
    log "Запускаю остановленный кластер $CLUSTER"
    k3d cluster start "$CLUSTER" --wait
  fi

  # ~/.kube/config бывает перезаписан (например при перезапуске Docker Desktop) - без контекста kubectl ждал бы впустую.
  # merge идемпотентен и заодно обновляет порт API, если он сменился
  k3d kubeconfig merge "$CLUSTER" --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null

  # сразу после create/start API-сервер ещё отвечает 503, а CoreDNS и Traefik ставятся следом
  # k3s иногда падает на первом старте (гонка RBAC у cloud-controller-manager), а контейнер остаётся Up
  log "Жду API кластера $CLUSTER"
  local i ready=""
  for i in $(seq 1 60); do
    if kubectl --context "$CONTEXT" --request-timeout=5s -n kube-system get deployment/coredns >/dev/null 2>&1; then
      ready=1
      break
    fi
    # после перезапуска Docker Desktop балансировщик k3d может сбрасывать соединения, хотя k3s внутри узла жив:
    # его nginx держит старое подключение к узлу. Перезапуск балансировщика это лечит
    if ((i == 10)) && docker exec "k3d-$CLUSTER-server-0" kubectl get --raw /readyz >/dev/null 2>&1; then
      echo "k3s внутри узла отвечает, а через балансировщик нет - перезапускаю k3d-$CLUSTER-serverlb"
      docker restart "k3d-$CLUSTER-serverlb" >/dev/null
    fi
    ((i % 10 == 0)) && echo "API ещё не отвечает, жду ($((i * 2)) с из 120)"
    sleep 2
  done
  [[ -n "$ready" ]] || die "API кластера не отвечает 2 минуты. Перезапустите: k3d cluster stop $CLUSTER && k3d cluster start $CLUSTER (или cluster.ps1 down, затем up)"
  kubectl --context "$CONTEXT" -n kube-system rollout status deployment/coredns --timeout=2m >/dev/null

  log "Базовые ресурсы: namespace, DNS, секреты, ingress"
  kubectl --context "$CONTEXT" apply -f "$DEPLOY_DIR/k8s/namespace.yaml"

  local dns
  dns=$(kubectl --context "$CONTEXT" apply -f "$DEPLOY_DIR/k8s/coredns-custom.yaml")
  echo "$dns"
  # reload в CoreDNS подхватит ConfigMap сам, но только через минуту-две
  if [[ "$dns" != *unchanged* ]]; then
    kubectl --context "$CONTEXT" -n kube-system rollout restart deployment/coredns
    kubectl --context "$CONTEXT" -n kube-system rollout status deployment/coredns --timeout=2m
  fi

  # .env правится на Windows: срезаем \r, иначе он попадёт в значения
  kc create secret generic invest-secrets --from-env-file=<(sed 's/\r$//' "$DEPLOY_DIR/.env") \
    --dry-run=client -o yaml | kc apply -f -
  kc apply -f "$DEPLOY_DIR/k8s/ingress.yaml"
}

status() {
  cluster_exists || die "кластера $CLUSTER нет, создайте: cluster.sh up"
  cluster_running || die "кластер $CLUSTER остановлен, запустите: cluster.sh up"
  kc get pods,svc,ingress -o wide
  cat <<EOF

UI:        http://invest.localhost:$HTTP_PORT     (пользователь investor / investor)
Keycloak:  http://keycloak.localhost:$HTTP_PORT   (admin / KEYCLOAK_ADMIN_PASSWORD из .env)
Swagger:   kubectl --context $CONTEXT -n $NAMESPACE port-forward svc/invest-api 8081:80
           -> http://localhost:8081/swagger-ui.html
Postgres:  kubectl --context $CONTEXT -n $NAMESPACE port-forward svc/postgres 5433:5432
EOF
}

logs() {
  local app
  case "${1:-}" in
    api) app=invest-api ;;
    gateway) app=invest-gateway ;;
    ui) app=invest-api-ui ;;
    keycloak | postgres) app=$1 ;;
    *) die "укажите сервис: api, gateway, ui, keycloak, postgres" ;;
  esac
  kc logs -l "app=$app" --tail=200 -f --prefix
}

case "${1:-status}" in
  up) up ;;
  stop) k3d cluster stop "$CLUSTER" ;;
  down) k3d cluster delete "$CLUSTER" ;;
  status) status ;;
  logs) logs "${2:-}" ;;
  *) die "неизвестная команда '$1', доступны: up, stop, down, status, logs" ;;
esac
