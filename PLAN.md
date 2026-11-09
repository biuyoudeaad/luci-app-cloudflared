# luci-app-cloudflared 优化开发计划

> 目标版本：v1.1.0（多隧道 / 域名热重载 / 界面安装核心 / 界面授权）
>
> 本文档为可执行开发计划，按阶段推进；每个阶段都有明确改动文件、验收标准与测试项。
>
> **开发进度**：阶段 A–G 全部代码与本地自动化测试已完成；剩余未勾选项仅为**真实设备 / Cloudflare 账号实测**。
> 本地测试：`sh tests/run.sh`；设备自检：`sh tests/device-check.sh`；实测清单：`tests/DEVICE_TEST.md`。

---

## 1. 背景与目标

当前项目已实现单隧道、单域名的 LuCI 管理，但存在三个明显短板：

1. **切换域名后无法热重载**：修改 `main.domain` 只更新了 UCI，不会重写 ingress hostname、不会重建 config.yml，DNS 仍按旧 hostname 处理。
2. **不支持多域名 / 多隧道**：全局只有一份 `config.yml`、一个 tunnel JSON、一个 cert，`procd` 只启动一个实例。
3. **不支持界面安装 Cloudflare Tunnel 核心**：下载、架构判断、登录、建隧道全部依赖 `tools/setup.sh`。

本次优化目标：

- [x] 支持**多隧道**，每个隧道绑定一个根域名，独立 `config.yml` / cert / credentials / 运行实例。
- [x] 提供**域名切换热重载按钮**：改域名后一键重写 hostname、重建配置、同步 DNS、重启服务。
- [x] 提供**界面安装/更新 cloudflared 核心**：自动识别架构、下载、校验版本、原子替换。
- [x] 提供**界面授权**：后台 `cloudflared login` + 页面显示 URL + 轮询结果，同时支持上传 `cert.pem` / 隧道 JSON。
- [x] 保持对旧版单隧道配置的平滑升级，升级后旧配置自动迁移为 `default` 隧道。
- [x] 修复现有 DNS 同步的跨隧道误删风险，杜绝保存时误删其他隧道记录。

### 1.1 已确认的设计取舍

| 决策点 | 结论 |
|---|---|
| “多域名”含义 | **多隧道，每个隧道一个域名**（不是单隧道跨多根域名） |
| 界面安装核心范围 | 先做**下载/更新二进制 + 版本检测**，不做完整建隧道向导 |
| 授权方式 | **两种都支持**：后台 login + URL 轮询，以及手动上传 cert/credentials |

---

## 2. 现状问题定位

| 问题 | 文件 / 位置 | 说明 |
|---|---|---|
| 单实例 | `root/etc/init.d/cloudflared:54-59` | 只 `procd_open_instance` 一次，读取单一 `config.yml` |
| 单域名 | `root/usr/lib/lua/luci/model/cbi/cloudflared/main.lua:146-149` | 只读 `main.domain` |
| 保存即重建单配置 | `main.lua:471-556` | `on_after_commit` 固定写 `$base_path/config.yml` |
| DNS 误删风险 | `main.lua:545-551` | 删除所有不在全局 hostname 集合中的记录 |
| 域名切换不重写 hostname | `main.lua:528-552` | 只改 `main.domain`，ingress 仍是旧域名 |
| 热更新脚本强制删证书 | `root/usr/bin/cloudflared-hotupdate:288-297` | cert 是账号级，同账号换域名无需重新登录 |
| 无核心安装入口 | 仅 `tools/setup.sh` | LuCI 无下载/更新能力 |
| 依赖缺少 CA | `Makefile:8` | HTTPS 下载依赖 CA 证书包 |

---

## 3. 目标架构

### 3.1 组件关系

```
┌─────────────────────────────────────────────────────────────┐
│ LuCI (Lua CBI / controller)                                 │
│  overview.lua   tunnels.lua   ingress.lua                   │
│        │             │            │                         │
│        └─────────────┴────────────┴──────────────┐          │
│                         luci/cloudflared/common.lua          │
│                         controller/cloudflared.lua (action)  │
└─────────────────────────────┬───────────────────────────────┘
                              │ sys.call / HTTP action
┌─────────────────────────────▼───────────────────────────────┐
│ cloudflared-ctl (shell)                                     │
│  gen-config / domain-switch / dns-sync / login-* / core-*   │
│                    │                                        │
│         /usr/lib/cloudflared/common.sh                      │
└─────────────────────────────┬───────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────┐
│ /etc/init.d/cloudflared  ->  procd 多实例                    │
│   tunnel_default  tunnel_office  ...                        │
└─────────────────────────────────────────────────────────────┘
```

**原则：所有特权/共享逻辑收敛到 `cloudflared-ctl` + `common.sh`，Lua 只做 UI、校验、状态展示和 HTTP action 调度。**

### 3.2 目录布局

```
/opt/cloudflare/
├── cloudflared                      # 核心二进制（可被 UI 安装/更新）
├── cert.pem                         # 全局默认证书（兼容旧配置）
├── tunnels/
│   ├── default/                     # 旧配置迁移后仍指向 /opt/cloudflare
│   ├── office/
│   │   ├── cert.pem                 # 可选，缺省继承全局
│   │   ├── <tunnel_id>.json
│   │   ├── config.yml
│   │   ├── config.yml.bak1
│   │   └── config.yml.bak2
│   └── home/
│       └── ...
└── .tmp/                            # 下载/上传临时文件
```

### 3.3 UCI 数据模型

保持 `main` 作为全局段，新增 `tunnel` 段，`ingress` 增加归属字段。

```uci
config main 'main'
    option base_path '/opt/cloudflare'
    option cloudflared_path ''
    option api_token ''
    option config_version '2'
    option download_url 'https://github.com/cloudflare/cloudflared/releases/latest/download'
    option allow_dns_delete '0'

config tunnel 'default'
    option name 'default'
    option enabled '1'
    option domain 'example.com'
    option tunnel_id 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
    option data_dir '/opt/cloudflare'
    option cert_path '/opt/cloudflare/cert.pem'
    option credentials_file '/opt/cloudflare/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.json'
    option api_token ''                 # 可选，跨账号覆盖全局
    option applied_domain 'example.com'

config tunnel 'office'
    option name 'office'
    option enabled '1'
    option domain 'office.com'
    option tunnel_id 'yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy'
    option data_dir '/opt/cloudflare/tunnels/office'
    option cert_path ''
    option credentials_file ''
    option api_token ''
    option applied_domain 'office.com'

config ingress 'rule1'
    option tunnel 'default'
    option hostname 'app.example.com'
    option service 'http://192.168.1.10:8080'
```

约定：

- `tunnel.name` 用于展示，`tunnel` 的 section 名用于内部引用。
- `tunnel_id` 全局唯一，保存时校验。
- `data_dir` 为空时按 `$base_path/tunnels/<section>` 计算；`default` 迁移后固定为 `$base_path`。
- `cert_path` 为空时继承 `main.cert_path` 或 `$base_path/cert.pem`。
- `ingress.hostname` 统一存完整 FQDN，UI 不做“子域 + 后缀”自动拼接，降低多隧道联动复杂度。
- `applied_domain` 与 `domain` 不一致时，页面提示“域名已修改，需要热重载”。

---

## 4. 分阶段开发计划

### 阶段 A：统一后端（基础，必须先做）

**目标**：把 config 生成、binary 查找、证书解析、DNS 同步、核心安装收敛到脚本，避免 Lua / init / hotupdate 三处重复。

#### A1. 新增 `root/usr/lib/cloudflared/common.sh`

