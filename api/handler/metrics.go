package handler

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"time"
)

// Metric はSlackメトリクスのデータ構造
type Metric struct {
	ID        int       `json:"id"`
	Channel   string    `json:"channel"`
	MsgCount  int       `json:"msg_count"`
	ActiveUsers int     `json:"active_users"`
	RecordedAt time.Time `json:"recorded_at"`
}

// MetricsHandler はメトリクスのCRUDを担当するハンドラー
type MetricsHandler struct {
	DB *sql.DB
}

// GetMetrics は全メトリクスを返す
func (h *MetricsHandler) GetMetrics(w http.ResponseWriter, r *http.Request) {
	rows, err := h.DB.QueryContext(r.Context(),
		`SELECT id, channel, msg_count, active_users, recorded_at
		 FROM slack_metrics
		 ORDER BY recorded_at DESC
		 LIMIT 100`)
	if err != nil {
		log.Printf("メトリクス取得エラー: %v", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	metrics := []Metric{}
	for rows.Next() {
		var m Metric
		if err := rows.Scan(&m.ID, &m.Channel, &m.MsgCount, &m.ActiveUsers, &m.RecordedAt); err != nil {
			log.Printf("スキャンエラー: %v", err)
			continue
		}
		metrics = append(metrics, m)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(metrics)
}

// PostMetric は新しいメトリクスを登録する
func (h *MetricsHandler) PostMetric(w http.ResponseWriter, r *http.Request) {
	var m Metric
	if err := json.NewDecoder(r.Body).Decode(&m); err != nil {
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return
	}

	err := h.DB.QueryRowContext(r.Context(),
		`INSERT INTO slack_metrics (channel, msg_count, active_users, recorded_at)
		 VALUES ($1, $2, $3, NOW())
		 RETURNING id, recorded_at`,
		m.Channel, m.MsgCount, m.ActiveUsers,
	).Scan(&m.ID, &m.RecordedAt)
	if err != nil {
		log.Printf("メトリクス登録エラー: %v", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(m)
}

// HealthCheck はヘルスチェックエンドポイント
func HealthCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}
