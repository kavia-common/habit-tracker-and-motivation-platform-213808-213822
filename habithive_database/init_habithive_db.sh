#!/bin/bash
set -euo pipefail

# HabitHive DB schema + minimal seed data
# This script is intentionally idempotent: safe to run multiple times.
#
# CRITICAL CONVENTION:
# - Always use db_connection.txt for the connection string (per container rules).

CONN_CMD_FILE="db_connection.txt"

if [ ! -f "${CONN_CMD_FILE}" ]; then
  echo "ERROR: ${CONN_CMD_FILE} not found. Run startup.sh first (it creates connection info)." >&2
  exit 1
fi

PSQL_CMD="$(cat "${CONN_CMD_FILE}")"

echo "Initializing HabitHive schema + seed data..."

exec_psql() {
  local sql="$1"
  # Use bash -lc to ensure the 'psql postgresql://...' command in db_connection.txt is executed properly.
  bash -lc "${PSQL_CMD} -v ON_ERROR_STOP=1 -c \"${sql}\""
}

# --- Extensions ---
exec_psql "CREATE EXTENSION IF NOT EXISTS pgcrypto"

# --- Core tables ---
exec_psql "CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT UNIQUE NOT NULL,
  password_hash TEXT,
  display_name TEXT NOT NULL,
  avatar_url TEXT,
  timezone TEXT NOT NULL DEFAULT 'UTC',
  is_verified BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
)"

exec_psql "CREATE TABLE IF NOT EXISTS refresh_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  user_agent TEXT,
  ip_address TEXT
)"
exec_psql "CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id ON refresh_tokens(user_id)"

exec_psql "CREATE TABLE IF NOT EXISTS habits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  color TEXT NOT NULL DEFAULT '#3b82f6',
  icon TEXT,
  is_archived BOOLEAN NOT NULL DEFAULT FALSE,
  target_value INTEGER NOT NULL DEFAULT 1,
  unit TEXT NOT NULL DEFAULT 'check',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
)"
exec_psql "CREATE INDEX IF NOT EXISTS idx_habits_user_id ON habits(user_id)"

exec_psql "CREATE TABLE IF NOT EXISTS habit_schedules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  habit_id UUID NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
  schedule_type TEXT NOT NULL CHECK (schedule_type IN ('daily','weekly','custom')),
  interval_days INTEGER NOT NULL DEFAULT 1,
  days_of_week SMALLINT[],
  start_date DATE NOT NULL DEFAULT CURRENT_DATE,
  end_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)"
exec_psql "CREATE INDEX IF NOT EXISTS idx_habit_schedules_habit_id ON habit_schedules(habit_id)"

exec_psql "CREATE TABLE IF NOT EXISTS habit_checkins (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  habit_id UUID NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  checkin_date DATE NOT NULL,
  value INTEGER NOT NULL DEFAULT 1,
  note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (habit_id, checkin_date)
)"
exec_psql "CREATE INDEX IF NOT EXISTS idx_habit_checkins_user_date ON habit_checkins(user_id, checkin_date)"

exec_psql "CREATE TABLE IF NOT EXISTS habit_streaks (
  habit_id UUID PRIMARY KEY REFERENCES habits(id) ON DELETE CASCADE,
  current_streak INTEGER NOT NULL DEFAULT 0,
  longest_streak INTEGER NOT NULL DEFAULT 0,
  last_checkin_date DATE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
)"

# --- Groups / social ---
exec_psql "CREATE TABLE IF NOT EXISTS groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  is_private BOOLEAN NOT NULL DEFAULT FALSE,
  invite_code TEXT UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)"

exec_psql "CREATE TABLE IF NOT EXISTS group_memberships (
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner','admin','member')),
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, user_id)
)"
exec_psql "CREATE INDEX IF NOT EXISTS idx_group_memberships_user_id ON group_memberships(user_id)"

exec_psql "CREATE TABLE IF NOT EXISTS group_posts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  post_type TEXT NOT NULL DEFAULT 'text' CHECK (post_type IN ('text','checkin','achievement')),
  content TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)"
exec_psql "CREATE INDEX IF NOT EXISTS idx_group_posts_group_created ON group_posts(group_id, created_at DESC)"

# --- Badges / achievements + rewards ---
exec_psql "CREATE TABLE IF NOT EXISTS badges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  icon TEXT,
  criteria JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)"

exec_psql "CREATE TABLE IF NOT EXISTS user_badges (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  badge_id UUID NOT NULL REFERENCES badges(id) ON DELETE CASCADE,
  awarded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  context JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (user_id, badge_id)
)"

exec_psql "CREATE TABLE IF NOT EXISTS rewards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  points_cost INTEGER NOT NULL DEFAULT 0,
  is_redeemed BOOLEAN NOT NULL DEFAULT FALSE,
  redeemed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)"
exec_psql "CREATE INDEX IF NOT EXISTS idx_rewards_user_id ON rewards(user_id)"

# -----------------------
# Minimal seed data
# -----------------------
exec_psql "INSERT INTO users (email, password_hash, display_name, is_verified)
VALUES ('demo@habithive.app', 'demo', 'Demo User', TRUE)
ON CONFLICT (email) DO UPDATE SET display_name = EXCLUDED.display_name, is_verified=EXCLUDED.is_verified"

