# 软件包镜像离线导入导出（mirror-sync）设计文档

日期: 2026-08-17
状态: 待用户复核

## 背景与目标

为 Verdaccio（NPM）、Devpi（Python）等镜像仓库提供通用的离线导入导出能力：

- 导出端：首次全量导出；此后基于上一次导出状态做增量导出（仅新增/变化的文件），
  产出可刻录光盘传输的离线数据包，并带版本信息与完整性校验信息。
- 导入端：在隔离内网环境校验数据包完整性，支持全量初始化或增量合并，具备
  导入顺序检查与重复导入保护，确保内网 Verdaccio/Devpi 服务在导入后能正常
  查询、下载、安装已同步的软件包。

非目标（明确不做）：

- 不处理源端软件包的删除/下架同步（镜像仓库以追加为主，增量只处理新增/变化文件）。
- 不支持同一后端配置多个仓库实例（如两个独立的 Verdaccio storage 目录）——
  每个后端只有一份配置路径，YAGNI。
- 导入完成后不自动重启 Verdaccio/Devpi 服务，只打印重启提示命令；提示命令
  根据 `*_DEPLOY_TYPE`（`systemd` 或 `docker-compose`）生成，不支持 systemd/
  docker-compose 之外的部署方式（如 k8s）。
- 不做数据签名（GPG 等）体系，完整性校验仅用 sha256。

## 架构

**共享核心 + 每后端一对具体脚本**，与项目现有“每个业务脚本独立可运行”的约定一致。

```
lib/
  mirror_sync.sh          # 新增：通用的配置/清单/差异/校验/状态读写函数

scripts/
  mirror_sync/             # 新增分类
    configure.sh            # 查看/编辑 config.env
    npm_export.sh            # Verdaccio 导出（全量/增量自动判定）
    npm_import.sh             # Verdaccio 导入
    python_export.sh          # Devpi 导出
    python_import.sh          # Devpi 导入
```

`main.bash`/`lib/menu_scan.sh` 无需改动——按约定自动扫描到新分类。

每个业务脚本遵循模板约定：`set -euo pipefail`、条件 `source` lib（找不到时降级为最小
日志函数）、可独立 `bash scripts/mirror_sync/xxx.sh` 运行。四个脚本本身只负责“后端
特有的部分”：

- 后端标识（`BACKEND=npm` / `BACKEND=python`）
- 配置项键名与首次配置时的提示文案（存储目录路径）
- 服务重启提示命令（如 `systemctl restart verdaccio`）
- Devpi 专属：导出前先跑 `devpi-server --export=<tmp_dir>` 生成一份干净的文件系统
  快照，再把 `<tmp_dir>` 当作“存储目录”交给共享流水线（原因见下方“后端适配说明”）。

其余（配置读写、清单生成、增量差异、打包、校验、状态读写、顺序/去重检查）全部走
`lib/mirror_sync.sh` 的通用函数。

## 配置

单一配置文件：`${CLI_COVE_STATE_DIR:-$HOME/.cli-cove}/mirror-sync/config.env`，
纯 `KEY=value` 文本（可直接 `source`），不引入 jq 等额外依赖。

字段：

| Key | 说明 | 默认值提示 |
|---|---|---|
| `NPM_STORAGE_DIR` | Verdaccio storage 目录 | `/opt/verdaccio/storage` |
| `NPM_DEPLOY_TYPE` | Verdaccio 部署方式：`systemd` 或 `docker-compose` | `systemd` |
| `NPM_SERVICE_NAME` | 重启提示用的服务名（systemd 单元名，或 compose service 名） | `verdaccio` |
| `NPM_COMPOSE_DIR` | Verdaccio 的 `docker-compose.yml` 所在目录（`NPM_DEPLOY_TYPE=docker-compose` 时使用） | 空 |
| `PYTHON_SERVER_DIR` | Devpi server-dir | `/opt/devpi/server` |
| `PYTHON_DEPLOY_TYPE` | Devpi 部署方式：`systemd` 或 `docker-compose` | `systemd` |
| `PYTHON_SERVICE_NAME` | 重启提示用的服务名（systemd 单元名，或 compose service 名） | `devpi-server` |
| `PYTHON_COMPOSE_DIR` | Devpi 的 `docker-compose.yml` 所在目录（`PYTHON_DEPLOY_TYPE=docker-compose` 时使用） | 空 |
| `EXPORT_OUTPUT_DIR` | 导出包存放目录（供后续刻录） | `$HOME/mirror-exports` |

