package db

import (
	"database/sql"
	"fmt"
	"log"
	"os"

	_ "github.com/lib/pq"
)

// Connect は環境変数からPostgreSQLへの接続を返す
func Connect() *sql.DB {
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
