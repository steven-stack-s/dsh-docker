#!/bin/sh
# 黑盒测试：rescue clean 的孤儿判定与清理行为。
# 重点守护两条红线：① 被 lockfile 引用的条目绝不删 ② package.json/lockfile 字节级不变。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/scripts/librescue.sh"
[ -f "$LIB" ] || { echo "FAIL librescue missing"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web"
# profile 基线文件：任务 3/4 的红线用例要对它们做字节级比对，故此处先建立。
printf '%s' '{"name":"web","dependencies":{"@wenaixi/dsh-superpower":"6.3.0-dsh.10"}}' > "$DSH_HOME/profiles/web/package.json"
RESCUE_PROFILE=web
. "$LIB"

fail() { echo "FAIL-$1"; exit 1; }

# --- 1) 目录名解析：scope 包 + peer 后缀 ---
k=$(rescue_pnpm_dir_to_key '@wenaixi+dsh-superpower@6.3.1_@deepseek-ai+cordis@4.0.2_ea847881') \
  || fail parse-scoped-with-peer
[ "$k" = '@wenaixi/dsh-superpower@6.3.1' ] || fail "parse-scoped-with-peer:$k"

k=$(rescue_pnpm_dir_to_key '@deepseek-ai+cordis@4.0.2') || fail parse-scoped-nopeer
[ "$k" = '@deepseek-ai/cordis@4.0.2' ] || fail "parse-scoped-nopeer:$k"

k=$(rescue_pnpm_dir_to_key 'yaml@2.9.1') || fail parse-plain
[ "$k" = 'yaml@2.9.1' ] || fail "parse-plain:$k"

# 非包目录必须被拒绝（pnpm 内部文件 / 解析失败）
if rescue_pnpm_dir_to_key 'node_modules' >/dev/null 2>&1; then fail 'parse-should-reject-node_modules'; fi
if rescue_pnpm_dir_to_key 'lock.yaml' >/dev/null 2>&1; then fail 'parse-should-reject-lockyaml'; fi

# --- 2) lockfile 键提取：带引号、带 peer 括号后缀 ---
cat > "$DSH_HOME/profiles/web/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '9.0'

importers:

  .:
    dependencies:
      '@wenaixi/dsh-superpower':
        specifier: 6.3.0-dsh.10
        version: 6.3.0-dsh.10(@deepseek-ai/cordis@4.0.2)

packages:

  '@deepseek-ai/cordis@4.0.2':
    resolution: {integrity: sha512-xxx}

  '@wenaixi/dsh-superpower@6.3.0-dsh.10':
    resolution: {integrity: sha512-yyy}

  yaml@2.9.1:
    resolution: {integrity: sha512-zzz}

snapshots:

  '@wenaixi/dsh-superpower@6.3.0-dsh.10(@deepseek-ai/cordis@4.0.2)':
    dependencies:
      '@deepseek-ai/cordis': 4.0.2
EOF

rescue_pnpm_locked_keys "$DSH_HOME/profiles/web/pnpm-lock.yaml" > "$T/keys"
grep -qx '@deepseek-ai/cordis@4.0.2' "$T/keys" || fail keys-missing-cordis
grep -qx '@wenaixi/dsh-superpower@6.3.0-dsh.10' "$T/keys" || fail keys-missing-superpower
grep -qx 'yaml@2.9.1' "$T/keys" || fail keys-missing-yaml
# snapshots 段的键也必须被剥掉 peer 括号（否则 packages 段与 snapshots 段重复计数无害，但不能产生垃圾键）
if grep -q '(' "$T/keys"; then fail keys-should-strip-peer-parens; fi

# --- 3) 孤儿判定 ---
if ! rescue_pnpm_is_orphan '@wenaixi+dsh-superpower@6.3.1_@deepseek-ai+cordis@4.0.2_ea1' "$DSH_HOME/profiles/web/pnpm-lock.yaml"; then
  fail orphan-not-detected
fi
if rescue_pnpm_is_orphan '@wenaixi+dsh-superpower@6.3.0-dsh.10_@deepseek-ai+cordis@4.0.2_ea1' "$DSH_HOME/profiles/web/pnpm-lock.yaml"; then
  fail referenced-wrongly-flagged-orphan
fi
# 关键回归：在用的 6.3.1 存在于 packages 段时绝不能被判为孤儿
sed -i "s/@wenaixi\/dsh-superpower@6.3.0-dsh.10/@wenaixi\/dsh-superpower@6.3.1/" "$DSH_HOME/profiles/web/pnpm-lock.yaml" 2>/dev/null || \
  sed -i '' "s/@wenaixi\/dsh-superpower@6.3.0-dsh.10/@wenaixi\/dsh-superpower@6.3.1/" "$DSH_HOME/profiles/web/pnpm-lock.yaml"
if rescue_pnpm_is_orphan '@wenaixi+dsh-superpower@6.3.1_@deepseek-ai+cordis@4.0.2_ea1' "$DSH_HOME/profiles/web/pnpm-lock.yaml"; then
  fail live-package-misjudged-as-orphan
fi

# --- 4) 匹配必须整行相等（精确），不得因前缀/子串/glob 造成漏删 ---
# 4a) lockfile 仅存在「以该 key 为前缀」的行时，必须判为孤儿（前缀不等于命中）。
LOCKS="$DSH_HOME/profiles/web/pnpm-lock.yaml"
cat > "$LOCKS" <<'EOF'
lockfileVersion: '9.0'

packages:

  react@18.2.0+esm20230101:
    resolution: {integrity: sha512-prefix}

  yaml@2.9.1:
    resolution: {integrity: sha512-zzz}

snapshots:

  'yaml@2.9.1':
    dependencies:
      foo: 1
EOF
# 目录名 'react@18.2.0_peer' -> key 'react@18.2.0'，仅为上面首行的前缀，未精确出现 => 孤儿
if rescue_pnpm_is_orphan 'react@18.2.0_peer' "$LOCKS"; then
  :
else
  fail prefix-line-must-not-suppress-orphan
fi
# 4b) 键自身精确存在 -> 必须 live（非孤儿）
if rescue_pnpm_is_orphan 'react@18.2.0+esm20230101' "$LOCKS"; then
  fail exact-key-must-stay-live
fi
# 4c) 未出现的 key -> 必须孤儿
if rescue_pnpm_is_orphan 'absolutely-not-locked@9.9.9' "$LOCKS"; then
  :
else
  fail absent-key-must-be-orphan
fi

# --- 4) 目录体积统计 ---
mkdir -p "$T/sz/a/b"
# 用固定大小文件避免依赖 block size：8 字节 × 2
printf '12345678' > "$T/sz/a/f1"
printf '12345678' > "$T/sz/a/b/f2"
sz=$(rescue_dir_size_bytes "$T/sz")
[ "$sz" -ge 16 ] || fail "dir-size-too-small:$sz"
sz0=$(rescue_dir_size_bytes "$T/does-not-exist")
[ "$sz0" = 0 ] || fail "dir-size-missing-should-be-0:$sz0"

# --- 5) npm 缓存清理：dry-run 不删，实删只删 _cacache ---
CACHE="$T/npmcache"
mkdir -p "$CACHE/_cacache/content-v2" "$CACHE/_logs"
printf 'cache-blob' > "$CACHE/_cacache/content-v2/blob"
printf 'log' > "$CACHE/_logs/keep.log"
NPM_CONFIG_CACHE="$CACHE" npm_config_cache="$CACHE"
export NPM_CONFIG_CACHE="$CACHE"

rescue_clean_npm_cache 1 >/dev/null 2>&1 || true
[ -d "$CACHE/_cacache" ] || fail 'dryrun-deleted-npm-cache'

rescue_clean_npm_cache 0 >/dev/null 2>&1 || true
[ ! -d "$CACHE/_cacache" ] || fail 'real-run-kept-npm-cache'
[ -d "$CACHE/_logs" ] || fail 'must-not-delete-logs-dir'

# --- 6) pnpm store 清理：dry-run 不调用 prune ---
# 用 stub pnpm 记录调用，避免依赖真实网络/存储
STUB="$T/bin"; mkdir -p "$STUB"
cat > "$STUB/pnpm" <<'STUBEOF'
#!/bin/sh
printf '%s\n' "$*" >> "${PNPM_STUB_LOG:?}"
exit 0
STUBEOF
chmod +x "$STUB/pnpm"
export PATH="$STUB:$PATH"
export PNPM_STUB_LOG="$T/pnpm-calls"
: > "$PNPM_STUB_LOG"

rescue_clean_pnpm_store 1 >/dev/null 2>&1 || true
if [ -s "$PNPM_STUB_LOG" ]; then fail 'dryrun-invoked-pnpm-store'; fi

rescue_clean_pnpm_store 0 >/dev/null 2>&1 || true
grep -q 'store prune' "$PNPM_STUB_LOG" || fail 'real-run-did-not-prune-store'

# --- 7) profile 孤儿清理：被引用者绝不删 ---
P="$DSH_HOME/profiles/web"
mkdir -p "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" \
         "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.0-dsh.10_peer_bb" \
         "$P/node_modules/.pnpm"
printf 'old' > "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa/index.js"
printf 'new' > "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.0-dsh.10_peer_bb/index.js"
cat > "$P/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '9.0'

packages:

  '@wenaixi/dsh-superpower@6.3.0-dsh.10':
    resolution: {integrity: sha512-yyy}

snapshots:
EOF
# 红线基线：记录两个受保护文件的字节指纹
before_pkg=$(cksum < "$P/package.json")
before_lock=$(cksum < "$P/pnpm-lock.yaml")

# 前置存在性断言：函数不存在时必须立刻失败，
# 否则下面的「目录还在」断言会因「没人删东西」而空洞通过（评审者变异测试证明）。
command -v rescue_clean_pnpm_orphans >/dev/null 2>&1 || fail 'function-missing:rescue_clean_pnpm_orphans'

# dry-run：不删任何东西
rescue_clean_pnpm_orphans "$P" 1 >/dev/null 2>&1 || true
[ -d "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" ] || fail 'dryrun-deleted-orphan'

# 真实清理：孤儿消失、在用者保留
rescue_clean_pnpm_orphans "$P" 0 >/dev/null 2>&1 || true
[ ! -d "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" ] || fail 'real-run-kept-orphan'
[ -d "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.0-dsh.10_peer_bb" ] || fail 'REGRESSION-deleted-referenced-entry'

# 红线：两个受保护文件字节级不变
[ "$before_pkg" = "$(cksum < "$P/package.json")" ] || fail 'REDLINE-package.json-modified'
[ "$before_lock" = "$(cksum < "$P/pnpm-lock.yaml")" ] || fail 'REDLINE-lockfile-modified'

# --- 8) 救援历史轮转函数在 librescue 上下文可用（可见性回归）---
command -v rescue_evidence_prune >/dev/null 2>&1 || fail 'evidence-prune-not-visible-in-librescue'
command -v rescue_incident_prune >/dev/null 2>&1 || fail 'incident-prune-not-visible-in-librescue'
rescue_clean_rescue_history >/dev/null 2>&1 || fail 'rescue-history-clean-failed'

# --- 9) 锁文件格式不匹配 / 解析不出键时，必须保守跳过（Critical 红线）---
# 设计原则：区分「我确认这些条目无引用」与「我无法判断谁有引用」。
# 前者才可删；后者必须原样保留整棵树。
command -v rescue_clean_pnpm_orphans >/dev/null 2>&1 || fail 'function-missing:rescue_clean_pnpm_orphans'

# 9a) pnpm v6 风格锁文件：键形如 /react@18.2.0（带前导斜杠）
G="$T/guard"; PG="$G/profiles/web"
mkdir -p "$PG/node_modules/.pnpm/@scope+name@1.0.0_pp" "$PG/node_modules/.pnpm/react@18.2.0_aa"
printf 'a' > "$PG/node_modules/.pnpm/@scope+name@1.0.0_pp/f"
printf 'b' > "$PG/node_modules/.pnpm/react@18.2.0_aa/f"
printf '%s' '{"name":"web"}' > "$PG/package.json"
cat > "$PG/pnpm-lock.yaml" <<'EOF'
lockfileVersion: 6.0

packages:

  /@scope/name@1.0.0:
    resolution: {integrity: sha512-aaa}

  /react@18.2.0:
    resolution: {integrity: sha512-bbb}
EOF
# 归一化契约：v6 键必须被剥掉前导斜杠
kk=$(rescue_pnpm_locked_keys "$PG/pnpm-lock.yaml")
printf '%s\n' "$kk" | grep -qxF '/react@18.2.0' && fail 'v6-key-leading-slash-not-normalized'
printf '%s\n' "$kk" | grep -qxF 'react@18.2.0' || fail 'v6-key-missing-after-normalize'
printf '%s\n' "$kk" | grep -qxF '@scope/name@1.0.0' || fail 'v6-scoped-key-not-normalized'

rescue_clean_pnpm_orphans "$PG" 0 >/dev/null 2>&1 || true
[ -d "$PG/node_modules/.pnpm/react@18.2.0_aa" ] || fail 'CRITICAL-v6-lockfile-wiped-referenced-entry'
[ -d "$PG/node_modules/.pnpm/@scope+name@1.0.0_pp" ] || fail 'CRITICAL-v6-lockfile-wiped-scoped-entry'

# 9b) 0 字节锁文件 → 解析不出任何键 → 必须整棵保留
G2="$T/guard-empty"; PG2="$G2/profiles/web"
mkdir -p "$PG2/node_modules/.pnpm/react@18.2.0_aa"
printf 'b' > "$PG2/node_modules/.pnpm/react@18.2.0_aa/f"
printf '%s' '{"name":"web"}' > "$PG2/package.json"
: > "$PG2/pnpm-lock.yaml"
rescue_clean_pnpm_orphans "$PG2" 0 >/dev/null 2>&1 || true
[ -d "$PG2/node_modules/.pnpm/react@18.2.0_aa" ] || fail 'CRITICAL-empty-lockfile-wiped-tree'

# 9c) 缺 snapshots: 段（截断/损坏）→ 解析不出键 → 必须整棵保留
G3="$T/guard-trunc"; PG3="$G3/profiles/web"
mkdir -p "$PG3/node_modules/.pnpm/react@18.2.0_aa"
printf 'b' > "$PG3/node_modules/.pnpm/react@18.2.0_aa/f"
printf '%s' '{"name":"web"}' > "$PG3/package.json"
printf 'lockfileVersion: 9.0\n' > "$PG3/pnpm-lock.yaml"
rescue_clean_pnpm_orphans "$PG3" 0 >/dev/null 2>&1 || true
[ -d "$PG3/node_modules/.pnpm/react@18.2.0_aa" ] || fail 'CRITICAL-truncated-lockfile-wiped-tree'

# --- 9) CLI：默认 dry-run 不产生副作用、不拍快照 ---
RESCUE="$ROOT/scripts/rescue"
[ -x "$RESCUE" ] || fail 'rescue-not-executable'
rm -rf "$RESCUE_DIR"/snap-*
before_n=$(ls -1d "$RESCUE_DIR"/snap-* 2>/dev/null | wc -l | tr -d ' ')
sh "$RESCUE" clean >/dev/null 2>&1 || fail 'clean-dryrun-exit-nonzero'
after_n=$(ls -1d "$RESCUE_DIR"/snap-* 2>/dev/null | wc -l | tr -d ' ')
[ "$before_n" = "$after_n" ] || fail 'dryrun-created-snapshot'
[ -d "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.0-dsh.10_peer_bb" ] || fail 'dryrun-removed-live-entry'

# --- 10) CLI：usage 串包含 clean ---
sh "$RESCUE" >/dev/null 2>&1 || true
usage=$(sh "$RESCUE" 2>&1 || true)
printf '%s' "$usage" | grep -q 'clean' || fail 'usage-missing-clean'

# --- 11) CLI：--yes 拍 pre-clean 快照 ---
# 重建一份孤儿，确保有东西可清
mkdir -p "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.9_peer_zz"
printf 'junk' > "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.9_peer_zz/index.js"
: > "$PNPM_STUB_LOG"
sh "$RESCUE" clean --yes >/dev/null 2>&1 || fail 'clean-yes-exit-nonzero'
ls -1d "$RESCUE_DIR"/snap-* >/dev/null 2>&1 || fail 'clean-yes-created-no-snapshot'
grep -q '"reason":"pre-clean"' "$RESCUE_DIR"/snap-*/meta.json || fail 'pre-clean-reason-missing'
[ ! -d "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.9_peer_zz" ] || fail 'clean-yes-did-not-remove-orphan'

# --- 12) CLI：未知选项须报错退出（非 0）---
if sh "$RESCUE" clean --bogus >/dev/null 2>&1; then fail 'unknown-option-should-fail'; fi

# --- 13) 红线：--yes 后 package.json 与 lockfile 仍字节级不变 ---
[ "$before_pkg" = "$(cksum < "$P/package.json")" ] || fail 'REDLINE-yes-package.json-modified'
[ "$before_lock" = "$(cksum < "$P/pnpm-lock.yaml")" ] || fail 'REDLINE-yes-lockfile-modified'

# --- 14) 与自愈预算解耦 ---
[ ! -f "$RESCUE_DIR/state/selfheal.json" ] || fail 'clean-touched-selfheal-budget'

# --- 15) 要求 A：rescue history 轮转失败不得中断整个 clean（部分失败须如实反映）---
# 构造真实故障：把 scripts/ 整棵复制到沙箱，并在副本里删掉 rescue_evidence_prune /
# rescue_incident_prune 的定义（等价于任务 3 修掉的「函数在 librescue 里不可见」回归）。
# 此时 rescue_clean_rescue_history 的真实契约是打印 "prune incomplete" 并返回非 0。
# 断言：① 该函数的确失败了（否则本用例空洞通过）② clean 仍以 0 退出且走到 'clean: done'。
A="$T/attach-fail"
mkdir -p "$A"
cp -a "$ROOT/scripts" "$A/scripts"
sed -i 's/^rescue_evidence_prune() {/rescue_evidence_prune_disabled_for_test() {/' "$A/scripts/librescue.sh" 2>/dev/null || \
  sed -i '' 's/^rescue_evidence_prune() {/rescue_evidence_prune_disabled_for_test() {/' "$A/scripts/librescue.sh"
sed -i 's/^rescue_incident_prune() {/rescue_incident_prune_disabled_for_test() {/' "$A/scripts/librescue.sh" 2>/dev/null || \
  sed -i '' 's/^rescue_incident_prune() {/rescue_incident_prune_disabled_for_test() {/' "$A/scripts/librescue.sh"
# 前置断言：故障注入必须真的生效（否则下面的断言毫无意义）
if grep -q '^rescue_evidence_prune() {' "$A/scripts/librescue.sh"; then fail 'requirementA-injection-ineffective'; fi
# 前置断言：控制组 —— 在该副本中直接调用该函数必须返回非 0
if ( DSH_HOME="$T/attach-home" sh -c ". '$A/scripts/librescue.sh'; rescue_clean_rescue_history" ) >/dev/null 2>&1; then
  fail 'requirementA-control-function-did-not-fail'
fi
# 主断言：即便 history 轮转失败，clean --yes 也必须正常结束（退出 0 且不中断）
mkdir -p "$T/attach-home/profiles/web"
printf '%s' '{"name":"web"}' > "$T/attach-home/profiles/web/package.json"
set +e
out15=$(DSH_HOME="$T/attach-home" sh "$A/scripts/rescue" clean --yes 2>&1)
rc15=$?
set -e
[ "$rc15" = 0 ] || fail "requirementA-clean-aborted-on-history-failure:rc=$rc15"
printf '%s' "$out15" | grep -q 'clean: done' || fail 'requirementA-clean-did-not-complete'
# 部分失败必须如实反映，不得静默吞掉
printf '%s' "$out15" | grep -q 'prune incomplete' || fail 'requirementA-partial-failure-not-reported'

# --- 15) 回滚交互红线：清理孤儿后仍能回滚到清理前的快照 ---
# 这是本设计的核心安全性质：clean 只删「当前 lockfile 未引用」的条目，而快照
# （hardlink 模式下 cp -al 对目录是新建目录 + 硬链接文件）里另有一份独立的目录项，
# 故回滚会连同 lockfile 一起还原，6.3.1 的条目重新可用。若后续改动破坏该性质，
# 用户就失去了「升级出问题 -> clean -> 回滚」这条自救路径。
R2="$T/home2"; export DSH_HOME="$R2"
mkdir -p "$R2/profiles/web"
printf '%s' '{"name":"web","dependencies":{"@wenaixi/dsh-superpower":"6.3.1"}}' > "$R2/profiles/web/package.json"
cat > "$R2/profiles/web/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '9.0'

packages:

  '@wenaixi/dsh-superpower@6.3.1':
    resolution: {integrity: sha512-yyy}

snapshots:
EOF
mkdir -p "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa"
printf '6.3.1' > "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa/index.js"

# 重新 source 以套用新 DSH_HOME（RESCUE_DIR / LOG_FILE 都按 DSH_HOME 派生）
. "$LIB"
RESCUE_KEEP=5 REASON_SNAPSHOT='pre-upgrade' rescue_snapshot >/dev/null 2>&1 || fail 'rollback-fixture-snapshot-failed'

# 升级：lockfile 指向新版本，旧版本变孤儿
sed -i 's/@wenaixi\/dsh-superpower@6.3.1/@wenaixi\/dsh-superpower@6.3.9/' "$R2/profiles/web/pnpm-lock.yaml"
printf '%s' '{"name":"web","dependencies":{"@wenaixi/dsh-superpower":"6.3.9"}}' > "$R2/profiles/web/package.json"
mkdir -p "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.9_peer_bb"
printf '6.3.9' > "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.9_peer_bb/index.js"

# 前置断言（防空洞）：升级后 lockfile 必须真的不再引用 6.3.1，否则下面的
# 「孤儿已被删除」断言会因为「它其实是被引用的、照理不该删」而失去意义。
grep -q '@wenaixi/dsh-superpower@6.3.9' "$R2/profiles/web/pnpm-lock.yaml" || fail 'setup-upgrade-lockfile-not-rewritten'
if grep -q '@wenaixi/dsh-superpower@6\.3\.1' "$R2/profiles/web/pnpm-lock.yaml"; then fail 'setup-old-version-still-locked'; fi

# 清理孤儿（6.3.1 已不被新 lockfile 引用）
command -v rescue_clean_pnpm_orphans >/dev/null 2>&1 || fail 'function-missing:rescue_clean_pnpm_orphans'
rescue_clean_pnpm_orphans "$R2/profiles/web" 0 >/dev/null 2>&1 || true
[ ! -d "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" ] || fail 'setup-orphan-not-removed'

# 回滚到 pre-upgrade 快照
snap=$(rescue_snapshot_list_by_time | head -n1)
[ -n "$snap" ] || fail 'no-snapshot-to-restore'
rescue_restore "${snap##*/}" >/dev/null 2>&1 || fail 'restore-failed-after-clean'

# 断言：回滚后 lockfile 与依赖树一致，且 6.3.1 条目重新可用
# 用整键匹配（锁文件里键写作 '@pkg@ver':）而不是纯子串，避免 6.3.19/6.3.1x 也被算作命中。
grep -qF "'@wenaixi/dsh-superpower@6.3.1':" "$R2/profiles/web/pnpm-lock.yaml" \
  || fail 'rollback-lockfile-not-restored'
[ -d "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" ] \
  || fail 'REGRESSION-rollback-target-missing-after-clean'

# 恢复默认 DSH_HOME，避免后续用例依赖「上一个用例留下的状态」
export DSH_HOME="$T/home"
. "$LIB"

# --- 16) dry-run 全盘零副作用：整棵目录树指纹比对（补充要求 1）---
# 既有 dry-run 用例（第 7、9 节）只抽查「某个已知目录还在不在」，无法捕捉
# 「dry-run 删除了**未抽查的其它文件**」这类回归。这里改为对整棵沙箱树做指纹比对：
# 铺好真实形态的残留（npm _cacache、profile .pnpm 孤儿、evidence/incident 目录），
# 跑 dry-run 前后要求指纹完全一致。
#
# 注意 rescue.log 必须排除在比对之外：dry-run 会写审计日志（记录「跳过了什么」是预期行为），
# 其大小/mtime 必然变化；把它算进指纹会让用例变成永远失败。日志以外的任何差异都算副作用。
dry_fp() {
  # $1 = 根目录。%y 类型 / %m 权限 / %s 大小 / %p 相对路径。
  # 不含 mtime（日志/目录 mtime 会被审计写入扰动），不含 %i（inode 跨运行不稳定）。
  ( cd "$1" && find . -printf '%y %m %s %p\n' 2>/dev/null | LC_ALL=C sort )
}

D="$T/dryrun-full"
mkdir -p "$D/home/profiles/web/node_modules/.pnpm" \
         "$D/home/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" \
         "$D/home/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.0-dsh.10_peer_bb" \
         "$D/home/.rescue/evidence/boot-1-20260901000000" \
         "$D/home/.rescue/incidents" \
         "$D/npmcache/_cacache/content-v2" \
         "$D/npmcache/_logs"
printf '%s' '{"name":"web","dependencies":{"@wenaixi/dsh-superpower":"6.3.0-dsh.10"}}' > "$D/home/profiles/web/package.json"
cat > "$D/home/profiles/web/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '9.0'

packages:

  '@wenaixi/dsh-superpower@6.3.0-dsh.10':
    resolution: {integrity: sha512-yyy}

snapshots:
EOF
printf 'old' > "$D/home/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa/index.js"
printf 'live' > "$D/home/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.0-dsh.10_peer_bb/index.js"
# 一个「不该被动到」的旁观目录：它既不是孤儿也没有被任何既有用例抽查。
# 没有它，本节只能证明「已知的几个残留没被删」；有了它，才能真正证明「dry-run 没删任何东西」。
mkdir -p "$D/home/profiles/web/node_modules/.pnpm/bystander-pkg@1.0.0_aa"
printf 'bystander' > "$D/home/profiles/web/node_modules/.pnpm/bystander-pkg@1.0.0_aa/index.js"
printf 'cache-blob' > "$D/npmcache/_cacache/content-v2/blob"
printf 'keepme' > "$D/npmcache/_logs/keep.log"
printf '%s' '{"id":"inc-1"}' > "$D/home/.rescue/incidents/inc-1.json"
printf 'ev' > "$D/home/.rescue/evidence/boot-1-20260901000000/dsh.log"
# 快照护栏：dry-run 连快照都不该拍，先造一份作为基线
DSH_HOME="$D/home" RESCUE_PROFILE=web sh -c ". '$LIB'; RESCUE_KEEP=5 rescue_snapshot" >/dev/null 2>&1 \
  || fail 'dryrun-full:fixture-snapshot-failed'

# 控制组：残留必须真的在场，否则「没被删」断言空洞通过（没有任何东西可删时自然一致）
[ -f "$D/npmcache/_cacache/content-v2/blob" ] || fail 'dryrun-full:fixture-npm-cache-missing'
[ -d "$D/home/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" ] || fail 'dryrun-full:fixture-orphan-missing'
[ -d "$D/home/.rescue/evidence/boot-1-20260901000000" ] || fail 'dryrun-full:fixture-evidence-missing'
[ -f "$D/home/.rescue/incidents/inc-1.json" ] || fail 'dryrun-full:fixture-incident-missing'

# 用真实 CLI 走真实路径（NPM_CONFIG_CACHE 指向沙箱缓存树）
dry_fp "$D" > "$D/fp.before"
[ -s "$D/fp.before" ] || fail 'dryrun-full:empty-fingerprint'
set +e
outdry=$(DSH_HOME="$D/home" RESCUE_PROFILE=web NPM_CONFIG_CACHE="$D/npmcache" sh "$RESCUE" clean -n 2>&1)
rc_dry=$?
set -e
[ "$rc_dry" = 0 ] || fail "dryrun-full:exit-nonzero:rc=$rc_dry"
dry_fp "$D" > "$D/fp.after"
# 指纹文件自身是上面两条重定向建出来的，必须排除在比对之外，否则必然 diff。
grep -v ' \./fp\.\(before\|after\)$' "$D/fp.before" > "$D/fp.before.clean"
grep -v ' \./fp\.\(before\|after\)$' "$D/fp.after" > "$D/fp.after.clean"

# 主断言：除审计日志外的整棵树指纹必须逐字节一致
if ! diff -u "$D/fp.before.clean" "$D/fp.after.clean" > "$D/fp.diff" 2>&1; then
  echo '--- dry-run full-tree fingerprint diff (before vs after) ---'
  cat "$D/fp.diff"
  fail 'dryrun-full:filesystem-side-effect'
fi

# 日志本身必须存在（证明 dry-run 真的走到了 clean 路径，而不是整条命令没执行），
# 同时它只能增长，不得被清空/截断
[ -s "$D/home/.rescue/log/rescue.log" ] || fail 'dryrun-full:audit-log-missing'
grep -q 'removed' "$D/home/.rescue/log/rescue.log" \
  && fail 'dryrun-full:dryrun-logged-removal'

# --- 17) 审计日志假成功回归：rm 失败时不得打印/记录 removed（补充要求 2）---
# 任务 3 修掉了「rm -rf 失败仍打印/记录 removed」的假成功问题，但当时无任何测试覆盖。
# 这里用 PATH shim 注入一个恒失败的 rm 真正触发失败分支。
# 为什么不能靠 chmod：本环境/镜像内是 root，root 无视目录权限位，rm -rf 照样成功。
R3="$T/home3"; export DSH_HOME="$R3"
mkdir -p "$R3/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa"
printf '6.3.1' > "$R3/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa/index.js"
printf '%s' '{"name":"web"}' > "$R3/profiles/web/package.json"
cat > "$R3/profiles/web/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '9.0'

packages:

  '@wenaixi/dsh-superpower@6.3.9':
    resolution: {integrity: sha512-yyy}

snapshots:
EOF
. "$LIB"
ORPHAN3='@wenaixi+dsh-superpower@6.3.1_peer_aa'

SHIM3="$T/bin-rmfail"; mkdir -p "$SHIM3"
cat > "$SHIM3/rm" <<'RMFAIL'
#!/bin/sh
# 恒失败的 rm：证明「删除失败」路径；但必须精确复现 rm -rf 的语义 ——
# 失败时不得删除，成功路径一律不在此分支。
printf 'rm-shim invoked: %s\n' "$*" >> "${RM_SHIM_LOG:-/dev/null}"
exit 1
RMFAIL
chmod +x "$SHIM3/rm"
export RM_SHIM_LOG="$T/rm-shim.log"
: > "$RM_SHIM_LOG"
SAVED_PATH3="$PATH"
export PATH="$SHIM3:$PATH"

# 控制组（关键）：先证明在这个 PATH 下 rm 确实失败了。
# 若 shim 未生效，后面的删除会成功、日志里自然没有 failed 记录，用例会「空洞通过」。
if rm -rf "$R3/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" 2>/dev/null; then
  export PATH="$SAVED_PATH3"
  fail 'logfailsuccess:control-rm-shim-ineffective'
fi
[ -s "$RM_SHIM_LOG" ] || { export PATH="$SAVED_PATH3"; fail 'logfailsuccess:control-rm-shim-not-invoked'; }
[ -d "$R3/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" ] || \
  { export PATH="$SAVED_PATH3"; fail 'logfailsuccess:control-orphan-removed-despite-failure'; }

# 被测函数：真实清理路径下删除必然失败
rescue_clean_pnpm_orphans "$R3/profiles/web" 0 >/dev/null 2>&1 || true
# 还原 PATH 后再读日志/做断言，避免后续任何 sh 调用受影响
export PATH="$SAVED_PATH3"

LOG3="$R3/.rescue/log/rescue.log"
[ -f "$LOG3" ] || fail 'logfailsuccess:audit-log-missing'

# 主断言 ①：审计日志必须如实记录失败
grep -q "clean: failed to remove orphan $ORPHAN3" "$LOG3" || fail 'logfailsuccess:no-failure-record'
# 主断言 ②：审计日志绝不得出现该条目的假成功记录
if grep -q "clean: removed pnpm orphan $ORPHAN3" "$LOG3"; then
  echo '--- audit log ---'; cat "$LOG3"
  fail 'logfailsuccess:false-success-recorded'
fi
# 主断言 ③：条目确实没被删（失败的事实与日志一致）
[ -d "$R3/profiles/web/node_modules/.pnpm/$ORPHAN3" ] || fail 'logfailsuccess:entry-vanished-despite-rm-failure'

export DSH_HOME="$T/home"
. "$LIB"

echo 'ALL-PASS'