行为：

- 任一脚本运行时，若所需 key 缺失 → `read -rp` 交互式提示（带默认值）后写入
  `config.env`，随后照常执行。
- `configure.sh` 列出全部 key 当前值，逐个 `read -rp "新值 [$当前值]: "` 确认/修改。
- `--reconfigure` 参数：export/import 脚本支持该 flag，强制重新走一遍对应 key 的
  提示流程（不必打开 configure.sh）。

## 数据包格式

导出产物是一个 tar 包（不额外 gzip——payload 本身多为已压缩的 `.tgz`/`.whl`），
解包后目录结构：

```
<package_root>/
  meta.env              # 元数据，KEY=value 纯文本
  CHECKSUMS.sha256       # sha256sum 标准格式，覆盖 meta.env 自身 + 全部 payload 文件
  files/                  # payload，相对路径与源 storage 目录一一对应
    ...
```

`meta.env` 字段：

| Key | 说明 |
|---|---|
| `BACKEND` | `npm` 或 `python` |
| `CHAIN_ID` | 本次全量导出生成的链标识（见下），增量包继承同一个值 |
| `SEQUENCE` | 本包序号，全量固定为 `0`，增量依次递增 |
| `BASE_SEQUENCE` | 本包所基于的上一个序号；全量包为空 |
| `PACKAGE_ID` | `${BACKEND}-${CHAIN_ID}-seq${SEQUENCE}` 组合出的唯一 id，用于去重 |
| `CREATED_AT` | ISO8601 时间戳 |
| `SOURCE_HOST` | `hostname` 输出 |
| `FILE_COUNT` / `TOTAL_BYTES` | 本包 payload 统计 |

**完整性校验**：`CHECKSUMS.sha256` 用标准 `sha256sum` 输出格式（`<hash>  <relpath>`），
既覆盖 `files/` 下每个文件，也包含 `meta.env` 自己这一行（防止元数据被篡改而未被
发现）。导入时在解包目录内执行 `sha256sum -c CHECKSUMS.sha256`，任何一行不匹配
即视为校验失败并中止导入，不做任何写入。

**为什么不用 JSON**：项目定位是纯 bash、无编译产物、无额外依赖；机器上不保证有
`jq`。清单/元数据一律用 `KEY=value` 或 `sha256sum` 这类可被 coreutils 原生解析
的纯文本格式。

## 链（CHAIN_ID）与顺序检查

单靠“序号递增”不足以判断顺序——如果导出端状态文件丢失导致重新做了一次全量导出，
序号会从 0 重新开始，若只比较序号会把“新链的全量包”误判成“旧链的重复/乱序包”。
因此引入 `CHAIN_ID`：

- 全量导出时用 `date +%s%N`+`$$`+`$RANDOM` 拼出一个新的 `CHAIN_ID`，`SEQUENCE=0`，
  `BASE_SEQUENCE` 为空。
- 增量导出复用导出状态里记录的当前 `CHAIN_ID`，`SEQUENCE` 在上次基础上 +1，
  `BASE_SEQUENCE` 设为上一次的 `SEQUENCE`。

导入端顺序检查（基于 `import_state.env` 里的 `LAST_CHAIN_ID` / `LAST_APPLIED_SEQUENCE`）：

