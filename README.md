# invest-deploy

Локальный CI/CD для invest-api, invest-gateway и invest-api-ui: сборка на Windows, выкатка в k3d в WSL.

```powershell
copy .env.example .env    # заполнить TINKOFF_TOKEN
.\deploy.ps1              # всё; .\deploy.ps1 api - один сервис
.\cluster.ps1             # статус и адреса
```

UI: http://invest.localhost:8088 (`investor` / `investor`).

Документация - в [docs/](docs/README.md).
