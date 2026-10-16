# ---- ビルドステージ ----
FROM golang:1.21-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./

# go.sum の不整合を修正（ここで tidy）
RUN go mod tidy

# go.mod に lib/pq を追加する
RUN go get github.com/lib/pq

RUN go mod download

COPY batch/ ./batch/
ENV CGO_ENABLED=0 GOOS=linux
RUN go build -o /app/batch-bin ./batch/

# ---- 実行ステージ ----
FROM gcr.io/distroless/static-debian12

COPY --from=builder /app/batch-bin /batch-bin

CMD ["/batch-bin"]
