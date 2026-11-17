<p align="center">
<img src="src/tr-web-control/logo.png"><br/>
<img src="https://img.shields.io/badge/transmission-2.40%20~%204.1%2B%20(JSON--RPC%202.0)-green.svg" title="Support Transmission Version">
<img src="https://img.shields.io/badge/version-v1.7.1--zhCN-blue.svg" title="Version">
<a href="LICENSE" title="license"><img src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
</p>

----

# Transmission Web Control (v1.7.1-zhCN 群晖 & Transmission 4.1+ 增强维护版)

本项目是基于 [ronggang/transmission-web-control](https://github.com/ronggang/transmission-web-control)（栽培者原版 v1.6.1，已于 2025-06 归档）的中文社区续作，融合了 [uuunit/transmission-web-control](https://github.com/uuunit/transmission-web-control)（v1.7.0）与 [wzya2026/transmission-web-control-zhcn](https://github.com/wzya2026/transmission-web-control-zhcn) 的核心改进，专为 **Transmission 4.0 / 4.1+（JSON-RPC 2.0）** 及 **群晖 DSM 7（SynoCommunity 套件）** 打造。

## 核心特性与改进

| 功能模块 | 支持状态 | 说明 |
|---|---|---|
| **Transmission 4.1 JSON-RPC 2.0 兼容层** | ✅ | 内置 `rpc-compat.js` 协议边界适配，自动协商 `X-Transmission-Rpc-Version >= 6`（JSON-RPC 2.0），自动转换 `snake_case` / `camelCase`、`cache_size_mib`、`recently_active`、`wanted` 等字段，同时保留旧版守护进程回退能力 |
| **服务端标签 (`labels`)** | ✅ | 支持 Transmission 4.0+ 服务端持久化标签，左侧导航树新增「服务端标签」分类筛选，配有图形化芯片标签编辑器（支持单种与右键批量设置） |
| **按文件顺序下载 (`sequential_download`)** | ✅ | 支持种子列表右键一键开启/关闭顺序下载、详情面板切换、以及「系统参数 -> 基本设置」新任务默认顺序下载 |
| **带宽限速组 (`group-get` / `group-set`)** | ✅ | 完整支持 Transmission 4.x 限速组管理对话框、详情页下拉绑定、以及右键菜单批量分配限速组 |
| **桌面式上下分栏详情面板** | ✅ | 点选种子自动展开底部详情栏，顶部常驻任务进度条、总大小、已完成、实时下载/上传速度与分享率摘要，新增累计下载、下载用时、做种用时、私有种子标识，修复快速切换任务时的异步竞态清空问题 |
| **新版功能扩展（默认公开 Tracker & 双栈端口测试）** | ✅ | 「系统参数 -> 新版功能」标签页支持配置 `default-trackers`（仅作用于公开种子，不影响 PT 私有种子）及 IPv4 / IPv6 端口连通性检测 |
| **群晖 DSM 7 专用部署与套件升级自愈** | ✅ | `deploy-synology.sh` 自动识别群晖 `public_html`、原子备份并保留官方界面入口（`index.original.html`），并注入 `service_prestart` 与 `rc.d` 守护钩子，防止套件中心升级 Transmission 后覆盖中文界面 |
| **可复现构建与单元测试** | ✅ | `node build.js` 基于 Terser 一键生成全部 `script/min/*.min.js`；`node test-compat.js` 覆盖 JSON-RPC 2.0 转换、能力检测与 UI 选择竞态测试 |

## 群晖 DSM 7 快速安装与升级守护

将构建产物 `dist/transmission-web-control-zhcn.tar.gz` 与 `deploy-synology.sh` 上传至群晖任意目录（例如 `/volume2/homes/helixzz/twc-zhcn`），通过 SSH 执行：

```bash
sudo bash /volume2/homes/helixzz/twc-zhcn/deploy-synology.sh deploy
```

常用管理命令：

```bash
# 查看当前 Web 目录、已安装版本与历史备份快照
bash /volume2/homes/helixzz/twc-zhcn/deploy-synology.sh status

# 一键回滚至升级前的官方原版 WebUI
sudo bash /volume2/homes/helixzz/twc-zhcn/deploy-synology.sh rollback
```

安装完成后，在浏览器访问 `http://<群晖IP>:9091/transmission/web/` 并按 `Ctrl+F5` 强制刷新即可。

## 本地开发与构建

```bash
npm install
node build.js          # 重新打包压缩 src/tr-web-control/script/min/*.min.js
node build.js --check  # 仅校验压缩产物语法
node test-compat.js    # 运行 JSON-RPC 2.0 兼容层与桌面详情组件单元测试
```

## 致谢与许可

* 原作者：[栽培者 (ronggang)](https://github.com/ronggang/transmission-web-control) 及全体贡献者
* Transmission 4.x 特性与构建工具参考：[uuunit/transmission-web-control](https://github.com/uuunit/transmission-web-control)
* JSON-RPC 2.0 协议适配与桌面分栏参考：[wzya2026/transmission-web-control-zhcn](https://github.com/wzya2026/transmission-web-control-zhcn)

遵循 [MIT License](LICENSE) 开源许可。
