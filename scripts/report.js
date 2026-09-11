'use strict';
// report.js — DSH 救援「rescue report」人读/JSON 报告（决策③）。
// 用法: node report.js [<incident-id>] [--json] [--rescue-dir <dir>] [--limit N]
const fs = require('node:fs');
const path = require('node:path');

function parseArgs(argv) {
  const a = { json: false, id: null, limit: 8 };
  for (let i = 0; i < argv.length; i++) {
    const v = argv[i];
    if (v === '--json') a.json = true;
    else if (v === '--rescue-dir') a.rescueDir = argv[++i];
    else if (v === '--limit') a.limit = Number(argv[++i]);
    else if (!v.startsWith('--')) a.id = v;
  }
  return a;
}
function rescueDirOf(args) {
  if (args.rescueDir) return args.rescueDir;
  if (process.env.DSH_HOME) return path.join(process.env.DSH_HOME, '.rescue');
  return '';
}
function readJson(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { return null; } }
function countDir(p) { try { return fs.readdirSync(p).length; } catch (e) { return 0; } }
function listIncidents(dir) {
  const incDir = path.join(dir, 'incidents');
  let files = [];
  try {
    files = fs.readdirSync(incDir).filter((n) => n.startsWith('inc-') && n.endsWith('.json'));
  } catch (e) { return []; }
  files.sort();
  return files.map((f) => ({ id: f.replace(/\.json$/, ''), file: path.join(incDir, f) }));
}
function pad(s, n) { s = String(s); return s.length > n ? s.slice(0, n - 1) + '…' : s; }
function outHuman(rec) {
  const rc = rec.rootCause || {};
  const sh = rec.selfHeal || {};
  const lines = [];
  lines.push('== ' + (rec.id || '?') + ' ==  ' + (rec.created || '') + '  phase=' + (rec.phase || '?') + '  trigger=' + (rec.trigger || '?'));
  lines.push('  symptom: ' + JSON.stringify(rec.symptom || {}));
  lines.push('  rootCause: category=' + (rc.category || '?') + '  offender=' + (rc.offendingPlugin || '-') + '  confidence=' + (rc.confidence || '-'));
  if (rc.rationale) lines.push('  rationale: ' + rc.rationale);
  lines.push('  changeContext: ' + JSON.stringify(rec.changeContext || {}));
  if (Array.isArray(sh.actions) && sh.actions.length) {
    for (const a of sh.actions) lines.push('  heal["' + a.kind + '"] ' + (a.target || '') + ' -> ' + (a.outcome || '') + ' @' + (a.ts || ''));
  }
  lines.push('  selfHeal.outcome: ' + (sh.outcome || '-') + '  recommended: ' + (sh.recommended || '-'));
  if (rec.evidenceRef) lines.push('  evidenceRef: ' + rec.evidenceRef);
  const rl = rec.redline || {};
  if (rl.cordisPatchTouched || rl.userDataTouched) {
    lines.push('  !!! REDLINE TOUCH !!! cordisPatchTouched=' + rl.cordisPatchTouched + ' userDataTouched=' + rl.userDataTouched);
  } else {
    lines.push('  redline: cordis.patch.yml untouched, user data untouched');
  }
  return lines.join('\n');
}
function main() {
  const args = parseArgs(process.argv.slice(2));
  const rd = rescueDirOf(args);
  if (!rd) { console.error('report: no rescue dir (set --rescue-dir or DSH_HOME)'); process.exit(2); }
  const incs = listIncidents(rd);
  if (args.json) {
    const data = incs.map((i) => readJson(i.file)).filter(Boolean);
    process.stdout.write(JSON.stringify(data));
    return;
  }
  if (args.id) {
    const found = incs.find((i) => i.id === args.id);
    if (!found) { console.error('incident not found: ' + args.id); process.exit(1); }
    const rec = readJson(found.file) || {};
    process.stdout.write(outHuman(rec) + '\n');
    return;
  }
  // overview
  let snapDirs = [];
  try { snapDirs = fs.readdirSync(rd).filter((n) => /^snap-\d{4}$/.test(n)); } catch (e) {}
  const evidenceN = countDir(path.join(rd, 'evidence'));
  console.log('DSH rescue report');
  console.log('  time: ' + new Date().toString());
  console.log('  rescue dir: ' + rd);
  console.log('  snapshots: ' + snapDirs.length + '   evidence boots: ' + evidenceN + '   incidents: ' + incs.length);
  const recent = incs.slice(-args.limit);
  if (recent.length === 0) {
    console.log('  (no incidents recorded)');
  } else {
    console.log('  recent incidents:');
    for (const i of recent) {
      const rec = readJson(i.file) || {};
      const rc = rec.rootCause || {};
      const sh = rec.selfHeal || {};
      console.log('    - ' + pad(rec.id || '?', 30) + ' ' + pad(rec.phase || '?', 8) + ' ' + pad(rc.category || '?', 24) +
        ' offender=' + (rc.offendingPlugin || '-') + '  outcome=' + (sh.outcome || '-'));
    }
    console.log('  use: rescue report <incident-id>  for detail');
  }
}
module.exports = { listIncidents, outHuman };
if (require.main === module) main();

