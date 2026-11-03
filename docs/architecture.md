# Архитектура invest-deploy

Локальный CI/CD для [invest-api](../../invest-api), [invest-gateway](../../invest-gateway) и
[invest-api-ui](../../invest-api-ui): код пишется на Windows, по команде сервисы собираются и выкатываются в k3d в WSL.

## Пайплайн

```
Windows                                 WSL (Ubuntu)
───────                                 ────────────
deploy.ps1 api ui                       scripts/deploy.sh api@<sha> ui@<sha>
  mvn clean package  (invest-api)   ──▶   docker build  -> invest-api:<sha>-<время>
  npm run build      (invest-api-ui)      k3d image import (registry не нужен)
                                          kubectl apply + rollout status
```

- **Сборка на Windows**: там JDK 25 и Node 24, в WSL только Java 17. Репозитории сервисов - соседние папки
  (`../invest-api` и т.д.).
- **Образ в WSL**: `docker build` с контекстом из уже собранной раскладки (`app/target/dockerbuild` или `dist/`),
  Dockerfile'ы лежат здесь, в `docker/`, а не в репозиториях сервисов.
- **Без registry**: `k3d image import` кладёт образ прямо в containerd узла, в манифестах `imagePullPolicy: Never`.
- **Тег** `<short sha>[-dirty]-<время>` уникален для каждого деплоя, поэтому `apply` всегда меняет pod template
  и запускает rolling update (`maxUnavailable: 0` - старый под живёт, пока новый не пройдёт readiness).
- После успешной выкатки старые теги удаляются из docker и неиспользуемые образы - из containerd узла.

## Стенд

```
браузер ──▶ localhost:8088 ──▶ k3d loadbalancer ──▶ Traefik
              invest.localhost   /api /oauth2 /login /logout ──▶ invest-gateway ──▶ invest-api ──▶ postgres
                                 /                           ──▶ invest-api-ui (nginx)
              keycloak.localhost                             ──▶ keycloak ──▶ postgres
```

Кластер `invest` (1 сервер, без агентов), контекст `k3d-invest`, namespace `invest`. Traefik идёт в k3s из коробки.

| Компонент        | Манифест                 | Что                                                                     |
| ---------------- | ------------------------ | ----------------------------------------------------------------------- |
| postgres         | `k8s/postgres.yaml`      | StatefulSet, PVC 2Gi; при первом старте создаёт БД `invest` (схема `invest_api`) и `keycloak` |
| keycloak         | `k8s/keycloak.yaml`      | `start-dev --import-realm` на Postgres, realm из `keycloak/invest-realm.json` |
| invest-api       | `k8s/invest-api.yaml`    | наружу не публикуется                                                    |
| invest-gateway   | `k8s/invest-gateway.yaml`| один экземпляр: сессии в памяти                                          |
| invest-api-ui    | `k8s/invest-api-ui.yaml` | nginx со статикой, SPA-fallback                                         |
| ingress          | `k8s/ingress.yaml`       | UI и gateway на одном host - gateway держит сессию в cookie              |

### Конфигурация сервисов

ConfigMap `<сервис>-config` монтируется в `/app/config` и содержит два файла:

- `application.yml` - из репозитория сервиса, так что новые настройки сервиса попадают на стенд сами;
- `application-k8s.yml` - из `config/<сервис>/` здесь, включается `SPRING_PROFILES_ACTIVE=k8s`: адреса и секреты стенда.

Секреты из `.env` при каждом деплое кладутся в Secret `invest-secrets`, сервисы читают их через env.

## Решения

- **Порт 8088, а не 80.** `docker` в WSL Ubuntu работает через Docker Desktop (WSL integration подменяет
  `/var/run/docker.sock`), а Docker Desktop на этой машине не пробрасывает на Windows порт 80. Непривилегированные
  порты работают. Порт задаётся в `scripts/lib.sh` (`HTTP_PORT`) и ещё в нескольких местах - список там же.
- **Один issuer для браузера и gateway.** Браузер ходит в Keycloak по `http://keycloak.localhost:8088`, gateway
  должен видеть тот же адрес (Spring проверяет `iss` токена). Внутри кластера CoreDNS переписывает
  `keycloak.localhost` на сервис keycloak (`k8s/coredns-custom.yaml`), а сервис слушает и 80, и 8088.
- **`*.localhost`** браузеры и curl резолвят в 127.0.0.1 сами, hosts править не нужно.
- **Keycloak в dev-режиме** (`start-dev`), но на Postgres: realm и пользователи переживают рестарт пода.
  `strategy: Recreate`, чтобы два экземпляра не работали с одной БД.
- **Ожидание API кластера с таймаутом.** k3s иногда падает на первом старте (гонка RBAC у cloud-controller-manager),
  а контейнер остаётся `Up`; `cluster.sh up` ждёт API 2 минуты и падает с подсказкой, а не висит.
- **PowerShell 5.1**: `.ps1` сохранены в UTF-8 с BOM (иначе кириллица ломается), вывод нативных команд идёт через
  `Write-Host` и проверку кода выхода, а не через `$ErrorActionPreference = 'Stop'` (с ним любая строка в stderr,
  например WARNING от JVM, - фатальная ошибка).
