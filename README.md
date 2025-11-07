# shell-scripts

存储一些自己写的 shell 脚本

## 仓库脚本列表

以下列出仓库中包含的脚本，并对每个脚本的功能、依赖与使用方法做简要说明：

### `activate-wechat.sh`
- 功能：激活托盘区或任务栏中的微信主窗口，使微信窗口从托盘弹出并置于前台。
- 主要行为：检测微信进程，若存在任务栏窗口则先关闭使其最小化到托盘，然后通过 D-Bus（StatusNotifierItem）激活托盘中的微信。
- 依赖：`dbus-send`、`qdbus`、`wmctrl`。脚本包含简单的包管理器检测（apt/pacman/dnf/yum）并尝试自动安装缺失依赖。
- 注意：脚本默认微信可执行文件位于 `/usr/bin/wechat`，如果你安装在其他位置，请修改脚本中的 `wechat_path`。

### `github-wrappers.sh`
- 功能：提供对 `curl` 和 `wget` 的 shell 包装器（函数），自动将参数中的 GitHub URL 替换为镜像地址（示例使用 `https://gh-proxy.com/https://` 前缀），以便在网络不稳定或被限时加速下载。
- 使用方法：在交互式 shell 或你的 shell 启动脚本（如 `~/.bashrc` / `~/.zshrc`）中 source 该脚本以启用包装器：
  - 示例：在 `~/.bashrc` 中添加 `source /path/to/github-wrappers.sh`（请替换为实际路径）。
- 注意：包装器通过定义同名函数覆盖系统命令，然后用 `command curl` / `command wget` 调用原始可执行文件；如果脚本被 source，在当前 shell 会话中生效。

### `install-jdk-dragonwell.sh`
- 功能：交互式从 Dragonwell 项目（Alibaba Dragonwell JDK）抓取发行列表，列出可用版本与下载链接，下载并安装到 `/opt/java`，并将 JAVA_HOME、PATH 写入 `/etc/profile`。
- 依赖：`jq`、`wget`（脚本会尝试基于发行版使用 apt 或 yum 安装这些依赖）；需要网络访问 `https://dragonwell-jdk.io/releases.json`。
- 注意：脚本会修改系统级 `/etc/profile`，因此建议以 root 或使用 sudo 执行；并在安装目录写入文件（默认 `/opt/java`）。

### `update-github-hosts.sh`
- 功能：下载预定义的 GitHub hosts 列表并追加到系统 `/etc/hosts`，同时在 `/etc/cron.d/` 中创建定时任务（每天 01:00）来自动更新该 hosts 文件。
- 依赖：`curl`（用于下载 hosts 内容）。
- 注意：脚本必须以 root 权限运行（会写入 `/etc/hosts` 和 `/etc/cron.d/`），并且会覆盖或更新 `/etc/cron.d/update-github-hosts`。

## 其他说明与安全提醒
- 在对系统文件（如 `/etc/hosts`、`/etc/profile`、`/etc/cron.d/`）进行修改的脚本执行前，请先备份相关文件。
- 以 root 权限运行的脚本会对系统产生持久变化，执行前请确认脚本逻辑并在受控环境下测试。
- 若需自定义路径或行为，请直接编辑相应脚本中的变量（脚本顶部通常有说明），或在执行前导出环境变量覆盖默认值。

## 如何帮助改进文档
如果你希望我为每个脚本补充更详细的使用示例或添加安装/卸载步骤，告诉我你想要的格式（例如命令示例或交互式演示），我会把 README 更新为更完整的使用手册。
