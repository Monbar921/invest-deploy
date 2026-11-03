# invest-deploy

Локальный CI/CD для [invest-api](../invest-api), [invest-gateway](../invest-gateway) и [invest-api-ui](../invest-api-ui):
код пишется на Windows, по команде сервисы собираются и выкатываются в k3d внутри WSL.

```
Windows                                 WSL (Ubuntu)
───────                                 ────────────
deploy.ps1 api ui                       scripts/deploy.sh api@<sha> ui@<sha>
  mvn clean package  (invest-api)   ──▶   docker build  -> invest-api:<sha>-<время>
  npm run build      (invest-api-ui)      k3d image import (registry не нужен)
                                          kubectl apply + rollout status
```

## Стенд

```
браузер ──▶ localhost:8088 ──▶ k3d loadbalancer ──▶ Traefik
              invest.localhost   /api /oauth2 /login /logout ──▶ invest-gateway ──▶ invest-api ──▶ postgres
                                 /                           ──▶ invest-api-ui (nginx)
              keycloak.localhost                             ──▶ keycloak ──▶ postgres
```

| Адрес                         | Что                                                          |
| ----------------------------- | ------------------------------------------------------------ |
| http://invest.localhost:8088  | UI, логин `investor` / `investor`                            |
| http://keycloak.localhost:8088 | Keycloak, админ `admin` / `KEYCLOAK_ADMIN_PASSWORD` из `.env` |

invest-api и Postgres наружу не опубликованы, доступ через port-forward (команды печатает `.\cluster.ps1`).

`*.localhost` браузеры резолвят в 127.0.0.1 сами, hosts править не нужно. Внутри кластера CoreDNS переписывает
`keycloak.localhost` на сервис keycloak (`k8s/coredns-custom.yaml`), поэтому gateway и браузер видят один issuer.

## Что нужно

- Windows: JDK 25, Maven, Node 24, git
- WSL Ubuntu: docker, k3d, kubectl
- свободный порт 8088 на Windows (порт задаётся в `scripts/lib.sh`, `HTTP_PORT`)

## Первый запуск

```powershell
copy .env.example .env    # заполнить TINKOFF_TOKEN, остальное можно оставить
.\deploy.ps1              # создаст кластер и выкатит всё
```

## Обновление сервисов

```powershell
.\deploy.ps1 api                 # только invest-api
.\deploy.ps1 api gateway ui      # несколько
.\deploy.ps1                     # всё (postgres keycloak api gateway ui)
.\deploy.ps1 api -Test           # с тестами: mvn verify, для ui - lint + test
.\deploy.ps1 ui -SkipBuild       # без пересборки, из уже собранных артефактов
```

Тег образа - `<short sha>[-dirty]-<время>`: каждый деплой уникален и всегда запускает rolling update.
Старый под живёт, пока новый не пройдёт readiness. Если новый не поднялся, скрипт печатает логи и падает,
старая версия продолжает работать.

`-Test` для Java запускает Testcontainers, им нужен Docker на Windows (Docker Desktop).

## Кластер

```powershell
.\cluster.ps1             # поды и адреса
.\cluster.ps1 logs api    # логи (api, gateway, ui, keycloak, postgres)
.\cluster.ps1 stop        # остановить, данные сохраняются
.\cluster.ps1 up          # запустить снова
.\cluster.ps1 down        # удалить вместе с данными Postgres
```

Из WSL то же самое: `bash scripts/cluster.sh status`, `bash scripts/deploy.sh api` (артефакты должны быть уже собраны).
kubectl: контекст `k3d-invest`, namespace `invest`.

## Конфигурация

| Файл                                       | Что                                                                     |
| ------------------------------------------ | ----------------------------------------------------------------------- |
| `.env`                                     | секреты, при каждом деплое кладутся в Secret `invest-secrets`           |
| `config/<сервис>/application-k8s.yml`      | профиль `k8s`: адреса и секреты стенда поверх `config/application.yml` сервиса |
| `k8s/*.yaml`                               | манифесты, `__TAG__` подставляет `deploy.sh`                            |
| `keycloak/invest-realm.json`               | realm `invest`: клиент `invest-gateway` и тестовый пользователь         |
| `docker/`                                  | Dockerfile для Java-сервисов (общий) и UI                               |

Базовый `config/application.yml` берётся из репозитория сервиса, так что новые настройки сервиса попадают на стенд сами.

Что применяется не сразу:

- **Пароли БД** - только при первом создании тома Postgres. Чтобы сменить: `.\cluster.ps1 down` и заново.
- **Realm** импортируется, только если его ещё нет. После правок `invest-realm.json` удалить realm `invest`
  в админке Keycloak и выполнить `.\deploy.ps1 keycloak`.

## Если что-то не так

- `ErrImageNeverPull` - образа нет в кластере: повторить деплой сервиса.
- `CrashLoopBackOff` у invest-api - `.\cluster.ps1 logs api`, обычно токен или БД.
- gateway не стартует - он при старте читает OIDC discovery Keycloak; после того как Keycloak поднимется, под перезапустится сам.
- страница не открывается - проверить, что кластер запущен (`.\cluster.ps1`) и порт 8088 на Windows не занят.
- `404 Not Found / nginx` вместо UI - порт в WSL держит кто-то другой, например nginx-ingress MicroK8s
  (hostNetwork). Остановить: `sudo microk8s stop`, автозапуск выключить: `sudo snap disable microk8s`.
