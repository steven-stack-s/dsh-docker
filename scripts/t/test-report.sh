#!/bin/sh
# Task3 单元测试：report.js 报告聚合（总览 / <id> / --json）
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R="$T/.rescue"; mkdir -p "$R/incidents" "$R/evidence/boot-x" "$R/snap-0001"
fail(){ echo "FAIL-$1"; exit 1; }

printf '%s' '{"id":"inc-AAA","created":"2026-09-07T10:00:00+08:00","phase":"boot","trigger":"probe-timeout","symptom":{"type":"never-listening"},"changeContext":{"baselinePresent":true,"baselineSnapshot":"snap-0001","lastChange":{"kind":"plugin-add","pkg":"@scope/bad"},"lastGoodSnapshot":"snap-0001"},"rootCause":{"category":"plugin-load-failure","offendingPlugin":"@scope/bad","confidence":"high","rationale":"hit"},"selfHeal":{"recommended":"remove-plugin","target":"@scope/bad","actions":[{"kind":"remove-plugin","target":"@scope/bad","ts":"x","outcome":"ok"}],"outcome":"recovered-remove"},"evidenceRef":"evidence/boot-x","redline":{"cordisPatchTouched":false,"userDataTouched":false}}' > "$R/incidents/inc-AAA.json"
printf '%s' '{"id":"inc-BBB","created":"2026-09-07T11:00:00+08:00","phase":"runtime","trigger":"child-exit","rootCause":{"category":"unknown","offendingPlugin":null,"confidence":"low"},"selfHeal":{"outcome":"report-only"},"redline":{"cordisPatchTouched":false,"userDataTouched":false}}' > "$R/incidents/inc-BBB.json"

# 总览含标题与两 id
out=$(node "$ROOT/scripts/report.js" --rescue-dir "$R")
echo "$out" | grep -q 'DSH rescue report' || fail ov-title
echo "$out" | grep -q 'inc-AAA' || fail ov-inc-a
echo "$out" | grep -q 'inc-BBB' || fail ov-inc-b
echo "$out" | grep -q 'recovered-remove' || fail ov-outcome
echo "$out" | grep -q 'snapshots: 1' || fail ov-snaps

# 单条详情含 rationale 与 redline 断言
d=$(node "$ROOT/scripts/report.js" inc-AAA --rescue-dir "$R")
echo "$d" | grep -q 'rationale: hit' || fail det-rat
echo "$d" | grep -q 'cordis.patch.yml untouched' || fail det-redline
echo "$d" | grep -q 'recovered-remove' || fail det-outcome

# --json 合法且含 2 条
j=$(node "$ROOT/scripts/report.js" --json --rescue-dir "$R")
node -e "const a=JSON.parse(process.argv[1]); if(a.length!==2) process.exit(1);" "$j" || fail json-count

echo 'ALL-PASS'

