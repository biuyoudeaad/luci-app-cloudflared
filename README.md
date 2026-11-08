# luci-app-cloudflared

一款 OpenWrt/iStoreOS 上的 **Cloudflare Tunnel** 本地可视化管理插件。

## 📌 项目介绍

- 首选 `Cloudflare` 后台面板可以对隧道可视化管理
- 每次登录或者换设备太麻烦了，所以有了本项目，通过本地 `config.yml` 的方式控制隧道
- 支持**多隧道**：每个隧道独立域名、证书、凭据和 `config.yml`
- 支持**界面安装/更新 cloudflared 核心**
- 支持**界面授权**：后台登录 + 上传 `cert.pem` / 隧道 JSON
- 支持**域名切换热重载**：改完域名点按钮即可重建配置、同步 DNS、重启服务

> **支持协议**：目前已测试 **HTTP / HTTPS**。其他协议需额外配置，请在配置好以后自行测试。

---

## 🚀 安装

### 1️⃣ 安装 Cloudflare Tunnel（二选一）

**方式 A：界面安装（推荐）**

先安装 LuCI 插件，进入 **服务 → Cloudflared → 概览**，在 **Cloudflared Core** 区域点击
**安装 / 更新**，插件会按设备架构自动下载并校验二进制。

**方式 B：一键脚本**

```bash
wget -O /tmp/setup.sh https://github.com/onlineY/luci-app-cloudflared/raw/main/tools/setup.sh
sh /tmp/setup.sh
```

脚本会自动：
- 下载对应架构的 cloudflared 二进制
- 引导完成 Cloudflare 账号授权（获取证书）
- 创建隧道并保存凭据到安装目录

### 2️⃣ 安装 LuCI 管理插件

从 [Releases](../../releases) 下载最新 `.ipk` 文件，在路由器上运行：

```bash
opkg install luci-app-cloudflared_*_all.ipk
```

安装后刷新 LuCI，进入 **服务 → Cloudflared** 完成配置。

---

## ⚙️ 使用指南

### 概览（Overview）

- 查看运行状态、隧道数量、二进制路径与版本
- 配置基础路径、默认证书、API Token、下载镜像地址
- **安装 / 更新 cloudflared 核心**
- 启动 / 停止 / 重启服务

### 隧道（Tunnels）

每个隧道包含：

- `名称`、`启用`、`根域名`
- `Tunnel ID`、`数据目录`、`证书路径`、`凭据文件`
- 可选的独立 `API Token`（跨 Cloudflare 账号时使用）
- 操作按钮：
  - **热重载**：按当前域名重写 ingress hostname、重建 `config.yml`、同步 DNS、重启服务
  - **同步 DNS**：只创建缺失的 CNAME 记录
  - **授权**：后台执行 `cloudflared login`，页面显示授权 URL
- 证书与凭据上传：
  - `cert.pem`
  - `<tunnel_id>.json`（Cloudflare 隧道凭据）

新隧道默认使用：

```
<base_path>/tunnels/<section>/
├── cert.pem
├── <tunnel_id>.json
└── config.yml
```

旧版单隧道配置升级后会迁移为 `default` 隧道，继续使用 `<base_path>` 根目录。

### Ingress 规则（Ingress）

- 选择所属隧道
- 填写完整 hostname（如 `app.example.com`），留空子域时会自动补上当前隧道域名
- 配置协议、IP、端口
- 保存后会自动重建配置、同步缺失的 DNS 记录并重启服务
- **默认不会删除任何 DNS 记录**

---

## 🔁 域名切换热重载

1. 在 **Tunnels** 页面修改某个隧道的域名
2. 点击该隧道的 **热重载** 按钮（或直接 **保存并应用**）
3. 插件会：
   - 将该隧道下以旧域名结尾的 hostname 改为新域名
   - 更新 `domain` / `applied_domain`
   - 重建 `config.yml`
   - 为新的 hostname 创建 CNAME
   - 重启服务

> `cert.pem` 是 **账号级** 证书，同账号切换域名不需要重新登录。
> 如果新域名属于另一个 Cloudflare 账号，请使用 **授权** 或上传新的证书/凭据。

---

## 🔐 界面授权

### 方式 A：后台 login

在 **Tunnels** 页面点击某个隧道的 **授权**，页面会显示 `cloudflared login` 生成的 URL。
在浏览器中打开并完成授权后，插件会自动检测并安装 `cert.pem`。

> 无显示器 / 远程路由器场景下，浏览器授权后的 localhost 回调可能到不了路由器。
> 此时请使用方式 B。

### 方式 B：上传证书 / 凭据

在 **Tunnels** 页面下方 **Certificate & Credentials** 区域：

1. 上传 `cert.pem`
2. 上传隧道凭据 `<tunnel_id>.json`
3. 点击该隧道的 **热重载** 使配置生效

---

## 🖥️ CLI 热更新

安装插件后仍可使用命令行：

```bash
# 重新生成默认隧道配置、同步 DNS、重启
cloudflared-hotupdate

# 只刷新证书（强制重新登录）
cloudflared-hotupdate --reauth

# 切换域名并自动重写 hostname、重建配置、同步 DNS、重启
cloudflared-hotupdate --domain new-example.com

# 操作指定隧道
cloudflared-hotupdate --tunnel office --domain office-new.com
```

说明：默认**不会删除** `cert.pem`；只有显式使用 `--reauth` 才会重新登录。

---

## 🔑 获取 Cloudflare API Token

为了实现 DNS 记录的自动同步，需要配置一个 Cloudflare API Token：

1. 访问 [Cloudflare 控制面板 - API Tokens](https://dash.cloudflare.com/profile/api-tokens)
2. 点击 **创建 Token** 按钮
3. 选择 **Edit zone DNS** 预设模板
4. 在 **Zone Resources** 中选择你要管理的域名
5. 点击创建，复制生成的 Token
6. 粘贴到 LuCI 页面 **概览 → Cloudflare API 令牌** 字段

完成后点击 **保存并应用**，插件会自动同步 DNS 记录。

---

## ⬆️ 升级说明

- 旧版 `main + ingress` 配置会在升级时自动迁移为 `default` 隧道
- 迁移由 `/etc/uci-defaults/99-cloudflared` 完成，幂等可重复执行
- 旧版 `/opt/cloudflare/config.yml` 继续作为 `default` 隧道的配置

---

## ⚠️ 注意事项

- 核心二进制约 30–50MB，小闪存设备请先确认剩余空间
- DNS 删除默认关闭；如开启，只删除匹配当前隧道 `*.cfargotunnel.com` 的记录
- 多隧道请确保每个隧道的 `Tunnel ID` 唯一
- 下载失败时可把 **下载地址** 换成 GitHub 镜像

## 截图

![示例图片](./img/image.png)
