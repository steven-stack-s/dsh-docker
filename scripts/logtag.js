#!/usr/bin/env node
// logtag: 逐行给 stdin 加时间戳前缀 [YYYY-MM-DDTHH:MM:SS+HHMM] 后写 stdout。
// 供 entrypoint 的 tee 证据链使用（dsh 输出经 fifo -> logtag -> tee -> docker logs + evidence），
// 使容器日志与证据文件每行都带时间。纯子串读写的行过滤器，崩溃风险极低；EOF 后自动退出。
'use strict';
const readline = require('readline');
const p = n => String(n).padStart(2, '0');
function ts() {
  const d = new Date();
  const o = -d.getTimezoneOffset(); // 分钟，东区为正
  const sign = o < 0 ? '-' : '+';
  const ao = Math.abs(o);
  return '[' + d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
    'T' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()) +
    sign + p(Math.floor(ao / 60)) + p(ao % 60) + ']';
}
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', line => process.stdout.write(ts() + ' ' + line + '\n'));
// 必须在 close 时【不】调用 process.exit()：stdout 接管道时是异步的，缓冲区里可能还压着
// 上万行未刷出。process.exit() 会立即终止进程并丢弃这些数据 —— 实测 20001 行输入只留下
// 8712 行（丢 56%），且**尾部（往往正是崩溃原因）整段丢失**，diagnose 拿不到证据只能 report-only。
// 改用 exitCode 让 Node 在事件循环自然排空（stdout flush 完）后退出。
rl.on('close', () => { process.exitCode = 0; });
