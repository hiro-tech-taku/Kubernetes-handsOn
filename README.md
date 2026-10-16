# slack-metrics API — Kind 環境構築手順書

## 概要

このドキュメントは、Kind（Kubernetes in Docker）を使って以下の構成を手元で再現するための手順書です。

```
[ブラウザ / curl]
      │  http://sm-api.local
      ▼
/etc/hosts (127.0.0.1 → sm-api.local)
      │
      ▼ port 80
┌─────────────────────────────────────────────────┐
│  Kind クラスタ (sm-api-cluster)                  │
│                                                  │
│  Nginx Ingress Controller (NodePort → 80)        │
│          │                                       │
│        Ingress (sm-api.local → sm-api:8080)      │
│          │                                       │
│  Service: sm-api (ClusterIP)                     │
│     │              │                             │
│   Pod(API)       Pod(API)   ← Deployment×2       │
│     └──────┬──────┘                              │
│            │  envFrom ConfigMap / Secret         │
│            ▼                                     │
│  Service: postgres (Headless)                    │
│            │                                     │
│         Pod(PostgreSQL)  ← StatefulSet           │
│            │                                     │
│          PVC ← PV (1Gi)                          │
│                                                  │
│  Job: db-migrate    (単発実行 Pod)               │
│  CronJob: slack-metrics-batch (毎時0分)          │
└─────────────────────────────────────────────────┘
```

### 使用するKubernetesリソース一覧

| リソース | 名前 | 役割 |
|---|---|---|
| Namespace | sm-api | 全リソースの分離 |
| ConfigMap | app-config | DB接続先・ポート等の設定値 |
| Secret | db-secret | DBユーザー名・パスワード |
| StatefulSet | postgres | PostgreSQL本体 |
| Service (Headless) | postgres | PostgreSQL への安定したDNS名 |
| PVC | postgres-data | PostgreSQLデータ永続化 |
| Job | db-migrate | DBマイグレーション（単発） |
| Deployment | sm-api | slack-metrics API（2レプリカ） |
| Service (ClusterIP) | sm-api | API Podへの内部エンドポイント |
| CronJob | slack-metrics-batch | 毎時0分バッチ集計 |
| Ingress | sm-api-ingress | 外部からのルーティング定義 |

---

## 前提条件

以下のツールがインストール済みであること。

```powershell
# バージョン確認
docker version
kind version        # v0.20 以上推奨
kubectl version --client
```

インストールされていない場合:

- Docker Desktop: https://docs.docker.com/desktop/install/windows-install/
- Kind: https://kind.sigs.k8s.io/docs/user/quick-start/#installation
- kubectl: https://kubernetes.io/ja/docs/tasks/tools/install-kubectl-windows/

---

## ディレクトリ構成

```
sm-api/
├── go.mod                        # Go モジュール定義
├── go.sum
├── kind-config.yaml              # Kind クラスタ設定
├── api/
│   ├── Dockerfile                # API イメージ
│   ├── main.go                   # HTTPサーバー (/health, /metrics)
│   ├── db/db.go                  # DB接続共通処理
│   └── handler/metrics.go        # GET/POST ハンドラー
├── migrate/
│   ├── Dockerfile                # マイグレーション イメージ
│   ├── main.go                   # マイグレーション実行器
│   └── migrations/
│       ├── 001_create_slack_metrics.sql
│       └── 002_add_reaction_count.sql
├── batch/
│   ├── Dockerfile                # バッチ イメージ
│   └── main.go                   # Slackメトリクス集計バッチ
└── k8s/
    ├── 00-namespace.yaml
    ├── 01-configmap.yaml
    ├── 02-secret.yaml
    ├── 03-postgres.yaml          # StatefulSet + Headless Service
    ├── 04-migrate-job.yaml       # Job
    ├── 05-api-deployment.yaml    # Deployment + ClusterIP Service
    ├── 06-batch-cronjob.yaml     # CronJob
    └── 07-ingress.yaml
```

---

## 手順

### STEP 1 — Kind クラスタを作成する

```powershell
cd C:\Users\takuh\OneDrive\Desktop\k8s\sm-api

kind create cluster --config kind-config.yaml
```

作成確認:

```powershell
kubectl cluster-info --context kind-sm-api-cluster
kubectl get nodes
```

期待する出力:
```
NAME                            STATUS   ROLES           AGE
sm-api-cluster-control-plane    Ready    control-plane   1m
sm-api-cluster-worker           Ready    <none>          1m
sm-api-cluster-worker2          Ready    <none>          1m
```

---

### STEP 2 — Nginx Ingress Controller をインストールする

Kind 用の公式マニフェストを適用します。

```powershell
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/kind/deploy.yaml
```

Controller の起動を待機します（1〜2分かかります）:

```powershell
kubectl wait --namespace ingress-nginx `
  --for=condition=ready pod `
  --selector=app.kubernetes.io/component=controller `
  --timeout=120s
