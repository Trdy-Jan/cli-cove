# cli-cove

个人 Linux 运维脚本合集，通过一个统一入口 `main.bash` 以键盘（方向键/回车/数字键）驱动的菜单来选择并执行脚本。

## 依赖

- Bash 4+
- `whiptail` 或 `dialog`（二选一即可，启动时会自动探测；都没有会提示对应发行版的安装命令）

## 快速开始

```bash
chmod +x main.bash
./main.bash
```

菜单操作：↑/↓ 移动选项、数字键直接跳转到对应编号的项、回车确认、ESC/Cancel 返回上一级（在顶层菜单则退出程序）。

## 目录结构

```
cli-cove/
├── main.bash              # 入口：依赖检查 -> 扫描 scripts/ -> 菜单导航循环
├── lib/                   # 公共库，业务脚本可选 source 复用
│   ├── colors.sh          # 颜色常量
│   ├── log.sh              # log::info/warn/error/success/debug
│   ├── die.sh               # die() 统一错误退出
│   ├── deps.sh               # 依赖探测（whiptail/dialog）
│   ├── ui_backend.sh          # 封装 whiptail 与 dialog 差异
│   ├── menu_scan.sh            # 扫描 scripts/ 并解析头部元数据
│   ├── menu_render.sh           # 两级菜单导航状态机
│   └── paths.sh                  # 健壮的自身目录解析（兼容软链/空格）
├── scripts/
│   ├── <category>/         # 一个子目录 = 菜单里的一个分类
│   │   └── xxx.sh           # 具体脚本，菜单项由头部注释元数据生成
│   └── _template/           # 以 "_" 开头的目录不会出现在菜单里，仅存放模板
└── tests/
    └── run_tests.sh          # 轻量 smoke test
```

## 新增一个脚本

1. 选一个已有分类目录（`scripts/<category>/`），或直接新建一个目录——**无需在任何地方“注册”**，菜单会自动扫描到。
2. 复制模板作为起点：
   ```bash
   cp scripts/_template/template_with_lib.sh scripts/<category>/新脚本.sh
   ```
3. 修改文件头部的元数据注释：
   ```bash
   #!/bin/bash
   # @title: 脚本标题（必填建议，缺失则用文件名代替）
   # @desc: 一句话描述（可选）
   # @order: 10        # 可选，数值越小在菜单中越靠前，缺省排在后面
   ```
4. 编写脚本主体逻辑，可选 `source` 公共 lib（模板中已演示健壮写法）。
5. 先脱离菜单验证能独立运行：`bash scripts/<category>/新脚本.sh`，再通过 `./main.bash` 验证菜单集成。菜单会以 `bash <script>` 方式调用脚本，无需手动 `chmod +x`；若想用 `./新脚本.sh` 直接执行，才需要自行赋予执行权限。

全程不需要修改 `main.bash`、`lib/` 或任何清单文件。

## lib 函数速查

| 函数 | 说明 |
|---|---|
| `log::info/warn/error/success/debug` | 统一格式日志输出（`CLI_COVE_DEBUG=1` 开启 debug，`CLI_COVE_LOG_TIMESTAMP=0` 关闭时间戳） |
| `die "msg" [code]` | 打印错误并 `exit`（不改变引入方的 `set -e`/`-u` 行为） |
| `deps::has_cmd <cmd>` | 判断命令是否存在 |
| `deps::check_ui_backend` | 探测可用的 `whiptail`/`dialog`，可用 `CLI_COVE_UI_BACKEND` 强制指定 |
| `deps::print_install_hint` | 按发行版打印安装命令 |
| `ui::menu` / `ui::msgbox` | 封装 whiptail/dialog 差异的菜单与提示框 |
| `menu_scan::list_categories` | 列出所有有效分类 |
| `menu_scan::list_scripts_in_category` | 列出某分类下按 `@order` 排序的脚本 |
| `menu_scan::parse_metadata` | 解析脚本头部元数据到 `META_TITLE`/`META_DESC`/`META_ORDER` |
| `paths::resolve_dir` | 解析文件所在真实目录（兼容软链接） |

## 常见问题

- **启动报错找不到 whiptail/dialog**：按提示的安装命令安装其中一个即可（如 `sudo apt install -y whiptail`）。
- **脚本执行失败**：菜单会显示退出码并暂停等待回车，方便查看脚本自身打印的报错信息。

## 测试

```bash
bash tests/run_tests.sh
```
