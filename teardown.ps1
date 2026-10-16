#Requires -Version 5.1
<#
.SYNOPSIS
    sm-api の Kind 環境を一括削除するクリーンアップスクリプト

.EXAMPLE
    # 通常実行
    .\teardown.ps1

    # /etc/hosts の sm-api.local 行も削除する場合（管理者権限が必要）
    .\teardown.ps1 -CleanHosts
#>
param(
    [switch]$CleanHosts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"  # 削除時はエラーを無視

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# -------------------------------------------------------
# Kind クラスタ削除
# -------------------------------------------------------

Write-Step "Kind クラスタを削除"

$clusterExists = kind get clusters 2>&1 | Select-String "sm-api-cluster"
if ($clusterExists) {
    kind delete cluster --name sm-api-cluster
    Write-Info "クラスタ 'sm-api-cluster' を削除しました"
} else {
    Write-Warn "クラスタ 'sm-api-cluster' は存在しません。スキップします。"
}

# -------------------------------------------------------
# ローカルの Docker イメージ削除（オプション）
# -------------------------------------------------------

Write-Step "ローカル Docker イメージの確認"

foreach ($image in @("sm-api:latest", "sm-api-migrate:latest", "sm-api-batch:latest")) {
    $exists = docker images $image --format "{{.Repository}}:{{.Tag}}" 2>&1 | Select-String $image.Split(":")[0]
    if ($exists) {
        Write-Info "削除: $image"
        docker rmi $image 2>&1 | Out-Null
    } else {
        Write-Warn "存在しない: $image"
    }
}

# -------------------------------------------------------
# /etc/hosts クリーンアップ（オプション）
# -------------------------------------------------------

Write-Step "/etc/hosts のクリーンアップ"

$hostsPath = "C:\Windows\System32\drivers\etc\hosts"

if ($CleanHosts) {
    $hostsContent = Get-Content $hostsPath -ErrorAction SilentlyContinue
    if ($hostsContent | Select-String "sm-api.local") {
        try {
            $newContent = $hostsContent | Where-Object { $_ -notmatch "sm-api\.local" }
            Set-Content -Path $hostsPath -Value $newContent
            Write-Info "/etc/hosts から sm-api.local を削除しました"
        } catch {
            Write-Warn "管理者権限がないため /etc/hosts の編集に失敗しました。"
            Write-Warn "管理者権限の PowerShell で以下を実行してください:"
            Write-Warn '  $h = Get-Content "C:\Windows\System32\drivers\etc\hosts"'
            Write-Warn '  $h | Where-Object { $_ -notmatch "sm-api\.local" } | Set-Content "C:\Windows\System32\drivers\etc\hosts"'
        }
    } else {
        Write-Warn "sm-api.local は /etc/hosts に存在しません。スキップします。"
    }
} else {
    Write-Warn "-CleanHosts を指定しなかったため /etc/hosts はそのままです。"
    Write-Warn "削除する場合は管理者権限の PowerShell で:"
    Write-Warn '  .\teardown.ps1 -CleanHosts'
}

# -------------------------------------------------------
# 完了メッセージ
# -------------------------------------------------------

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  クリーンアップ完了!" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  再構築するには:" -ForegroundColor White
Write-Host "    .\setup.ps1" -ForegroundColor Yellow
Write-Host ""
