# Step 12: 概念が似ているリソースの違いを理解する

sm-api の Kind 環境で実際に使われているリソースを題材に、Service の種類と Ingress の違いを整理する。

---

## 目次

1. [Service の4種類を整理する](#1-service-の4種類)
2. [sm-api 環境で実際に確認する](#2-sm-api-環境で実際に確認する)
3. [Service(LoadBalancer) と Ingress の違い](#3-serviceloadbalancer-と-ingress-の違い)
4. [ハンズオン：Service の種類を変えて挙動を確認する](#4-ハンズオン)
5. [自分の言葉で説明できるか確認する](#5-確認チェックリスト)

---

## 1. Service の4種類

### 全体像

```
クラスタ外部
  │
  │  ← LoadBalancer    クラウドのLBを作成して外部IPを払い出す
  │  ← NodePort        Nodeのポートを開けて外部からアクセス可能にする
  │
クラスタ内部
  │
  │  ← ClusterIP       クラスタ内専用の仮想IP。外部からは到達不可
  │  ← Headless        IPを持たない。DNS名でPodに直接名前解決
```

---

### ClusterIP（デフォルト）

```yaml
spec:
  type: ClusterIP   # 省略した場合もClusterIP
  clusterIP: 10.96.x.x  # 自動割り当て
```

- クラスタ**内部**にだけ存在する仮想IP
- 外部からは絶対に到達できない
- Pod が増減しても Service の IP は変わらない
- **用途:** クラスタ内のPod同士の通信（API → DB など）

```
sm-api Pod ──→ ClusterIP:8080 ──→ sm-api Pod-A
                               └─→ sm-api Pod-B
```

sm-api プロジェクトでの使用例:
```yaml
# k8s/05-api-deployment.yaml
kind: Service
spec:
  type: ClusterIP
  ports:
    - port: 8080
```

---

### NodePort

```yaml
spec:
  type: NodePort
  ports:
    - port: 8080        # ClusterIP のポート（クラスタ内）
      targetPort: 8080  # Pod のポート
      nodePort: 30080   # Node に開けるポート（30000〜32767）
```

- 全Nodeの指定ポート（30000〜32767）を開放する
- `NodeのIP:30080` でクラスタ外からアクセス可能
- **用途:** 開発・検証環境でのアクセス確認。本番では使わないことが多い

```
外部 ──→ Node-A:30080 ──→ ClusterIP:8080 ──→ Pod
         Node-B:30080 ─┘
```

**注意点:** NodePort は全Nodeのポートを開けるため、Nodeが増えるたびにポートが増える。セキュリティ・管理の面から本番では LoadBalancer か Ingress を使う。

---

### LoadBalancer

```yaml
spec:
  type: LoadBalancer
```

- クラウドプロバイダー（AWS/GCP/Azure）のロードバランサーを自動作成する
- **外部IPが自動で払い出される**
- 内部的には NodePort + クラウドLB の組み合わせ

```
外部 ──→ クラウドLB（外部IP） ──→ Node:NodePort ──→ Pod
```

**Kind環境での挙動:** Kind はクラウド環境ではないため、`type: LoadBalancer` にしても `EXTERNAL-IP` が `<pending>` のまま払い出されない。

---

### Headless Service

```yaml
spec:
  clusterIP: None   # これだけでHeadlessになる
```

- **IPを持たない** Service
- DNS 名を Pod 単体の IP に直接解決する
- `kubectl get service` で `CLUSTER-IP` が `None` と表示される
- **用途:** StatefulSet（DB、Kafka等）で Pod 個別に接続したいとき

```
通常のClusterIP:
  postgres.sm-api.svc.cluster.local → 10.96.x.x（仮想IP）→ Pod

Headless:
  postgres.sm-api.svc.cluster.local → 10.244.x.x（PodのIP直接）
  postgres-0.postgres.sm-api.svc.cluster.local → postgres-0 のIP
  postgres-1.postgres.sm-api.svc.cluster.local → postgres-1 のIP
```

sm-api プロジェクトでの使用例:
```yaml
# k8s/03-postgres.yaml
kind: Service
spec:
  clusterIP: None   # Headless
```

StatefulSet の各Podに `postgres-0`、`postgres-1` という固定のDNS名でアクセスできるのはこのHeadless Serviceのおかげ。

---

### 4種類の比較表

| 種類 | CLUSTER-IP | 外部アクセス | 主な用途 |
|---|---|---|---|
| ClusterIP | あり（仮想IP） | ❌ 不可 | クラスタ内サービス間通信 |
| NodePort | あり | ✅ NodeのIP:ポートで可能 | 開発・検証環境 |
| LoadBalancer | あり | ✅ 外部IPが払い出される | クラウド本番環境 |
| Headless | None | ❌ 不可 | StatefulSet の Pod個別アクセス |

---

## 2. sm-api 環境で実際に確認する

### 全 Service の一覧

```powershell
kubectl get service --namespace sm-api
```

期待する出力:
```
NAME       TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
postgres   ClusterIP   None           <none>        5432/TCP   ...  ← Headless
sm-api     ClusterIP   10.96.x.x      <none>        8080/TCP   ...  ← ClusterIP
```

### Headless Service の DNS 解決を確認する

```powershell
# クラスタ内に一時Podを起動してDNS解決を確認
kubectl run dns-test --image=busybox:1.36 --restart=Never --namespace sm-api `
  -- sh -c "nslookup postgres.sm-api.svc.cluster.local; nslookup postgres-0.postgres.sm-api.svc.cluster.local"

kubectl logs dns-test --namespace sm-api
kubectl delete pod dns-test --namespace sm-api
```

**確認ポイント:**
- `postgres.sm-api.svc.cluster.local` → Pod の実IP が直接返ってくる（仮想IPではない）
- `postgres-0.postgres.sm-api.svc.cluster.local` → postgres-0 Pod の IP が返ってくる

### ClusterIP Service の仮想IP を確認する

```powershell
# sm-api Service の ClusterIP を確認
kubectl get service sm-api --namespace sm-api -o jsonpath="{.spec.clusterIP}"

# 同じく DNS で確認
kubectl run dns-test2 --image=busybox:1.36 --restart=Never --namespace sm-api `
  -- sh -c "nslookup sm-api.sm-api.svc.cluster.local"

kubectl logs dns-test2 --namespace sm-api
kubectl delete pod dns-test2 --namespace sm-api
```

**確認ポイント:**
- `sm-api.sm-api.svc.cluster.local` → ClusterIPの仮想IPが返ってくる（Headlessとの違い）

---

## 3. Service(LoadBalancer) と Ingress の違い

ここが最も混乱しやすいポイント。

### Service(LoadBalancer)

```
外部 ──→ クラウドLB ──→ Service(LoadBalancer) ──→ Pod群
```

- **Service 1つに対して外部IP が1つ**割り当てられる
- L4（TCP/UDP レベル）のルーティング
- ホスト名やパスでの振り分けはできない
- 10個のサービスを公開したら → 外部IP が10個、クラウドLBが10個作られてコスト大

```
外部IP-1 → Service-A（sm-api）
外部IP-2 → Service-B（admin）
外部IP-3 → Service-C（webhook）
```

### Ingress

```
外部 ──→ クラウドLB（1つ） ──→ Ingress Controller ──→ Ingress ルール ──→ Service-A
                                                                      └─→ Service-B
                                                                      └─→ Service-C
```

- **1つの外部IPで複数のサービスを振り分けられる**
- L7（HTTP レベル）のルーティング
- ホスト名・パスでの振り分けが可能

```
sm-api.local/        → sm-api Service
sm-api.local/admin   → admin Service
other.local/         → other Service
```

sm-api プロジェクトでの Ingress 定義:
```yaml
# k8s/07-ingress.yaml
spec:
  rules:
    - host: sm-api.local
      http:
        paths:
          - path: /
            backend:
              service:
                name: sm-api      # ClusterIP Service に転送
                port:
                  number: 8080
```

### 重要: Ingress 単体では動かない

```
Ingress リソース（ルール定義）
    ↑ 参照
Ingress Controller（実際にトラフィックを処理するPod）← これが必要
```

`kubectl apply -f ingress-nginx/deploy.yaml` でインストールしたのが Ingress Controller。Ingress リソースはルール定義だけで、実際に HTTP を受け取って振り分けるのは Controller の仕事。

### LoadBalancer vs Ingress の使い分け

| | LoadBalancer | Ingress |
|---|---|---|
| レイヤー | L4（TCP/UDP） | L7（HTTP/HTTPS） |
| 外部IP | サービスごとに1つ | 全サービスで1つ共有 |
| ホスト名振り分け | ❌ | ✅ |
| パス振り分け | ❌ | ✅ |
| TLS終端 | 設定による | ✅ 得意 |
| 費用（クラウド） | LBの数だけかかる | LB1つで済む |
| HTTPs以外のプロトコル | ✅（TCP/UDPも可） | ❌（HTTP/HTTPSのみ） |

**結論:**
- HTTP/HTTPS のウェブサービスを外部公開 → **Ingress**
- TCP/UDP が必要（DBやgRPC等）または HTTPs以外 → **LoadBalancer**

---

## 4. ハンズオン

### ① NodePort を試す

sm-api の Service を一時的に NodePort に変えてみる。

```powershell
# 現在の Service を確認
kubectl get service --namespace sm-api sm-api

# NodePort に変更（kubectl patch で一時変更）
kubectl patch service sm-api --namespace sm-api `
  -p '{"spec":{"type":"NodePort","ports":[{"port":8080,"targetPort":8080,"nodePort":30080}]}}'

# 変更確認
kubectl get service --namespace sm-api sm-api
# TYPE が NodePort、PORT が 8080:30080/TCP になることを確認
```

NodePort 経由でアクセスできることを確認する:

```powershell
# Kind の worker Node の IP を確認
kubectl get nodes -o wide

# Node の IP:30080 でアクセス（docker inspect で確認）
docker inspect sm-api-cluster-worker --format '{{.NetworkSettings.Networks.kind.IPAddress}}'

# 取得したIPでアクセス
curl.exe http://<NodeIP>:30080/health
```

元の ClusterIP に戻す:

```powershell
kubectl patch service sm-api --namespace sm-api `
  -p '{"spec":{"type":"ClusterIP","ports":[{"port":8080,"targetPort":8080}]}}'

kubectl get service --namespace sm-api sm-api
# TYPE が ClusterIP に戻っていることを確認
```

---

### ② LoadBalancer を試す（Kind での挙動確認）

```powershell
# LoadBalancer に変更
kubectl patch service sm-api --namespace sm-api `
  -p '{"spec":{"type":"LoadBalancer"}}'

# EXTERNAL-IP が <pending> のまま払い出されないことを確認
kubectl get service --namespace sm-api sm-api -w
# → EXTERNAL-IP が <pending> のまま変わらない（Kind はクラウドLBを持たないため）
```

```powershell
# ClusterIP に戻す
kubectl patch service sm-api --namespace sm-api `
  -p '{"spec":{"type":"ClusterIP","ports":[{"port":8080,"targetPort":8080}]}}'
```

---

### ③ Ingress のルーティングを確認する

現在の Ingress のルールを確認する:

```powershell
kubectl get ingress --namespace sm-api
kubectl describe ingress sm-api-ingress --namespace sm-api
```

新しいパスのルールを追加して動作を確認する。`k8s/07-ingress.yaml` に以下を追加してみる:

```yaml
paths:
  - path: /
    pathType: Prefix
    backend:
      service:
        name: sm-api
        port:
          number: 8080
  - path: /metrics    # 既存パス
    pathType: Prefix
    backend:
      service:
        name: sm-api
        port:
          number: 8080
```

```powershell
kubectl apply -f k8s/07-ingress.yaml
kubectl describe ingress sm-api-ingress --namespace sm-api
# Rules に複数パスが表示されることを確認
```

---

## 5. 確認チェックリスト

以下を自分の言葉で説明できれば理解できている。

**Service の種類:**
- [ ] ClusterIP は「クラスタ内部専用の仮想IP」を持つ。なぜ外部から到達できないか説明できる
- [ ] NodePort が「30000〜32767」の範囲のポートを使う理由を説明できる
- [ ] LoadBalancer が Kind 環境では `<pending>` になる理由を説明できる
- [ ] Headless Service の `clusterIP: None` が何を意味するか説明できる
- [ ] postgres が Headless を使っている理由を説明できる（StatefulSet との関係）

**LoadBalancer vs Ingress:**
- [ ] Ingress 単体ではトラフィックを受け取れない理由を説明できる（Controller が必要）
- [ ] 10個のHTTPサービスを公開するとき、LoadBalancer より Ingress が優れている理由を説明できる
- [ ] TCP のサービス（例: PostgreSQL）を外部公開したいとき Ingress が使えない理由を説明できる
- [ ] sm-api の構成（ClusterIP + Ingress）がなぜこの組み合わせなのかを説明できる
