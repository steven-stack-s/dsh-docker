// 探测 127.0.0.1:<port> 在 timeout 内是否开始监听。用于 dsh 启动窗口健康判定。
// 用法: node probe-ready.js <port> [timeoutMs]   默认 timeoutMs=120000
const net = require('node:net');
const port = Number(process.argv[2]);
const timeoutMs = Number(process.argv[3] || 120000);
if (!port) { console.error('usage: node probe-ready.js <port> [timeoutMs]'); process.exit(2); }
const deadline = Date.now() + timeoutMs;
function tryOnce() {
  const s = net.connect(port, '127.0.0.1');
  const onOk = () => { s.destroy(); process.exit(0); };
  const onFail = () => { s.destroy(); if (Date.now() >= deadline) process.exit(1); else setTimeout(tryOnce, 1000); };
  s.once('connect', onOk);
  s.once('error', onFail);
}
tryOnce();
