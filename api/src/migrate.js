import { DEFAULT_WHEEL_SPEC, stepRangesFor } from './constants.js';

// 标准型六步范围快照（原 4200–4800 规则）：作为列默认值回填历史会话
const STANDARD_SNAPSHOT_JSON = JSON.stringify(stepRangesFor(DEFAULT_WHEEL_SPEC));

/**
 * 幂等结构迁移：为历史数据库补齐轮毂规格与六步范围快照。
 *
 * - 全新部署由 db/init.sql 建成同构结构，以下语句均为 no-op；
 * - 旧数据卷升级时，ADD COLUMN ... NOT NULL DEFAULT 会把现存历史会话原地回填为
 *   标准型 + 原 4200–4800 cN·m 六步快照，即迁移后历史会话仍按原规则解释；
 * - confirmations.torque 的行级 CHECK 由 4200–4800 放宽为两规格包络 4200–5200
 *   （逐步精确范围始终由应用层按会话快照校验，行级 CHECK 仅作兜底）。
 */
export async function migrate(pool) {
  await pool.query(
    `ALTER TABLE sessions
       ADD COLUMN IF NOT EXISTS wheel_spec TEXT NOT NULL DEFAULT 'standard'`,
  );
  await pool.query(
    `ALTER TABLE sessions
       ADD COLUMN IF NOT EXISTS step_ranges JSONB NOT NULL DEFAULT '${STANDARD_SNAPSHOT_JSON}'::jsonb`,
  );
  // 规格取值约束：仅在新加列（或旧部署无此约束）时补上，避免重复建约束
  await pool.query(`
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'sessions_wheel_spec_check'
      ) THEN
        ALTER TABLE sessions
          ADD CONSTRAINT sessions_wheel_spec_check
          CHECK (wheel_spec IN ('standard', 'heavy'));
      END IF;
    END
    $$`);
  // 确认事件标准扭矩的兜底范围放宽到两种规格的包络（重载型 B 位可达 5200）
  await pool.query(
    'ALTER TABLE confirmations DROP CONSTRAINT IF EXISTS confirmations_torque_check',
  );
  await pool.query(
    `ALTER TABLE confirmations
       ADD CONSTRAINT confirmations_torque_check CHECK (torque BETWEEN 4200 AND 5200)`,
  );
}