- [x] 颜色/日志函数：`info` / `warn` / `error` / `step`。
- [x] `require_root`。
- [x] `cf_get <section> <option> [default]`：封装 `uci -q get`。
- [x] `cf_base_path`：读取 `main.base_path`，默认 `/opt/cloudflare`。
- [x] `cf_find_binary`：自定义路径 -> `base/cloudflared` -> `base/cloudflared-linux-*` -> `/usr/bin/cloudflared`。
- [x] `cf_tunnel_dir <section>`：返回 `data_dir`，空则按 `$base_path/tunnels/<section>`；`default` 且旧布局存在时返回 `$base_path`。
- [x] `cf_cert_path <section>`：隧道 cert -> 全局 cert -> `$base/cert.pem`。
- [x] `cf_credentials <section>`：`credentials_file` -> `dir/<tunnel_id>.json` -> 目录内首个 `*.json`。
- [x] `cf_config_path <section>`：默认 `dir/config.yml`。
- [x] `cf_gen_config <section>`：按 UCI 生成 YAML，原子写入 + 滚动备份 `.bak1/.bak2`。
- [x] `cf_domain_rewrite <section> <old> <new>`：重写该隧道 ingress hostname。
- [x] `cf_dns_sync <section>`：用 `cloudflared tunnel --origincert ... route dns` 创建缺失记录。
- [x] `cf_restart [section]`：重启 `/etc/init.d/cloudflared`（当前整服务重启）。

**验收**：`sh -n root/usr/lib/cloudflared/common.sh` 通过；函数可被 `cloudflared-ctl` 与 `init.d` source。

#### A2. 新增 `root/usr/bin/cloudflared-ctl`

子命令设计：

```
cloudflared-ctl gen-config <section>
cloudflared-ctl get-config-path <section>
cloudflared-ctl domain-switch <section> <new_domain> [--rewrite-hosts] [--sync-dns] [--no-restart]
cloudflared-ctl dns-sync <section>
cloudflared-ctl login-start <section>
cloudflared-ctl login-status <section>
cloudflared-ctl install-cert <section> <file>
cloudflared-ctl install-credentials <section> <file>
cloudflared-ctl core-install [version|url]
cloudflared-ctl core-status
cloudflared-ctl version [binary]
cloudflared-ctl status <section>
```

统一输出约定：

- 正常结果输出到 stdout，人可读。
- 需要机器解析的命令（`core-status`、`login-status`）输出 `key=value` 行，便于 Lua 解析。
- 错误输出到 stderr，退出码非 0。
- 后台任务（`login-start`、`core-install`）写状态文件：
  - `/tmp/cloudflared/login-<section>.log`
  - `/tmp/cloudflared/login-<section>.status`
  - `/tmp/cloudflared/core-install.log`
  - `/tmp/cloudflared/core-install.status`

**验收**：每个子命令在本地 `sh -n` 通过；`gen-config` 能根据 UCI 生成合法 YAML。

#### A3. 新增 `root/usr/lib/lua/luci/cloudflared/common.lua`

- [x] `shellquote(s)`。
- [x] `find_binary()` / `resolve_cert(section)` / `tunnel_dir(section)`。
- [x] `list_tunnels()`：返回 section -> 配置表。
- [x] `gen_config(section)`：调用 `cloudflared-ctl gen-config`。
- [x] `restart_service()`：调用 `/etc/init.d/cloudflared restart`。
- [x] `run_ctl(...)`：统一执行 `cloudflared-ctl` 并返回 stdout/stderr/exit code。
- [x] `cf_api(method, path, token)`：保留现有 curl + `luci.jsonc` 逻辑。
- [x] `get_zone_id` / `fetch_tunnel_dns`：改为按 tunnel 维度调用。
- [x] `read_status_file(path)`：解析 `key=value` 状态文件。
- [x] 路径校验 `is_safe_path`，防止 action 参数注入任意路径。

**验收**：`main.lua` 中现有 helper 逐步替换为公共模块调用，无行为回退。

#### A4. 更新 `root/usr/bin/cloudflared-hotupdate`

- [x] 默认**不删除** `cert.pem`。
- [x] 新增 `--reauth`，只有显式指定才删除并重新登录。
- [x] 新增 `--tunnel <section>`，默认 `default`。
- [x] `--domain` 改为调用 `cloudflared-ctl domain-switch`。
- [x] 配置生成统一调用 `cloudflared-ctl gen-config`。
- [x] `--help` 同步更新。

**验收**：同账号切换域名无重新登录；`--reauth` 行为与旧脚本一致。

---

### 阶段 B：多隧道数据模型与 init 改造

#### B1. 迁移脚本 `root/etc/uci-defaults/99-cloudflared`

- [x] 幂等：重复执行不产生重复 `tunnel` 段。
- [x] 若不存在 `tunnel` 段且旧 `main.domain` 存在：
  - [x] 从旧 `*.json` 提取 `tunnel_id`；
  - [x] 创建 `tunnel 'default'`，继承 `domain` / `cert_path` / `tunnel_id` / `data_dir=$base_path`；
  - [x] `applied_domain=domain`。
- [x] 给没有 `tunnel` 的 `ingress` 补 `option tunnel 'default'`。
- [x] 写入 `main.config_version='2'`。
- [x] 保留 `mkdir -p /opt/cloudflare`、`chmod +x init.d`、`enable` 原有行为。

**验收**：旧版 `/etc/config/cloudflared` 升级后自动生成 `default` 隧道，ingress 全部归属正确；再次执行无变化。

#### B2. `root/etc/init.d/cloudflared`

- [x] `start_service` 加载 UCI 并遍历 `tunnel`。
- [x] 新增 `start_one()`：校验 `enabled`，调用 `cloudflared-ctl gen-config`，再 `procd_open_instance "tunnel_<sec>"`。
- [x] `procd_set_param command "$BIN" --config "$CFG" tunnel run`。
- [x] 保留 `respawn` / `stdout` / `stderr`。
- [x] 找不到 binary 时记录 logger 并跳过，不影响其他隧道。
- [x] 单个隧道配置缺失时记录日志并跳过。
- [x] `stop_service` 保持空，由 `procd` 统一管理。

**验收**：两个 `tunnel` 段时 `ps` 能看到两个 cloudflared 进程；停用一个不影响另一个。

#### B3. 兼容性

- [x] `default` 隧道继续使用旧 `$base_path/config.yml`，避免升级后找不到配置。
- [x] 新隧道使用 `$base_path/tunnels/<section>/config.yml`。
- [x] 旧 `cloudflared-hotupdate` 命令行为保持兼容（不带参数时只刷新证书/配置，不删除证书）。

---

### 阶段 C：LuCI 页面拆分与 action 框架

#### C1. 控制器 `root/usr/lib/lua/luci/controller/cloudflared.lua`

```lua
module("luci.controller.cloudflared", package.seeall)

function index()
    entry({"admin", "services", "cloudflared"},
        alias("admin", "services", "cloudflared", "overview"),
        _("Cloudflared"), 90).dependent = true

    entry({"admin", "services", "cloudflared", "overview"},
        cbi("cloudflared/overview"), _("Overview"), 1)

    entry({"admin", "services", "cloudflared", "tunnels"},
        cbi("cloudflared/tunnels"), _("Tunnels"), 2)

    entry({"admin", "services", "cloudflared", "ingress"},
        cbi("cloudflared/ingress"), _("Ingress"), 3)

    entry({"admin", "services", "cloudflared", "action"},
        post("action"), nil).leaf = true
end
```

- [x] `overview`：状态、全局设置、核心安装/更新、服务控制。
- [x] `tunnels`：隧道列表、增删、启用、域名、热重载、授权、上传。
- [x] `ingress`：ingress 规则，增加隧道下拉列。
- [x] `action`：POST JSON action 入口。
- [x] 保留旧 `main` 路径 302/alias 到 `overview`，避免书签失效。

#### C2. action 接口设计

统一路径：`POST /admin/services/cloudflared/action`

请求参数：`action=<name>` + 业务参数 + CSRF `token`。

