# shell-scripts

个人常用 Shell 脚本集合，主要用于 Linux 桌面、Arch AUR 打包辅助和网络下载加速。

## 快速索引

| 脚本 | 主要用途 | 典型环境 | 权限/副作用 |
| --- | --- | --- | --- |
| `activate-wechat.sh` | 激活托盘微信窗口（X11/Wayland） | Linux 桌面 | 可能自动安装依赖 |
| `github-mirror-axel.sh` | 用镜像包装 `axel` 下载 GitHub 资源 | 通用 Linux | 会创建缓存文件、自我更新 |
| `github-wrappers.sh` | 包装 `curl`/`wget`，自动改写 GitHub URL | 交互式 shell | 仅当前 shell 生效 |
| `install-jdk-dragonwell.sh` | 交互式下载并安装 Dragonwell JDK | Debian/RedHat 系 | 会写 `/opt/java`、`/etc/profile` |
| `install-launcherx-bin.sh` | 自动更新并构建 AUR `launcherx-bin` | Arch Linux | 会执行 `makepkg -si` 安装 |
| `reset_screen.sh` | 关闭再重开指定显示器输出 | X11 + xrandr |  |
| `synology-ignore-monitor.sh` | 监控并注入 Synology Drive 忽略规则 | Linux + Synology Drive Client | 持续监控并修改配置文件 |
| `update-github-hosts.sh` | 更新 GitHub hosts 并创建 cron 定时任务 | 通用 Linux | 必须 root，修改 `/etc/hosts`、`/etc/cron.d` |
| `termius-update.sh` | 自动更新 AUR `termius` 的 PKGBUILD | Arch Linux | 进入临时 shell，用户手动构建 |

## 通用使用方式

```bash
chmod +x ./*.sh
```

单次执行脚本：

```bash
bash ./script-name.sh
```

`github-wrappers.sh` 例外，需要 `source` 到当前 shell：

```bash
source ./github-wrappers.sh
```

## 脚本说明

### `activate-wechat.sh`
- 功能：将微信窗口从任务栏/托盘激活到前台，支持 X11 与 Wayland（依赖 XWayland 窗口可见）。
- 核心流程：加锁防连按并发 -> 检查/安装依赖 -> 尝试关闭当前微信窗口到托盘 -> 通过 `StatusNotifierItem.Activate` 激活。
- 依赖：`dbus-send`、`qdbus`、`wmctrl`；缺失时会尝试通过 `apt/pacman/dnf/yum` 自动安装。
- 注意事项：
  - 默认微信路径是 `/usr/bin/wechat`。
  - 非终端运行时优先走 `pkexec`；若无 `pkexec` 且 `sudo` 需密码，会直接退出避免死锁。
  - 锁文件位于 `/tmp/activate-wechat-${USER}.lock`。

### `github-mirror-axel.sh`
- 功能：对 `axel` 下载做镜像加速与重试，目标 URL 为 GitHub 域名时自动选镜像，配合 AUR 使用。
- 用法：
  - `bash github-mirror-axel.sh <output_file> <url>`
  - `bash github-mirror-axel.sh --self-update`（强制自更新）
- 特性：
  - 仅 `github.com` 与 `raw.githubusercontent.com` 使用代理逻辑。
  - 多镜像随机选择，重试时尽量避开上次失败镜像。
  - 镜像下载速度低于阈值时会中断并切换；最后一次尝试禁用低速检测兜底。
  - 24 小时冷却的自动更新检查（缓存：`~/.cache/github-mirror-axel.last_check`）。
- 依赖：`axel`、`curl`、`awk`、`stat`、`grep` 等常见工具。

### `github-wrappers.sh`
- 功能：定义同名函数包装 `wget` 和 `curl`，将参数中的 GitHub URL 改写为镜像前缀 `https://gh-proxy.com/https://`。
- 使用方式：`source ./github-wrappers.sh`，之后在该 shell 会话中 `curl/wget` 自动生效。
- 注意事项：
  - 仅在脚本被 `source` 的 shell 中生效。
  - 通过 `command wget` / `command curl` 调原始命令，避免递归调用。

