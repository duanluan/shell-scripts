# shell-scripts

个人常用 Shell 脚本集合，主要用于 Linux 桌面、Arch AUR 打包辅助和网络下载加速。

## 快速索引

| 脚本 | 主要用途 | 典型环境 | 权限/副作用 |
| --- | --- | --- | --- |
| `activate-wechat.sh` | 激活托盘微信窗口（X11/Wayland） | Linux 桌面 | 可能自动安装依赖 |
| `aur-fix-checksums-and-make.sh` | 遇到 source 校验失败时自动更新 `PKGBUILD` 校验值并继续构建 | Arch Linux / AUR 构建目录 | 会改写 `PKGBUILD` 并执行 `makepkg -si` |
| `github-mirror-axel.sh` | 用镜像包装 `axel` 下载 GitHub 资源 | 通用 Linux | 会创建缓存文件、自我更新 |
| `github-wrappers.sh` | 包装 `curl`/`wget`，自动改写 GitHub URL | 交互式 shell | 仅当前 shell 生效 |
| `install-hmcl.sh` | 手动方式安装最新 HMCL 并创建桌面启动器 | Linux 桌面 | 会写 `~/.local/share/hmcl` 和 `.desktop` 文件 |
| `install-jdk-dragonwell.sh` | 交互式下载并安装 Dragonwell JDK | Debian/RedHat 系 | 会写 `/opt/java`、`/etc/profile` |
| `install-launcherx-bin.sh` | 自动更新并构建 AUR `launcherx-bin` | Arch Linux | 会执行 `makepkg -si` 安装 |
| `navicat-manager.sh` | 管理 Navicat Linux 配置：备份、恢复、检查和 reset | Linux 桌面 + Navicat 16/17 | 会读写 `~/.config/navicat` 和对应 dconf 项，会创建缓存文件、自我更新 |
| `prepare-jetbrains-zh-plugin.sh` | 自动为 JetBrains 系 IDE 准备可从磁盘安装的中文语言包 | Linux + JetBrains IDE 安装目录 | 会下载或重打包插件 jar 到本地 |
| `reset_screen.sh` | 关闭再重开指定显示器输出 | X11 + xrandr |  |
| `synology-ignore-monitor.bat` | Windows 下监控并注入 Synology Drive 忽略规则 | Windows + Synology Drive Client + AlwaysUp | 建议作为 AlwaysUp 常驻任务运行；若脚本依赖 `%LOCALAPPDATA%` 等用户环境变量，需在 AlwaysUp 中填写用户和密码 |
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

Windows 下的 `.bat` 常驻脚本统一建议通过 AlwaysUp 运行，不建议直接双击后挂在前台窗口。

如果 `.bat` 脚本中使用了 `%LOCALAPPDATA%` 这类用户环境变量，必须在 AlwaysUp 的 `Logon` 页签中勾选“Instead of running the application in the Local System Account... run the application using this user”，并填写实际登录用户和密码；否则服务以 `Local System` 运行时，拿到的不是目标用户的目录。

## 脚本说明

### `activate-wechat.sh`
- 功能：将微信窗口从任务栏/托盘激活到前台，支持 X11 与 Wayland（依赖 XWayland 窗口可见）。
- 核心流程：加锁防连按并发 -> 检查/安装依赖 -> 尝试关闭当前微信窗口到托盘 -> 通过 `StatusNotifierItem.Activate` 激活。
- 依赖：`dbus-send`、`qdbus`、`wmctrl`；缺失时会尝试通过 `apt/pacman/dnf/yum` 自动安装。
- 注意事项：
  - 默认微信路径是 `/usr/bin/wechat`。
  - 非终端运行时优先走 `pkexec`；若无 `pkexec` 且 `sudo` 需密码，会直接退出避免死锁。
  - 锁文件位于 `/tmp/activate-wechat-${USER}.lock`。

### `aur-fix-checksums-and-make.sh`
- 功能：在 AUR 包目录里先执行 `makepkg --verifysource`，如果发现一个或多个 source 校验失败，就自动调用 `updpkgsums` 更新 `PKGBUILD`，再继续执行 `makepkg -si`。
- 适用场景：上游文件内容发生变化，但 AUR 仓库里的校验值还没跟上，例如 `visual-studio-code-bin` 这类会抓取多个上游文本文件的包。
- 用法：
  - 在包目录执行：`bash ./aur-fix-checksums-and-make.sh`
  - 传目录执行：`bash ./aur-fix-checksums-and-make.sh ~/.cache/paru/clone/visual-studio-code-bin`
  - `yay` 目录执行：`bash ./aur-fix-checksums-and-make.sh ~/.cache/yay/visual-studio-code-bin`
  - 直接传包名：`aur-fix-checksums-and-make visual-studio-code-bin`
  - 透传 `makepkg` 参数：`bash ./aur-fix-checksums-and-make.sh . --noconfirm`
  - 强制自更新：`aur-fix-checksums-and-make --self-update`