| action | 参数 | 返回 |
|---|---|---|
| `domain_switch` | `section`, `new_domain`, `rewrite_hosts`, `sync_dns`, `restart` | `{ok, old, new, rewritten, dns_created, restarted, message}` |
| `dns_sync` | `section` | `{ok, created, deleted, message}` |
| `core_install` | `url` 可选 | `{ok, job_id, message}` |
| `core_status` | — | `{ok, state, version, message, log_tail}` |
| `login_start` | `section`, `force` | `{ok, url, job_id, message}` |
| `login_status` | `section` | `{ok, state, url, message}` |
| `upload_cert` | `section` + file | `{ok, path, message}` |
| `upload_credentials` | `section` + file | `{ok, tunnel_id, message}` |
| `tunnel_delete` | `section` | `{ok, message}` |
| `service` | `op=start|stop|restart` | `{ok, message}` |

实现要求：

- [x] 所有 action 先校验 `section` 存在，且只能操作 `cloudflared` UCI 中已知 section。
- [x] 所有 shell 参数通过 `shellquote` 或 `cloudflared-ctl` 参数传递，禁止字符串拼接执行。
- [x] 上传文件限制大小（如 64KB），校验 PEM/JSON 格式。
- [x] action 返回 `application/json`，失败返回 `{ok:false, message=...}`。
- [x] CSRF：沿用 CBI token 机制，前端从页面取 hidden `token` 一并提交。

#### C3. 前端交互

- [x] 新增 `root/usr/lib/lua/luci/view/cloudflared/action.js`（或内联 `<script>`）封装：

```js
async function cfAction(action, params) {
  const body = new URLSearchParams(params || {});
  const tk = document.querySelector('input[name=token]');
  if (tk) body.set('token', tk.value);
  body.set('action', action);
  const res = await fetch(window.location.pathname.replace(/\/[^/]+$/, '/action'), {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body
  });
  return res.json();
}
```

- [x] 长任务（core install / login）轮询状态，显示日志尾部。
- [x] 按钮操作期间禁用并显示 loading 状态。
- [x] 失败时 `alert` 或页面内红色提示，不使用 `console.log` 作为唯一反馈。

**验收**：三个 Tab 可正常打开；`action` 可通过 curl 带 token 调用并返回 JSON。

---

### 阶段 D：域名切换 + 热重载按钮

#### D1. 后端 `cloudflared-ctl domain-switch`

流程：

1. 校验 `<section>` 存在、`new_domain` 合法（沿用 `hotupdate` 的 `domain_is_valid`）。
2. 读取旧域名（优先 `applied_domain`，其次 `domain`）。
3. 若 `--rewrite-hosts`：
   - 遍历该隧道所有 ingress；
   - 若 hostname 等于旧域名 -> 替换为新域名；
   - 若 hostname 以 `.<old_domain>` 结尾 -> 保留前缀，替换后缀；
   - 其他域名保持不变并输出警告。
4. `uci set cloudflared.<section>.domain=<new_domain>`；
5. `uci set cloudflared.<section>.applied_domain=<new_domain>`；
6. `uci commit cloudflared`；
7. `cloudflared-ctl gen-config <section>`；
8. 可选 `dns-sync <section>`；
9. 可选重启服务；
10. 输出统计：`rewritten=N dns_created=M`。

边界：

- [x] 新域名与旧域名相同：直接返回 no-op。
- [x] 任意 ingress hostname 未匹配旧域名：不删除、不改写，仅警告。
- [x] 不删除任何 DNS 记录，除非显式 `allow_dns_delete=1`。

#### D2. 前端 Tunnels 页面

- [x] 每个隧道行展示：`name`、`enabled`、`domain`、`applied_domain`、状态、tunnel id 摘要。
- [x] 域名输入框旁增加 `Hot Reload` 按钮。
- [x] 点击时提示即将改写多少条 hostname（前端无法精确统计时，后端返回统计并提示）。
- [x] 增加选项：
  - `重写 ingress hostname`（默认勾选）
  - `同步 DNS`（默认勾选）
  - `重启服务`（默认勾选）
- [x] 成功后显示 `old -> new`、改写条数、DNS 创建数，并刷新页面。
- [x] `applied_domain != domain` 时行内显示黄色提示“待热重载”。

#### D3. `on_after_commit` 收敛

- [x] `overview` / `tunnels` / `ingress` 保存后，只重建受影响隧道的 config。
- [x] 默认不删除 DNS 记录。
- [x] 删除孤立记录需 `main.allow_dns_delete=1`，且只删除 `content == <当前 tunnel_id>.cfargotunnel.com` 的记录。
- [x] 保存后不强制重启，除非配置实际变化；重启交给按钮或 `service` action。

**验收**：
- 同账号 `old.com -> new.com`：hostname 正确改写、新 config 生效、新 CNAME 创建、服务重启、cert 不变。
- 存在其他域名 hostname 时不被误改。
- 多隧道下删除某条 ingress 不影响其他隧道 DNS。

---

### 阶段 E：界面安装/更新 cloudflared 核心

#### E1. 后端 `cloudflared-ctl core-install`

- [x] 架构映射（`uname -m`）：
  - `aarch64|arm64` -> `cloudflared-linux-arm64`
  - `x86_64|amd64` -> `cloudflared-linux-amd64`
  - `armv7l|armhf` -> `cloudflared-linux-arm`
  - `i386|i686` -> `cloudflared-linux-386`
  - `mips` -> `cloudflared-linux-mips`
  - `mipsel` -> `cloudflared-linux-mipsle`
  - 未知架构直接报错并提示手动安装。
- [x] 目标路径优先级：`main.cloudflared_path` -> `$base_path/cloudflared` -> `/usr/bin/cloudflared`。
- [x] 下载 URL：`main.download_url` 或默认 GitHub `latest/download`，支持镜像。
- [x] 使用 `curl -fL --retry 3 --connect-timeout 10 -o "$tmp"`。
- [x] 下载前检查磁盘空间（`df -k`），不足 64MB 给出警告/报错。
- [x] `chmod 755`，执行 `"$tmp" --version` 验证。
- [x] 备份旧文件为 `cloudflared.old`，`mv` 原子替换。
- [x] 后台执行，状态写入 `/tmp/cloudflared/core-install.status`：
  - `state=downloading|verifying|done|failed`
  - `version=x.y.z`
  - `message=...`
- [x] 失败时清理临时文件，保留旧二进制。

#### E2. 前端 Overview 页面

- [x] 展示：架构、当前版本、目标路径、最新版本（可选）。
- [x] 按钮：`Install / Update`、`Check Latest`。
- [x] 异步轮询 `core_status`，显示下载/校验/完成状态和日志尾部。
- [x] 更新完成后提示“核心已更新，点击重启服务生效”，或自动重启（可配置）。
- [x] 空间不足/架构不支持时显示明确错误。

#### E3. 依赖

- [x] `Makefile`：`LUCI_DEPENDS:=+curl +ca-bundle +luci-base`。
- [x] `build.yml` 的 `Depends:` 同步增加 `ca-bundle`。
- [x] README 说明小闪存设备注意事项（二进制约 30–50MB）。

**验收**：
- `aarch64` / `x86_64` 各测一次下载、版本识别、更新替换、服务重启。
- 断网/空间不足/架构不支持时错误提示清晰，旧二进制不受损。

---

### 阶段 F：界面授权（login + 上传）

#### F1. 后台 login

- [x] `cloudflared-ctl login-start <section>`：
  - 若已有 cert 且未 `--force`：提示已存在并退出；
  - 备份现有 cert（`.bak`）而非直接删除；
  - 后台运行 `cloudflared login`，stdout/stderr 写入 `/tmp/cloudflared/login-<section>.log`；
  - 从日志提取 `https://dash.cloudflare.com/argotunnel?...` 写入 status；
  - 记录 PID，支持取消。
- [x] `cloudflared-ctl login-status <section>`：
  - 读取日志中 URL；
  - 检测进程是否存活；
  - 检测 cert 是否出现；
  - 出现后复制到隧道 `cert_path`，`chmod 600`，更新 UCI。
- [x] 超时（默认 600 秒）后终止进程并标记 `failed/timeout`。

#### F2. 上传 cert / credentials

- [x] `cloudflared-ctl install-cert <section> <file>`：
  - 校验文件包含 `BEGIN CERTIFICATE` 或 PEM 头；
  - 大小限制；
  - 写入 `data_dir/cert.pem`，权限 `600`；
  - 更新 `tunnel.cert_path` / `main.cert_path`。
