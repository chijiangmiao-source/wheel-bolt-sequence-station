# 轮毂复核工位（hub-review）

触屏工位 + API 的真实联调项目：操作工按固定顺序 **A1 → B2 → A3 → B1 → A2 → B3** 逐颗复核轮毂的六颗螺栓，服务端以 PostgreSQL 持久化会话与**不可变确认事件**，只有在六次有效确认全部落库后才判定「轮毂复核完成」。

现场承接**标准型**与**重载型**两种轮毂：复核顺序相同，但各位置合格扭矩不同（标准型各位置 4200–4800 cN·m；重载型 A 位 4600–5000、B 位 4800–5200 cN·m）。操作工先选规格再开始六步复核；会话创建时把六步范围**固化为快照**随会话持久化，确认校验、页面展示与进度查询均以快照为准。

针对现场两类典型故障做了明确的协议设计：

- **触屏重试 / 网络重试导致同一颗螺栓被记两次** → 幂等键去重：同一幂等键 + 完全相同载荷的重试返回**原确认**，不产生第二条记录；
- **迟到的旧响应错误推进下一步** → 序号守卫：小于当前期待序号的按**迟到**拒绝，大于的按**越序**拒绝，任何失败都不推进进度。

## 目录结构

```
├── docker-compose.yml   # db / api / web / verify 四个服务
├── db/init.sql          # 建表 + 唯一约束 + 不可变触发器（postgres 首次启动执行）
├── api/                 # Express API：会话与确认事件（Node 20）
├── web/                 # 工位页面（nginx 托管静态页，/api 反向代理到 api）
└── verify/              # 一次性验收服务：协议用例 + 真实浏览器（Playwright/Chromium）操作用例
```

## 运行

```bash
docker compose up --build -d db api web
# 工位页面：http://localhost:${WEB_PORT:-8080}
# API：     http://localhost:${API_PORT:-3000}
```

宿主端口由环境变量覆盖（见 `.env.example`）：

```bash
WEB_PORT=9000 API_PORT=9001 docker compose up --build -d db api web
```

## 一次性验收（verify）

`verify` 是一次性服务：等待 api/web 健康后跑完全部用例并退出，退出码即验收结果。

```bash
# 方式一：起全栈并跟随 verify 的退出码（验收结束自动停掉全部容器）
docker compose up --build --exit-code-from verify

# 方式二：应用已在跑，单独执行验收
docker compose up --build -d db api web
docker compose run --rm verify
```

验收覆盖：

- **协议用例**（直连 API）：固定顺序、边界扭矩和幂等冲突；N·m 精确换算、精度与越界拒绝、跨单位幂等重放及旧格式客户端；工单码首次与重复打开、跨终端续作、并发首次打开和非法码；带原因终止、终止后拒绝、重复终止、完成态保护及最后一步与终止并发；迟到、越序、位置、扭矩、未知会话与缺字段拒绝、并发去重和数据库事件不可变；撤回上一步（撤回第二步以新扭矩重做后完成、刷新后只有重做记录且保留审计、重复撤回与无可撤回拒绝、完成态/终止态保护、两个撤回竞争只成功一次、撤回与确认并发、撤回事件不可变）；轮毂规格（重载型按 A/B 差异范围完成六步、4800 在相邻 A/B 步均可接受、4799 在 B 位与 4599 在 A 位被拒绝并停留原步骤、未知规格 400、未传规格默认标准型并按原 4200–4800 完成、查询返回规格/完整范围/当前范围且刷新后不变、工单码打开携带规格、历史会话迁移回填后按原规则解释）；
- **页面用例**（真实 Chromium 驱动页面）：六步完成、异常扭矩、刷新恢复、网络重试、慢响应连点和完成态刷新；N·m 边界读数、越界与精度拒绝及历史 cN·m 展示；新工单、另一浏览器接续、并发首次打开、非法码及无码旧流程；完成两步后终止、展示并持久化原因与时间、关闭扭矩提交；二次确认撤回第二步并以新扭矩重做完成、刷新后只显示重做记录且保留撤回审计、并发先撤回时页面收到明确原因并保留当前输入；先选重载型规格再复核、逐步展示当前范围、4800 在 A/B 步均可接受、4799 在 B 位被页面拒绝并停留、刷新后规格与当前范围不变、重载型工单跨终端接续同一规格。