exec_psql "INSERT INTO users (email, password_hash, display_name, is_verified)
VALUES ('alex@habithive.app', 'demo', 'Alex', TRUE)
ON CONFLICT (email) DO UPDATE SET display_name = EXCLUDED.display_name, is_verified=EXCLUDED.is_verified"

exec_psql "INSERT INTO habits (user_id, title, description, color, unit, target_value)
SELECT id, 'Drink Water', '8 glasses a day', '#06b6d4', 'glass', 8
FROM users WHERE email='demo@habithive.app'
ON CONFLICT DO NOTHING"

exec_psql "INSERT INTO habits (user_id, title, description, color, unit, target_value)
SELECT id, 'Read', 'Read 20 pages', '#3b82f6', 'pages', 20
FROM users WHERE email='demo@habithive.app'
ON CONFLICT DO NOTHING"

exec_psql "INSERT INTO habit_schedules (habit_id, schedule_type, interval_days, days_of_week)
SELECT id, 'daily', 1, NULL
FROM habits
WHERE title='Drink Water' AND user_id=(SELECT id FROM users WHERE email='demo@habithive.app')
ON CONFLICT DO NOTHING"

exec_psql "INSERT INTO habit_schedules (habit_id, schedule_type, interval_days, days_of_week)
SELECT id, 'weekly', 7, ARRAY[1,3,5]::smallint[]
FROM habits
WHERE title='Read' AND user_id=(SELECT id FROM users WHERE email='demo@habithive.app')
ON CONFLICT DO NOTHING"

# Seed 5 days of checkins for demo habits
exec_psql "INSERT INTO habit_checkins (habit_id, user_id, checkin_date, value, note)
SELECT h.id, h.user_id, CURRENT_DATE - i,
       CASE WHEN h.title='Drink Water' THEN 8 ELSE 20 END,
       'Seed check-in'
FROM habits h, generate_series(0,4) AS i
WHERE h.user_id=(SELECT id FROM users WHERE email='demo@habithive.app')
ON CONFLICT (habit_id, checkin_date) DO NOTHING"

# Seed streak state
exec_psql "INSERT INTO habit_streaks (habit_id, current_streak, longest_streak, last_checkin_date)
SELECT id, 5, 7, CURRENT_DATE
FROM habits
WHERE user_id=(SELECT id FROM users WHERE email='demo@habithive.app')
ON CONFLICT (habit_id) DO UPDATE SET
  current_streak=EXCLUDED.current_streak,
  longest_streak=GREATEST(habit_streaks.longest_streak, EXCLUDED.longest_streak),
  last_checkin_date=EXCLUDED.last_checkin_date,
  updated_at=now()"

# Group + memberships + a welcome post
exec_psql "INSERT INTO groups (name, description, owner_user_id, invite_code)
SELECT 'Retro Accountability', 'A friendly group to share streaks and cheer each other on.', id, 'RETRO123'
FROM users WHERE email='demo@habithive.app'
ON CONFLICT (invite_code) DO UPDATE SET description=EXCLUDED.description"

exec_psql "INSERT INTO group_memberships (group_id, user_id, role)
SELECT g.id, u.id, CASE WHEN u.email='demo@habithive.app' THEN 'owner' ELSE 'member' END
FROM groups g CROSS JOIN users u
WHERE g.invite_code='RETRO123'
  AND u.email IN ('demo@habithive.app','alex@habithive.app')
ON CONFLICT (group_id, user_id) DO UPDATE SET role=EXCLUDED.role"

exec_psql "INSERT INTO group_posts (group_id, user_id, post_type, content, metadata)
SELECT g.id, u.id, 'text',
       'Welcome to Retro Accountability! Share your streaks and celebrate small wins.',
       '{}'::jsonb
FROM groups g
JOIN users u ON u.email='demo@habithive.app'
WHERE g.invite_code='RETRO123'
ON CONFLICT DO NOTHING"

# Badges + award one
exec_psql "INSERT INTO badges (code, name, description, icon, criteria)
VALUES ('FIRST_CHECKIN','First Check-in','Completed your first habit check-in.','spark',
        jsonb_build_object('type','checkins','count',1))
ON CONFLICT (code) DO UPDATE SET
  name=EXCLUDED.name, description=EXCLUDED.description, icon=EXCLUDED.icon, criteria=EXCLUDED.criteria"

exec_psql "INSERT INTO badges (code, name, description, icon, criteria)
VALUES ('STREAK_7','7-Day Streak','Maintained a 7-day streak on any habit.','flame',
        jsonb_build_object('type','streak','days',7))
ON CONFLICT (code) DO UPDATE SET
  name=EXCLUDED.name, description=EXCLUDED.description, icon=EXCLUDED.icon, criteria=EXCLUDED.criteria"

exec_psql "INSERT INTO user_badges (user_id, badge_id, context)
SELECT u.id, b.id, jsonb_build_object('note','Seed award')
FROM users u
JOIN badges b ON b.code='FIRST_CHECKIN'
WHERE u.email='demo@habithive.app'
ON CONFLICT (user_id, badge_id) DO NOTHING"

# Rewards
exec_psql "INSERT INTO rewards (user_id, title, description, points_cost)
SELECT id, 'Coffee Break', 'Redeem for a guilt-free coffee break.', 50
FROM users WHERE email='demo@habithive.app'
ON CONFLICT DO NOTHING"

echo "✓ HabitHive schema + seed complete."
