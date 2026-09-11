#!/bin/sh
# Task1 单元测试：librescue 状态/incident/meta-trigger 基础（沿用临时 DSH_HOME 模式）
set -eu
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DSH_HOME="$T/home"; mkdir -p "$DSH_HOME/profiles/web"
printf '%s' '{"name":"web","dependencies":{"demo":"1.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
printf 'lock v1\n' > "$DSH_HOME/profiles/web/pnpm-lock.yaml"
. "$(dirname "$0")/../librescue.sh"

fail(){ echo "FAIL-$1"; exit 1; }

# --- meta trigger: snapshot --reason 后 meta.json 含 reason ---
REASON_SNAPSHOT='plugin add @scope/demo' rescue_snapshot >/dev/null
grep -q '"reason":"plugin add @scope/demo"' "$RESCUE_DIR/snap-0001/meta.json" || fail meta-reason
grep -q '"created"' "$RESCUE_DIR/snap-0001/meta.json" || fail meta-created
grep -q '"dsh"' "$RESCUE_DIR/snap-0001/meta.json" || fail meta-dsh

# 默认（无 reason）应含 manual trigger
RESCUE_KEEP=5 rescue_snapshot >/dev/null
grep -q '"reason":"manual"' "$RESCUE_DIR/snap-0002/meta.json" || fail meta-default-manual

# --- incident: 原子写 + id 唯一 + 文件存在 + prune ---
id1=$(rescue_incident_write '{"phase":"boot"}')
id2=$(rescue_incident_write '{"phase":"runtime"}')
[ "$id1" != "$id2" ] || fail inc-id-uniq
[ -f "$RESCUE_DIR/incidents/$id1.json" ] || fail inc-file
grep -q '"phase":"boot"' "$RESCUE_DIR/incidents/$id1.json" || fail inc-content
# 列表包含二者
rescue_incident_list | grep -q "$id1" || fail inc-list

# prune：超过 RESCUE_INCIDENT_KEEP 只留 keep 份
export RESCUE_INCIDENT_KEEP=1
id3=$(rescue_incident_write '{"phase":"x"}')
n=$(ls -1 "$RESCUE_DIR"/incidents/inc-*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -le 1 ] || fail inc-prune

# --- state: 原子 roundtrip ---
rescue_state_write_lastrun '{"ok":1}'
[ "$(rescue_state_read_lastrun)" = '{"ok":1}' ] || fail state-lastrun
rescue_state_write_selfheal '{"removes":0}'
[ "$(rescue_state_read_selfheal)" = '{"removes":0}' ] || fail state-selfheal

echo 'ALL-PASS'

