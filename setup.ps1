#Requires -Version 5.1
<#
.SYNOPSIS
  sm-api Kind environment setup script

.DESCRIPTION
  Runs the following steps automatically:
    cluster  : Create Kind cluster
    ingress  : Install Nginx Ingress Controller
    build    : Build Docker images (parallel)
    load     : Load images into Kind cluster
    manifests: Apply Kubernetes manifests
    hosts    : Add sm-api.local to /etc/hosts
    verify   : Health check

.EXAMPLE
  # Run all steps
  .\setup.ps1

  # Run specific steps only
  .\setup.ps1 -Step build,load

  # Skip /etc/hosts writing
  .\setup.ps1 -SkipHosts

  # Install Kubernetes Dashboard as well
  .\setup.ps1 -WithDashboard
#>
param(
    [string[]]$Step = @("cluster","ingress","build","load","manifests","hosts","verify"),
    [switch]$SkipHosts,
    [switch]$WithDashboard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --------------------------------------------------
# Utility functions
# --------------------------------------------------

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
}

function Write-Info([string]$msg) {
    Write-Host "[INFO] $msg" -ForegroundColor Green
}

function Write-Warn([string]$msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Yellow
}

function Write-Fail([string]$msg) {
    Write-Host "[FAIL] $msg" -ForegroundColor Red
}

function Invoke-Cmd([string]$desc, [scriptblock]$cmd) {
    Write-Info $desc
    & $cmd
    if ($LASTEXITCODE -ne 0) {
        throw "Failed: $desc (exit=$LASTEXITCODE)"
    }
}

function Should-Run([string]$name) {
    return ($Step -contains $name)
}

# --------------------------------------------------
# Working directory
# --------------------------------------------------

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir
Write-Info "Working directory: $ScriptDir"
Write-Info "Steps to run: $($Step -join ', ')"

# --------------------------------------------------
# Prerequisite check
# --------------------------------------------------

foreach ($tool in @("docker","kind","kubectl")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool is not installed. See README prerequisites."
    }
    Write-Info "$tool ... OK"
}

# --------------------------------------------------
# STEP: cluster
# --------------------------------------------------

if (Should-Run "cluster") {
    Write-Step "STEP cluster: Create Kind cluster"

    $exists = (kind get clusters 2>$null) -match "sm-api-cluster"
    if ($exists) {
        Write-Warn "Cluster 'sm-api-cluster' already exists. Skipping."
    } else {
        Invoke-Cmd "Create Kind cluster" {
            kind create cluster --config kind-config.yaml
        }
    }

    Write-Info "Waiting for all nodes to be Ready (max 120s)..."
    kubectl wait --for=condition=Ready node --all --timeout=120s
    if ($LASTEXITCODE -ne 0) { throw "Node Ready timeout" }

    Invoke-Cmd "Check node status" {
        kubectl get nodes
    }
}

# --------------------------------------------------
# STEP: ingress
# --------------------------------------------------