## API 协议

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/sessions` | 开始新会话（固定顺序 A1→B2→A3→B1→A2→B3），返回 `201` 与初始进度；可选请求体 `{ "wheel_spec": "standard" \| "heavy" }`，未传或空请求体仍创建标准型会话（旧客户端协议，继续可用） |
| POST | `/api/work-orders/{code}/session` | **按工单码打开复核**：同一事务内返回已绑定会话（`200`），尚未绑定时才创建（`201`）；可选请求体 `{ "wheel_spec" }` 仅在首次创建时生效 |
| GET | `/api/sessions/{id}` | 读取权威进度（页面刷新后以此为准），返回规格、完整六步范围与当前范围 |
| POST | `/api/sessions/{id}/confirmations` | 提交一次复核确认（按会话快照校验当前步骤范围） |
| POST | `/api/sessions/{id}/confirmations/last/retract` | **撤回上一步**：为当前最后一条有效确认追加不可变撤回事件并回到该颗，随后可重新确认 |
| POST | `/api/sessions/{id}/cancel` | 带原因终止复核（拆下返修/装夹错误），幂等可重放 |
| GET | `/healthz` | 健康检查 |

### 轮毂规格与逐步合格范围

- 创建会话时可提交 `wheel_spec`：`standard`（标准型）或 `heavy`（重载型）；**未传仍创建标准型会话**，空请求体创建语义不变。未知规格返回 `400 unknown_wheel_spec`（中文原因可直接展示），不创建会话；
- 六步合格范围（cN·m，含边界）在**创建时固化为快照**随会话持久化，确认校验只认快照：
  - 标准型：六个位置均 **4200–4800**（即历史规则，历史会话迁移后同样按此解释）；
  - 重载型：**A 位（A1/A3/A2）4600–5000**、**B 位（B2/B1/B3）4800–5200**——因此 4800 在相邻 A、B 步均可接受，而 4799 在 B 位、4599 在 A 位会被拒绝；
- 会话视图（创建/查询/工单打开的响应）携带：
  - `wheel_spec`：规格代号；
  - `step_ranges`：完整六步范围快照 `[{ sequence, position, min, max }]`；
  - `current_range`：当前期待步骤的范围（进行中），会话完成/终止后为 `null`；确认、终止、撤回响应的 `progress` 中同样携带；
  - 既有 `torque_range` 字段保留，为全部步骤范围的包络（标准型即原 4200–4800），旧客户端字段解析不受影响；
- 不符合当前位置范围的读数返回 `422 torque_out_of_range`，原因中给出当前步骤与范围（如「超出第 2 步（B2）合格范围 4800–5200 cN·m」），**不写确认事件、停留原步骤**；
- 页面进入区先选规格再开始复核（工单码打开同样在首次创建时按所选规格固化）；复核中逐步展示当前合格范围，刷新后规格与当前范围从服务端恢复、保持不变。

### 工单码绑定（换班 / 换触屏 / 清理浏览器后接续）

- 操作工在进入区输入或扫码工单码后调用「打开复核」`POST /api/work-orders/{code}/session`；
- 接口对工单码**去除首尾空白**后校验（非空、≤64 字符）并保存，非法码返回 `400 invalid_work_order_code`（中文原因可直接展示）；
- 已绑定该码的会话在**同一事务**中连同其确认记录一起返回（`200`）；尚未绑定时才创建新会话并绑定（`201`，从第一颗 A1 开始）；
- 数据库对非空工单码建立唯一约束，两个终端并发首次打开同一码：一个请求 `201`，其余在唯一约束冲突后改读已建会话返回 `200`，**只产生一个会话**；
- 页面刷新或在另一台触屏输入同一码，均读取服务端权威进度接续复核；查询或创建暂时失败时页面不覆盖本地已有会话；
- 历史会话无工单码（`work_order_code` 为 `NULL`，NULL 之间互不冲突），**无需补值**。

确认请求体：

```json
{
  "session_id": "会话编号（须与路径一致）",
  "sequence": 1,
  "position": "A1",
  "torque": 4500,
  "unit": "cN·m",
  "idempotency_key": "客户端为本次提交意图生成的唯一键"
}
```

- `sequence`：从 1 开始的整数序号；`position`：位置码；`idempotency_key`：1–128 字符。
- `torque`：读数。配合 `unit` 使用，支持 JSON 数字或十进制文本字符串（如 `"42.00"`，页面按录入原文发送以保真）：
  - `unit` 为 `"cN·m"` 或**不传**（旧格式客户端）：整数 cN·m，合格范围 **4200–4800 含边界**；
  - `unit` 为 `"N·m"`：数显扳手读数，**最多两位小数**，服务端先精确换算（×100，BigInt 十进制，不走浮点）为整数 cN·m，合格范围 **42.00–48.00 含边界**。
- 成功：`201` `{ replayed: false, confirmation, progress }`；重放：`200` `{ replayed: true, confirmation, progress }`。
- 失败：`{ error: { code, message }, progress }`，`message` 为可直接展示的中文原因，`progress` 为当前权威进度。
- `confirmation` 同时返回标准字段 `torque`（整数 cN·m，进度与完成明细使用）与原始读数 `torque_input`、`torque_unit`（仅作记录；历史明细仍按 cN·m 展示）。

### 录入单位与换算失败

现场部分数显扭矩扳手只显示 N·m，操作工无需心算：

- 工位默认单位保持 **cN·m**，可在页面切换为 **N·m**（最多两位小数），提交仍走同一个确认入口；
- 服务端先精确换算再执行既有的顺序、范围与幂等判定，因此 **45 N·m 与 4500 cN·m 是同一标准载荷**，同一幂等键跨单位重试只返回原确认；
- 换算失败时页面展示中文原因并停留在当前螺栓，失败请求不写事件、不推进序号：
  - 超过两位小数（无法精确换算为整数 cN·m，尾随零也占一位，如 45.000 与 45.123 同样拒绝）→ `422 torque_precision_exceeded`；
  - 数值过大无法精确换算 → `422 torque_unconvertible`；
  - 换算后越界（如 41.99 N·m = 4199 cN·m）→ `422 torque_out_of_range`，原因中同时给出原始读数与换算值。
- 空请求体创建会话、以及不传 `unit` 的旧格式确认请求，均保持原语义。

### 重试语义（核心）

服务端对 `POST /confirmations` 按以下顺序判定，**任何失败都不推进进度、不消耗幂等键**：

1. **幂等键优先**（键已落库时）：
   - 载荷（序号/位置/扭矩）完全相同 → `200` 返回**原确认事件**（`replayed: true`），不重复记录；
   - 载荷不同 → `409 idempotency_conflict`，返回已存在的确认，未推进。
2. **序号守卫**（键未见过时）：
   - `sequence < 当前期待序号` → `409 late_sequence`（迟到响应，拒绝）；
   - `sequence > 当前期待序号` → `409 out_of_order_sequence`（越序，拒绝）。
3. **位置校验**：位置码与当前期待步骤不符 → `422 position_mismatch`。
4. **扭矩校验**：服务端先按 `unit` 把读数精确换算为整数 cN·m（缺省单位按 cN·m），再按**会话快照中当前步骤的范围**判定（标准型 4200–4800、重载型 A 位 4600–5000 / B 位 4800–5200，含边界）→ `422 torque_out_of_range`；N·m 超过两位小数 → `422 torque_precision_exceeded`；无法精确换算 → `422 torque_unconvertible`；非整数 cN·m、非法单位等非法请求体 → `400 invalid_body`；未知会话 → `404 session_not_found`。

并发与一致性：同一会话的提交在事务内以 `SELECT ... FOR UPDATE` 行锁串行化；`(session_id, idempotency_key)` 唯一约束与「每序号至多一条有效确认」触发器兜底，因此并发重试/触屏连点最多落库一条确认。确认事件表与撤回事件表均由触发器禁止 `UPDATE/DELETE`，是只增不改的事件日志。

### 终止复核（POST /cancel）

轮毂拆下返修或装夹错误时，操作工可在未完成页面点击「终止复核」，填写 **2–100 字**原因后确认：

- 请求体：`{ "reason": "轮毂拆下返修" }`；成功：`200 { cancelled: true, replayed: false, progress }`，`progress.status = 'cancelled'` 并携带 `cancel_reason`、`cancelled_at`、`confirmed_count`，`expected_sequence/expected_position` 为 `null`；
- **已完成会话不可终止**：`409 session_completed`，返回完成态 `progress`；
- **重复终止幂等**：已终止会话再次终止返回现有结果 `200 { cancelled: true, replayed: true, progress }`，原因与终止时间不被覆盖；
- 原因缺失/非字符串/长度越界：`400 invalid_body`；未知会话：`404 session_not_found`。

终止与确认并发：两者都在**会话行锁事务**内执行，先取得锁者生效，后到者在同一把锁上读到最新权威状态——确认先到则会话完成、终止收到 `409 session_completed`；终止先到则最后一步确认收到 `409 session_cancelled`。因此一个会话只会形成**一个终态**，确认事件始终只增不改（终止不删除、不改写任何事件）。

已终止会话的任何确认提交（包括旧客户端在途的自动重试）一律返回 `409 session_cancelled` 与最新权威 `progress`，**不写事件、不推进、不消耗幂等键**；该判定在幂等键查询之前。

`GET /api/sessions/{id}` 在已终止会话上额外返回 `cancel_reason`、`cancelled_at`；其余字段与原格式一致，旧客户端的创建、查询、确认请求不受影响。

### 撤回上一步（POST /confirmations/last/retract）

操作工提交后发现刚录入的扭矩抄错时，可撤回**当前最后一条有效确认**，不用废弃整轮复核：

- 页面仅在会话进行中、至少有一条有效确认且尚未完成时显示「撤回上一步」，二次确认后调用本接口，空请求体即可；页面可附带 `{ "confirmation_id": 123 }` 做乐观并发校验；
- 成功：`200 { retracted: true, replayed: false, retraction, progress }`，`progress.expected_sequence` 回退到被撤回那一步（如两步后撤回第二步回到序号 2 / B2），随后**仍从原确认入口** `POST /confirmations` 以**新幂等键**提交新读数；
- 失败均随错误返回最新权威 `progress`：没有有效确认 → `409 no_active_confirmation`；会话已完成 → `409 session_completed`；目标已被另一请求先撤回 → `409 confirmation_already_retracted`；页面携带的目标已不是当前最后一条 → `409 retract_target_changed`；会话已终止 → `409 session_cancelled`；未知会话 → `404 session_not_found`；`confirmation_id` 非正整数 → `400 invalid_body`；
- 失败时页面展示原因、保持最新权威进度且**不清除当前输入**，操作工修正后可立即重新提交；
- 被撤回确认的旧幂等键不可再用：携带旧键的迟到重试得到 `409 confirmation_retracted`，不重放已失效读数；**重新确认必须生成新键**（页面在撤回后从原确认入口正常提交即可，键由页面按新提交意图生成）；
- 撤回与确认/终止一样在**会话行锁事务**内执行，同一会话的撤回、确认、终止共用同一把行锁串行化；两个并发撤回只可能成功一次，另一个拿到回退后进度与 `confirmation_already_retracted`；
- 撤回与确认并发：先取得行锁者生效——撤回先到则越序的后到确认按 `out_of_order_sequence` 拒绝；确认先到则陈旧撤回收 `retract_target_changed`，有效确认与期待序号始终一致。

`retraction` 与会话视图中的 `retractions` 审计数组结构：

```json
{
  "id": 1,
  "confirmation_id": 7,
  "sequence": 2,
  "retracted_at": "2026-09-12T08:00:00.000Z",
  "confirmation": {
    "id": 7, "sequence": 2, "position": "B2", "torque": 4600,
    "torque_input": "4600", "torque_unit": "cN·m",
    "idempotency_key": "…", "confirmed_at": "2026-09-12T07:59:00.000Z"
  }
}
```

- `confirmations` 只包含**未撤回（有效）**记录——刷新后只显示重做后的有效记录；被撤回的原读数只出现在 `retractions` 审计数组中，按撤回顺序返回；新会话的创建响应中 `retractions` 为空数组，旧客户端忽略多余字段即可；
- **事件不可变规则继续成立**：撤回只向 `confirmation_retractions` 追加事件，确认行本身不删除、不改写（UPDATE/DELETE 触发器仍然生效）；同一序号允许「撤回 → 重新确认」，因此 `confirmations` 表可能为同一序号保留多条历史记录，但触发器保证**任一时刻每个序号至多一条有效记录**；`(session_id, idempotency_key)` 唯一约束仍然成立，旧键语义不复用。

页面侧约定：

- 进入区以工单码「打开复核」为主入口（也可开始无码新会话）；本地保存会话编号与工单码，刷新或重启页面时优先按工单码向服务端打开权威会话；
- 每次「用户提交意图」生成一个幂等键；**网络异常（超时/断连）的自动重试复用同一键**（指数退避，最多 6 次），因此重试永远不会把同一颗螺栓记两次；
- 收到确定性拒绝（4xx）不重试，展示拒绝原因并重新拉取权威进度对齐页面；
- 提交在途时禁用提交按钮，避免触屏连点产生并发提交；
- 刷新页面后重新 `GET` 权威进度；「轮毂复核完成」只在服务端状态为 `completed`（即六次有效确认全部落库）时显示，否则稳定停留在当前螺栓。
- 「终止复核」仅在进行中会话可用：填写 2–100 字原因并确认后，页面展示终止时间与原因并关闭扭矩提交；刷新后从服务端恢复已终止态；旧页面不调用 `/cancel` 也不受任何影响。
- 「撤回上一步」仅在进行中会话且已有有效确认时出现：二次确认面板明示将撤回的螺栓与读数，确认后以服务端返回的权威进度回到上一颗，**不清除扭矩输入框内容**，操作工可立即从原确认入口重新提交；失败（无可撤回记录、已完成、并发落败）时展示中文原因、对齐权威进度并保留输入；页面始终展示撤回审计表（被撤回的原读数与撤回时间），刷新后仍在。

## 数据模型

- `sessions(id, status, expected_sequence, work_order_code, wheel_spec, step_ranges, cancel_reason, cancelled_at, created_at, updated_at)`：`expected_sequence` 单调推进（1→7），只在有效确认落库的同一事务中递增，在撤回上一步的同一事务中回退到被撤回序号（有效确认始终形成 `1..k` 前缀）；`work_order_code` 可空且非空值全表唯一；`status` 为 `in_progress`/`completed`/`cancelled`，终止原因与时间仅在 `cancelled` 时非空；`wheel_spec` 为 `standard`/`heavy`（缺省 `standard`），`step_ranges` 为创建时固化的六步合格范围快照（JSONB）——API 启动时执行幂等迁移，历史会话由列默认值原地回填为标准型 + 原 4200–4800 快照，迁移后按原规则解释；
- `confirmations(id, session_id, sequence, position, torque, torque_input, torque_unit, idempotency_key, confirmed_at)`：不可变事件，`torque` 为换算后的整数 cN·m 标准字段（行级 CHECK 为两种规格的包络 4200–5200，逐步精确范围由应用层按会话快照校验），`torque_input`/`torque_unit` 保存操作工原始读数与单位；唯一约束 `(session_id, idempotency_key)`；同一序号在撤回后允许重新确认，因此可能保留多条历史确认，由触发器保证任一时刻每个序号至多一条**有效**（无撤回事件）记录；
- `confirmation_retractions(id, session_id, confirmation_id, sequence, retracted_at)`：不可变撤回事件，`confirmation_id` 唯一（每条确认至多被撤回一次，并发撤回只成功一次）；确认是否有效完全由是否存在对应撤回事件决定，确认行本身永不删除/改写。撤回事件同样禁止 UPDATE/DELETE。

重置数据：`docker compose down -v`（清空数据卷后 `db/init.sql` 会重新执行）。