```

---

### STEP 3 — Docker イメージをビルドする

`go.mod` を共有しているため、ビルドコンテキストは `sm-api/` ルートを指定します。

```powershell
cd C:\Users\takuh\OneDrive\Desktop\k8s\sm-api

# API イメージ
docker build -f api/Dockerfile -t sm-api:latest .

# マイグレーション イメージ
docker build -f migrate/Dockerfile -t sm-api-migrate:latest .

# バッチ イメージ
docker build -f batch/Dockerfile -t sm-api-batch:latest .
```

---

### STEP 4 — イメージを Kind クラスタにロードする

Kind はローカルの Docker レジストリとは独立しているため、`kind load` が必要です。

```powershell
kind load docker-image sm-api:latest        --name sm-api-cluster
kind load docker-image sm-api-migrate:latest --name sm-api-cluster
kind load docker-image sm-api-batch:latest  --name sm-api-cluster
```

ロード確認:

```powershell
kubectl get nodes -o wide
# 各ノードで確認する場合
docker exec sm-api-cluster-worker crictl images | Select-String "sm-api"
```

---

### STEP 5 — Kubernetes マニフェストを適用する

#### 5-1. 基盤リソース（Namespace / ConfigMap / Secret）

```powershell
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-configmap.yaml
kubectl apply -f k8s/02-secret.yaml
```

#### 5-2. PostgreSQL（StatefulSet）

```powershell
kubectl apply -f k8s/03-postgres.yaml
```

PostgreSQL の起動を待機します:

```powershell
kubectl wait --namespace sm-api `
  --for=condition=ready pod `
  --selector=app=postgres `
  --timeout=120s
```

#### 5-3. DBマイグレーション（Job）

```powershell
kubectl apply -f k8s/04-migrate-job.yaml
```

Job の完了を確認します:

```powershell
kubectl wait --namespace sm-api `
  --for=condition=complete job/db-migrate `
  --timeout=120s

# ログで適用内容を確認
kubectl logs --namespace sm-api job/db-migrate
```

期待するログ出力例:
```
DB接続成功: host=postgres.sm-api.svc.cluster.local dbname=appdb
スキップ (適用済み): 001_create_slack_metrics  ← 2回目以降
適用完了: 002_add_reaction_count
マイグレーション完了: 1 件適用
```

#### 5-4. API（Deployment + Service）

```powershell
kubectl apply -f k8s/05-api-deployment.yaml
```

Pod の起動確認:

```powershell
kubectl get pods --namespace sm-api -l app=sm-api
kubectl get service --namespace sm-api sm-api
```

#### 5-5. バッチ（CronJob）

```powershell
kubectl apply -f k8s/06-batch-cronjob.yaml
```

CronJob の登録確認:

```powershell
kubectl get cronjob --namespace sm-api
```

#### 5-6. Ingress

```powershell
kubectl apply -f k8s/07-ingress.yaml
```

Ingress の確認:

```powershell
kubectl get ingress --namespace sm-api
```

---

### STEP 6 — /etc/hosts を設定する（ホスト名解決）

`sm-api.local` を `127.0.0.1` に向けます。

**Windows（管理者権限が必要）:**

```powershell
# 管理者権限の PowerShell で実行
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "127.0.0.1  sm-api.local"
```

または `C:\Windows\System32\drivers\etc\hosts` をメモ帳（管理者）で開き、末尾に追記:

```
127.0.0.1  sm-api.local
```

---

### STEP 7 — 動作確認

全リソースの状態を確認します:

```powershell
kubectl get all --namespace sm-api
```

**ヘルスチェック:**

```powershell
curl http://sm-api.local/health
# 期待値: {"status":"ok"}
```

**メトリクス一覧取得（GET）:**

```powershell
curl http://sm-api.local/metrics
# 期待値: [] （マイグレーション直後は空配列）
```

**メトリクス登録（POST）:**

```powershell
curl -X POST http://sm-api.local/metrics `
  -H "Content-Type: application/json" `
  -d '{"channel":"general","msg_count":42,"active_users":10}'
# 期待値: {"id":1,"channel":"general","msg_count":42,...}
```
何が起きているか:
```
curl → /etc/hosts → 127.0.0.1
  → Kind NodePort (ホストのポート80)
    → Nginx Ingress Controller (Pod)
      → Ingress ルール (sm-api.local → sm-api Service)
        → sm-api Pod (API サーバー)
          → PostgreSQL Pod
            → slack_metrics テーブルに INSERT
              → {"id":1, "channel":"general", ...} を返す
# main.go が HTTP リクエストを受け取り、受け取ったJSONを slack_metrics テーブルに1行追加します。これは手動で作ったテストデータです。
```


**再度 GET して登録されていることを確認:**

```powershell
curl http://sm-api.local/metrics
```

---

## 運用操作

### バッチを手動で即時実行する

CronJobから手動で Job を作成します:

```powershell
kubectl create job --namespace sm-api `
  --from=cronjob/slack-metrics-batch `
  slack-metrics-batch-manual-001

# ログ確認
kubectl logs --namespace sm-api `
  -l app=slack-metrics-batch --tail=50
