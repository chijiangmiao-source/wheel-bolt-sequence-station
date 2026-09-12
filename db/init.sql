-- 轮毂复核工位：会话与不可变确认事件
-- 该脚本由 postgres 容器在空数据卷首次启动时执行（docker-entrypoint-initdb.d）。

CREATE TABLE sessions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- in_progress 进行中；completed 六步全部完成；cancelled 操作工带原因终止（拆下返修/装夹错误）
  status            TEXT NOT NULL DEFAULT 'in_progress'
                    CHECK (status IN ('in_progress', 'completed', 'cancelled')),
  -- 下一个期待的序号（从 1 开始）；六步全部确认后为 7，仅服务端可推进；
  -- 撤回上一步时在同一事务内回退到被撤回确认的序号（有效确认始终形成 1..k 的前缀）
  expected_sequence INTEGER NOT NULL DEFAULT 1
                    CHECK (expected_sequence BETWEEN 1 AND 7),
  -- 可选工单码：非空值全表唯一（NULL 互不冲突，历史无码会话无需补值）。
  -- 同一工单码的并发首次打开由该唯一约束兜底，只会绑定一个会话。
  work_order_code   TEXT,
  -- 轮毂规格：standard 标准型 / heavy 重载型；创建时确定，缺省标准型（历史会话同）
  wheel_spec        TEXT NOT NULL DEFAULT 'standard'
                    CONSTRAINT sessions_wheel_spec_check CHECK (wheel_spec IN ('standard', 'heavy')),
  -- 创建时固化的六步合格范围快照（cN·m，含边界），确认按快照校验；
  -- 默认值即标准型原 4200–4800 规则：历史会话迁移时由该默认值原地回填
  step_ranges       JSONB NOT NULL DEFAULT '[
    {"sequence":1,"position":"A1","min":4200,"max":4800},
    {"sequence":2,"position":"B2","min":4200,"max":4800},
    {"sequence":3,"position":"A3","min":4200,"max":4800},
    {"sequence":4,"position":"B1","min":4200,"max":4800},
    {"sequence":5,"position":"A2","min":4200,"max":4800},
    {"sequence":6,"position":"B3","min":4200,"max":4800}
  ]'::jsonb,
  -- 终止原因与终止时间：仅 status = 'cancelled' 时非空，长度 2–100 字
  cancel_reason     TEXT,
  cancelled_at      TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (
    (status = 'cancelled'
      AND char_length(cancel_reason) BETWEEN 2 AND 100
      AND cancelled_at IS NOT NULL)
    OR
    (status <> 'cancelled' AND cancel_reason IS NULL AND cancelled_at IS NULL)
  ),
  CONSTRAINT sessions_work_order_code_uniq UNIQUE (work_order_code)
);

CREATE TABLE confirmations (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  session_id      UUID NOT NULL REFERENCES sessions (id),
  sequence        INTEGER NOT NULL CHECK (sequence BETWEEN 1 AND 6),
  position        TEXT NOT NULL CHECK (position IN ('A1', 'B2', 'A3', 'B1', 'A2', 'B3')),
  -- 标准扭矩：换算后的整数 cN·m，既有顺序/范围/幂等判定与历史展示均以此为准。
  -- 行级 CHECK 为两种规格六步范围的包络（标准型 4200–4800、重载型 4600–5200），
  -- 逐步精确范围由应用层按会话快照校验
  torque          INTEGER NOT NULL CHECK (torque BETWEEN 4200 AND 5200),
  -- 原始读数与录入单位：操作工实际录入的值（N·m 保留至多两位小数），仅作记录；
  -- 统一存为普通十进制文本以保真（如 42.00），标准字段 torque 才用于业务判定
  torque_input    TEXT NOT NULL CHECK (torque_input ~ '^[0-9]+(\.[0-9]+)?$'),
  torque_unit     TEXT NOT NULL CHECK (torque_unit IN ('cN·m', 'N·m')),
  idempotency_key TEXT NOT NULL,
  confirmed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- 同一会话内：每个幂等键至多绑定一条确认（含已撤回的历史事件，键语义永不复用）
  UNIQUE (session_id, idempotency_key)
  -- 注意：不再对 (session_id, sequence) 做行内唯一约束——同一序号允许「撤回后重新确认」，
  -- 因而同一序号可能保留多条历史确认；任一时刻至多一条「有效」记录由下方触发器保证。
);

