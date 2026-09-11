// 分层就绪探测：dsh 启动窗口的健康判定（rescue 监督循环使用）。
//
// 退出码契约与改造前完全一致 —— exit 0 = 就绪，非 0 = 不就绪：
// rescue-supervise.sh 依赖该契约（`if node "$probe" ...; then`），故行为语义不变，
// 只是把「单一层」判据扩展为多层，收紧 healthy 的边界。
//
// 三层：
//   L1  TCP 连上 127.0.0.1:<port>
//   L2  在该端口上完成一次 HTTP 往返（任何状态码都算通过）
//   L3  L1+L2 连续 stable 次成立
//
// 关于 L2 为何「任何状态码都算通过」：装了第三方认证网关（如 @xgone/dsh-remote）时，
// 未认证的 GET / 返回的是登录页而非应用外壳；若要求 200 + 特定内容，这类实例会被
// 永久判为不健康并触发回滚死循环。故 L2 只证明「HTTP 栈真的能应答」，而不是只完成了
// TCP 握手：只有连上了却拿不到任何 HTTP 响应（超时/连接重置）才算失败。
//
// 关于 L4（客户端激活层）：L2 故意不看正文，但"插件树激活失败"恰恰是进程健康、端口在听、
// HTTP 也返回 200+HTML、只有浏览器里白屏的故障 —— v0.3.7 的 CHANGELOG 明确承认探针覆盖不到它。
// 这里补一步低风险的正文模式匹配：dsh 正常返回的 HTML 里不含任何启动失败标记（实测 14.7KB 的
// 正常 shell 连 "booting" 都没有），因此只在出现 "Failed to load plugins" /
// "N entries did not activate" 这类明确失败文案时才判不健康。
// 极端部署若服务端 HTML 恒含类似字样，可用 RESCUE_PROBE_FAIL_CHECK=off 整体关闭该检查。
//
// 用法: node probe-ready.js <port> [timeoutMs] [--pid <pid>] [--stable <n>] [--quiet]
//   --pid <pid>    该进程一消失即立即判失败（可选；不传则与改造前行为一致，
//                  即一直轮询到超时）。用于把「启动后立刻崩溃」的失败检测从
//                  RESCUE_START_TIMEOUT(默认 120s) 降到秒级。
//   --stable <n>   需要连续成功的次数，默认 2。
//   --quiet        不输出分层日志。
'use strict';
const net = require('node:net');
const http = require('node:http');

const HOST = '127.0.0.1';
const IO_TIMEOUT_MS = 3000; // 单次 TCP/HTTP 尝试的上限，避免任何一次挂起拖死整个探测
const RETRY_MS = 1000; // 失败后的重试间隔
const STABLE_MS = 400; // 已达成就绪层、只差连续确认时的间隔
const BODY_READ_MAX = 262144; // L4 最多读 256KB 正文，超限即断开，绝不因为读正文把探测拖住
const FAIL_BODY_PATTERNS = [
  /Failed to load plugins/i,
  /did not activate/i,
  /dsh-boot-(error|failed)/i,
];
const failCheckEnabled = () => (process.env.RESCUE_PROBE_FAIL_CHECK || 'on') !== 'off';

function parseArgs(argv) {
  const out = { port: 0, timeoutMs: 120000, pid: 0, stable: 2, quiet: false };
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--pid') out.pid = Number(argv[++i]) || 0;
    else if (a === '--stable') out.stable = Math.max(1, Number(argv[++i]) || 2);
    else if (a === '--quiet') out.quiet = true;
    else positional.push(Number(a));
  }
  out.port = positional[0] || 0;
  out.timeoutMs = positional[1] || out.timeoutMs;
  return out;
}

const opts = parseArgs(process.argv.slice(2));
if (!opts.port) {
  console.error('usage: node probe-ready.js <port> [timeoutMs] [--pid <pid>] [--stable <n>] [--quiet]');
  process.exit(2);
}

const deadline = Date.now() + opts.timeoutMs;
let consecutive = 0;
let lastNote = '';
const log = (msg) => {
  if (!opts.quiet) console.error(`[probe] ${msg}`);
};
// 仅在状态变化时输出：1s 轮询下避免刷屏，同时保留「卡在哪一层」的诊断线索
const note = (msg) => {
  if (msg !== lastNote) {
    lastNote = msg;
    log(msg);
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 可选：目标进程是否已消失（ESRCH=不存在；EPERM=存在但无权限，视为仍在）
function pidGone() {
  if (!opts.pid) return false;
  try {
    process.kill(opts.pid, 0);
    return false;
  } catch (e) {
    return e.code === 'ESRCH';
  }
}

function tcpOnce() {
  return new Promise((resolve) => {
    let settled = false;
    const done = (v) => {
      if (settled) return;
      settled = true;
      s.destroy();
      resolve(v);
    };
    const s = net.connect(opts.port, HOST);
    s.setTimeout(IO_TIMEOUT_MS, () => done(false));
    s.once('connect', () => done(true));
    s.once('error', () => done(false));
  });
}

function httpOnce() {
  return new Promise((resolve) => {
    const req = http.request(
      { host: HOST, port: opts.port, path: '/', method: 'GET', timeout: IO_TIMEOUT_MS },
      (res) => {
        let body = '';
        let seen = 0;
        res.on('data', (chunk) => {
          seen += chunk.length;
          if (seen > BODY_READ_MAX) {
            res.destroy(); // 正文够判断了，别为了读完拖住探测
            resolve({ ok: true, body });
            return;
          }
          body += chunk;
        });
        res.on('end', () => resolve({ ok: true, body })); // 任何状态码都算 HTTP 栈就绪
        res.on('error', () => resolve({ ok: true, body }));
      },
    );
    req.on('timeout', () => {
      req.destroy();
      resolve({ ok: false, body: '' });
    });
    req.on('error', () => resolve({ ok: false, body: '' }));
    req.end();
  });
}

async function tick() {
  if (pidGone()) return 'gone';
  if (!(await tcpOnce())) {
    consecutive = 0;
    note('L1 tcp: not listening yet');
    return 'retry';
  }
  const h = await httpOnce();
  if (!h.ok) {
    consecutive = 0;
    note('L2 http: tcp up but no HTTP response yet');
    return 'retry';
  }
  // L4：端口与 HTTP 栈都正常，但正文里出现"插件树没激活"的明确失败文案
  if (failCheckEnabled()) {
    const hit = FAIL_BODY_PATTERNS.find((re) => re.test(h.body));
    if (hit) {
      consecutive = 0;
      note(`L4 boot-failure marker in response body (${hit}): the port and HTTP stack are fine but the plugin tree did not activate`);
      return 'retry';
    }
  }
  consecutive += 1;
  note(`L1 tcp ok, L2 http ok, L4 body clean (${consecutive}/${opts.stable})`);
  return consecutive >= opts.stable ? 'ready' : 'retry';
}

(async () => {
  for (;;) {
    const state = await tick();
    if (state === 'ready') {
      log(`ready on ${HOST}:${opts.port} (${opts.stable} consecutive check(s))`);
      process.exit(0);
    }
    if (state === 'gone') {
      log(`child pid ${opts.pid} is gone; not ready`);
      process.exit(1);
    }
    if (Date.now() >= deadline) {
      log(`not ready within ${opts.timeoutMs}ms`);
      process.exit(1);
    }
    await sleep(consecutive > 0 ? STABLE_MS : RETRY_MS);
  }
})();
