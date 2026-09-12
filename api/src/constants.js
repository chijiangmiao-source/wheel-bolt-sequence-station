// 复核顺序固定：每个新会话都按此顺序复核六颗螺栓
export const POSITIONS = Object.freeze(['A1', 'B2', 'A3', 'B1', 'A2', 'B3']);
export const TOTAL_STEPS = POSITIONS.length;

// 合格扭矩范围（含边界），单位 cN·m：标准型（历史规则）全位置一致
export const TORQUE_MIN = 4200;
export const TORQUE_MAX = 4800;

// 轮毂规格：标准型沿用历史范围；重载型 A/B 位合格范围不同
export const WHEEL_SPEC_STANDARD = 'standard';
export const WHEEL_SPEC_HEAVY = 'heavy';
export const WHEEL_SPECS = Object.freeze([WHEEL_SPEC_STANDARD, WHEEL_SPEC_HEAVY]);
export const DEFAULT_WHEEL_SPEC = WHEEL_SPEC_STANDARD;

// 重载型按位（A/B）的合格范围（cN·m，含边界）
const HEAVY_RANGES_BY_AXLE = Object.freeze({
  A: Object.freeze({ min: 4600, max: 5000 }),
  B: Object.freeze({ min: 4800, max: 5200 }),
});

/**
 * 某规格六步的合格范围快照（创建会话时固化并随会话持久化，确认按快照校验）。
 * 标准型六步同为 4200–4800（历史规则）；重载型 A 位 4600–5000、B 位 4800–5200。
 * @returns {Array<{sequence:number, position:string, min:number, max:number}>}
 */
export function stepRangesFor(spec) {
  return POSITIONS.map((position, index) => {
    const range =
      spec === WHEEL_SPEC_HEAVY
        ? HEAVY_RANGES_BY_AXLE[position.charAt(0)]
        : { min: TORQUE_MIN, max: TORQUE_MAX };
    return { sequence: index + 1, position, min: range.min, max: range.max };
  });
}

export const IDEMPOTENCY_KEY_MAX_LENGTH = 128;

// 终止复核原因长度（按字符计），2–100 字
export const CANCEL_REASON_MIN_LENGTH = 2;
export const CANCEL_REASON_MAX_LENGTH = 100;

// 工单码长度（去除首尾空白后计），扫码/手输共用
export const WORK_ORDER_CODE_MIN_LENGTH = 1;
export const WORK_ORDER_CODE_MAX_LENGTH = 64;
