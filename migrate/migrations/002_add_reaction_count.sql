-- マイグレーション 002: リアクション数カラムを追加
ALTER TABLE slack_metrics
    ADD COLUMN IF NOT EXISTS reaction_count INTEGER NOT NULL DEFAULT 0;