- [x] `cloudflared-ctl install-credentials <section> <file>`：
  - 校验 JSON 可解析，含 `TunnelID`、`TunnelSecret`、`AccountTag`；
  - 写入 `data_dir/<TunnelID>.json`，权限 `600`；
  - 更新 `tunnel.tunnel_id` / `tunnel.credentials_file`。
- [x] Lua action 使用 LuCI 文件上传能力接收，不在 Lua 中拼接 shell 文件内容。

#### F3. 前端 Tunnels 页面

- [x] 每个隧道行增加：
  - `Authorize`（后台 login）
  - `Upload cert.pem`
  - `Upload credentials.json`
  - `Hot Reload`
- [x] 登录弹窗/区域显示授权 URL、复制按钮、状态（等待中/成功/超时/失败）。
- [x] 提示 headless 场景：浏览器回调可能到不了路由器，推荐授权后下载 cert.pem 上传。
- [x] 上传成功后提示点击 `Hot Reload` 应用。

**验收**：
- 后台 login 能显示 URL，授权成功后 cert 落到正确目录。
- 上传 cert/json 后隧道能启动。
- 错误文件（非 PEM / 非 JSON / 缺字段）被拒绝且有提示。

---

### 阶段 G：DNS 安全、文档、CI

#### G1. DNS 安全

- [x] 所有 DNS 查询按隧道维度：`fetch_tunnel_dns(token, tunnel_id, domain)`。
- [x] 删除条件必须同时满足：
  - `main.allow_dns_delete=1`；
  - 记录 `content == <tunnel_id>.cfargotunnel.com`；
  - hostname 不在该隧道 ingress 集合中。
- [x] 保存页面显示“将删除的 DNS 记录”预览，需二次确认。
- [x] 多隧道同 zone 测试用例必须覆盖。

#### G2. CI / 打包

- [x] `build.yml` 增加执行权限：

```yaml
chmod 755 build/data/usr/bin/cloudflared-ctl
chmod 755 build/data/usr/lib/cloudflared/common.sh
chmod 755 build/data/etc/init.d/cloudflared
chmod 755 build/data/etc/uci-defaults/99-cloudflared
```

- [x] 打包前对 shell 脚本做 `sh -n` 语法检查。
- [x] 如可行，在 CI 中加入 `luac -p`（需安装 lua5.1）检查 Lua 语法。
- [x] `Makefile` 更新依赖与 `PKG_RELEASE`。

#### G3. 文档

- [x] README 增加：
  - 多隧道配置说明；
  - 域名热重载按钮使用说明；
  - 界面安装/更新核心说明；
  - 授权两种方式；
  - 升级迁移说明；
  - 常见问题（空间不足、回调失败、DNS 权限）。
- [x] 保留 CLI `cloudflared-hotupdate` 文档，补充 `--reauth` / `--tunnel`。

---

## 5. 关键接口详细设计

### 5.1 `cloudflared-ctl` 输出格式

**gen-config**

```
OK config=/opt/cloudflare/tunnels/office/config.yml tunnel=office
```

**domain-switch**

```
OK old=old.com new=new.com rewritten=3 dns_created=2 restarted=1
```

**core-status**

```
state=downloading
version=
target=/opt/cloudflare/cloudflared
message=Downloading cloudflared-linux-amd64
```

**login-status**

```
state=waiting
url=https://dash.cloudflare.com/argotunnel?...
message=Waiting for authorization
```

### 5.2 Lua action 返回示例

```json
{
  "ok": true,
  "message": "Domain switched",
  "old": "old.com",
  "new": "new.com",
  "rewritten": 3,
  "dns_created": 2,
  "restarted": true
}
```

### 5.3 状态文件位置

```
/tmp/cloudflared/
├── login-<section>.log
├── login-<section>.status
├── login-<section>.pid
├── core-install.log
├── core-install.status
└── core-install.pid
```

使用 `/tmp` 是为了避免写入 flash；重启后状态丢失可接受。

---

## 6. 测试计划

### 6.1 静态检查

- [x] `sh -n` 全部 shell 脚本。
- [x] `luac -p` 全部 Lua 文件（在具备 lua5.1 的环境或设备上）。
- [x] `uci -q show cloudflared` 语法正确（迁移后）。

### 6.2 功能测试矩阵

| 场景 | 步骤 | 期望 |
|---|---|---|
| 旧配置升级 | 用旧 `main + ingress` 配置安装新版 | 自动生成 `default` 隧道，ingress 归属正确 |
| 多隧道启动 | 配置 `default`、`office` 两个隧道 | 两个进程、两份 config.yml |
| 单隧道停用 | `enabled=0` | 对应进程不启动，其他不受影响 |
| 域名热重载（同账号） | `old.com -> new.com` | hostname 改写、DNS 新建、服务重启、cert 不变 |
| 域名重载（跨账号） | 新域名不在账号 | DNS 失败提示，引导重新认证 |
| 域名重载（混合 hostname） | ingress 含其他域名 | 其他域名不变，仅警告 |
| 多隧道 DNS | 同 zone 两隧道删 ingress | 不删其他隧道记录 |
| 核心安装 | `x86_64` 无 binary | 下载、校验、安装成功 |
| 核心更新 | 已有旧版本 | 更新成功，`.old` 备份存在 |
| 核心异常 | 断网/空间不足 | 报错清晰，旧 binary 可用 |
| 后台登录 | 点击 Authorize | 显示 URL，授权后 cert 落盘 |
| 上传 cert | 上传合法 PEM | 写入 600，隧道可启动 |
| 上传非法文件 | 上传文本 | 拒绝并提示 |
| 保存 ingress | 任意修改 | 不自动删 DNS（默认） |

### 6.3 设备/环境

- [ ] OpenWrt x86_64。
- [ ] OpenWrt aarch64（如 R4S / iStoreOS）。
- [ ] 至少一个真实 Cloudflare 账号，含两个 zone。
- [ ] 小闪存设备（剩余空间 < 100MB）验证核心安装提示。

---

## 7. 风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| DNS 误删 | 生产域名解析中断 | 默认关闭删除；按 tunnel target 精确匹配；保存前预览 |
| headless login 回调失败 | 无法自动拿 cert | 必备上传 cert.pem；页面明确提示 |
| 下载超时/空间不足 | 核心安装失败 | 异步任务 + 磁盘检查 + 保留旧 binary |
| 多隧道抢同一 tunnel_id | 隧道冲突 | 保存时校验唯一性 |
| 配置生成三处不一致 | 行为漂移 | 统一到 `cloudflared-ctl` |
| procd 单实例重启缺失 | 重启影响全部隧道 | 先整服务重启；后续用 ubus 精确重启 |
| LuCI 请求超时 | 大下载中断 | 后台任务 + 状态轮询 |
| 旧书签失效 | 用户体验 | 旧路径 alias 到 overview |

---

## 8. 里程碑与交付顺序

| 里程碑 | 内容 | 交付物 |
|---|---|---|
| M1 | 阶段 A 后端统一 | `common.sh`、`cloudflared-ctl`、Lua common |
| M2 | 阶段 B 多隧道模型 | UCI 迁移、init.d 多实例 |
| M3 | 阶段 C UI 拆分与 action | 三个 Tab、action 接口 |
| M4 | 阶段 D 域名热重载 | `domain-switch` + 按钮 |
| M5 | 阶段 E 核心安装 | 异步下载 + 版本检测 UI |
| M6 | 阶段 F 授权 | login + 上传 |
| M7 | 阶段 G 收尾 | DNS 安全、文档、CI、测试 |

建议按 M1 -> M4 先交付“多隧道 + 热重载”最小闭环，再补 M5/M6。

---

## 9. 验收标准（Definition of Done）

