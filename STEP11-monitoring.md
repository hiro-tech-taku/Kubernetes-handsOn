# Step 11: Kubernetesの運用監視ハンズオン

sm-api の Kind 環境を使って、Kubernetesの運用・監視に必要な知識を実際に手を動かしながら学ぶ。

---

## 目次

1. [Probe（Readiness / Liveness / Startup）](#1-probe)
2. [QoS Class（Guaranteed / Burstable / BestEffort）](#2-qos-class)
3. [Metrics Server の導入と kubectl top](#3-metrics-server)
4. [requests / limits によるリソース制限](#4-requests--limits)
5. [HPA（Horizontal Pod Autoscaler）](#5-hpa)
6. [Kubernetesのログ収集の仕組み](#6-ログ収集)

---

## 1. Probe

### 1-1. 概念

Kubernetesには3種類のProbeがある。

| Probe | 役割 | 失敗時の動作 |
|---|---|---|
| **Readiness** | トラフィックを受け取れる状態か | ServiceのEndpointから除外（Podは落とさない） |
| **Liveness** | プロセスが生きているか | Podを再起動する |
| **Startup** | 起動完了したか（起動に時間がかかるアプリ向け） | 成功するまでLiveness/Readinessを無効化 |

**重要な使い分け：**
- `readinessProbe` のみ失敗 → Podは死んでいないがトラフィックが来ない（デプロイ途中などに有効）
- `livenessProbe` 失敗 → Podが再起動される（デッドロック・メモリリークの検知に有効）
- `startupProbe` → 起動に30秒以上かかるJavaアプリなどに使う。これが成功するまでLivenessが動かない

### 1-2. 現状確認

`05-api-deployment.yaml` にはすでに Readiness と Liveness が設定されている。

```powershell
kubectl describe pod --namespace sm-api -l app=sm-api | Select-String -Pattern "Liveness|Readiness|Startup" -Context 0,2
```

### 1-3. ハンズオン：Probeの動作を観察する

**① 正常な状態を確認する**

```powershell
kubectl get endpoints --namespace sm-api sm-api
# ADDRESS が2つ表示されていれば両Podがトラフィックを受け取れる状態
```

**② ReadinessProbeを意図的に失敗させる（存在しないパスに変更）**

`k8s/05-api-deployment.yaml` の `readinessProbe.httpGet.path` を `/health` から `/notfound` に変更して適用する。

```powershell
kubectl apply -f k8s/05-api-deployment.yaml
```

変化を観察する：

```powershell
# READY が 0/1 になり、Endpointから外れることを確認
kubectl get pods --namespace sm-api -l app=sm-api -w
kubectl get endpoints --namespace sm-api sm-api
```

**③ 元に戻す**

`readinessProbe.httpGet.path` を `/health` に戻して再適用する。

```powershell
kubectl apply -f k8s/05-api-deployment.yaml
kubectl get pods --namespace sm-api -l app=sm-api -w
# READY が 1/1 に戻ることを確認
```

**④ LivenessProbeとRESTARTS の関係を確認する**

```powershell
# RESTARTS 列を見る。Liveness失敗が続くとここが増える
kubectl get pods --namespace sm-api -l app=sm-api
```

---

## 2. QoS Class

### 2-1. 概念

KubernetesはPodに自動でQoS（Quality of Service）クラスを割り当てる。ノードのリソースが不足したとき、**BestEffort → Burstable → Guaranteed** の順で強制退去（Evict）される。

| クラス | 条件 | 特徴 |
|---|---|---|
| **Guaranteed** | 全コンテナで `requests == limits` | 最も保護される。確実にリソースが保証される |
| **Burstable** | `requests < limits` または一部だけ設定 | 余裕があればlimitsまで使える |
| **BestEffort** | `requests` も `limits` も未設定 | 余ったリソースしか使えない。最初に退去される |

### 2-2. 現状確認

sm-api は `requests < limits` なので **Burstable** クラスになっているはず。

```powershell
kubectl get pod --namespace sm-api -l app=sm-api -o jsonpath="{range .items[*]}{.metadata.name}{'\t'}{.status.qosClass}{'\n'}{end}"
```

### 2-3. ハンズオン：クラスを変えて確認する

**① Guaranteed に変更する**

`k8s/05-api-deployment.yaml` の resources を以下のように変更する（requests == limits にする）。

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "100m"       # requests と同じ値にする
    memory: "128Mi"   # requests と同じ値にする
```

```powershell
kubectl apply -f k8s/05-api-deployment.yaml
kubectl get pod --namespace sm-api -l app=sm-api -o jsonpath="{range .items[*]}{.metadata.name}{'\t'}{.status.qosClass}{'\n'}{end}"
# Guaranteed が表示されることを確認
```

**② Burstable に戻す**

元の値（requests != limits）に戻して再適用する。

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "64Mi"
  limits:
    cpu: "500m"
    memory: "256Mi"
```

```powershell
kubectl apply -f k8s/05-api-deployment.yaml
```

---

## 3. Metrics Server

### 3-1. 概念

`kubectl top` コマンドでPod/NodeのCPU・メモリ使用量をリアルタイムに確認するには **Metrics Server** が必要。HPAもMetrics Serverのデータを使ってスケーリングを判断する。

```
kubectl top pod  →  Metrics Server  →  kubelet（各Nodeのメトリクス収集）
```

### 3-2. Metrics Server のインストール

Kind 環境では TLS 検証を無効にするオプションが必要。  
公式マニフェストをローカルにダウンロードしてから `--kubelet-insecure-tls` を追加して適用する。

**① ダウンロード（`-L` でリダイレクトを追う）**

```powershell
curl.exe -L -o k8s/metrics-server.yaml `
  https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

**② `k8s/metrics-server.yaml` の args に `--kubelet-insecure-tls` を追記する**

Deployment の `args` セクションを以下のように変更する：

```yaml
      - args:
        - --cert-dir=/tmp
        - --secure-port=10250
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        - --kubelet-insecure-tls   # Kind環境用: kubeletのTLS検証を無効化
```

**③ 適用する**

```powershell
kubectl apply -f k8s/metrics-server.yaml
```

起動を待つ（1〜2分）：

```powershell
kubectl wait --namespace kube-system `
  --for=condition=ready pod `
  --selector=k8s-app=metrics-server `
  --timeout=120s
```

### 3-3. ハンズオン：kubectl top を使う

```powershell
# NodeのCPU・メモリ使用量
kubectl top node

# 全NamespaceのPod使用量
kubectl top pod --all-namespaces

# sm-api NamespaceのPodのみ
kubectl top pod --namespace sm-api

# コンテナ単位で表示
kubectl top pod --namespace sm-api --containers
```

期待する出力例：
```
NAME                      CPU(cores)   MEMORY(bytes)
sm-api-7d5896d4df-sx99f   1m           12Mi
sm-api-7d5896d4df-tpg8c   1m           11Mi
```

---

## 4. requests / limits

### 4-1. 概念

| 設定 | 意味 | スケジューリングへの影響 |
|---|---|---|
| `requests` | Podが**確保を要求する**リソース量 | Nodeに空きがなければそのNodeには配置されない |
| `limits` | Podが**使ってよい上限**のリソース量 | CPU: 超えるとスロットリング。メモリ: 超えるとOOMKill |

### 4-2. 現状確認

```powershell
kubectl describe pod --namespace sm-api -l app=sm-api | Select-String -Pattern "Requests|Limits" -Context 0,3
```

### 4-3. ハンズオン：OOMKill を体験する（メモリ上限超過）

**① メモリ上限を極端に小さくする**

`k8s/05-api-deployment.yaml` の limits.memory を `10Mi` に変更する。

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "10Mi"
  limits:
    cpu: "500m"
    memory: "10Mi"   # 極端に小さくする
```

```powershell
kubectl apply -f k8s/05-api-deployment.yaml
kubectl get pods --namespace sm-api -l app=sm-api -w
# OOMKilled → CrashLoopBackOff になることを確認
```

理由の確認：

```powershell
kubectl describe pod --namespace sm-api -l app=sm-api | Select-String "OOMKilled|Exit Code|Reason" -Context 0,1
```

**② 元に戻す**

limits.memory を `256Mi` に戻して再適用する。

```powershell
kubectl apply -f k8s/05-api-deployment.yaml
kubectl get pods --namespace sm-api -l app=sm-api -w
```

---

## 5. HPA（Horizontal Pod Autoscaler）

### 5-1. 概念

HPAはCPU・メモリ使用率を監視して、Podの数を自動で増減させる。

```
負荷増加 → CPU使用率上昇 → HPA検知 → replicas を増やす → 負荷分散
負荷減少 → CPU使用率低下 → HPA検知 → replicas を減らす
```

**前提**: Metrics Server が動いていること（Step 3 完了後に実施）

### 5-2. HPA マニフェストの作成

`k8s/09-hpa.yaml` を作成する：

```powershell
@"
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: sm-api-hpa
  namespace: sm-api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: sm-api
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 30   # CPU使用率30%超でスケールアウト
"@ | Set-Content k8s/09-hpa.yaml
```

```powershell
kubectl apply -f k8s/09-hpa.yaml

# 状態確認
kubectl get hpa --namespace sm-api
```

期待する出力：
```
NAME          REFERENCE          TARGETS   MINPODS   MAXPODS   REPLICAS
sm-api-hpa    Deployment/sm-api  1%/30%    2         6         2
```

### 5-3. ハンズオン：負荷をかけてスケールアウトを確認する

**別のターミナルで監視用コマンドを実行しておく：**

```powershell
# ターミナル1（監視）
kubectl get hpa --namespace sm-api -w
```

```powershell
# ターミナル2（監視）
kubectl get pods --namespace sm-api -l app=sm-api -w
```

**負荷をかける（ターミナル3）：**

Kind クラスタ内に負荷生成Podを起動する。

```powershell
kubectl run load-generator `
  --image=busybox:1.36 `
  --restart=Never `
  --namespace sm-api `
  -- sh -c "while true; do wget -q -O- http://sm-api.sm-api.svc.cluster.local:8080/metrics > /dev/null; done"
```

1〜2分待つと HPA がスケールアウトするのを確認できる：

```
# HPAのTARGETSが30%を超える
sm-api-hpa    Deployment/sm-api  45%/30%   2    6    4   ← レプリカが増える
```

**負荷を止める：**

```powershell
kubectl delete pod load-generator --namespace sm-api
```

数分後にスケールインして replicas が 2 に戻ることを確認する（スケールインはデフォルトで5分の安定化ウィンドウがある）。

```powershell
kubectl get hpa --namespace sm-api -w
```

---

## 6. ログ収集

### 6-1. Kubernetesのログの仕組み

```
アプリ（stdout/stderr）
    ↓
コンテナランタイム（containerd）
    ↓
Nodeのファイルシステム（/var/log/pods/）に書き込み
    ↓
kubectl logs → kubelet経由で取得
```

**重要なポイント：**
- `kubectl logs` が取得できるのは**現在起動中または直前のコンテナのログのみ**
- Podが削除されるとログも消える（揮発的）
- 本番環境では外部にログを転送・永続化する仕組みが必要

### 6-2. ハンズオン：基本的なログ操作

```powershell
# 現在のログを表示
kubectl logs --namespace sm-api -l app=sm-api

# リアルタイムでストリーミング
kubectl logs --namespace sm-api -l app=sm-api -f

# 直近50行だけ表示
kubectl logs --namespace sm-api -l app=sm-api --tail=50

# タイムスタンプ付きで表示
kubectl logs --namespace sm-api -l app=sm-api --timestamps

# 過去のコンテナのログ（再起動した場合）
kubectl logs --namespace sm-api <pod-name> --previous
```

### 6-3. Nodeのログファイルを直接確認する

```powershell
# Nodeのシェルに入る
docker exec -it sm-api-cluster-worker sh

# ログファイルの場所を確認
ls /var/log/pods/
ls /var/log/pods/sm-api_*/
```

### 6-4. ログ収集の本番パターン（概念）

本番環境では以下のパターンが使われる。

```
【パターン1: DaemonSet型（Fluent Bit / Fluentd）】
各NodeにDaemonSetでログ収集エージェントを配置
→ /var/log/pods/ を読んで外部のElasticsearch / CloudWatch / Loki に転送

【パターン2: Sidecar型】
アプリPodの中にログ収集コンテナを同居させる
→ 共有Volumeを通じてログファイルを収集

【パターン3: クラウドマネージドサービス】
EKS → CloudWatch Logs
GKE → Cloud Logging
AKS → Azure Monitor
```

### 6-5. ハンズオン：Fluent Bitを導入してログを確認する（発展）

```powershell
# Fluent Bit を Helm でインストール
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

helm install fluent-bit fluent/fluent-bit `
  --namespace logging `
  --create-namespace `
  --set backend.type=stdout   # まずはstdoutに出力して動作確認
```

```powershell
# Fluent Bit がどのログを拾っているか確認
kubectl logs --namespace logging -l app.kubernetes.io/name=fluent-bit --tail=30
```

---

## まとめ：各項目の関係

```
kubectl top pod / node
        ↑
  Metrics Server（メトリクス収集）
        ↑
    kubelet（各Nodeのリソース情報）

HPA ←── Metrics Server（CPU/メモリ使用率）
 ↓
Deployment の replicas を自動調整

Probe（Readiness/Liveness/Startup）
 ↓
Podの健全性をチェック → トラフィック制御 / 再起動

requests / limits → QoS Class の決定 → Eviction の優先順位
```