if (Should-Run "ingress") {
    Write-Step "STEP ingress: Install Nginx Ingress Controller"

    $nsOutput = kubectl get namespace ingress-nginx --ignore-not-found 2>$null
    if ($nsOutput -match "ingress-nginx") {
        Write-Warn "Namespace ingress-nginx already exists. Skipping apply."
    } else {
        Invoke-Cmd "Apply Nginx Ingress Controller" {
            kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/kind/deploy.yaml
        }
    }

    Write-Info "Waiting for Ingress Controller to be ready (max 120s)..."
    kubectl wait --namespace ingress-nginx `
        --for=condition=ready pod `
        --selector=app.kubernetes.io/component=controller `
        --timeout=120s
    if ($LASTEXITCODE -ne 0) { throw "Ingress Controller timeout" }
    Write-Info "Ingress Controller: Ready"
}

# --------------------------------------------------
# STEP: build  (parallel)
# --------------------------------------------------

if (Should-Run "build") {
    Write-Step "STEP build: Build Docker images (parallel)"

    $builds = @(
        @{ Name = "sm-api";         Dockerfile = "api/Dockerfile"     },
        @{ Name = "sm-api-migrate"; Dockerfile = "migrate/Dockerfile" },
        @{ Name = "sm-api-batch";   Dockerfile = "batch/Dockerfile"   }
    )

    $jobs = @()
    foreach ($b in $builds) {
        $name = $b.Name
        $file = $b.Dockerfile
        $dir  = $ScriptDir
        Write-Info "Starting build: ${name} (${file})"

        $jobs += Start-Job -ScriptBlock {
            param($n, $f, $d)
            Set-Location $d
            $result = docker build -f $f -t "${n}:latest" . 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "docker build failed for ${n}: $result"
            }
            return "[DONE] build ${n}"
        } -ArgumentList $name, $file, $dir
    }

    Write-Info "Waiting for all builds to complete..."
    $failed = @()
    foreach ($j in $jobs) {
        $out = Receive-Job -Job $j -Wait -AutoRemoveJob
        if ($j.State -eq "Failed") {
            $failed += $j.Name
            Write-Fail "Build job failed: $($j.Name)"
        } else {
            Write-Info $out
        }
    }
    if ($failed.Count -gt 0) {
        throw "Some builds failed: $($failed -join ', ')"
    }
    Write-Info "All images built successfully."
}

# --------------------------------------------------
# STEP: load
# --------------------------------------------------

if (Should-Run "load") {
    Write-Step "STEP load: Load images into Kind cluster"

    foreach ($img in @("sm-api:latest","sm-api-migrate:latest","sm-api-batch:latest")) {
        Invoke-Cmd "kind load $img" {
            kind load docker-image $img --name sm-api-cluster
        }
    }
}

# --------------------------------------------------
# STEP: manifests
# --------------------------------------------------

if (Should-Run "manifests") {
    Write-Step "STEP manifests: Apply Kubernetes manifests"

    # 5-1 Base resources
    Write-Info "5-1: Namespace / ConfigMap / Secret"
    kubectl apply -f k8s/00-namespace.yaml
    kubectl apply -f k8s/01-configmap.yaml
    kubectl apply -f k8s/02-secret.yaml

    # 5-2 PostgreSQL
    Write-Info "5-2: PostgreSQL StatefulSet"
    kubectl apply -f k8s/03-postgres.yaml
    Write-Info "Waiting for PostgreSQL (max 120s)..."
    kubectl wait --namespace sm-api `
        --for=condition=ready pod `
        --selector=app=postgres `
        --timeout=120s
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL timeout" }
    Write-Info "PostgreSQL: Ready"

    # 5-3 DB Migration Job
    Write-Info "5-3: DB Migration Job"
    $jobOutput = kubectl get job db-migrate -n sm-api --ignore-not-found 2>$null
    if ($jobOutput -match "db-migrate") {
        Write-Warn "Job db-migrate already exists. Deleting and re-applying."
        kubectl delete job db-migrate -n sm-api
    }
    kubectl apply -f k8s/04-migrate-job.yaml
    Write-Info "Waiting for migration to complete (max 120s)..."
    kubectl wait --namespace sm-api `
        --for=condition=complete job/db-migrate `
        --timeout=120s
    if ($LASTEXITCODE -ne 0) { throw "Migration job timeout" }
    Write-Info "Migration logs:"
    kubectl logs --namespace sm-api job/db-migrate

    # 5-4 API Deployment
    Write-Info "5-4: API Deployment"
    kubectl apply -f k8s/05-api-deployment.yaml
    Write-Info "Waiting for API Pods (max 60s)..."
    kubectl wait --namespace sm-api `
        --for=condition=ready pod `
        --selector=app=sm-api `
        --timeout=60s
    if ($LASTEXITCODE -ne 0) { throw "API Pod timeout" }
    Write-Info "API Pods: Ready"

    # 5-5 CronJob
    Write-Info "5-5: CronJob"
    kubectl apply -f k8s/06-batch-cronjob.yaml

    # 5-6 Ingress
    Write-Info "5-6: Ingress"
    kubectl apply -f k8s/07-ingress.yaml

    # 5-7 Dashboard (optional)
    if ($WithDashboard) {
        Write-Info "5-7: Kubernetes Dashboard"
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
        kubectl apply -f k8s/08-dashboard-admin.yaml
        Write-Info "Dashboard installed."
        Write-Warn "Get token: kubectl create token admin-user --namespace kubernetes-dashboard"
        Write-Warn "Run proxy: kubectl proxy"
        Write-Warn "Open: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
    }
}

# --------------------------------------------------
# STEP: hosts
# --------------------------------------------------

if (Should-Run "hosts") {
    Write-Step "STEP hosts: Add sm-api.local to /etc/hosts"

    $hostsPath  = "C:\Windows\System32\drivers\etc\hosts"
    $hostsEntry = "127.0.0.1  sm-api.local"

    if ($SkipHosts) {
        Write-Warn "-SkipHosts specified. Skipping /etc/hosts update."
        Write-Warn "Add manually: $hostsEntry"
    } else {
        $alreadyExists = Get-Content $hostsPath -ErrorAction SilentlyContinue | Select-String "sm-api.local"
        if ($alreadyExists) {
            Write-Warn "sm-api.local already exists in /etc/hosts. Skipping."
        } else {
            try {
                Add-Content -Path $hostsPath -Value $hostsEntry
                Write-Info "Added to /etc/hosts: $hostsEntry"
            } catch {
                Write-Warn "Failed to write /etc/hosts (admin privilege required)."
                Write-Warn "Run as Administrator:"
                Write-Warn "  Add-Content -Path `"$hostsPath`" -Value `"$hostsEntry`""
            }
        }
    }
}

# --------------------------------------------------
# STEP: verify
# --------------------------------------------------

if (Should-Run "verify") {
    Write-Step "STEP verify: Health check"

    Write-Info "All resources in sm-api namespace:"
    kubectl get all --namespace sm-api

    Write-Info "Ingress:"
    kubectl get ingress --namespace sm-api

    $hostsOk = Get-Content "C:\Windows\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue |
               Select-String "sm-api.local"

    if ($hostsOk) {
        Write-Info "Health check: http://sm-api.local/health"
        Write-Info "Waiting 5s for Ingress to initialize..."
        Start-Sleep -Seconds 5
        try {
            $res = Invoke-WebRequest -UseBasicParsing -Uri "http://sm-api.local/health" -TimeoutSec 10
            Write-Info "StatusCode : $($res.StatusCode)"
            Write-Info "Response   : $($res.Content)"
        } catch {
            Write-Warn "Health check failed. Ingress may still be initializing."
            Write-Warn "Retry: Invoke-WebRequest -UseBasicParsing -Uri http://sm-api.local/health"
        }
    } else {
        Write-Warn "/etc/hosts not configured. Skipping HTTP check."
        Write-Warn "After adding hosts entry, run:"
        Write-Warn "  Invoke-WebRequest -UseBasicParsing -Uri http://sm-api.local/health"
    }
}

# --------------------------------------------------
# Done
# --------------------------------------------------

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host "  GET  http://sm-api.local/health"
Write-Host "  GET  http://sm-api.local/metrics"
Write-Host "  POST http://sm-api.local/metrics"
Write-Host ""
Write-Host "  Teardown: .\teardown.ps1" -ForegroundColor Yellow
Write-Host ""