1. 若待导入包是全量包（`BASE_SEQUENCE` 为空）：
   - 若目标端还没有任何导入记录 → 直接作为初始化导入。
   - 若目标端已有其他链的记录 → 视为“新的一条链”，交互式提示用户确认
     （明确告知这会开始一条新链，旧链的增量包将不再能接续），确认后覆盖
     `LAST_CHAIN_ID`/`LAST_APPLIED_SEQUENCE`。
2. 若待导入包是增量包：必须 `CHAIN_ID` 与 `LAST_CHAIN_ID` 相同，且
   `BASE_SEQUENCE == LAST_APPLIED_SEQUENCE`，否则拒绝导入并报错说明期望的
   序号/链。

**重复导入保护**：`import_state` 目录下维护 `applied_ids.list`（每行一个
`PACKAGE_ID`，只追加）。导入前检查 `PACKAGE_ID` 是否已存在于该文件——存在则
视为幂等操作，打印“已导入过，跳过”并以 exit code 0 结束，不重复写入 payload。

文件写入本身也是纯追加式覆盖拷贝（`cp` 到目标 storage 目录下对应相对路径，
存在则覆盖），不做任何删除，全量包重复导入在文件层面本身也是安全的。

## 导出流程

1. 读配置（缺失则交互式补全），确认 storage 目录存在。
2. 读导出状态 `mirror-sync/<backend>/state.env`：
   - 不存在 → 全量导出：`CHAIN_ID` 新生成，`SEQUENCE=0`。
   - 存在 → 增量导出：复用 `CHAIN_ID`，`SEQUENCE = LAST_SEQUENCE + 1`。
3. 遍历 storage 目录生成当前清单（`sha256sum` 格式，相对路径），按后端适配器提供
   的排除规则跳过运行时索引/锁文件。
4. 增量时，将当前清单与状态目录下保存的上一次 `last_checksums.sha256` 比较，
   得到“新增或变化”的相对路径集合（新路径，或路径相同但 hash 不同）。全量时
   直接取全部路径。
5. 把命中的文件拷贝进 staging 目录的 `files/` 下（保持相对路径），生成
   `meta.env`、`CHECKSUMS.sha256`。
6. 打包为 `<backend>-<chain_id前8位>-seq<NN>-<时间戳>.tar`，写入
   `EXPORT_OUTPUT_DIR`。
7. 打包成功后，原子更新导出状态（先写临时文件再 `mv`）：`state.env` 记录新的
   `CHAIN_ID`/`SEQUENCE`，同时把本次完整清单另存为
   `mirror-sync/<backend>/last_checksums.sha256` 供下次比较。

## 导入流程

1. 读配置（缺失则交互式补全），确认目标 storage 目录存在。
2. 用户指定待导入的 tar 包路径，解压到临时目录。
3. `sha256sum -c CHECKSUMS.sha256` 校验；失败则报错退出，不写入任何目标文件。
4. 读取 `meta.env`，确认 `BACKEND` 与当前脚本匹配（防止把 npm 包喂给 python
   导入脚本）。
5. 按“链与顺序检查”规则校验；不满足则报错退出并提示期望状态。
6. 按 `applied_ids.list` 做重复导入检查；命中则提示已导入并 exit 0。
7. 校验全部通过后，才开始把 `files/` 下内容拷贝进目标 storage 目录（先校验
   完再写入，不做半途而废的写入）。
8. 更新 `import_state.env`（`LAST_CHAIN_ID`/`LAST_APPLIED_SEQUENCE`）并追加
   `PACKAGE_ID` 到 `applied_ids.list`。
9. 打印成功信息 + 对应的 `systemctl restart <SERVICE_NAME>` 提示（不自动执行）。

## 后端适配说明

- **Verdaccio（npm）**：storage 目录本身就是按包组织的文件，可以安全地按文件
  粒度做增量拷贝。运行时索引文件（如 `.verdaccio-db.json`）默认排除在清单之外
  ——Verdaccio 重启时会重新扫描 storage 生成索引；具体排除规则需要在实现阶段
  对照实际 Verdaccio 版本验证一次（记为实现期风险点）。
