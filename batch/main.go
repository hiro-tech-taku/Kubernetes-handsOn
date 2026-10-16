package main

import (
	"database/sql"
	"fmt"
	"log"
	"math/rand"
	"os"
	"time"

	_ "github.com/lib/pq"
)

// channels はサンプルのSlackチャンネル一覧
var channels = []string{
	"general", "random", "dev", "ops", "design", "marketing",
}

func main() {
	log.Println("バッチ処理開始: Slackメトリクス集計")

	conn := connectDB()
	defer conn.Close()

	// 各チャンネルのメトリクスをDBに書き込む
	// 実際のシステムではSlack APIからデータを取得する
	now := time.Now()
	r := rand.New(rand.NewSource(now.UnixNano()))

	inserted := 0
	for _, ch := range channels {
		msgCount := r.Intn(500) + 1
		activeUsers := r.Intn(50) + 1
		reactionCount := r.Intn(200)

		_, err := conn.Exec(`
			INSERT INTO slack_metrics (channel, msg_count, active_users, reaction_count, recorded_at)
			VALUES ($1, $2, $3, $4, $5)
		`, ch, msgCount, activeUsers, reactionCount, now)

		if err != nil {
			log.Printf("チャンネル[%s]のメトリクス書き込みエラー: %v", ch, err)
			continue
		}
		log.Printf("書き込み完了: channel=%s msg_count=%d active_users=%d reaction_count=%d",
			ch, msgCount, activeUsers, reactionCount)
		inserted++
	}

	// 古いデータの集計サマリーをログ出力（DBから読み取り）
	printSummary(conn)

	// 90日以上前の古いデータを削除（クリーンアップ）
	deleted, err := cleanup(conn)
	if err != nil {
		log.Printf("クリーンアップエラー: %v", err)
	} else {
		log.Printf("クリーンアップ完了: %d件削除", deleted)
	}

	log.Printf("バッチ処理完了: %d/%d チャンネル処理", inserted, len(channels))
}

func printSummary(conn *sql.DB) {
	rows, err := conn.Query(`
		SELECT channel, SUM(msg_count) as total_msgs, AVG(active_users) as avg_users
		FROM slack_metrics
		WHERE recorded_at >= NOW() - INTERVAL '7 days'
		GROUP BY channel
		ORDER BY total_msgs DESC
	`)
	if err != nil {
		log.Printf("サマリー取得エラー: %v", err)
		return
	}
	defer rows.Close()

	log.Println("=== 直近7日間チャンネルサマリー ===")
	for rows.Next() {
		var channel string
		var totalMsgs int
		var avgUsers float64
		if err := rows.Scan(&channel, &totalMsgs, &avgUsers); err != nil {
			continue
		}
		log.Printf("  channel=%-15s total_msgs=%5d avg_active_users=%.1f", channel, totalMsgs, avgUsers)
	}
}

func cleanup(conn *sql.DB) (int64, error) {
	result, err := conn.Exec(`
		DELETE FROM slack_metrics
		WHERE recorded_at < NOW() - INTERVAL '90 days'
	`)
	if err != nil {
		return 0, fmt.Errorf("削除クエリ失敗: %w", err)
	}
	return result.RowsAffected()
}

func connectDB() *sql.DB {
	host := getEnv("DB_HOST", "localhost")
	port := getEnv("DB_PORT", "5432")
	user := getEnv("DB_USER", "appuser")
	password := getEnv("DB_PASSWORD", "apppassword")
	dbname := getEnv("DB_NAME", "appdb")

	dsn := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		host, port, user, password, dbname,
	)

	conn, err := sql.Open("postgres", dsn)
	if err != nil {
		log.Fatalf("DB接続失敗: %v", err)
	}
	if err := conn.Ping(); err != nil {
		log.Fatalf("DBへのPing失敗: %v", err)
	}
	log.Printf("DB接続成功: host=%s dbname=%s", host, dbname)
	return conn
}

func getEnv(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}