- [x] 旧配置升级零手工干预。
- [ ] 两个以上隧道可同时稳定运行。
- [x] 域名切换一键完成且不用重新登录（同账号）。
- [x] 跨账号可通过界面重新授权或上传证书。
- [x] 界面可安装/更新 cloudflared 核心并显示版本。
- [x] 保存配置默认不会删除任何 DNS 记录。
- [x] 所有 shell 脚本 `sh -n` 通过；Lua 文件在设备上可加载。
- [x] README 与实际的 UCI/按钮行为一致。
- [x] CI 能构建带新文件的 IPK，并保留执行权限。

---

## 10. 附录：关键代码骨架

### 10.1 `common.sh` 配置生成

```sh
cf_gen_config() {
    local sec="$1"
    local dir cfg tunnel_id creds cert tmp host svc
    dir="$(cf_tunnel_dir "$sec")" || return 1
    cfg="$(cf_config_path "$sec")"
    tunnel_id="$(cf_get "$sec" tunnel_id)"
    creds="$(cf_credentials "$sec")"
    cert="$(cf_cert_path "$sec")"
    [ -n "$tunnel_id" ] || { error "tunnel_id missing for $sec"; return 1; }
    [ -f "$creds" ] || { error "credentials missing for $sec"; return 1; }
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.config.XXXXXX")" || return 1
    {
        printf 'tunnel: %s\n' "$tunnel_id"
        printf 'credentials-file: %s\n' "$creds"
        [ -f "$cert" ] && printf 'origincert: %s\n' "$cert"
        printf '\ningress:\n'
        uci -q show cloudflared | awk -F= -v t="$sec" '
            $2=="ingress" { sect=$1 }
            sect && $1==sect".tunnel" && $2=="tunnel" { target=substr($0,index($0,"=")+1); gsub(/'"'"'/, "", target) }
            ...
        '
        printf '  - service: http_status:404\n'
    } > "$tmp"
    # backup + atomic move
    [ -f "$cfg.bak1" ] && mv -f "$cfg.bak1" "$cfg.bak2"
    [ -f "$cfg" ] && mv -f "$cfg" "$cfg.bak1"
    mv -f "$tmp" "$cfg"
}
```

> 实现阶段建议用 `config_load` + `config_foreach` 遍历 ingress，避免 awk 解析 UCI 的脆弱性。

### 10.2 `domain-switch` hostname 改写

```sh
cf_domain_rewrite() {
    local sec="$1" old="$2" new="$3"
    local changed=0 s host prefix
    for s in $(uci -q show cloudflared | awk -F= '$2=="ingress"{print $1}'); do
        [ "$(uci -q get "$s.tunnel")" = "$sec" ] || continue
        host="$(uci -q get "$s.hostname")"
        [ -n "$host" ] || continue
        if [ "$host" = "$old" ]; then
            uci set "cloudflared.$s.hostname=$new"; changed=$((changed+1))
        elif [ "${host%.$old}" != "$host" ]; then
            prefix="${host%.$old}"
            uci set "cloudflared.$s.hostname=$prefix.$new"; changed=$((changed+1))
        fi
    done
    uci commit cloudflared
    echo "$changed"
}
```

### 10.3 init.d 多实例骨架

```sh
start_service() {
    config_load cloudflared
    config_get base_path main base_path "/opt/cloudflare"
    BIN="$(cf_find_binary "$base_path")" || {
        logger -t cloudflared "ERROR: cloudflared binary not found"
        return 1
    }
    config_foreach start_one tunnel
}

start_one() {
    local sec="$1" enabled cfg
    config_get_bool enabled "$sec" enabled 1
    [ "$enabled" -eq 1 ] || return 0
    cloudflared-ctl gen-config "$sec" >/dev/null 2>&1 || {
        logger -t cloudflared "ERROR: gen-config failed for $sec"
        return 1
    }
    cfg="$(cloudflared-ctl get-config-path "$sec")"
    procd_open_instance "tunnel_$sec"
    procd_set_param command "$BIN" --config "$cfg" tunnel run
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
```

### 10.4 action 路由骨架

```lua
local common = require "luci.cloudflared.common"
local jsonc = require "luci.jsonc"
local http = require "luci.http"

function action()
    local req = http.formvalue
    local name = req("action") or ""
    local out
    if name == "domain_switch" then
        out = common.action_domain_switch(req)
    elseif name == "core_install" then
        out = common.action_core_install(req)
    elseif name == "core_status" then
        out = common.action_core_status(req)
    elseif name == "login_start" then
        out = common.action_login_start(req)
    elseif name == "login_status" then
        out = common.action_login_status(req)
    else
        out = { ok = false, message = "unknown action" }
    end
    http.prepare_content("application/json")
    http.write(jsonc.stringify(out))
end
```

---

## 11. 变更文件汇总

**新增**

```
root/usr/lib/cloudflared/common.sh
root/usr/bin/cloudflared-ctl
root/usr/lib/lua/luci/cloudflared/common.lua
root/usr/lib/lua/luci/model/cbi/cloudflared/overview.lua
root/usr/lib/lua/luci/model/cbi/cloudflared/tunnels.lua
root/usr/lib/lua/luci/model/cbi/cloudflared/ingress.lua
```

**修改**

```
root/etc/init.d/cloudflared
root/etc/uci-defaults/99-cloudflared
root/usr/lib/lua/luci/controller/cloudflared.lua
root/usr/bin/cloudflared-hotupdate
Makefile
.github/workflows/build.yml
README.md
```

**删除/替换**

```
root/usr/lib/lua/luci/model/cbi/cloudflared/main.lua   # 拆分为 overview/tunnels/ingress
```

---

## 12. 定制开发计划：多协议参数配置（2026-11）

> 目标：按 Cloudflare Tunnel ingress / `originRequest` 标准，为 HTTP、HTTPS、TCP、SSH、RDP、SMB、Unix Socket、HTTP Status 提供完整参数配置。
>
> UI 约定：
> - 共同参数默认显示在表格行内。
> - 非共同参数只在“设置”弹窗中显示。
> - 协议切换后显示“确认切换协议”按钮，点击后刷新该协议参数项。

### 12.1 参数矩阵

| 参数 | HTTP | HTTPS | TCP | SSH | RDP | SMB | Unix | HTTP Status |
|---|---|---|---|---|---|---|---|---|
| hostname | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| host:port | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — |
| unix path | — | — | — | — | — | — | ✓ | — |
| status code | — | — | — | — | — | — | — | ✓ |
| ingress path | ✓ | ✓ | — | — | — | — | ✓ | — |
| connectTimeout | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| tlsTimeout | — | ✓ | — | — | — | — | — | — |
| tcpKeepAlive | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — |
| noHappyEyeballs | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — |
| proxyAddress / Port / Type | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — |
| httpHostHeader | ✓ | ✓ | — | — | — | — | ✓ | — |
| http2Origin | ✓ | ✓ | — | — | — | — | ✓ | — |
| disableChunkedEncoding | ✓ | ✓ | — | — | — | — | ✓ | — |
| keepAliveConnections | ✓ | ✓ | — | — | — | — | ✓ | — |
| keepAliveTimeout | ✓ | ✓ | — | — | — | — | ✓ | — |
| originServerName | — | ✓ | — | — | — | — | — | — |
| noTLSVerify | — | ✓ | — | — | — | — | — | — |
| caPool | — | ✓ | — | — | — | — | — | — |
| bastionMode | — | — | — | ✓ | — | — | — | — |

### 12.2 开发任务

- [x] 12.2.1 定义协议参数元数据与共同/专有参数矩阵
- [x] 12.2.2 后端 `cf_gen_config` 支持完整 `originRequest` 输出
- [x] 12.2.3 Ingress 弹窗新增通用参数（超时、keepalive、代理）
- [x] 12.2.4 Ingress 弹窗新增 HTTP/HTTPS 专有参数（Host、HTTP2、chunked、TLS）
- [x] 12.2.5 Ingress 弹窗新增 SSH/Unix/HTTP Status 专有参数
- [x] 12.2.6 实现“确认切换协议”按钮与参数区域动态刷新
- [x] 12.2.7 表格默认列调整与 Target/服务摘要
- [x] 12.2.8 列选择器与本地缓存兼容
- [x] 12.2.9 测试按钮适配 Host Header / noTLSVerify
- [x] 12.2.10 编译插件并验证

