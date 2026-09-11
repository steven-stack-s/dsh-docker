#!/usr/bin/env node
// logtee: tee 的替身 + 证据文件轮转。逐行读 stdin，每行写 stdout（容器日志=docker logs），
// 同时 append 到 <file>（证据文件）。<file> 超过 RESCUE_EVIDENCE_MAX 字节时轮转：
// <file> -> <file>.1（覆盖旧 .1），从空重建 <file>，避免 healthy 后活动证据 dsh.log 无限增长。
// 纯子串读写 + 自管 fd，崩溃风险低；EOF（上游退出）后自动退出。缺失此文件时 supervise 回退原 tee。
// 用法: node logtee.js <file>     env RESCUE_EVIDENCE_MAX 默认 20MB
'use strict';
const fs = require('node:fs');
const readline = require('node:readline');

const file = process.argv[2];
const maxBytes = Number(process.env.RESCUE_EVIDENCE_MAX) > 0
  ? Number(process.env.RESCUE_EVIDENCE_MAX)
  : 20 * 1024 * 1024;

// 无 file 参数（异常调用）→ 纯透传，保证不丢容器日志
if (!file) { process.stdin.pipe(process.stdout); return; }

let fd = null, size = 0;
function openFd() {
  try { fd = fs.openSync(file, 'a'); size = fs.fstatSync(fd).size; }
  catch (e) { fd = null; size = 0; } // 写失败不阻塞容器日志
}
function rotate() {
  try { if (fd) { fs.closeSync(fd); fd = null; } fs.renameSync(file, file + '.1'); } catch (e) {}
  openFd();
}
openFd();

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  const out = line + '\n';
  process.stdout.write(out);
  if (fd) { try { fs.writeSync(fd, out); size += Buffer.byteLength(out); } catch (e) {} }
  if (size > maxBytes) rotate();
});
rl.on('close', () => { if (fd) { try { fs.closeSync(fd); } catch (e) {} } process.exit(0); });
