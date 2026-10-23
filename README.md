# Claude CoastClear

macOS 菜单栏工具：检测当前网络出口与系统、浏览器环境是否一致，评估运行 Claude 的环境风险。App 和命令名为 `cc`（CoastClear 的缩写）。

[English](README.en.md) · [更新日志](CHANGELOG.md) · [与原项目的差异](docs/upstream-differences.md)

## 功能

- 三路出口 IP 一致性检测，附线路质量趋势图。
- 出口国家、IP 类型与多源情报，DNS 解析，IPv6 与 WebRTC 泄漏检测。
- 系统与浏览器的时区、区域、语言是否与出口一致。
- 26 项加权评分与风险档位，可在浏览器中查看完整报告。
- 时区、DNS、PAC、区域格式的一键修复。

## 相比原项目的改进

Claude CoastClear 专注于检查 Claude 运行环境，在原项目基础上做了以下改进：

- **专注于 Claude 环境检测**：删除原项目启动时自动修改 Codex 配置并运行本地代理的冗余功能，不再改动其他应用的配置。
- **检测不改系统设置**：启动、定时检测和退出都只读；时区不再自动跟随出口，只给建议。
- **修复先确认**：每次修复都要确认，确认后才请求管理员授权；不安装 root 守护进程，不配置免密 sudo。确认框显示的是上次体检的结果，如果之后切换过代理节点，请先手动「重新体检」再修复。
- **结论更可靠**：本轮结果与历史结果分开显示，检测失败不再沿用旧数据冒充成功；评分暂时失败会自动复核一次。
- **检测更完整**：修复了原项目中从未实际执行的 IPv6 泄漏检测，并显示地址来源。

## 运行要求

- macOS 12 或以上，Apple 芯片或 Intel。
- Xcode 命令行工具，用于编译：`xcode-select --install`。
- 检测通过 curl 进行，不读取系统 HTTP 代理设置。
- App 未经签名公证，首次打开被拦截时，到「系统设置 → 隐私与安全性」中选择「仍要打开」。

## 使用

```bash
bash menubar/build.sh            # 构建 menubar/cc.app
open menubar/cc.app              # 启动菜单栏应用
bash cc-check.sh                 # 命令行完整体检，不修复
bash cc-check.sh --fix           # 体检后确认并修复
bash install.sh                  # 安装到 /Applications，不启动、不注册登录启动
bash install.sh --autostart      # 安装并注册登录启动
bash uninstall.sh                # 移除登录启动项，确认后删除应用
```

## 联网与隐私

- 检测会访问公共 IP 查询与连通性服务：ipip.net、ipify、icanhazip、ifconfig.me、ipinfo、ipapi.co、ipwho.is、ip-api（明文 HTTP）、ip.sb、myip.com、Cloudflare、Google 和 Anthropic，浏览器检测还会连接 Cloudflare 与 Google 的 STUN 服务器。
- 默认每分钟进行一次轻量出口检测；完整体检在出口变化或手动触发时运行。
- 检测结果只保存在 `~/Library/Application Support/cc`（可用 `CC_DATA_DIR` 修改）。浏览器报告经带随机令牌的 `127.0.0.1` 本机接口传递，不会上传。

## 说明

- 适合经常跨地区出差、需要随时确认当前网络与设备环境的用户。
- 评分为经验规则，不代表任何服务方的官方判断，也不保证账号安全。
- 本项目与 Anthropic 无关。使用时请遵守当地法律及所用服务的条款。

## 测试

```bash
bash test-cc-consent.sh && bash test-cc-check.sh && bash test-cc-network.sh && bash test-browser-report.sh
```

## 许可证

基于原项目 4.18 源码独立开发，采用 MIT 许可证，保留原作者版权声明，见 [LICENSE](LICENSE)。