---

## 13. 审查修复计划（2026-11）

> 基于 r27 代码审查结果，按 P0/P1/P2 优先级推进。

### P0

- [x] 13.1 修复登录状态 HTML 未转义导致的 XSS 风险
- [x] 13.2 创建隧道改为 POST action，移除状态变更 GET 路由
- [x] 13.3 插件版本升级到 1.2.0+，避免与 feed 旧版 1.2 冲突
- [x] 13.4 核心上传增加大小限制
- [x] 13.5 核心下载增加 SHA256 校验

### P1

- [x] 13.6 设置弹窗加入 Tunnel / Hostname
- [x] 13.7 Test 按钮尊重 noTLSVerify / CA
- [x] 13.8 避免输出空 originRequest 块
- [x] 13.9 cron 表达式校验
- [x] 13.10 日志过滤表达式错误提示
- [x] 13.11 DNS 查询缓存，减少重复 Cloudflare API 请求
- [x] 13.12 调整启动验证与核心下载超时

### P2

- [x] 13.13 日志文件大小上限
- [ ] 13.14 清理/审查旧 cloudflared-hotupdate
- [ ] 13.15 JS/CSS/字段元数据整理
- [ ] 13.16 uci-defaults 默认启用策略
- [x] 13.17 编译插件并验证

---

## 14. 匿名 section 名称不一致修复（r33）

> 公网访问 404，生成的 config.yml 只有 catch-all，根因是 shell 与 LuCI 使用了不同的 section 名称。

- [x] 14.1 复现：`uci show` 使用 `@tunnel[N]`，`uci show -X` 与 LuCI 使用 `cfXXXX`
- [x] 14.2 shell 统一改用 `uci show -X`，与 `tunnel` 选项保存的值一致
- [x] 14.3 `cf_ingress_sections` 改为按 ingress section 类型枚举并用 `uci get` 比较
- [x] 14.4 兼容旧 `@tunnel[N]` 数据目录，自动复用凭据/config
- [x] 14.5 单隧道时自动修复空的 `tunnel` 引用
- [x] 14.6 保存 ingress 后重新生成所有隧道配置
- [x] 14.7 新增 `cloudflared-ctl ingress-sections <section>` 诊断命令
- [x] 14.8 更新测试并编译验证
- [x] 14.9 修复 `uci -X` 参数顺序错误导致隧道列表为空（No enabled tunnels）
- [x] 14.10 修复隧道页创建/重载按钮读取现代 LuCI widget 值报错

---

## 15. 日志清理优化（r35）

- [x] 15.1 “定时清空”调整为“定时清理”
- [x] 15.2 勾选定时清理后显示 Cron 表达式并增加前端校验
- [x] 15.3 新增日志大小上限与单位（KB/MB/GB）
- [x] 15.4 插件日志与核心日志统一按上限自动清空
- [x] 15.5 0 表示不限制大小
- [x] 15.6 uci-defaults 补齐默认值
- [x] 15.7 定时清理按 Cron 执行，移除独立的 5 分钟大小检查任务
- [x] 15.8 日志查看器改为白底黑字并增大字号
- [x] 15.9 默认开启定时清理和停止时清空，Cron 为 `*/5 * * * *`，上限 1MB
- [x] 15.10 Cron/大小上限/单位仅在勾选定时清理时显示
- [x] 15.11 定时任务到点按大小上限决定是否清空（0 表示每次清空）
- [x] 15.12 “停止时清空”移到日志设置最上方
- [x] 15.13 日志字号从 15px 调整为 14px

---

## 16. 入站规则列选择优化（r40）

- [x] 16.1 列选择器固定包含：隧道、主机名、协议、IP/主机、端口、服务、DNS、检查
- [x] 16.2 默认勾选：隧道、主机名、协议、IP/主机、端口、DNS、检查
- [x] 16.3 列缓存 key 升级为 v5，避免旧状态覆盖默认值
- [x] 16.4 列选择器在取不到表头时使用内置名称兜底

---

## 17. 入站规则 DNS 状态与启用开关（r41）

- [x] 17.1 修复 DNS 状态全部显示“未知”（兼容空/过期 tunnel 引用）
- [x] 17.2 检查列后新增“启用”勾选框
- [x] 17.3 未启用规则不写入 config.yml、不同步/检测 DNS、不参与域名改写
- [x] 17.4 未启用规则的 DNS 显示“已禁用”，测试按钮提示规则已禁用
- [x] 17.5 tunnel 签名包含 enabled，切换后触发 DNS 同步
- [x] 17.6 更新测试并编译验证

---

## 18. 概览页统计卡片优化（r42）

- [x] 18.1 “版本”卡片改为“站点”统计：运行中 / 异常 / 已禁用
- [x] 18.2 “核心状态”卡片显示安装状态 + 版本号
- [x] 18.3 “连接状态”增加开机自启信息
- [x] 18.4 “隧道”卡片增加启用 / 已禁用数量
- [x] 18.5 卡片增加状态色条与副标题，移动端保持两列
- [x] 18.6 编译验证

---

## 19. HTTPS 源站测试优化（r43）

- [x] 19.1 Test 使用 `--resolve` 携带正确 SNI，同时连接源站 IP
- [x] 19.2 Test 支持 `origin_server_name`（SNI）与 `origin_ca_pool`（CA）
- [x] 19.3 编译验证

---

## 20. 入站规则隧道列显示优化（r44）

- [x] 20.1 隧道列只显示隧道名称，不再附带域名
- [x] 20.2 编译验证

---

## 21. 入站规则表格宽度优化（r45）

- [x] 21.1 隧道列加宽到 150px
- [x] 21.2 主机名/协议/IP/端口/服务/DNS/检查列设置合理宽度
- [x] 21.3 表格单元格左右内边距缩小到 5px
- [x] 21.4 启用列缩窄到 40px，仅保留勾选框
- [x] 21.5 编译验证

---

## 22. 入站规则控件间距优化（r46）

- [x] 22.1 单元格内输入框/下拉框宽度改为 100%，消除控件右侧空白
- [x] 22.2 使用表格 ID 提高内边距规则优先级
- [x] 22.3 编译验证

---

## 23. 入站规则表格对齐与边距优化（r47）

- [x] 23.1 表头和单元格内容居中
- [x] 23.2 主机名/IP 输入框保持文字左对齐
- [x] 23.3 隧道下拉框文字居中
- [x] 23.4 首列左内边距、末列右内边距加大到 12px
- [x] 23.5 操作按钮居中并允许换行
- [x] 23.6 编译验证

---

## 24. 入站规则表格紧凑化（r48）

- [x] 24.1 表格改为 `table-layout: fixed`，列宽按可见列百分比分配
- [x] 24.2 默认可见列比例总和 100%，避免自动布局产生大段空白
- [x] 24.3 切换显示列时动态重算列宽
- [x] 24.4 保留表头/单元格居中、首末列 12px 边距
- [x] 24.5 编译验证

---

## 25. 入站规则表格视觉优化（r49）

- [x] 25.1 列宽通过 `colgroup` 对整个表格统一控制，隐藏列占宽设为 0
- [x] 25.2 加宽主机名、协议、IP/主机、端口等主要编辑列
- [x] 25.3 统一控件高度、内边距、边框、圆角和焦点态
- [x] 25.4 操作按钮、启用控件和描述行统一视觉间距
- [x] 25.5 小屏保持表格可横向滚动，避免控件被压缩
- [x] 25.6 编译验证

---

## 26. 首次加载列宽稳定性（r50）

- [x] 26.1 首屏、pageshow、load、resize、orientationchange 后重复布局校正
- [x] 26.2 监听 LuCI widget 异步替换，完成后重算列宽
- [x] 26.3 编译验证

---

## 27. 入站规则操作按钮横向排列（r51）

