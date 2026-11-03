<#
.SYNOPSIS
    Управление локальным кластером k3d в WSL.

.EXAMPLE
    .\cluster.ps1             # status: поды и адреса
    .\cluster.ps1 up          # создать или запустить кластер
    .\cluster.ps1 stop        # остановить, данные сохраняются
    .\cluster.ps1 down        # удалить кластер вместе с данными Postgres
    .\cluster.ps1 logs api    # логи сервиса (api, gateway, ui, keycloak, postgres)
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'stop', 'down', 'status', 'logs')]
    [string] $Action = 'status',
    [Parameter(Position = 1)]
    [string] $Service,
    [string] $Distro = 'Ubuntu'
)

[Console]::OutputEncoding = [Text.Encoding]::UTF8

if ($Action -eq 'down') {
    $answer = Read-Host 'Кластер и данные Postgres будут удалены. Продолжить? (y/N)'
    if ($answer -ne 'y') { return }
}

wsl.exe -d $Distro --cd $PSScriptRoot -- bash scripts/cluster.sh $Action $Service
exit $LASTEXITCODE
