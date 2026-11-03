# Работа со стендом

| Адрес                          | Что                                                           |
| ------------------------------ | ------------------------------------------------------------- |
| http://invest.localhost:8088   | UI, логин `investor` / `investor`                             |
| http://keycloak.localhost:8088 | Keycloak, админ `admin` / `KEYCLOAK_ADMIN_PASSWORD` из `.env` |

invest-api и Postgres наружу не опубликованы, доступ через port-forward (команды печатает `.\cluster.ps1`).

## Что нужно

- Windows: JDK 25, Maven, Node 24, git
- WSL Ubuntu: docker (через Docker Desktop - он должен быть запущен), k3d, kubectl
- свободный порт 8088 на Windows

## Первый запуск

```powershell
copy .env.example .env    # заполнить TINKOFF_TOKEN, остальное можно оставить
.\deploy.ps1              # создаст кластер и выкатит всё
```

База после первого запуска пустая. В базовом конфиге invest-api шаг `bond` ночной синхронизации выключен - чтобы
облигации появились, включите его в `config/invest-api/application-k8s.yml` (см. ниже) или вызовите
maintenance-эндпоинт `POST /internal/rest/maintenance/bond/sync-all` через port-forward.

## Обновление сервисов

```powershell
.\deploy.ps1 api                 # только invest-api
.\deploy.ps1 api gateway ui      # несколько
.\deploy.ps1                     # всё (postgres keycloak api gateway ui)
.\deploy.ps1 api -Test           # с тестами: mvn verify, для ui - lint + test
.\deploy.ps1 ui -SkipBuild       # без пересборки, из уже собранных артефактов
```

Если новый под не поднялся, скрипт печатает его логи и падает, старая версия продолжает работать.
`-Test` для Java запускает Testcontainers - им нужен Docker на Windows.

Из WSL то же самое: `bash scripts/deploy.sh api` (артефакты должны быть уже собраны), `bash scripts/cluster.sh status`.

## Кластер

```powershell
.\cluster.ps1             # поды и адреса
.\cluster.ps1 logs api    # логи (api, gateway, ui, keycloak, postgres)
.\cluster.ps1 stop        # остановить, данные сохраняются
.\cluster.ps1 up          # запустить снова
.\cluster.ps1 down        # удалить вместе с данными Postgres
```

## Конфигурация

| Файл                                  | Что                                                                       |
| ------------------------------------- | ------------------------------------------------------------------------- |
| `.env`                                | секреты (шаблон `.env.example`), в git не попадает                        |
| `config/<сервис>/application-k8s.yml` | профиль `k8s` поверх `config/application.yml` из репозитория сервиса      |
| `k8s/*.yaml`                          | манифесты, `__TAG__` подставляет `deploy.sh`                              |
| `keycloak/invest-realm.json`          | realm `invest`: клиент `invest-gateway` и тестовый пользователь           |
| `docker/`                             | Dockerfile для Java-сервисов (общий), для UI и конфиг nginx               |
| `certs/`                              | корневой сертификат Минцифры для truststore Java-образов                  |

### Поменять конфиг сервиса

Правка любого из двух файлов (`application.yml` в репозитории сервиса или `application-k8s.yml` здесь), затем
выкатка без пересборки - ConfigMap обновится, под перезапустится:

```powershell
.\deploy.ps1 api -SkipBuild
```

Быстрый эксперимент прямо в кластере (следующий `deploy.ps1` его перезапишет):

```powershell
wsl kubectl --context k3d-invest -n invest edit configmap invest-api-config
wsl kubectl --context k3d-invest -n invest rollout restart deployment/invest-api
```

Что применяется не сразу:

- **Пароли БД** - только при первом создании тома Postgres. Чтобы сменить: `.\cluster.ps1 down` и заново.
- **Realm** импортируется, только если его ещё нет. После правок `invest-realm.json` удалить realm `invest`
  в админке Keycloak и выполнить `.\deploy.ps1 keycloak`.

## Логи и диагностика

```powershell
wsl kubectl --context k3d-invest -n invest logs deploy/invest-api --tail=100       # последние строки
wsl kubectl --context k3d-invest -n invest logs deploy/invest-api -f               # в реальном времени
wsl kubectl --context k3d-invest -n invest logs deploy/invest-api --previous       # прошлый контейнер после падения
wsl kubectl --context k3d-invest -n invest describe pod -l app=invest-api          # события, если под не стартует
wsl kubectl --context k3d-invest -n invest exec deploy/invest-api -- cat /app/config/application-k8s.yml
```

Deployment'ы: `invest-api`, `invest-gateway`, `invest-api-ui`, `keycloak`; Postgres - `statefulset/postgres`.

## Если что-то не так

| Симптом                                    | Причина и что делать                                                  |
| ------------------------------------------ | --------------------------------------------------------------------- |
| `ErrImageNeverPull`                        | образа нет в кластере - повторить деплой сервиса                      |
| `CrashLoopBackOff` у invest-api            | `.\cluster.ps1 logs api`, обычно токен или БД                         |
| gateway не стартует                        | при старте он читает OIDC discovery Keycloak; когда Keycloak поднимется, под перезапустится сам |
| `API кластера не отвечает 2 минуты`        | k3s упал при старте: `wsl k3d cluster stop invest`, затем `.\cluster.ps1 up`; не помогло - `down` и заново |
| страница не открывается, пустой ответ      | Docker Desktop не запущен, кластер остановлен (`.\cluster.ps1`) или порт 8088 занят |
| `404 Not Found / nginx` вместо UI          | порт держит кто-то другой, например nginx-ingress MicroK8s (hostNetwork): `sudo microk8s stop`, `sudo snap disable microk8s` |
| после MicroK8s нет связи с контейнерами    | его Calico удалил маршрут к сети k3d - пересоздать кластер: `.\cluster.ps1 down`, `.\deploy.ps1` |