```
何が起きているか:
```
CronJob は「毎時0分に自動実行」の定義体です。--from=cronjob/... を指定すると、その定義をコピーして今すぐ1回だけ実行する Job を手動で作成できます。
Kubernetes がその Job に対応する Pod を起動し、main.goが実行されます。
 ```
batch/main.go が実際にやること
```
① DBに接続 (PostgreSQL)
    ↓
② channels = ["general","random","dev","ops","design","marketing"] をループ
    ↓
③ 各チャンネルに対してランダム値を生成
    msg_count:     1〜500
    active_users:  1〜50
    reaction_count: 0〜199
    ↓
④ slack_metrics テーブルに INSERT（6行追加）
    ↓
⑤ 直近7日間の集計サマリーをログ出力（SELECT + GROUP BY）
    ↓
⑥ 90日以上前の古いデータを DELETE（クリーンアップ）
    ↓
⑦ 終了（Podはここで exit → Completed 状態になる）
```

### DBマイグレーションを再実行する（冪等）

既存の Job を削除してから再適用します:

```powershell
kubectl delete job --namespace sm-api db-migrate
kubectl apply -f k8s/04-migrate-job.yaml
kubectl wait --namespace sm-api --for=condition=complete job/db-migrate --timeout=60s
kubectl logs --namespace sm-api job/db-migrate
```

main.goが schema_migrations テーブルを確認して「すでに適用済みならスキップ」する冪等な設計になっていることが確認できました。何度実行してもテーブルが壊れません。
```
スキップ (適用済み): 001_create_slack_metrics
スキップ (適用済み): 002_add_reaction_count
マイグレーション完了: 0 件適用
```


### PostgreSQL に直接接続する

```powershell
kubectl exec --namespace sm-api -it statefulset/postgres `
  -- psql -U appuser -d appdb
```

よく使うクエリ:

```sql
-- テーブル一覧
\dt

-- マイグレーション適用状況
SELECT * FROM schema_migrations;

-- メトリクス確認
SELECT * FROM slack_metrics ORDER BY recorded_at DESC LIMIT 10;
```

### API の Pod ログを確認する

```powershell
kubectl logs --namespace sm-api -l app=sm-api -f
```

### イメージを更新してローリングアップデートする

```powershell
# 1. 新しいイメージをビルド
docker build -f api/Dockerfile -t sm-api:v2 .

# 2. Kind にロード
kind load docker-image sm-api:v2 --name sm-api-cluster

# 3. Deployment のイメージを更新（ローリングアップデート開始）
kubectl set image --namespace sm-api deployment/sm-api sm-api=sm-api:v2

# 4. ロールアウト状況を確認
kubectl rollout status --namespace sm-api deployment/sm-api
```

---

## トラブルシューティング

### Pod が `Pending` のまま起動しない

```powershell
kubectl describe pod --namespace sm-api <pod-name>
```

よくある原因:
- `imagePullPolicy: Never` なのに `kind load` が未実施 → STEP 4 を再実行
- PVC がバインドされない → `kubectl get pvc -n sm-api` で確認

### Ingress で `503 Service Unavailable`

```powershell
# API Pod の readinessProbe を確認
kubectl describe pod --namespace sm-api -l app=sm-api

# Ingress Controller のログを確認
kubectl logs --namespace ingress-nginx `
  -l app.kubernetes.io/component=controller --tail=50
```

### マイグレーション Job が失敗する

```powershell
kubectl describe job --namespace sm-api db-migrate
kubectl logs --namespace sm-api job/db-migrate
```

PostgreSQL が起動していない場合は initContainer のログを確認:

```powershell
kubectl logs --namespace sm-api job/db-migrate -c wait-for-postgres
```

### クラスタを完全にリセットする

```powershell
kind delete cluster --name sm-api-cluster
```

再構築は STEP 1 から実施します。

---

## クリーンアップ

```powershell
# マニフェストを全削除（PVCも含む）
kubectl delete namespace sm-api

# Kind クラスタ自体を削除
kind delete cluster --name sm-api-cluster

# /etc/hosts から sm-api.local の行を削除
#（メモ帳・管理者権限で編集）
```

---

## 一括実行スクリプト

手順書の STEP 1〜7 を自動実行するスクリプトを用意しています。

### セットアップ（構築）

```powershell
# 通常実行（全ステップ）
.\setup.ps1

# /etc/hosts の書き込みをスキップする場合（手動で追記する場合）
.\setup.ps1 -SkipHosts

# Kubernetes Dashboard も一緒にインストールする場合
.\setup.ps1 -WithDashboard
```

### クリーンアップ（削除）

```powershell
# Kind クラスタ + ローカルイメージを削除
.\teardown.ps1

# /etc/hosts の sm-api.local 行も削除する場合（管理者権限が必要）
.\teardown.ps1 -CleanHosts
```

### スクリプトの実行に失敗する場合

PowerShell の実行ポリシーが制限されている場合は以下で一時的に許可します:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup.ps1
```
