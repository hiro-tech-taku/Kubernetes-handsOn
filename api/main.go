package main

import (
	"log"
	"net/http"
	"os"

	"github.com/sm-api/api/db"
	"github.com/sm-api/api/handler"
)

func main() {
	// DB接続
	conn := db.Connect()
	defer conn.Close()

	h := &handler.MetricsHandler{DB: conn}

	mux := http.NewServeMux()

	// ヘルスチェック
	mux.HandleFunc("/health", handler.HealthCheck)

	// メトリクスAPI
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			h.GetMetrics(w, r)
		case http.MethodPost:
			h.PostMetric(w, r)
		default:
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		}
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("slack-metrics API 起動: port=%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}
