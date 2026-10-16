package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

	_ "github.com/lib/pq"
)

func main() {
	conn := connectDB()
	defer conn.Close()

	// schema_migrations テーブルを初期化（初回のみ作成）
	if _, err := conn.Exec(`
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version    VARCHAR(255) PRIMARY KEY,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)
	`); err != nil {
		log.Fatalf("schema_migrations テーブル作成失敗: %v", err)
	}

	// 適用済みバージョン一覧を取得
	applied, err := appliedVersions(conn)
	if err != nil {
		log.Fatalf("適用済みバージョン取得失敗: %v", err)
	}

	// migrations/ ディレクトリから .sql ファイルをソートして取得
	files, err := filepath.Glob("migrations/*.sql")
	if err != nil || len(files) == 0 {
		log.Fatal("マイグレーションファイルが見つかりません: migrations/*.sql")
	}
	sort.Strings(files)

	// 未適用のマイグレーションを順番に実行
	count := 0
	for _, f := range files {
		version := filepath.Base(f)
		version = strings.TrimSuffix(version, ".sql")

		if applied[version] {
			log.Printf("スキップ (適用済み): %s", version)
			continue
		}

		log.Printf("適用開始: %s", version)
		if err := applyMigration(conn, f, version); err != nil {
			log.Fatalf("マイグレーション失敗 [%s]: %v", version, err)
		}
		log.Printf("適用完了: %s", version)
		count++
	}

	log.Printf("マイグレーション完了: %d 件適用", count)
}

func applyMigration(conn *sql.DB, filePath, version string) error {
	content, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("ファイル読み込み失敗: %w", err)
	}

	// トランザクション内で実行して原子性を担保
	tx, err := conn.Begin()
	if err != nil {
		return fmt.Errorf("トランザクション開始失敗: %w", err)
	}

	if _, err := tx.Exec(string(content)); err != nil {
		tx.Rollback()
		return fmt.Errorf("SQL実行失敗: %w", err)
	}

	if _, err := tx.Exec(
		`INSERT INTO schema_migrations (version) VALUES ($1)`, version,
	); err != nil {
		tx.Rollback()
		return fmt.Errorf("バージョン記録失敗: %w", err)
	}

	return tx.Commit()
}

func appliedVersions(conn *sql.DB) (map[string]bool, error) {
	rows, err := conn.Query(`SELECT version FROM schema_migrations`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	applied := map[string]bool{}
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		applied[v] = true
	}
	return applied, nil
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
