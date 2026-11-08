# 设备实测清单

以下项目需要真实设备 / Cloudflare 账号，无法在 CI 中完成。

## 1. 安装与升级

```sh
opkg install luci-app-cloudflared_*_all.ipk
uci show cloudflared
```

- [ ] 旧版单隧道配置升级后自动生成 `default` 隧道
- [ ] 旧 `ingress` 规则自动归属 `default`
- [ ] `/opt/cloudflare/config.yml` 继续可用

## 2. 多隧道

在 **服务 → Cloudflared → 隧道** 添加两个隧道（可共用同一个根域名）：

- [ ] 两个隧道分别生成独立的 `config.yml`
- [ ] `procd` 启动两个实例
- [ ] 停用其中一个不影响另一个
- [ ] 保存 ingress 时不会删除另一隧道的 DNS 记录

## 3. 域名热重载

- [ ] 修改域名后点击 **热重载**，hostname 正确改写
- [ ] `applied_domain` 更新为当前域名
- [ ] 同账号切换域名不需要重新登录
- [ ] 跨账号时能通过授权/上传证书恢复
- [ ] 取消勾选“同步 DNS”“重启”时行为符合预期

## 4. 核心安装 / 更新

- [ ] 概览页显示架构、当前版本、二进制路径
- [ ] 点击 **安装 / 更新** 能下载并校验二进制
- [ ] 更新后保留 `cloudflared.old`
- [ ] 小闪存设备（剩余 < 100MB）出现明确空间不足提示

## 5. 授权与上传

- [ ] 点击 **授权** 显示 URL，授权后自动检测 cert.pem
- [ ] 点击 **复制链接** 可复制授权 URL
- [ ] 上传 `cert.pem` 后保存并应用自动生效
- [ ] 上传 `<tunnel_id>.json` 后隧道 ID / 凭据路径正确更新
- [ ] 非法 PEM / JSON 被拒绝

## 6. 一键检查

在路由器上运行：

```sh
sh tests/device-check.sh
```

检查项：二进制、剩余空间、每个隧道的 config / credentials / cert、进程是否运行。

## 7. 环境矩阵

- [ ] OpenWrt x86_64
- [ ] OpenWrt aarch64（R4S / iStoreOS）
- [ ] 真实 Cloudflare 账号，含两个 zone
- [ ] 小闪存设备
