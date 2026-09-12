import { createApp } from './app.js';
import { pool } from './db.js';
import { migrate } from './migrate.js';

const port = Number(process.env.PORT || 3000);

async function waitForDb(attempts = 30) {
  for (let i = 1; i <= attempts; i += 1) {
    try {
      await pool.query('SELECT 1');
      return;
    } catch {
      console.log(`等待数据库就绪（${i}/${attempts}）…`);
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  throw new Error('数据库不可用，放弃启动');
}

await waitForDb();
// 启动前执行幂等结构迁移：历史会话回填为标准型 + 原 4200–4800 快照
await migrate(pool);
const app = createApp();
app.listen(port, () => {
  console.log(`轮毂复核 API 已监听 :${port}`);
});