- 行为说明：
  - 只要没有发现校验失败，就不会改写 `PKGBUILD`，并会先提示“无需修改”，再询问是否继续执行 `makepkg -si`。
  - 发现失败时会先备份一份 `PKGBUILD.bak.<时间戳>`。
  - 更新校验值后会再检查一次 source；若仍失败则停止，避免继续构建。
  - 默认带 24 小时冷却的自动更新检查；更新检查失败时会自动跳过，不影响后续构建流程。
  - 如果 `paru` 和 `yay` 的缓存目录同时存在，会按序号提示你选择使用哪个目录。

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

### `install-hmcl.sh`
- 功能：按手动安装思路自动获取 HMCL 最新 GitHub Release 的 jar，安装到 `~/.local/share/hmcl`，并创建 `hmcl.desktop`。
- 关键流程：检查 `curl/jq/java` -> 查询 GitHub Releases 最新版本 -> 下载 jar 与图标 -> 写入桌面启动器。
- 依赖：`curl`、`jq`、`java`。
- 行为说明：
  - jar 固定安装为 `~/.local/share/hmcl/HMCL.jar`，并额外写入 `~/.local/share/hmcl/VERSION` 用于版本判断。
  - 启动参数默认带 `-Dglass.gtk.uiScale=1.5`，可通过环境变量 `HMCL_UI_SCALE` 覆盖。
  - 若本地已是相同版本，交互式终端会询问是否强制重装；非交互式调用会直接退出。

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

### `navicat-manager.sh`
- 功能：管理 Navicat Linux 本地配置，支持 `backup`、`restore`、`inspect`、`reset` 和 `--self-update`。
- 适配格式：
  - `Common/connections.json` 中的 `Users[].Projects[].Servers[]`、旧版 `Connections[]` / `connections[]`。
  - `Common/ui_connections.json` 中的 UI 连接记录。
  - `Premium/preferences.json` 中的 `CloudSessions*`、`Clouds`、`Recents*`、`Continues*`、`AutoSaves*`。
- 默认路径：
  - 配置目录：`~/.config/navicat`
  - 产品目录：`~/.config/navicat/Premium`
  - 备份目录：`~/navicat-backups/backup-<timestamp>`
  - dconf 路径：`/com/premiumsoft/navicat-premium/`
- 备份内容：
  - `~/.config/navicat/Common/connections.json`
  - `~/.config/navicat/Common/ui_connections.json`
  - `~/.config/navicat/Common/system_wide_preferences.json`
  - `~/.config/navicat/Premium/preferences.json`
  - `~/.config/navicat/Premium/ui_preferences.json`
  - `dconf dump /com/premiumsoft/navicat-premium/` 的输出
- 用法：
  - 查看帮助：`bash ./navicat-manager.sh -h`
  - 检查当前配置：`bash ./navicat-manager.sh inspect`
  - 创建完整备份：`bash ./navicat-manager.sh backup`
  - 从备份恢复：`bash ./navicat-manager.sh restore ~/navicat-backups/backup-20260525-164822 --kill`
  - reset 并保留连接、UI 设置和云账号会话：`bash ./navicat-manager.sh reset`
  - 只预览操作：`bash ./navicat-manager.sh restore <backup-dir> --dry-run`
  - 强制自更新：`bash ./navicat-manager.sh --self-update`
- 常用选项：
  - `--config-dir <dir>`：指定 Navicat 配置目录，默认 `~/.config/navicat`。
  - `--backup-root <dir>`：指定备份根目录，默认 `~/navicat-backups`。
  - `--product <name>`：指定产品目录名，默认 `Premium`。
  - `--kill`：执行动作前关闭 `navicat` / `Navicat` 进程。
  - `--yes`：跳过确认提示。
  - `--dry-run`：只显示将要执行的操作，不修改文件。
  - `--self-update`：从远端更新脚本本身后退出。
- `reset` 流程：
  - 先保存当前 `Common` 和 `Premium` 配置。
  - 重置当前产品对应的 dconf 路径。
  - 删除 `preferences.json` 和 `preferences.json.lock`。
  - 提示启动 Navicat，并等待新的 `preferences.json` 生成。
  - 检测到新配置后询问是否自动关闭 Navicat，默认不关闭。
  - Navicat 退出后恢复连接、UI 设置和云账号会话字段。
- 注意事项：
  - 依赖 `jq`；自更新需要 `curl`；有 `dconf` 时会读写对应 dconf 项。
  - 脚本内置中英文提示，会根据 `LANG` 自动切换，单文件下载后即可运行。
  - 执行动作前会做一次 24 小时冷却的自动更新检查，缓存文件为 `~/.cache/navicat-manager.last_check`；可用 `NAVICAT_MANAGER_UPDATE_URL` 覆盖更新源。
  - `restore` 会先自动创建一份安全备份，再写入目标配置。
  - 恢复 `preferences.json` 时只合并可迁移字段，不覆盖新生成配置里的其它字段。
  - `reset` 过程中，看到“请启动 Navicat”就启动；询问“是否自动关闭 Navicat”时可按需选择。若界面已关闭但仍提示运行中，可重新执行 `bash ./navicat-manager.sh reset --kill`。
  - 云账号会话过期时仍需要在 Navicat 内重新登录，脚本只能保留本地已有会话和连接数据。

