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
rl.on('close', () => process.exit(0));
