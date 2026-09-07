'use strict';
// diagnose.js — DSH 救援「根因归因」引擎（确定性规则，非 LLM）。
// 输入：证据目录(evidence 含 dsh.stdout.log/dsh.stderr.log) + 快照 meta(经 rescue-dir) + phase。
// 输出：stdout 单行 JSON（规范 §4），exit 0。
// 用法: node diagnose.js --phase boot --evidence <dir> --rescue-dir <dir> [--log <audit>]
const fs = require('node:fs');
const path = require('node:path');

// ---- 真机校准点：DSH 插件加载失败/其他故障 的日志模式表（放顶部便于调参，不改逻辑）----
const PLUGIN_FAIL_PATTERNS = [
  /failed to (load|start|initialize|apply) plugin/i,
  /plugin .* (error|fail|crash)/i,
  /Cannot find module [\'\"]([^\'\"]+)[\'\"]/,
  /Error:.*[\'\"](@?[\w.-]+\/[\w.-]+|@?[\w.-]+)[\'\"]/i,
];
const NON_PLUGIN_PATTERNS = [
  { re: /EADDRINUSE/, cat: 'port-in-use', kw: '端口被占用（EADDRINUSE）' },
  { re: /heap out of memory|JavaScript heap|FATAL ERROR:|OutOfMemory/i, cat: 'resource', kw: '内存不足/堆溢出' },
  { re: /requires node (>= )?[0-9.]+/i, cat: 'node-version', kw: 'Node 版本过低' },
  { re: /listen EADDRINUSE/i, cat: 'port-in-use', kw: '端口被占用' },
];
// 从错误文本提取“疑似包名”：优先插件加载/模块缺失行，其次全局
function extractPluginName(text) {
  const candidates = [];
  // Cannot find module 'X' 或 plugin ... 'X'
  for (const m of text.matchAll(/Cannot find module [\'\"]([^\'\"]+)[\'\"]/g)) {
    if (m[1]) candidates.push(m[1].replace(/^.*node_modules[\/\\]/, ''));
  }
  for (const m of text.matchAll(/plugin.*?[\'\"](@?[\w.-]+(?:\/[\w.-]+)?)[\'\"]/gi)) {
    if (m[1]) candidates.push(m[1]);
  }
  for (const m of text.matchAll(/[\'\"](@[\w-]+\/[\w.-]+)[\'\"]/g)) {
    if (m[1]) candidates.push(m[1]);
  }
  if (candidates.length) return candidates[0];
  return null;
}
function parseArgs(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    const v = argv[i];
    if (v === '--phase') a.phase = argv[++i];
    else if (v === '--evidence') a.evidence = argv[++i];
    else if (v === '--rescue-dir') a.rescueDir = argv[++i];
    else if (v === '--log') a.log = argv[++i];
    else if (v === '--json-in') a.jsonIn = argv[++i];
    else if (v === '--id') a.id = argv[++i];
    else if (v === '--trigger') a.trigger = argv[++i];
    else if (v === '--evidence-ref') a.evidenceRef = argv[++i];
    else if (v === '--journal') a.journal = argv[++i];
    else if (v === '--resolve') a.resolve = argv[++i];
    else if (v === '--write-incident') a.writeIncident = 1;
    else if (v === '--diag-file') a.diagFile = argv[++i];
  }
  return a;
}
function readFileOr(p) { try { return fs.readFileSync(p, 'utf8'); } catch (e) { return ''; } }
function readDirJson(dir) {
  const out = [];
  if (!dir) return out;
  let names = [];
  try { names = fs.readdirSync(dir).filter((n) => /^snap-\d{4}$/.test(n)).sort(); } catch (e) { return out; }
  for (const n of names) {
    const meta = readFileOr(path.join(dir, n, 'meta.json'));
    let o = {};
    try { o = JSON.parse(meta); } catch (e) { o = { created: '', reason: '' }; }
    o._name = n;
    out.push(o);
  }
  return out;
}
// 从快照 meta 找“最近一次插件变更”：最新快照若 reason 形如 "plugin add <pkg>" / "plugin remove <pkg>" 即其为基线
function buildChangeContext(rescueDir) {
  const snaps = readDirJson(rescueDir);
  const newest = snaps.length ? snaps[snaps.length - 1] : null;
  const ctx = { baselinePresent: !!newest, baselineSnapshot: newest ? newest._name : null, lastChange: null, lastGoodSnapshot: newest ? newest._name : null };
  if (newest && typeof newest.reason === 'string') {
    const m = newest.reason.match(/^plugin (add|remove) (\S+)/);
    if (m) ctx.lastChange = { kind: 'plugin-' + m[1], pkg: m[2], ts: newest.created || '', reason: newest.reason };
  }
  return ctx;
}
function buildOutcome({ phase, symptom, evid, ctx, offender, cat, conf, heal, target, detail }) {
  const rationale = [];
  if (offender) rationale.push('证据日志命中插件相关失败，疑似肇事插件=' + offender);
  else if (ctx.lastChange) rationale.push('未在日志定位具体插件，但最近一次变更为 ' + ctx.lastChange.reason);
  else rationale.push('日志未见插件相关错误，且无最近插件变更基线');
  if (!ctx.baselinePresent) rationale.push('无变更前基线快照（可能未经 rescue plugin 封装直接改动）');
  rationale.push(detail);
  return {
    phase: phase, symptom: { type: symptom, detail: detail },
    changeContext: ctx,
    rootCause: { category: cat, offendingPlugin: offender, confidence: conf, rationale: rationale.join('；') },
    recommendedHeal: heal, recommendedTarget: target,
  };
}
function diagnose(opts) {
  const phase = opts.phase || 'boot';
  const evidDir = opts.evidence;
  const out = readFileOr(path.join(evidDir, 'dsh.stdout.log'));
  const err = readFileOr(path.join(evidDir, 'dsh.stderr.log'));
  const merged = readFileOr(path.join(evidDir, 'dsh.log'));
  const text = (out + '\n' + err + '\n' + merged);
  const ctx = buildChangeContext(opts.rescueDir);
  const offender = extractPluginName(text);
  const nonPlugin = NON_PLUGIN_PATTERNS.find((p) => p.re.test(text));
  let r;
  if (nonPlugin && !offender) {
    r = buildOutcome({ phase, symptom: phase === 'boot' ? 'never-listening' : 'healthy-then-crash', evid: text, ctx,
      offender: null, cat: nonPlugin.cat, conf: 'high', heal: 'report-only', target: null,
      detail: '日志指向非插件问题：' + nonPlugin.kw });
  } else if (phase === 'runtime' && !ctx.lastChange) {
    r = buildOutcome({ phase, symptom: 'healthy-then-crash', evid: text, ctx,
      offender, cat: offender ? 'plugin-runtime-crash' : 'unknown', conf: offender ? 'medium' : 'low',
      heal: 'report-only', target: offender,
      detail: '运行期崩溃但无紧邻插件变更，多为非插件（升级/内存/偶发），仅报告不自动回退' });
  } else if (offender) {
    const isLastAdded = ctx.lastChange && ctx.lastChange.pkg === offender && ctx.lastChange.kind === 'plugin-add';
    r = buildOutcome({ phase, symptom: phase === 'boot' ? 'never-listening' : 'healthy-then-crash', evid: text, ctx,
      offender, cat: isLastAdded ? 'plugin-load-failure' : 'plugin-related',
      conf: isLastAdded ? 'high' : 'medium',
      heal: isLastAdded ? 'remove-plugin' : (ctx.baselinePresent ? 'rollback' : 'report-only'),
      target: isLastAdded ? offender : (ctx.baselineSnapshot || null),
      detail: (isLastAdded ? '肇事插件正是最近一次新增' : '肇事插件并非最近新增') + '，' + (ctx.baselinePresent ? '有基线可回退' : '无基线') });
  } else if (ctx.lastChange && ctx.baselinePresent) {
    r = buildOutcome({ phase, symptom: phase === 'boot' ? 'never-listening' : 'healthy-then-crash', evid: text, ctx,
      offender: null, cat: 'post-change-boot-failure', conf: 'medium', heal: 'rollback', target: ctx.baselineSnapshot,
      detail: '失败紧跟插件变更 ' + ctx.lastChange.reason + '，回退到变更前基线是最确定性恢复' });
  } else {
    r = buildOutcome({ phase, symptom: phase === 'boot' ? 'never-listening' : 'healthy-then-crash', evid: text, ctx,
      offender, cat: offender ? 'plugin-related' : 'unknown', conf: 'low', heal: 'report-only',
      target: offender,
      detail: '无法确定根因且' + (ctx.baselinePresent ? '' : '无') + '变更前基线，保守仅报告不自动拆' });
  }
  return r;
}
// ---- incident 组装（写盘由 entrypoint 用 librescue 完成，此处只产 body + id）----
function genIncidentId() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  const ts = '' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + 'T' + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
  let rnd = '';
  try { rnd = require('node:crypto').randomBytes(2).toString('hex'); } catch (e) { rnd = '' + process.pid; }
  return 'inc-' + ts + '-' + rnd;
}
// journal：entrypoint 把自愈动作逐行 append（每行 kind|target|ts|outcome）
function readJournal(jfile) {
  const acts = [];
  if (!jfile) return acts;
  let txt = '';
  try { txt = fs.readFileSync(jfile, 'utf8'); } catch (e) { return acts; }
  for (const line of txt.split(/\n/)) {
    const m = line.match(/^(\S+)\|(.*?)\|(\S+)\|(\S+)$/);
    if (m) acts.push({ kind: m[1], target: m[2], ts: m[3], outcome: m[4] });
  }
  return acts;
}
function makeIncident(rec, opts) {
  const sh0 = { recommended: rec.recommendedHeal, target: rec.recommendedTarget || null, actions: readJournal(opts.journal) };
  const sh = { ...sh0, outcome: opts.resolve || resolveOutcome(sh0) };
  // redline 断言：本实现所有自愈动作只动插件树四件套；若 journal 出现 kind 涉及 patch/用户数据（不应有），标 true
  const redTouched = sh.actions.some((a) => a.kind === 'patch' || a.kind === 'user-data');
  return {
    id: opts.id || genIncidentId(),
    created: new Date().toISOString(),
    phase: rec.phase, trigger: opts.trigger || 'auto',
    symptom: rec.symptom || {},
    changeContext: rec.changeContext || {},
    rootCause: rec.rootCause || {},
    selfHeal: sh,
    evidenceRef: opts.evidenceRef || null,
    redline: { cordisPatchTouched: !!redTouched, userDataTouched: false },
  };
}
function resolveOutcome(sh) {
  if (!sh.actions.length) return 'report-only';
  if (sh.actions.some((a) => a.outcome === 'fail')) return 'unrecovered';
  const ok = sh.actions.filter((a) => a.outcome === 'ok');
  const lastOk = ok[ok.length - 1];
  if (!lastOk) return 'unrecovered';
  return lastOk.kind === 'remove-plugin' ? 'recovered-remove' : lastOk.kind === 'rollback' ? 'recovered-rollback' : 'recovered';
}
module.exports = { diagnose, buildChangeContext, extractPluginName, makeIncident, resolveOutcome };
if (require.main === module) {
  const args = parseArgs(process.argv.slice(2));
  let evidDir = args.evidence;
  let rescueDir = args.rescueDir || '';
  if (args.jsonIn) {
    const inj = JSON.parse(args.jsonIn);
    const result = { ...inj, phase: args.phase || inj.phase || 'boot' };
    process.stdout.write(JSON.stringify(result));
    process.exit(0);
  }
  if (!evidDir && !args.writeIncident) { console.error('usage: node diagnose.js --phase boot|runtime --evidence <dir> [--rescue-dir <dir>] [--write-incident 1] [--journal <f>] [--trigger <t>] [--evidence-ref <r>] [--resolve <outcome>]'); process.exit(2); }
  if (!rescueDir && process.env.DSH_HOME) rescueDir = path.join(process.env.DSH_HOME, '.rescue');
  let r;
  if (args.diagFile) {
    try { r = JSON.parse(fs.readFileSync(args.diagFile, 'utf8')); } catch (e) { console.error('diag-file unreadable'); process.exit(2); }
  } else {
    r = diagnose({ phase: args.phase, evidence: evidDir, rescueDir });
  }
  if (args.writeIncident) {
    const sh0 = { recommended: r.recommendedHeal, target: r.recommendedTarget || null, actions: readJournal(args.journal), outcome: args.resolve || resolveOutcome({ actions: readJournal(args.journal) }) };
    const inc = makeIncident(r, { id: args.id, trigger: args.trigger, evidenceRef: args.evidenceRef, journal: args.journal, resolve: args.resolve });
    process.stdout.write(JSON.stringify(inc));
  } else {
    process.stdout.write(JSON.stringify(r));
  }
  process.exit(0);
}
