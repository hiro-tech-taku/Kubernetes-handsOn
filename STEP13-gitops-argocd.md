# Step 13: GitOps を体験する（Argo CD × Kind × sm-api）

## 概要

GitOps とは「**Git リポジトリをシステムの唯一の正源（Single Source of Truth）として、クラスタの状態を Git と一致させ続ける運用手法**」です。

```
開発者が k8s/*.yaml を編集して GitHub に push
    ↓
Argo CD が変更を検知（ポーリングまたは Webhook）
    ↓
Kind クラスタに自動で kubectl apply
    ↓
クラスタの状態が Git と一致した状態に保たれる
```

このハンズオンでは sm-api の `k8s/` ディレクトリを Argo CD で管理し、**GitHub に push するだけでデプロイが走る**仕組みを構築します。

---

## 前提条件

- sm-api の Kind クラスタが起動済み（`kind get clusters` で `sm-api-cluster` が表示される）
- GitHub アカウントがあること
- `git` コマンドが使えること

---

## 目次

1. [GitOps の概念を理解する](#1-gitops-の概念)
2. [GitHub リポジトリを用意する](#2-github-リポジトリを用意する)
3. [Argo CD をインストールする](#3-argo-cd-をインストールする)
4. [Argo CD の UI にアクセスする](#4-argo-cd-の-ui-にアクセスする)
5. [Argo CD に Application を登録する](#5-application-を登録する)
6. [GitOps を体験する（push → 自動デプロイ）](#6-gitops-を体験する)
7. [Argo CD の主要な概念を整理する](#7-主要な概念)

---

## 1. GitOps の概念

### 従来のデプロイ（Push型）

```
開発者
  ↓ kubectl apply / helm upgrade を直接実行
クラスタ
```

問題点：
- 誰が何をいつデプロイしたか Git に残らない
- クラスタの状態と Git の状態が乖離する可能性がある
- CI/CD パイプラインがクラスタへの認証情報を持つ必要がある

### GitOps（Pull型）

```
開発者
  ↓ git push（マニフェストを変更）
GitHub
  ↓ Argo CD が変更を検知（クラスタ内からポーリング）
Argo CD（クラスタ内）
  ↓ 自動で apply
クラスタ
```

メリット：
- デプロイ履歴が Git の commit 履歴として残る
- `git revert` でロールバックできる
- クラスタの外部から認証情報を持つ必要がない（Argo CD がクラスタ内で動く）
- クラスタの状態を常に Git と一致させられる（drift 検知）

---

## 2. GitHub リポジトリを用意する

### 2-1. sm-api を GitHub にプッシュする

現在ローカルにある sm-api ディレクトリを GitHub リポジトリとして公開します。

```powershell
cd C:\Users\takuh\OneDrive\Desktop\k8s\sm-api

# Git の初期化（未初期化の場合）
git init
git add .
git commit -m "initial commit"
```

GitHub で新しいリポジトリを作成する（例: `sm-api-k8s`）。

```powershell
# リモートを追加して push
git remote add origin https://github.com/<your-username>/sm-api-k8s.git
git branch -M main
git push -u origin main
```

### 2-2. リポジトリ構成の確認

Argo CD は指定したディレクトリ以下の YAML を監視します。今回は `k8s/` ディレクトリを対象にします。

```
sm-api-k8s/           ← GitHub リポジトリのルート
└── k8s/
    ├── 00-namespace.yaml
    ├── 01-configmap.yaml
    ├── 02-secret.yaml
    ├── 03-postgres.yaml
    ├── 04-migrate-job.yaml
    ├── 05-api-deployment.yaml
    ├── 06-batch-cronjob.yaml
    ├── 07-ingress.yaml
    └── 09-hpa.yaml
```

---

## 3. Argo CD をインストールする

### 3-1. Namespace を作成してインストール

```powershell
# Namespace 作成
kubectl create namespace argocd

# Argo CD をインストール
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 3-2. 起動を待つ

```powershell
kubectl wait --namespace argocd `
  --for=condition=ready pod `
  --selector=app.kubernetes.io/name=argocd-server `
  --timeout=180s
```

### 3-3. 起動確認

```powershell
kubectl get pods --namespace argocd
```

期待する出力（全て Running）：
```
NAME                                               READY   STATUS
argocd-application-controller-...                 1/1     Running
argocd-applicationset-controller-...              1/1     Running
argocd-dex-server-...                             1/1     Running
argocd-notifications-controller-...               1/1     Running
argocd-redis-...                                  1/1     Running
argocd-repo-server-...                            1/1     Running
argocd-server-...                                 1/1     Running
```

---

## 4. Argo CD の UI にアクセスする

### 4-1. ポートフォワードで UI を公開

```powershell
# 別のターミナルで実行（このコマンドは実行し続ける）
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

ブラウザで `https://localhost:8080` を開く（証明書警告は無視して続行）。

### 4-2. 初期パスワードを取得する

```powershell
# 初期パスワードを取得
$pass = kubectl get secret argocd-initial-admin-secret `
  -n argocd `
  -o jsonpath="{.data.password}"

[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($pass))
```

- ユーザー名: `admin`
- パスワード: 上のコマンドで取得した文字列

---

## 5. Application を登録する

Argo CD の「Application」は「どの Git リポジトリのどのディレクトリを、どのクラスタのどの Namespace に同期するか」を定義するリソースです。

### 5-1. Application マニフェストを作成する

`k8s/10-argocd-app.yaml` を作成する：

```powershell
@"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sm-api
  namespace: argocd
spec:
  project: default

  # 同期元: GitHub リポジトリ
  source:
    repoURL: https://github.com/<your-username>/sm-api-k8s.git
    targetRevision: main          # 監視するブランチ
    path: k8s                     # 監視するディレクトリ

  # 同期先: 現在のクラスタの sm-api Namespace
  destination:
    server: https://kubernetes.default.svc
    namespace: sm-api

  # 自動同期の設定
  syncPolicy:
    automated:
      prune: true      # Git から削除されたリソースをクラスタからも削除
      selfHeal: true   # クラスタが手動変更された場合に Git の状態に戻す
    syncOptions:
      - CreateNamespace=true
"@ | Set-Content k8s/10-argocd-app.yaml
```

`<your-username>` を実際の GitHub ユーザー名に変更してから適用する：

```powershell
kubectl apply -f k8s/10-argocd-app.yaml
```

### 5-2. 同期状態を確認する

```powershell
kubectl get application sm-api --namespace argocd
```

期待する出力：
```
NAME     SYNC STATUS   HEALTH STATUS
sm-api   Synced        Healthy
```

`Synced` = Git の状態とクラスタが一致している  
`Healthy` = 全リソースが正常に動いている

---

## 6. GitOps を体験する

### 6-1. sm-api のレプリカ数を変えて push する

`k8s/05-api-deployment.yaml` の `replicas` を `2` から `3` に変更する：

```yaml
spec:
  replicas: 3   # 2 → 3 に変更
```

```powershell
git add k8s/05-api-deployment.yaml
git commit -m "scale sm-api to 3 replicas"
git push origin main
```

### 6-2. Argo CD が自動で同期することを確認する

```powershell
# Argo CD のポーリング間隔はデフォルト3分。すぐ確認したい場合は手動同期
kubectl port-forward svc/argocd-server -n argocd 8080:443
# UI で "Sync" ボタンを押すか、以下のコマンドで即時同期

# argocd CLI をインストールしている場合
# argocd app sync sm-api

# または Application を確認してレプリカが増えていることを確認
kubectl get pods --namespace sm-api -l app=sm-api -w
```

30秒〜3分以内に Pod が3つになることを確認する：

```
NAME                      READY   STATUS    RESTARTS
sm-api-xxx-aaa            1/1     Running   0
sm-api-xxx-bbb            1/1     Running   0
sm-api-xxx-ccc            1/1     Running   0   ← 新しく追加された
```

### 6-3. selfHeal を体験する（手動変更を検知して自動で戻す）

`selfHeal: true` の効果を確認する。kubectl で直接レプリカ数を変更してみる：

```powershell
# クラスタを直接変更
kubectl scale deployment sm-api --namespace sm-api --replicas=1

# Pod が1つになることを確認
kubectl get pods --namespace sm-api -l app=sm-api

# しばらく待つ（30秒〜3分）
# → Argo CD が差分を検知して Git の状態（replicas: 3）に戻す
kubectl get pods --namespace sm-api -l app=sm-api -w
```

Argo CD が自動で replicas を 3 に戻すことを確認する。これが **drift 検知（設定のズレを自動修正する機能）** です。

### 6-4. ロールバックを体験する

Git の `revert` でデプロイをロールバックできる：

```powershell
# 直前の commit を revert
git revert HEAD --no-edit
git push origin main
```

Argo CD が変更を検知して `replicas: 2` に戻ることを確認する：

```powershell
kubectl get pods --namespace sm-api -l app=sm-api -w
```

---

## 7. 主要な概念

### Sync Status（同期状態）

| 状態 | 意味 |
|---|---|
| `Synced` | クラスタの状態が Git と一致している |
| `OutOfSync` | Git に変更があり、クラスタに未反映の差分がある |

### Health Status（正常性）

| 状態 | 意味 |
|---|---|
| `Healthy` | 全リソースが正常に動いている |
| `Progressing` | ローリングアップデート等、処理中 |
| `Degraded` | Pod がクラッシュしているなど異常がある |
| `Missing` | クラスタにリソースが存在しない |

### automated syncPolicy の設定

```yaml
syncPolicy:
  automated:
    prune: true      # Git から消えたリソースをクラスタからも削除する
    selfHeal: true   # kubectl で直接変更されたらGitの状態に戻す
```

| オプション | false（デフォルト） | true |
|---|---|---|
| `prune` | Git で削除しても k8s リソースは残る | Git で削除すると k8s からも削除 |
| `selfHeal` | kubectl の直接変更を許容する | kubectl の変更を Git の状態で上書きする |

### Argo CD vs Flux の違い

| | Argo CD | Flux |
|---|---|---|
| UI | あり（リッチなWebUI） | なし（CLI中心） |
| セットアップ | 比較的複雑 | シンプル |
| 複数クラスタ管理 | 得意 | 可能だが設定が必要 |
| 採用率 | 高い（エンタープライズ向け） | 高い（シンプル志向） |

どちらも GitOps の実現手段として同等の機能を持つ。チームの好みや規模で選択する。

---

## クリーンアップ

```powershell
# Argo CD の Application を削除
kubectl delete application sm-api --namespace argocd

# Argo CD 自体を削除
kubectl delete namespace argocd
```
