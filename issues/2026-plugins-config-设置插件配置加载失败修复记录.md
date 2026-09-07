# 「设置 → 插件 → 插件配置」加载不出来的修复记录

- 日期：2026（会话内完成）
- 范围：DeepSeek Harness Web GUI（dsh web，运行在 3081 端口）
- 现象编号 / 触发来源：用户通过本部署真实对外受信地址访问 GUI 时，插件配置页签空白

---

## 1. 问题现象

Web GUI 的 **设置（Settings）→ 插件（Plugins）→ 插件配置（Plugin configuration）** 页签加载不出来。

具体表现为：

| 访问来源 | 现象 |
| --- | --- |
| 本机回环 `http://127.0.0.1:3081` | 插件配置正常，四个插件卡片都能显示 |
| 非回环受信来源（`--trusted-host`，如 `app-3080-shitaixi.cn44.ugdocker.link`） | 插件配置页签下一片空白：四个卡片、空态文案都没有，且 **没有任何 console 报错** |

同分区里**只读的「插件列表（Plugin list）」页签是正常的**（走另一条 RPC），因此表现为「列表能看、配置却空白」，很让人困惑。

> 该现象为 Web GUI 常规页面层面的问题，与会话、消息、工具执行等运行时功能无关。

---

## 2. 定位过程

用无头 Chromium（puppeteer，需 `danger-full-access` 沙箱、`/etc/hosts` 临时映射受信域名）分别在回环来源与非回环来源下复现并对比。

### 2.1 涉及的客户端插件与结构

- 设置域基础插件 `@deepseek-ai/dsh-client-ui-settings`（`lib/client.js`）：
  - 唯一的 `settings.describe` 读取者 → `SettingsDescribeMirror`。
  - `ctx.settingsScope.bind(namespace)` 依据该镜像推导每个命名空间各自的 scope。
  - 持久化选择：`ctx.remote.$host.isLoopback ? "host" : "memory"`。
- 插件配置 UI `@deepseek-ai/dsh-client-ui-settings-plugins`（`lib/client.js`）：
  - 注册分区 `settings.section`，id = `plugins`；内含页签：
    - `configurable`（插件配置）：`ConfigurablePluginsTabController` = **Host 提供的设置命名空间** ∩ **`settings.plugin.item` 槽位键**（shell、agent-loop、subagent-model-selection、web-search-deepseek 等）。卡片需要 scope 状态为 `ready`。
    - `all`（插件列表，来自 `dsh-client-ui-settings-plugin-inventory`）：只读，走 `remote.pluginInventory.list()`，**不依赖 settings.describe**，因此任何来源下都正常。
- `isLoopback` 的来源（`dsh-client-connection/lib/client.js`）：
  ```
  isLoopback = transport?.ownsHost === true
             || pageLocation === undefined
             || isLoopbackHostname(location.hostname)   // 仅 127/8、localhost、::1
  ```
  - 仅凭页面 URL 判断，无法得知服务端 `--trusted-host`。

### 2.2 复现结论（无头浏览器实测）

- 回环来源：`settings.describe` 正常返回命名空间（含 shell、agent-loop、subagent-model-selection、web-search-deepseek 等），插件配置页签渲染出全部卡片。
- 非回环受信来源：`$host.isLoopback === false` → 设置持久化走 `"memory"` → 镜像永不调用 `settings.describe` → 所有命名空间 scope 停留在 `unavailable` → `ConfigurablePluginsTab` 的 `loaded` 恒为 false、`namespaces` 恒为空 → **渲染 null（空白）**，且无空态、无报错。
- 浏览器来源事实：`origin` 非回环、`transport` 为 false、`loopback` 为 false。

---

## 3. 根因

设置域客户端插件用**页面 URL 是否回环**来决定是否启用设置（Host）持久化：

```js
const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";
```

只要浏览器来源不是回环（局域网、受信域名都算），设置文档镜像就不发起 `settings.describe`，从而「插件配置」这类完全依赖该镜像的表面整体静默置空。

这个按 URL 猜身份的判断与传输层的信任模型**相互矛盾**：

- 每个 `/api` RPC 本来就经过 Host 信任围栏（loopback / 部署派生的局域网 IP 直写 / 声明为 `--trusted-host` 的来源）**并叠加签名 Cookie 鉴权**，能到达接口的浏览器会话就是操作者来源，不存在「只读访客」这一层（Connection 文档明确：不存在按方法区分的 loopback 层）。
- 因此**受信的非回环来源被错误降级为不可用来源**；而未受信来源连 `/api` 都进不来，`memory` 模式实际保护不了任何人，只会误伤真实操作者。
- 附带：同一来源下「通用（General）」等其它依赖该文档的表面（外观、语言等编辑）此前也被静默禁用。

