-- マイグレーション 001: slack_metrics テーブル作成
CREATE TABLE IF NOT EXISTS slack_metrics (
    id           SERIAL PRIMARY KEY,
    channel      VARCHAR(255) NOT NULL,
    msg_count    INTEGER      NOT NULL DEFAULT 0,
    active_users INTEGER      NOT NULL DEFAULT 0,
    recorded_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_slack_metrics_channel ON slack_metrics (channel);
CREATE INDEX IF NOT EXISTS idx_slack_metrics_recorded_at ON slack_metrics (recorded_at DESC);

-- マイグレーション管理テーブル（冪等性のために使用）
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     VARCHAR(255) PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
