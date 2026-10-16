# ---- ビルドステージ ----
FROM golang:1.21-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./

# go.sum の不整合を修正（ここで tidy）
RUN go mod tidy

# go.mod に lib/pq を追加する
RUN go get github.com/lib/pq

RUN go mod download

COPY migrate/ ./migrate/
ENV CGO_ENABLED=0 GOOS=linux
# バイナリ名を migrator にしてディレクトリ名との衝突を回避
RUN go build -o /app/migrator ./migrate/

# ---- 実行ステージ ----
FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app

# バイナリをコピー
COPY --from=builder /app/migrator ./migrator
# SQLマイグレーションファイルを同梱
COPY migrate/migrations/ ./migrations/

CMD ["./migrator"]
