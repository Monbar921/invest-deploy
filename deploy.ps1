<#
.SYNOPSIS
    Локальный CI/CD: собирает сервисы на Windows и выкатывает их в k3d в WSL.

.DESCRIPTION
    Для каждого сервиса: сборка (mvn / npm) на Windows -> docker build в WSL -> k3d image import -> kubectl apply
    и ожидание rolling update. Если кластера нет, он создаётся.

.EXAMPLE
    .\deploy.ps1                    # всё: postgres keycloak api gateway ui
    .\deploy.ps1 api                # только invest-api
    .\deploy.ps1 api ui -Test       # с тестами (mvn verify, npm run lint + test)
    .\deploy.ps1 gateway -SkipBuild # без пересборки, из уже собранных артефактов
#>
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [ValidateSet('all', 'postgres', 'keycloak', 'api', 'gateway', 'ui')]
    [string[]] $Services = @('all'),
    [switch] $Test,
    [switch] $SkipBuild,
    [string] $Distro = 'Ubuntu'
)

$ErrorActionPreference = 'Stop'
# вывод WSL в UTF-8
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Projects = Split-Path $PSScriptRoot -Parent
$JavaRepos = @{ api = 'invest-api'; gateway = 'invest-gateway' }

if ($Services -contains 'all') {
    $Services = @('postgres', 'keycloak', 'api', 'gateway', 'ui')
}

function Invoke-Native([string] $Title, [scriptblock] $Block) {
    Write-Host "`n==> $Title" -ForegroundColor Cyan
    # PowerShell 5.1 при Stop превращает любую строку в stderr (например WARNING от JVM) в ошибку, успех определяем по коду выхода
    $ErrorActionPreference = 'Continue'
    # Write-Host: вывод сборки не должен попасть в возвращаемое значение функции
    & $Block 2>&1 | ForEach-Object { Write-Host "$_" }
    if ($LASTEXITCODE -ne 0) { throw "${Title}: код выхода $LASTEXITCODE" }
}

# short sha + -dirty, если есть незакоммиченные изменения: попадает в тег образа
function Get-Revision([string] $Repo) {
    $sha = git -C $Repo rev-parse --short HEAD 2>$null
    if (-not $sha) { return 'nogit' }
    if (git -C $Repo status --porcelain) { $sha += '-dirty' }
    return $sha
}

function Build-Java([string] $Repo) {
    Push-Location $Repo
    try {
        if ($Test) {
            # тестам нужен Docker для Testcontainers
            Invoke-Native "$(Split-Path $Repo -Leaf): mvn clean verify" { mvn -B -ntp -q clean verify }
        } else {
            Invoke-Native "$(Split-Path $Repo -Leaf): mvn clean package" { mvn -B -ntp -q clean package -DskipTests }
        }
    } finally {
        Pop-Location
    }
}

function Build-Ui([string] $Repo) {
    Push-Location $Repo
    try {
        $lock = Get-Item package-lock.json
        $modules = Get-Item node_modules -ErrorAction SilentlyContinue
        if (-not $modules -or $lock.LastWriteTime -gt $modules.LastWriteTime) {
            Invoke-Native 'invest-api-ui: npm ci' { npm ci --no-audit --no-fund }
        }
        if ($Test) {
            Invoke-Native 'invest-api-ui: npm run lint' { npm run lint }
            Invoke-Native 'invest-api-ui: npm test' { npm test }
        }
        Invoke-Native 'invest-api-ui: npm run build' { npm run build }
    } finally {
        Pop-Location
    }
}

# @(...): с одним сервисом foreach вернул бы строку, и @targets передал бы её в WSL по символам
$targets = @(foreach ($service in $Services) {
    switch ($service) {
        { $JavaRepos.ContainsKey($_) } {
            $repo = Join-Path $Projects $JavaRepos[$service]
            if (-not $SkipBuild) { Build-Java $repo }
            "$service@$(Get-Revision $repo)"
        }
        'ui' {
            $repo = Join-Path $Projects 'invest-api-ui'
            if (-not $SkipBuild) { Build-Ui $repo }
            "$service@$(Get-Revision $repo)"
        }
        default { $service }
    }
})

Invoke-Native "deploy: $($targets -join ' ')" {
    wsl.exe -d $Distro --cd $PSScriptRoot -- bash scripts/deploy.sh @targets
}