- [x] 27.1 设置和删除按钮固定同一行，不再折行
- [x] 27.2 增加操作列宽权重并微调按钮间距
- [x] 27.3 编译验证

---

## 28. 入站规则列内容对齐（r52）

- [x] 28.1 启用 checkbox 容器占满单元格并与标题中心对齐
- [x] 28.2 DNS 状态容器显式居中
- [x] 28.3 检查按钮与结果改为垂直分组、整体居中
- [x] 28.4 调整检查列宽权重以避免结果挤压
- [x] 28.5 编译验证

---

## 29. 检查列布局调整（r53）

- [x] 29.1 检查标题和测试按钮左对齐
- [x] 29.2 测试结果显示在按钮右侧并允许换行
- [x] 29.3 其他表格列的对齐保持不变
- [x] 29.4 编译验证

---

## 30. 概览页操作指引入口（r54）

- [x] 30.1 在 Cloudflare 隧道标题右侧加入操作指引链接
- [x] 30.2 使用低对比度浅灰小字，不干扰页面主内容
- [x] 30.3 链接新窗口打开并添加 noopener/noreferrer
- [x] 30.4 窄屏标题行保持响应式
- [x] 30.5 编译验证

---

## 31. 多主题布局兼容与辅助空栏清理（r55）

- [x] 31.1 概览统计卡片改为等宽响应式网格
- [x] 31.2 服务控制与核心卡片改为等宽响应式网格
- [x] 31.3 隐藏概览、隧道、入站页 JS 辅助 SimpleSection 空容器
- [x] 31.4 编译验证

---

## 32. 页面标题命名优化（r56）

- [x] 32.1 概览标题改为“Cloudflared 概览”
- [x] 32.2 隧道标题改为“Cloudflared 隧道”
- [x] 32.3 更新中文翻译并编译验证

---

## 33. 修复概览统计区被隐藏（r57）

- [x] 33.1 概览页统计卡片与脚本共用区域，不再隐藏整个辅助 SimpleSection
- [x] 33.2 保留隧道/入站页辅助空栏隐藏
- [x] 33.3 编译验证

---

## 34. 概览卡片状态色统一（r58）

- [x] 34.1 隧道卡片添加正常状态 class，左侧状态线统一为绿色
- [x] 34.2 编译验证

---

## 35. 入站显示列限于共同字段（r59）

- [x] 35.1 显示列菜单仅管理隧道、主机名、协议、IP/主机、端口、服务、DNS、检查、启用
- [x] 35.2 协议专属字段继续通过设置弹窗管理，不出现在列菜单
- [x] 35.3 缓存 key 升级至 v6，恢复默认列选择
- [x] 35.4 编译验证

---

## 36. 开发阶段移除显示列重置按钮（r60）

- [x] 36.1 从显示列菜单移除恢复默认按钮
- [x] 36.2 移除对应旧缓存清理逻辑
- [x] 36.3 编译验证

---

## 37. 修复入站规则设置弹窗与列显示（r61）

- [x] 37.1 将设置弹窗移动到 document.body，避免隐藏脚本宿主导致弹窗不可见及行控件被移出
- [x] 37.2 移除按固定列序号隐藏表格列的旧 CSS，避免误隐藏入站行字段
- [x] 37.3 Lua 语法、插件测试和差异检查通过
- [x] 37.4 r61 插件包编译验证

---

## 38. 站点统计口径和状态展示（r62）

- [x] 38.1 按已保存的入站规则统计总数，互斥分类为运行中、待同步、异常、禁用
- [x] 38.2 使用所属隧道的 procd 实例状态及 DNS 查询结果，关闭的规则或隧道优先归禁用
- [x] 38.3 DNS 查询失败区别于缺失记录，不写入成功缓存；按隧道隔离 DNS 结果
- [x] 38.4 两行两列按顺序展示，分别使用绿色、黄色、红色、黑色，并添加口径提示
- [x] 38.5 Lua、页面 JavaScript、分类测试及插件包编译验证

---

## 39. 修复新增入站规则泄漏弹窗参数列（r63）

- [x] 39.1 将弹窗专用列的隐藏与设置按钮初始化提取为逐行函数
- [x] 39.2 首次加载和动态新增/重绘后统一隐藏弹窗专用列
- [x] 39.3 Lua、页面 JavaScript 和插件测试验证
- [x] 39.4 r63 插件包编译验证

---

## 40. 兼容 Vantage div 表格结构（r64）

- [x] 40.1 字段单元格按 data-name 定位，兼容主题替换后的控件 ID
- [x] 40.2 统一兼容原生 table 和 LuCI .table/.tr/.td 结构
- [x] 40.3 Vantage div 表格直接设置单元格宽度，不插入 colgroup
- [x] 40.4 Lua、插件测试和构建产物检查通过
- [x] 40.5 r64 插件包编译验证

---

## 41. 入站表格弹窗列遗漏与入口查询修复（r65）

- [x] 41.1 修复 setup 首行查询仍使用原生 tr，主题下初始化未执行的问题
- [x] 41.2 弹窗专用列改为由“设置字段减去表格列”自动推导，补回 UNIX 路径、HTTP 状态码、Host 头、TLS 校验、TLS 主机名
- [x] 41.3 页面脚本语法与列集合校验
- [x] 41.4 插件测试与编译验证

---

## 42. 夜间模式输入框可读性（r66）

- [x] 42.1 入站表格输入框/下拉框改用主题颜色变量并提供浅色回退
- [x] 42.2 显式设置文字与占位符颜色，避免白底白字
- [x] 42.3 页面脚本与插件测试验证
- [x] 42.4 编译验证

---

## 43. 夜间模式日志查看器配色（r67）

- [x] 43.1 日志内容区背景/文字/边框改用主题颜色变量并保留浅色回退
- [x] 43.2 日志信息文字使用主题次要文字色
- [x] 43.3 语法与插件测试验证
- [x] 43.4 编译验证

---

## 44. 适配 Aurora 主题颜色变量（r68）

- [x] 44.1 确认当前启用主题为 Aurora，其变量为 surface/control-bg/text/hairline
- [x] 44.2 日志查看器按 Aurora → Vantage → Bootstrap 顺序回退取色
- [x] 44.3 入站输入框、下拉框、占位符同步适配
- [x] 44.4 设置弹窗与显示列菜单背景/文字适配夜间模式
- [x] 44.5 语法与插件测试验证
- [x] 44.6 编译验证

---

## 45. 迁移到 LuCI JS 视图（r69）

> 目标：用 LuCI JS 标准表单（`form.GridSection`、`modalonly`、`ui.showModal`）
> 替换自研表格与弹窗，彻底消除主题结构依赖；后端 `common.lua`、`cloudflared-ctl` 保留。

### 阶段 0：基线与测试

- [x] 45.0.1 以 r68 为回滚基线，梳理四个页面功能清单
- [x] 45.0.2 抽取 `service.js` 纯函数（解析/组装 service）并添加 Node 测试

### 阶段 1：桥接层

- [x] 45.1.1 新增 `resources/cloudflared/api.js` 统一 action 调用
- [x] 45.1.2 新增 `menu.d/luci-app-cloudflared.json`，页面改为 JS view
- [x] 45.1.3 controller 仅保留 action、upload 与别名入口

### 阶段 2：日志页

- [x] 45.2.1 `view/cloudflared/log.js`：设置表单、过滤、刷新、清空、自动滚动
- [x] 45.2.2 保存后调用 `apply_log` 更新清理任务
- [x] 45.2.3 主题/夜间/窄屏样式改用主题变量

### 阶段 3：概览页

- [x] 45.3.1 `view/cloudflared/overview.js`：状态卡片与服务控制
- [x] 45.3.2 核心安装/更新/上传与进度轮询
- [x] 45.3.3 站点统计与主题适配

### 阶段 4：隧道页

- [x] 45.4.1 `view/cloudflared/tunnels.js`：GridSection、增删、域名状态
- [x] 45.4.2 授权登录、证书/凭据上传、热重载
- [x] 45.4.3 保存后 `apply_tunnels` 重建配置

