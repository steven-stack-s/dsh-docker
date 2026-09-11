#!/bin/sh
# ============================================================================
# test-snapshot-integrity.sh — 快照完整性：meta 树哈希 + rescue verify + 快照模式
#
# 背景（P0-6）：`cp -al` 让快照与 live 的 node_modules 共享 inode，任何"就地改写"
# （append / sed -i / 原生模块重编）会同时改坏历史快照，而指纹只看 package.json+lockfile，
# 对 node_modules 完全盲 —— 于是"回退点"可能早已不可信。
#
# 契约：
#   1. 快照 meta 记录 node_modules 树哈希、profile、快照模式
#   2. 完好快照 verify 通过
#   3. hardlink 模式下 live 被就地改写 -> 快照被污染 -> verify 必须失败
#   4. copy 模式下快照是独立副本 -> live 改写不影响它 -> verify 通过
#
# 用法: sh scripts/t/test-snapshot-integrity.sh    （全通过打印 ALL-PASS）
# ============================================================================
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

export DSH_HOME="$T/home"
PDIR="$DSH_HOME/profiles/web"
mkdir -p "$PDIR/node_modules/pkg"
printf '{"name":"web","private":true,"dependencies":{"pkg":"1.0.0"}}' > "$PDIR/package.json"
printf 'v1\n' > "$PDIR/node_modules/pkg/index.js"
. "$HERE/../librescue.sh"

# ---- 1) meta 必须记录 treeHash / profile / mode ----
s=$(REASON_SNAPSHOT=integrity rescue_snapshot)
[ "$s" = "snap-0001" ] || { echo "FAIL-snapshot-name: $s"; exit 1; }
meta="$RESCUE_DIR/$s/meta.json"
grep -q '"treeHash":"[0-9a-f]\{32\}"' "$meta" || { echo "FAIL-meta-no-treehash: $(cat "$meta")"; exit 1; }
grep -q '"profile":"web"' "$meta" || { echo "FAIL-meta-no-profile: $(cat "$meta")"; exit 1; }
grep -q '"mode":"hardlink"' "$meta" || { echo "FAIL-meta-no-mode: $(cat "$meta")"; exit 1; }

# ---- 2) 完好快照 verify 通过 ----
rescue_verify "$s" >/dev/null 2>&1 || { echo 'FAIL-verify-fresh-snapshot'; rescue_verify "$s"; exit 1; }

# ---- 3) live 被就地改写（append 同一 inode）-> 快照被污染 ----
printf 'v2\n' >> "$PDIR/node_modules/pkg/index.js"
if rescue_verify "$s" >/dev/null 2>&1; then
  echo 'FAIL-verify-missed-hardlink-pollution'
  exit 1
fi

# ---- 4) copy 模式：快照是独立副本，live 改写不污染它 ----
rm -rf "$RESCUE_DIR"
s2=$(RESCUE_SNAPSHOT_MODE=copy REASON_SNAPSHOT=integrity-copy rescue_snapshot)
grep -q '"mode":"copy"' "$RESCUE_DIR/$s2/meta.json" || { echo 'FAIL-copy-mode-not-recorded'; exit 1; }
printf 'v3-append-after-copy-snapshot\n' >> "$PDIR/node_modules/pkg/index.js"
rescue_verify "$s2" >/dev/null 2>&1 || { echo 'FAIL-copy-mode-snapshot-should-be-immune'; rescue_verify "$s2"; exit 1; }

# ---- 5) meta 记录过 treeHash，但快照的 node_modules 不见了 -> 不完整，不得判 OK ----
# （否则 rescue_restore 会"成功"地把 live 的 node_modules 也删掉，还记 rollback ok + 耗预算）
rm -rf "$RESCUE_DIR/$s2/node_modules"
if rescue_verify "$s2" >/dev/null 2>&1; then
  echo 'FAIL-verify-missing-node-modules-passed'
  exit 1
fi

# ---- 6) 旧快照（meta 无 treeHash）不得被判为"已损坏" ----
# 升级到带 treeHash 的版本后，所有历史快照都缺该字段；若 verify 一律返回非 0 并提示
# "删除已被写坏者"，用户会被诱导删掉唯一可用的回退点。
mkdir -p "$RESCUE_DIR/snap-legacy/node_modules/pkg"
printf 'x\n' > "$RESCUE_DIR/snap-legacy/node_modules/pkg/i.js"
printf '%s' '{"created":"2026-01-01T00:00:00+0800","reason":"legacy","profile":"web"}' > "$RESCUE_DIR/snap-legacy/meta.json"
if ! vout=$(rescue_verify snap-legacy 2>&1); then
  echo "FAIL-verify-legacy-treated-as-broken: $vout"
  exit 1
fi
printf '%s' "$vout" | grep -q '跳过完整性校验' || { echo "FAIL-verify-legacy-wording: $vout"; exit 1; }

# ---- 7) 冗余判定必须看 node_modules，而不只是 package.json + lockfile ----
# copy 模式的快照（或 pnpm 重装后）配置文件相同、依赖树完全不同；若仍判 SAME，
# 界面会告诉用户"回滚没有任何效果"，实际却会换掉整棵树。
command -v rescue_snapshot_is_redundant >/dev/null 2>&1 || { echo 'FAIL-redundant-helper-missing'; exit 1; }
rm -rf "$RESCUE_DIR" "$DSH_HOME/profiles/web"
mkdir -p "$DSH_HOME/profiles/web/node_modules/pkg"
printf '{"name":"web","dependencies":{"a":"1"}}' > "$DSH_HOME/profiles/web/package.json"
printf 'v1\n' > "$DSH_HOME/profiles/web/node_modules/pkg/index.js"
s3=$(RESCUE_SNAPSHOT_MODE=copy REASON_SNAPSHOT=i8 rescue_snapshot)
printf 'v2-totally-different\n' > "$DSH_HOME/profiles/web/node_modules/pkg/index.js"
[ "$(rescue_live_differs_from "$s3")" = 0 ] || { echo 'FAIL-i8-fixture-fingerprint-should-match'; exit 1; }
if rescue_snapshot_is_redundant "$s3"; then
  echo 'FAIL-i8-redundant-despite-node-modules-differ'
  exit 1
fi

echo ALL-PASS
