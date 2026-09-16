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

echo 'ALL-PASS'
