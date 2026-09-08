#!/bin/sh
# Task2 单元测试：diagnose.js 归因引擎（夹具证据 + 各分支断言）
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DSH_HOME="$T/home"; R="$DSH_HOME/.rescue"
fail(){ echo "FAIL-$1"; exit 1; }

# 夹具：建快照 snap-0001，meta reason=plugin add @scope/bad-plugin（= 变更前基线 + lastChange）
mkdir -p "$R/snap-0001"
printf '%s' '{"created":"2026-09-07T10:00:00+08:00","reason":"plugin add @scope/bad-plugin","dsh":"x"}' > "$R/snap-0001/meta.json"

# A. boot + 日志命中肇事插件（=lastChange 新增）-> remove-plugin high
mkdir -p "$R/evidence/boot-a"
printf '%s\n' "Error: failed to load plugin '@scope/bad-plugin'" > "$R/evidence/boot-a/dsh.stderr.log"
: > "$R/evidence/boot-a/dsh.stdout.log"
node "$ROOT/scripts/diagnose.js" --phase boot --evidence "$R/evidence/boot-a" --rescue-dir "$R" > "$R/a.json"
grep -q '"recommendedHeal":"remove-plugin"' "$R/a.json" || { echo "A heal="$(cat "$R/a.json"); fail a-heal; }
grep -q '"offendingPlugin":"@scope/bad-plugin"' "$R/a.json" || fail a-plugin
grep -q '"confidence":"high"' "$R/a.json" || fail a-conf
grep -q '"baselinePresent":true' "$R/a.json" || fail a-baseline

# B. 无任何快照 + 日志无明显插件/非插件 -> report-only（no-baseline）
R2="$T/h2"; mkdir -p "$R2/evidence/boot-b"
printf '%s\n' "some generic dsh output" > "$R2/evidence/boot-b/dsh.stdout.log"
node "$ROOT/scripts/diagnose.js" --phase boot --evidence "$R2/evidence/boot-b" --rescue-dir "$R2" > "$R2/b.json"
grep -q '"baselinePresent":false' "$R2/b.json" || fail b-no-baseline
grep -q '"recommendedHeal":"report-only"' "$R2/b.json" || fail b-report

# C. boot + 日志指向 OOM（非插件）-> report-only + category resource
R3="$T/h3"; mkdir -p "$R3/snap-0001" "$R3/evidence/boot-c"
printf '%s' '{"created":"x","reason":"manual","dsh":"x"}' > "$R3/snap-0001/meta.json"
printf '%s\n' "FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory" > "$R3/evidence/boot-c/dsh.stderr.log"
node "$ROOT/scripts/diagnose.js" --phase boot --evidence "$R3/evidence/boot-c" --rescue-dir "$R3" > "$R3/c.json"
grep -q '"category":"resource"' "$R3/c.json" || fail c-cat
grep -q '"recommendedHeal":"report-only"' "$R3/c.json" || fail c-report

# D. runtime + 日志命中肇事插件但非最近新增(有基线) -> rollback（有基线兜底）
mkdir -p "$R/evidence/boot-d"
printf '%s\n' "Error: Cannot find module '@other/pkg'" > "$R/evidence/boot-d/dsh.stderr.log"
node "$ROOT/scripts/diagnose.js" --phase runtime --evidence "$R/evidence/boot-d" --rescue-dir "$R" > "$R/d.json"
grep -q '"phase":"runtime"' "$R/d.json" || fail d-phase
# lastChange.pkg=@scope/bad-plugin != offender @other/pkg -> isLastAdded false -> heal rollback（有基线）
grep -q '"recommendedHeal":"rollback"' "$R/d.json" || { echo "D="$(cat "$R/d.json"); fail d-rollback; }


# E. --write-incident：产出的 incident body 含 id/redline/selfHeal/evidenceRef
printf '%s\n' 'remove-plugin|@scope/bad-plugin|2026-09-07T10:06:00+08:00|ok' > "$T/journal.txt"
node "$ROOT/scripts/diagnose.js" --phase boot --evidence "$R/evidence/boot-a" --rescue-dir "$R"   --write-incident --journal "$T/journal.txt" --trigger probe-timeout --evidence-ref evidence/boot-a > "$R/e.json"
# F. runtime 归因 + 无 boot 证据（运行期崩溃仅 changeContext，无该轮 evidence 目录）-> 可产 phase=runtime report-only incident（Fix 1a）
R6="$T/h6"; mkdir -p "$R6"
node "$ROOT/scripts/diagnose.js" --phase runtime --write-incident --rescue-dir "$R6" --trigger child-exit > "$R6/f.json" 2>"$R6/f.err" || { echo "F threw: $(cat "$R6/f.err")"; fail f-throw; }
node -e "const o=require('$R6/f.json'); if(o.phase!=='runtime')process.exit(1); if(o.symptom.type!=='healthy-then-crash')process.exit(2); if(o.selfHeal.outcome!=='report-only')process.exit(3); if(o.selfHeal.recommended!=='report-only')process.exit(4); if(o.redline.cordisPatchTouched!==false)process.exit(5);" || { echo "F bad=$(cat "$R6/f.json")"; fail f-incident; }
grep -q '"phase":"runtime"' "$R6/f.json" || fail f-phase
echo 'ALL-PASS'