- **Devpi（python）**：Devpi 的落盘状态由内部数据库支撑，不能安全地按任意文件
  粒度做增量拷贝/合并。适配脚本在导出前先执行
  `devpi-server --export=<临时目录>` 得到一份自洽的文件系统快照（这一步仍然
  是“操作文件系统产物”，不涉及运行时 API 调用），再把这个临时目录当作
  “storage 目录”交给共享流水线走清单/差异/打包逻辑。导入方向对称：先把
  payload 合并进一个临时目录，再执行
  `devpi-server --import=<目录> --serverdir=<PYTHON_SERVER_DIR>` 完成落库，而不是
  直接拿 payload 覆盖目标 server-dir 里的数据库文件。这一步的确切命令行参数
  需要在实现阶段对照实际 Devpi 版本验证。
  - `PYTHON_DEPLOY_TYPE=docker-compose` 时（`devpi-server` 二进制不在宿主机
    PATH 上），`mirror_sync::devpi_export`/`devpi_import` 改为在
    `PYTHON_COMPOSE_DIR` 下执行
    `docker compose run --rm -T --entrypoint devpi-server <service>`，并用
    `-v` 把宿主机的 `PYTHON_SERVER_DIR`/快照目录各自 bind mount 到容器内固定
    路径（`/mirror-sync/serverdir`、`/mirror-sync/snapshot`）后传给
    `--serverdir`/`--export`/`--import`。前提是 `PYTHON_SERVER_DIR` 本身是
    宿主机可直接访问的 bind mount 目录（而非具名 volume）。覆盖
    `--entrypoint` 会跳过镜像原始入口脚本可能包含的初始化逻辑（如权限
    修复），需按实际镜像验证，记为实现期风险点。

## 错误处理与日志

- 四个业务脚本均 `set -euo pipefail`，遵循模板约定，条件 `source` lib 并在缺失
  时降级为最小日志函数。
- 校验类操作（配置路径存在性、包完整性、顺序/去重）一律显式检查并给出
  可读错误信息，不静默失败。
- 导入是相对敏感的操作（写入内网镜像的 storage 目录），仿照 `burn_disc.sh`
  的做法额外维护一份持久化日志文件（如
  `mirror-sync/<backend>/import_YYYYmmdd_HHMMSS.log`），方便事后排查；导出
  过程较轻量，只走标准 `log::*` 输出，不单独落盘。
- 所有会修改目标 storage 目录或状态文件的步骤，都放在“全部校验通过”之后
  执行；状态文件更新使用临时文件 + `mv` 保证原子性。

## 测试

在 `tests/run_tests.sh` 中新增对 `lib/mirror_sync.sh` 的纯逻辑用例（沿用现有
`mktemp -d` 沙箱风格，不依赖 whiptail/dialog，也不依赖真实 Verdaccio/Devpi）：

- 清单生成：给定一个假目录树，生成的 `sha256sum` 格式清单内容正确。
- 增量差异：修改/新增/不变三种文件，`diff_manifest` 只挑出新增和变化的。
- 完整性校验：篡改 payload 或 `meta.env` 后，`sha256sum -c` 校验能检测出来。
- 顺序检查：构造 `import_state`，验证“非法 base_sequence”“链不匹配”两种场景
  被拒绝，“正确衔接”场景被接受。
- 去重检查：同一个 `PACKAGE_ID` 二次导入时被判定为幂等跳过。

后端适配器里真正依赖 Verdaccio/Devpi 存在的部分（如 `devpi-server --export`
调用）无法在没有真实安装的环境里做单元测试，实现阶段应把“生成快照”这一步
封装成单独的函数，方便只测试它前后的通用逻辑。

## 文档

- README.md 的 "lib 函数速查" 表格新增 `mirror_sync::*` 关键函数条目。
- README.md 可选新增一小节说明 mirror-sync 的使用方式（首次配置 → 导出 →
  刻录/传输 → 导入 → 重启服务），非强制但建议一并完成。