-- 撤回事件：对某条确认的不可变撤回记录。确认行本身不删除、不改写，
-- 是否有效完全由「是否存在对应撤回事件」决定；有效确认 = 无撤回事件的确认。
-- 允许同一序号在撤回后以新的确认事件重新落库（旧事件与撤回事件均保留为审计痕迹）。
CREATE TABLE confirmation_retractions (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  session_id      UUID NOT NULL REFERENCES sessions (id),
  confirmation_id BIGINT NOT NULL REFERENCES confirmations (id),
  -- 冗余保存被撤回确认的序号（与其所属确认一致），便于审计直接阅读
  sequence        INTEGER NOT NULL CHECK (sequence BETWEEN 1 AND 6),
  retracted_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- 每条确认事件至多被撤回一次：并发撤回由该唯一约束兜底，只可能成功一次
  CONSTRAINT confirmation_retractions_confirmation_uniq UNIQUE (confirmation_id)
);

-- 任一时刻同一会话的同一序号至多一条「有效」确认（无撤回事件）。
-- 撤回只新增撤回事件、不修改确认行，因此无法用行内 UNIQUE 表达，改由触发器约束：
-- 插入新确认时若同序号仍存在其他有效确认则拒绝（应用层在会话行锁内串行化，此为兜底）。
-- 检查以 FOR UPDATE 锁住竞争行：并发事务未提交时在此等待，其提交后 READ COMMITTED
-- 读到最新版本再判定，从而即使绕过应用直接写库也不会落出两条有效记录。
CREATE OR REPLACE FUNCTION confirmations_check_active_unique() RETURNS trigger AS $$
DECLARE
  v_other BIGINT;
BEGIN
  SELECT c.id INTO v_other
  FROM confirmations c
  WHERE c.session_id = NEW.session_id
    AND c.sequence = NEW.sequence
    AND c.id <> NEW.id
    AND NOT EXISTS (
      SELECT 1 FROM confirmation_retractions r
      WHERE r.confirmation_id = c.id
    )
  FOR UPDATE
  LIMIT 1;
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION '会话 % 的序号 % 已存在有效确认，禁止插入第二条有效记录',
      NEW.session_id, NEW.sequence
      USING ERRCODE = 'unique_violation';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER confirmations_active_unique
  AFTER INSERT ON confirmations
  FOR EACH ROW EXECUTE FUNCTION confirmations_check_active_unique();

-- 撤回事件一致性：session_id/sequence 必须与被撤回确认一致
CREATE OR REPLACE FUNCTION confirmation_retractions_check_consistency() RETURNS trigger AS $$
DECLARE
  v_session_id UUID;
  v_sequence  INTEGER;
BEGIN
  SELECT session_id, sequence INTO v_session_id, v_sequence
  FROM confirmations WHERE id = NEW.confirmation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '被撤回确认 % 不存在', NEW.confirmation_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_session_id <> NEW.session_id OR v_sequence <> NEW.sequence THEN
    RAISE EXCEPTION '撤回事件与会话序号不一致（确认属于会话 % 的序号 %）',
      v_session_id, v_sequence
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER confirmation_retractions_consistency
  BEFORE INSERT ON confirmation_retractions
  FOR EACH ROW EXECUTE FUNCTION confirmation_retractions_check_consistency();

-- 事件表不可变：数据库层拒绝任何 UPDATE / DELETE（确认与撤回事件均只增不改）
CREATE OR REPLACE FUNCTION events_immutable() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION '% 为不可变事件表，禁止 %', TG_TABLE_NAME, TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER confirmations_no_update
  BEFORE UPDATE ON confirmations
  FOR EACH ROW EXECUTE FUNCTION events_immutable();

CREATE TRIGGER confirmations_no_delete
  BEFORE DELETE ON confirmations
  FOR EACH ROW EXECUTE FUNCTION events_immutable();

CREATE TRIGGER confirmation_retractions_no_update
  BEFORE UPDATE ON confirmation_retractions
  FOR EACH ROW EXECUTE FUNCTION events_immutable();

CREATE TRIGGER confirmation_retractions_no_delete
  BEFORE DELETE ON confirmation_retractions
  FOR EACH ROW EXECUTE FUNCTION events_immutable();
