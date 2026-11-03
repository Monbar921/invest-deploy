#!/usr/bin/env bash
# Сборка образов и выкатка сервисов в k3d. Артефакты (jar-раскладку и dist UI) собирает deploy.ps1 на Windows,
# здесь только docker build, импорт образа в кластер и kubectl apply.
#
#   deploy.sh [all | postgres keycloak api gateway ui]...
#
# К имени сервиса можно добавить ревизию для тега образа: api@1a2b3c4-dirty (deploy.ps1 передаёт git sha)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALL=(postgres keycloak api gateway ui)

# тег уникален для каждого деплоя: apply всегда меняет pod template и запускает rolling update
new_tag() { echo "${1:-local}-$(date +%Y%m%d%H%M%S)"; }

build_and_import() { # <образ> <docker build args...>
  local image=$1
  shift
  docker build -q -t "$image" "$@" >/dev/null
  k3d image import "$image" -c "$CLUSTER"
}

rollout() { # <имя deployment/statefulset>
  if ! kc rollout status "$1" --timeout=5m; then
    kc get pods -l "app=${1#*/}"
    kc logs -l "app=${1#*/}" --tail=80 --prefix || true
    die "${1#*/} не поднялся"
  fi
}

# убираем старые теги сервиса из docker и неиспользуемые образы из containerd кластера
cleanup_images() { # <имя> <текущий тег>
  docker images "$1" --format '{{.Tag}}' | grep -vx "$2" | xargs -r -I{} docker rmi -f "$1:{}" >/dev/null || true
  docker exec "k3d-$CLUSTER-server-0" crictl rmi --prune >/dev/null 2>&1 || true
}

deploy_app() { # <имя> <тег>
  sed "s/__TAG__/$2/" "$DEPLOY_DIR/k8s/$1.yaml" | kc apply -f -
  rollout "deployment/$1"
  cleanup_images "$1" "$2"
}

deploy_java() { # <имя = репозиторий> <main class> <ревизия>
  local name=$1 main=$2 repo="$PROJECTS_DIR/$1"
  local layout="$repo/app/target/dockerbuild" tag
  [[ -d "$layout/lib" ]] || die "нет $layout: соберите $name (mvn package) или запустите deploy.ps1 без -SkipBuild"
  tag=$(new_tag "$3")

  log "$name: образ $name:$tag"
  build_and_import "$name:$tag" -f "$DEPLOY_DIR/docker/java.Dockerfile" \
    --build-context certs="$DEPLOY_DIR/certs" --build-arg MAIN_CLASS="$main" "$layout"

  # базовый конфиг из репозитория сервиса + профиль k8s из invest-deploy
  kc create configmap "$name-config" \
    --from-file=application.yml="$repo/config/application.yml" \
    --from-file=application-k8s.yml="$DEPLOY_DIR/config/$name/application-k8s.yml" \
    --dry-run=client -o yaml | kc apply -f -
  deploy_app "$name" "$tag"
}

deploy_ui() { # <ревизия>
  local name=invest-api-ui dist="$PROJECTS_DIR/invest-api-ui/dist" tag
  [[ -f "$dist/index.html" ]] || die "нет $dist: соберите UI (npm run build) или запустите deploy.ps1 без -SkipBuild"
  tag=$(new_tag "$1")

  log "$name: образ $name:$tag"
  build_and_import "$name:$tag" -f "$DEPLOY_DIR/docker/ui.Dockerfile" --build-context conf="$DEPLOY_DIR/docker" "$dist"
  deploy_app "$name" "$tag"
}

deploy_postgres() {
  log "postgres"
  kc apply -f "$DEPLOY_DIR/k8s/postgres.yaml"
  rollout statefulset/postgres
}

deploy_keycloak() {
  log "keycloak"
  kc create configmap keycloak-realm --from-file="$DEPLOY_DIR/keycloak/invest-realm.json" \
    --dry-run=client -o yaml | kc apply -f -
  kc apply -f "$DEPLOY_DIR/k8s/keycloak.yaml"
  rollout deployment/keycloak
}

targets=("$@")
[[ ${#targets[@]} -eq 0 ]] && targets=(all)
if [[ " ${targets[*]} " == *" all "* ]]; then
  # ревизии, переданные вместе с all (all api@sha ...), сохраняем
  rest=("${targets[@]}")
  targets=()
  for s in "${ALL[@]}"; do
    t=$s
    for r in "${rest[@]}"; do [[ "${r%%@*}" == "$s" ]] && t=$r; done
    targets+=("$t")
  done
fi

for t in "${targets[@]}"; do
  [[ " ${ALL[*]} " == *" ${t%%@*} "* ]] || die "неизвестный сервис '${t%%@*}', доступны: all ${ALL[*]}"
done

"$DEPLOY_DIR/scripts/cluster.sh" up

for t in "${targets[@]}"; do
  service=${t%%@*}
  rev=""
  [[ "$t" == *@* ]] && rev=${t#*@}
  case "$service" in
    postgres) deploy_postgres ;;
    keycloak) deploy_keycloak ;;
    api) deploy_java invest-api ru.invest.api.InvestApplication "$rev" ;;
    gateway) deploy_java invest-gateway ru.invest.gateway.InvestGatewayApplication "$rev" ;;
    ui) deploy_ui "$rev" ;;
  esac
done

log "Готово"
"$DEPLOY_DIR/scripts/cluster.sh" status