### 阶段 5：入站页

- [x] 45.5.1 `view/cloudflared/ingress.js`：GridSection 行内公共列
- [x] 45.5.2 协议专属参数使用 modalonly + depends（切换时保留已填值）
- [x] 45.5.3 service 伪字段读写、DNS 状态、测试按钮、协议切换确认
- [x] 45.5.4 保存后 `apply_config` 重建配置并同步 DNS
- [x] 45.5.5 移除自研列选择器（GridSection 不支持持久化列隐藏）

### 阶段 6：收尾

- [x] 45.6.1 删除四个 Lua CBI 视图
- [x] 45.6.2 移除 `luci-compat` 依赖，显式保留 `luci-lua-runtime`（Lua action 所需）
- [x] 45.6.3 翻译补充与生成 `.lmo`
- [x] 45.6.4 Lua/JS 语法、单元测试与插件编译验证

### 验证

- [ ] 45.7.1 设备实测：四个页面、弹窗、协议切换、上传、夜间模式
- [ ] 45.7.2 设备实测：保存并应用后 config.yml 重建与 DNS 同步

---

## 46. 页面体验优化与回归修复（r70）

- [x] 46.1 概览站点卡片占两列，利用空白位置并放大统计指标
- [x] 46.2 隧道页行内加入同步 DNS、热重载按钮
- [x] 46.3 隧道启用勾选列移动到隧道 ID 之后
- [x] 46.4 授权弹窗轮询状态并显示授权链接
- [x] 46.5 隧道编辑弹窗内的操作结果改为弹窗提示，避免被遮挡
- [x] 46.6 入站协议切换改为字段下方红色确认按钮，确认后再刷新参数
- [x] 46.7 入站表右上角恢复“展示列”，仅管理共同列并持久化
- [x] 46.8 日志查看器强制占满可用宽度
- [ ] 46.9 设备实测以上交互

---

## 47. 核心更新校验与检查状态卡片（r71）

- [x] 47.1 安装/更新前先比较当前版本与远程最新版本
- [x] 47.2 已是最新时提示并停止下载；无法获取远程版本时不再盲目更新
- [x] 47.3 检查状态改为页面顶部可关闭的详情卡片
- [x] 47.4 安装前校验复用同一检查结果
- [ ] 47.5 设备实测版本比较与下载行为

---

## 48. 入站表格列宽调整（r72）

- [x] 48.1 压缩 IP/主机、端口列宽
- [x] 48.2 扩大隧道、主机名列宽
- [x] 48.3 表格改为固定布局，按比例分配列宽
- [ ] 48.4 设备实测各主题下列宽

---

## 49. 入站服务列默认隐藏（r73）

- [x] 49.1 显示列中“服务”默认不勾选、不显示
- [x] 49.2 用户勾选后仍可显示并持久化
- [ ] 49.3 设备实测默认列状态

---

## 50. 主动审查优化计划与列顺序调整（r74）

### 本次已实施

- [x] 50.1 入站表格“启用”列移动到“检查”列之前
- [x] 50.2 同步调整列宽、“展示列”菜单顺序

### P0 功能性问题

- [x] 50.3 入站测试状态分级：2xx/3xx 成功，4xx 警告，5xx/连接失败失败
- [x] 50.4 公网探测固定 IPv4 并绕过代理，DNS 失败单独提示
- [x] 50.5 保存时删除孤立 DNS 前增加确认或预览
- [x] 50.6 隧道保存仅在配置变化时重启服务
- [x] 50.7 行内“热重载”读取当前输入框域名
- [x] 50.8 Unix / HTTP Status 协议隐藏 IP、端口
- [x] 50.9 表格内协议确认按钮改为短文案

### P1 用户流程

- [x] 50.10 概览开机自启失败后回滚勾选状态
- [x] 50.11 核心安装增加取消入口或明确进度
- [x] 50.12 本地版本高于远程时给出准确提示
- [x] 50.13 隧道删除增加确认
- [x] 50.14 授权弹窗补充 headless 场景说明
- [x] 50.15 行内快捷按钮增加 busy/disabled 状态
- [x] 50.16 同步 DNS 成功改为页内短提示
- [x] 50.17 DNS 状态轮询在页面不可见时暂停
- [x] 50.18 展示列增加“恢复默认”
- [x] 50.19 日志增加暂停/继续与清空 loading
- [x] 50.20 切换日志页签立即加载一次
- [x] 50.21 说明“保存”与“保存并应用”的差异

### P2 后端、安全与性能

- [x] 50.22 `core_check` 远程版本查询增加缓存
- [x] 50.23 后端安装前再次校验版本
- [x] 50.24 仅对配置变化的隧道同步 DNS
- [x] 50.25 重启前执行 `cloudflared-ctl check` 预检
- [x] 50.26 上传证书/凭据增加格式与字段校验
- [ ] 50.27 评估并补充 ACL（需单独设计权限组）
- [x] 50.28 统一测试按钮与站点统计的隧道运行状态口径

### P3 测试与主题

- [ ] 50.29 版本比较、协议切换、列默认值单元测试
- [ ] 50.30 `apply_config` / `apply_tunnels` Lua 测试
- [ ] 50.31 Aurora / Vantage / Bootstrap、暗色、窄屏、移动端实测
- [ ] 50.32 固定表格布局在移动端卡片模式的按钮位置检查
- [ ] 50.33 日志 `:has()` 浏览器兼容性确认

---

## 51. 入站检查与操作列布局（r76）

- [x] 51.1 检查结果恢复为按钮右侧显示，允许换行
- [x] 51.2 检查列宽度增加，按钮居单元格左侧
- [x] 51.3 操作列固定为容纳“设置/删除”的宽度
- [ ] 51.4 设备实测各主题下布局

---

## 52. 入站 IP 与协议列固定宽度（r77）

- [x] 52.1 IP / 主机列固定为可完整显示 `255.255.255.255` 的宽度
- [x] 52.2 协议列加宽到可完整显示“HTTP 状态码”
- [x] 52.3 其他列宽相应让出空间
- [ ] 52.4 设备实测文本是否完整显示

---

## 53. 入站端口列固定宽度（r78）

- [x] 53.1 端口列固定为可完整显示 `17999` 的宽度
- [ ] 53.2 设备实测端口显示与列宽

---

## 54. 入站规则筛选与分页（r79）

- [x] 54.1 工具条：按隧道名、主机名筛选，输入防抖
- [x] 54.2 每页 10 / 20 / 30 / 50 / 100 条切换
- [x] 54.3 首页/上一页/下一页/末页与页码统计
- [x] 54.4 筛选、分页状态在表格重绘后保留
- [ ] 54.5 设备实测大数量规则下的分页与筛选

---

## 55. 分页默认每页 20 条（r80）

- [x] 55.1 显式设置每页条数下拉框初始值为 20
- [ ] 55.2 设备实测首次进入页面的默认条数

---

## 56. 入站筛选与分页布局调整（r81）

- [x] 56.1 隧道筛选改为隧道字典下拉框，含“全部”
- [x] 56.2 筛选条件横向排列，展示列并入筛选行右侧
- [x] 56.3 分页移动到表格与“添加”按钮之后的底部并右对齐
- [x] 56.4 隧道字典变化时自动刷新，避免观察器循环
- [ ] 56.5 设备实测筛选、添加、分页的顺序与对齐

---

## 57. 概览站点卡片操作指引（r82）

- [x] 57.1 站点卡片右上角外增加低对比度“操作指引”链接
- [x] 57.2 新窗口打开并设置 noopener/noreferrer
- [x] 57.3 窄屏保持响应式
- [ ] 57.4 设备实测链接位置与夜间模式

---

## 58. 操作指引位置调整（r83）

- [x] 58.1 在统计卡片上方增加全宽右对齐行
- [x] 58.2 链接右对齐到站点卡片右上侧
- [x] 58.3 移除卡片外绝对定位，避免悬浮错位
- [ ] 58.4 设备实测位置与夜间模式
