# Repository Guidelines

## 项目结构与模块组织

- `link_video.sh`：唯一入口，包含参数解析、文件筛选、预览、硬链接创建、交互重命名和撤销逻辑。默认处理 `.mp4`、`.mkv`，递归模式处理所有文件。
- `README.md`：项目说明；修改用户可见行为时同步补充用法。
- `.gitignore`：忽略运行记录 `vlink_last_run.log`。记录写入脚本所在目录，供 `-undo` 使用，不应提交。

## 构建、检查与本地运行

无需构建或安装包依赖。使用 Bash 4+（脚本使用关联数组），并确保 `find`、`sort`、`realpath`、`ln` 等工具可用。在 Windows 上使用具备这些工具的 Bash 环境。

```bash
bash -n link_video.sh                 # 检查语法
shellcheck link_video.sh              # 静态检查
shfmt -d -i 2 link_video.sh            # 查看格式差异
bash link_video.sh --help             # 查看参数
bash link_video.sh ./sample-source    # 仅预览
bash link_video.sh -op ./sample-source -lp ./sample-target -sn s01e01
```

目标目录必须已存在；创建硬链接时源与目标必须位于同一文件系统。优先使用命名参数，避免位置参数识别产生歧义。

## 编码风格与命名约定

沿用两空格缩进、`snake_case` 函数名、现有大写配置变量和小写局部变量风格。函数内临时变量使用 `local`；路径和数组展开应正确引用。文件遍历优先使用空字符分隔，保留空格和中文文件名。保持中文提示清楚一致，修改选项时同步更新 `show_help`。格式检查只用于审阅，避免无关的整文件重排。

## 测试指南

当前没有测试框架或覆盖率门槛。修改脚本后执行语法、静态检查，并在隔离的临时目录中手动验证受影响模式。覆盖预览、序号范围、正则过滤、原名模式、递归结构、重名交互和撤销；加入空格及中文文件名。通过 `test source-file -ef target-file` 验证硬链接身份，检查退出码、输出和运行记录。

## 提交与 Pull Request

采用约定式提交（Conventional Commits）：`<type>(<scope>): <description>`，其中 scope 可省略。常用类型为 `feat`、`fix`、`docs`、`refactor`、`test` 和 `chore`，例如 `fix(sequence): 修正起始序号解析`。破坏性变更使用 `!` 标记或在正文中添加 `BREAKING CHANGE:`。每次提交聚焦一个目的。

PR 应说明问题、行为变化、复现命令和验证结果；有关联 issue 时附链接，交互变化附终端输出即可。

## 文件操作注意事项

硬链接共享文件内容，默认模式可覆盖目标，`-undo` 会按运行记录删除文件并递归删除目录。验证写入和撤销时使用专用测试目录，避免混入其他文件。