### `prepare-jetbrains-zh-plugin.sh`
- 功能：自动发现本机 JetBrains IDE，自动查找中文语言包来源，并生成适配目标 IDE 的 `localization-zh.jar`。
- 关键流程：自动扫描 `/opt/jetbrains`、Toolbox 目录、`PATH` 里的 JetBrains 启动命令（含 `rebased`）-> 默认自动定位 Android Studio，或用 `--ide`/`--as` 显式指定目标 IDE -> 中文包来源按 `--source` -> `--jb` -> Marketplace -> 本机其它 JetBrains IDE 自带 `plugins/localization-zh/lib/localization-zh.jar` 的顺序选择 -> 自动改写 `META-INF/plugin.xml` -> 重新打包为可从磁盘安装的 jar。
- 默认行为：未指定目标时，安装到当前用户的 Android Studio 插件数据目录；若设置了 `XDG_DATA_HOME` 则使用它，否则使用 `~/.local/share`。目录名优先取 IDE 实际 selector，其次回退到 `dataDirectoryName`。例如 Android Studio 写到 `~/.local/share/Google/AndroidStudio2025.3.2/localization-zh.jar`，`rebased` 写到 `~/.local/share/JetBrains/IdeaIC1.0/localization-zh.jar`。
- `--output`：额外导出一份 jar 到指定路径，同时仍会安装到目标 IDE 的插件数据目录。
- 参数：
  - `--jb <目录或启动命令路径或命令名>`：显式指定 JetBrains IDE 安装目录、启动命令路径或命令名，优先用它的 `localization-zh.jar` 作为中文包来源。
  - `--ide <目录或启动命令路径或命令名>` / `--target <目录或启动命令路径或命令名>`：显式指定目标 IDE，适合 `rebased`、IDEA 等非 Android Studio 目标。
  - `--as <目录或启动命令路径或命令名>`：显式指定 Android Studio 安装目录、启动命令路径或命令名，兼容旧用法。
  - `--source <jar|zip>`：直接指定中文包，优先级高于 `--jb`。
- 用法：
  - 查看已发现 IDE：`bash ./prepare-jetbrains-zh-plugin.sh --list`
  - 为自动发现到的 Android Studio 直接安装：`bash ./prepare-jetbrains-zh-plugin.sh`
  - 为 `rebased` 直接安装：`bash ./prepare-jetbrains-zh-plugin.sh --ide rebased`
  - 指定 JB 与 Android Studio 路径：`bash ./prepare-jetbrains-zh-plugin.sh --jb /path/to/idea --as /path/to/studio`
  - 指定 JB 与 `rebased` 路径：`bash ./prepare-jetbrains-zh-plugin.sh --jb /path/to/idea --ide rebased`
  - 指定源包并直接安装：`bash ./prepare-jetbrains-zh-plugin.sh --source ~/Downloads/localization-zh.jar --as /path/to/studio`
  - 给 `rebased` 指定源包：`bash ./prepare-jetbrains-zh-plugin.sh --source ~/Downloads/localization-zh.jar --ide rebased`
  - 额外导出一份 jar：`bash ./prepare-jetbrains-zh-plugin.sh --jb /path/to/idea --ide rebased --output ~/Downloads/localization-zh.jar`

### `reset_screen.sh`
- 功能：通过 `xrandr` 对显示器执行一次 `off -> on`，用于恢复唤醒异常或主屏错乱。
- 默认自动选择已连接输出口，优先当前主屏和已启用输出，兼容 NVIDIA 常见的 `HDMI-0` 与 AMD/迷你主机常见的 `HDMI-A-0`。
- 可通过第一个参数或 `RESET_SCREEN_OUTPUT` 指定输出口：`./reset_screen.sh HDMI-0`、`RESET_SCREEN_OUTPUT=HDMI-A-0 ./reset_screen.sh`。

### `synology-ignore-monitor.bat`
- 功能：Windows 版 Synology Drive 忽略规则监控脚本，持续轮询 `%LOCALAPPDATA%\SynologyDrive\data\session` 下的 `blacklist.filter`，自动补写统一忽略规则。
- 运行方式：建议在 AlwaysUp 中创建应用并长期运行该 `.bat`。
- 注意事项：
  - 本脚本依赖 `%LOCALAPPDATA%`，所以在 AlwaysUp 中不能使用默认的 `Local System Account`。
  - 请在 AlwaysUp 的 `Logon` 页签中指定实际 Windows 登录用户，并保存对应密码，否则脚本可能找不到正确的 Synology Drive session 目录。
  - 脚本会持续轮询并直接修改 Synology Drive 客户端配置文件。

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