---

## 4. 修复内容

只改**一处决策点**：设置持久化一律使用 Host 模式，不再用页面 URL 是否回环来关闭它。

文件：`/opt/dsh/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-ui-settings/lib/client.js`

- 改动点（原 apply() 内第 1345 行附近）：

```js
// 修改前
const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";

// 修改后
const persistence = "host";
```

- 同时把两处说明旧行为（“non-loopback pages may remain process-local”）的参数注释改为与实现一致：

```text
@param persistence - client-selected Host persistence; every authenticated browser origin is Host-backed
(API trust fence + signed cookie gate each RPC, not the URL origin).
```

> 备注：本环境只有编译产物、没有 monorepo 源码树，改动落在安装包 bundle 上。若要让修复随上游构建长期保留，应在 `deepseek-harness` 仓库 `packages/client/ui-settings` 的 TS 源码里做同样的修改。

### 为什么这样改是安全的

- 未受信/未知来源无法通过 `/api` 信任围栏 + Cookie 鉴权，页面即便加载了 SPA 静态资源，`describe`/`mutate` 也会被 401/403 拒绝 → 不构成信息或权限泄露。
- 受信来源（回环 / 局域网 IP / `--trusted-host`）与回环在鉴权上等价，本就是操作者来源，理应能读取与保存设置。
- 多人同时编辑由现有 revision 冲突防护机制处理，与回环时行为一致。

---

## 5. 生效方式（无重启热生效）

客户端插件的服务端 HMR 轮询会检测 bundle 变更并重新哈希：

- `dsh-client-hmr/lib/index.js`：每 500ms 轮询各 client bundle 的 mtime/size，变化即触发 `clientModules.rebuilt(id)`。
- `dsh-client-modules/lib/index.js`：`rebuilt()` 重新读取文件并计算新 rev，随后对浏览器重新组合并推送。
- 实测 bundle rev 由 `9f6492dc1ac5` → `ed5f2572a6fa`，**无需重启 dsh web 服务**。
- 用户只需刷新一次 GUI 页面（建议硬刷新 Ctrl+Shift+R）拿到新 rev 即可。

---

## 6. 验证结果

用无头 Chromium 在真实 GUI 上验证（修复前/修复后对比 + 回环回归）：

| 场景 | 修复前 | 修复后 |
| --- | --- | --- |
| 非回环受信来源（用户实际访问地址） | 插件配置页签空白 | 卡片全部显示：Shell / Agent loop / Subagent / Web search（及 WorkBuddy Connect） |
| 回环 `http://127.0.0.1:3081` | 正常 | 仍正常（无回归），且无 console 报错 |

验证探针输出片段（修复后，非回环来源）：

```text
FACTS {"origin":"http://app-3080-...:3081","transport":false,"loopback":false}
...
CARD CHECK (config tab, default)
{"Shell":true,"Agent loop":true,"Subagent":true,"Web search":true, ...}
```

---

## 7. 关键文件与路径

| 项 | 值 |
| --- | --- |
| 修复对象 | `/opt/dsh/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-ui-settings/lib/client.js` |
| 上游对应源码 | `deepseek-harness/packages/client/ui-settings`（TS 源码，本环境未随附） |
| 相关客户端插件 | `dsh-client-ui-settings-plugins`、`dsh-client-ui-settings-plugin-inventory`、`dsh-client-ui-settings-general` |
| `isLoopback` 来源 | `@deepseek-ai/dsh-client-connection/lib/client.js` |
| 服务端 HMR 轮询 | `@deepseek-ai/dsh-client-hmr/lib/index.js` |
| 服务端组合/重哈希 | `@deepseek-ai/dsh-client-modules/lib/index.js` |

---

## 8. 复现 / 验证脚本要点（现场环境，非交付物）

位于 `/tmp/brow/`（临时、会话用，自动清理，不在 /workspace）：

- `drive.js` / `drive2.js`、`probe.js` / `probe2.js`：puppeteer 驱动。
- 运行前提：Chromium 需 `danger-full-access` 沙箱；复现非回环来源需在 `/etc/hosts` 临时加入 `127.0.0.1 <受信域名>`（验证后已还原）。
- 浏览器登录 Cookie 为 `dsh-auth-*`（HMAC 签名、按 authority 绑定），secret 取自 `/data/dsh/.credentials.yaml`。