### `install-jdk-dragonwell.sh`
- 功能：从 Dragonwell 发布 JSON 中读取版本，交互式选择下载包并安装到 `/opt/java`。
- 关键操作：
  - 自动安装 `jq`、`wget`（仅内置 Debian/RedHat 分支）。
  - 清理旧版本目录并解压新包。
  - 直接修改 `/etc/profile` 中 `JAVA_HOME` 与 `PATH`。
- 注意事项：
  - 需要 root 或 sudo（涉及系统目录与 `/etc/profile`）。
  - 执行前建议备份 `/etc/profile`。
  - 依赖外网访问：`https://dragonwell-jdk.io/releases.json`。

### `install-launcherx-bin.sh`
- 功能：自动获取 LauncherX 最新 stable linux-x64 构建，更新 AUR `launcherx-bin` 的 `PKGBUILD` 并安装。
- 关键流程：依赖检查 -> 克隆 AUR -> 调 Corona Studio API -> 更新 `pkgver/source` -> `updpkgsums` -> `makepkg -si`。
- 依赖：`jq`、`curl`、`git`、`updpkgsums`（`pacman-contrib`）、`makepkg`（`base-devel`）、`sed`。
- 适用环境：Arch Linux / Manjaro 等 `pacman` 生态。

### `reset_screen.sh`
- 功能：通过 `xrandr` 对显示器执行一次 `off -> on`，用于恢复唤醒异常或主屏错乱。
- 当前默认输出口：`HDMI-0`。
- 使用前建议先运行 `xrandr` 确认你的真实输出口名称，再改脚本中的接口名。

### `synology-ignore-monitor.sh`
- 功能：监控 `~/.SynologyDrive/data/session` 下的 `blacklist.filter`，自动注入统一忽略规则（如 `.git`、`node_modules`、`venv`、`dist` 等）。
- 关键行为：
  - 若缺少 `inotifywait`，会尝试自动安装 `inotify-tools`（仅在 root、`sudo -n` 免密、或交互式终端可输入密码时）。
  - `pacman` 环境下若检测到 `/etc/pacman.d/mirrorlist` 没有 `Server`，会先尝试调用 `pacman-mirrors` 自动修复镜像列表再安装。
  - 自动安装失败时会降级为轮询模式（默认每 5 秒检查一次，可用 `POLL_INTERVAL` 调整）。
  - 启动后先全量扫描并注入一次，再持续监听文件变更并自动补写。
- 注意事项：
  - 该脚本会长期运行（前台监控）。
  - 会直接修改 Synology Drive 客户端 session 配置文件。

### `update-github-hosts.sh`
- 功能：下载 GitHub hosts 内容并写入 `/etc/hosts`，同时创建 cron 每日更新任务。
- 执行要求：必须 root 运行。
- 关键操作：
  - 从 `https://ghfast.top/https://raw.githubusercontent.com/ittuann/GitHub-IP-hosts/refs/heads/main/hosts_single` 下载内容。
  - 先删除 `/etc/hosts` 中 `# GitHub IP hosts Start` 到 `# GitHub IP hosts End` 块，再追加新内容。
  - 写入 `/etc/cron.d/update-github-hosts`，计划任务为 `0 1 * * * root /bin/bash <脚本绝对路径>`。
- 注意事项：
  - 建议先备份 `/etc/hosts`。
  - 该脚本会覆盖同名 cron 文件。

### `termius-update.sh`
- 功能：自动更新 AUR `termius` 的 `PKGBUILD` 版本和下载地址。
- 关键流程：
  - 下载官方 `Termius.deb` 并解析 changelog 得到目标版本。
  - 查询 Snapcraft API 获取下载 URL。
  - 更新 `PKGBUILD` 的 `pkgver` 和 source，执行 `updpkgsums`。
  - 最后进入临时目录的子 shell，供用户手动执行 `makepkg -si`。
- 依赖：`jq`、`updpkgsums`、`ar`（`binutils`）、`git`、`wget`、`curl`、`zcat`。
- 适用环境：Arch Linux / Manjaro。

## 安全与维护建议

- 会修改系统文件的脚本请先在测试环境验证：`install-jdk-dragonwell.sh`、`update-github-hosts.sh`。
- 会长期驻留/监控的脚本建议使用 `systemd --user` 或 `tmux/screen` 管理：`synology-ignore-monitor.sh`。
- 与外部接口强绑定的脚本（AUR/API/镜像）可能因上游变更失效，建议定期回归测试。
