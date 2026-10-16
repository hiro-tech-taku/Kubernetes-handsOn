# ---- ビルドステージ ----
FROM golang:1.21-alpine AS builder

WORKDIR /app

# 依存関係を先にコピーしてキャッシュを活用
COPY go.mod go.sum ./

# go.sum の不整合を修正（ここで tidy）
RUN go mod tidy

# go.mod に lib/pq を追加する
RUN go get github.com/lib/pq

# 依存関係をダウンロード
RUN go mod download

# ソースコードをコピーしてビルド
COPY api/ ./api/
ENV CGO_ENABLED=0 GOOS=linux
RUN go build -o /app/server ./api/

# ---- 実行ステージ ----
FROM gcr.io/distroless/static-debian12

COPY --from=builder /app/server /server

EXPOSE 8080

CMD ["/server"]
