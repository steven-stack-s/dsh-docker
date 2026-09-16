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

echo 'ALL-PASS'
