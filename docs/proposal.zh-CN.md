# moon_schema_plan 项目申报书

## 项目简介与生态定位

MoonBit 已有 SQLite/PostgreSQL 驱动、ORM、SQL parser，也有 ORM 内部的单表结构
diff；但目前没有一个可独立复用、以「审查迁移风险」为核心的 schema migration
planner。现有能力解决的是连接数据库、生成模型或比较字段，本项目解决的是另一段链路：
给定两个明确的 schema，稳定地生成可审查的变更计划，按风险分级，并在默认路径阻止删表、
删列、危险类型转换等操作。它既可被 ORM 调用，也可独立用于 CI，不绑定数据库连接和运行时。

三个直接使用场景：

1. 应用升级前在 CI 中比较 v1/v2 schema。`verify` 子命令在计划超出风险上限时以退出码
   2 结束，构建直接失败；退出码 1 留给用法与校验错误，两者不会混淆。
2. ORM 或代码生成器把自身模型转换为本项目 IR，复用 PostgreSQL/SQLite 迁移规划与
   Markdown 评审报告，不再各写一套有分歧的 diff。
3. 教学或小型项目以 JSON 保存 schema 快照，先审查机器可读计划，再显式批准并生成 SQL；
   SQLite 遇到不支持的 ALTER 时自动生成可审计的表重建过程。

调研中最接近的是 [`oboard/morm`](https://mooncakes.io/docs/oboard/morm) 的
`diff_table`：它按名称列出单表 columns、indexes、foreign keys 的增删改。
`moon_schema_plan` 不做 ORM，而在此基础能力之外提供跨表依赖排序、显式 rename hint、
风险分级与可配置策略上限、默认拒绝破坏性 SQL、SQLite 数据复制/回填，以及
PostgreSQL 渲染。因此不是功能相同的重复包，也可以成为现有 ORM 的下游组件。

## 交付范围与边界

交付结构化 Schema/Plan JSON、完整 schema 校验、table/column/index/foreign-key diff、
显式表和列重命名、确定性及依赖排序、Safe/Review/Destructive 分级与 `--max-risk` 策略、
Markdown 评审报告、SQLite 与 PostgreSQL SQL renderer、可在 CI 中使用的命令行工具、
示例、GitHub Actions，以及单元 / 黑盒 / 真实 SQLite 迁移测试。

明确不做：连接生产数据库、解析任意 DDL、猜测重命名、自动迁移业务数据、完整回滚、
MySQL 支持。类型和 default expression 是受限的方言片段，来自可信配置；本项目不是 SQL
防火墙。这个边界让纯规划核心可在 Wasm、Wasm-GC、JavaScript 和 Native 后端编译。

IR 建模的范围是表、列、索引和外键；**不**建模 CHECK 约束、生成列、部分索引谓词、触发器
和视图。这条边界决定了两个对外可见的行为：SQLite 删列一律走表重建，而不用 3.35 起提供的
原生 `DROP COLUMN`——该语句失败的八种条件里有四种涉及 IR 看不见的对象，仅凭看得见的四种
放行会发出可能执行失败的 SQL；以及重建只恢复索引，不恢复触发器和视图，这一点由每个重建
步骤在自己的 reason 里写明。两者的完整论证见
[design-decisions.zh-CN.md](design-decisions.zh-CN.md)。

## 实现路径与验收

实现采用 `Schema -> validate -> deterministic diff -> risk gate -> dialect renderer`
五段纯函数流水线。重命名不采用相似度猜测，避免误把 drop/add 包装成无损操作。
PostgreSQL 新增表的外键延后到所有表创建完成，支持循环引用；依赖深度计算带访问集合，
循环引用收敛而不是递归下去。SQLite 无法直接 ALTER 的变更进入事务化 rebuild；
nullable 改为 required 时，只有目标 schema 给出 default 才允许规划，并先回填旧 NULL。

库本身没有第三方运行时依赖；命令行程序单独依赖 `moonbitlang/x` 完成文件读写与退出码。
这条边界既保证纯规划核心可跨四个后端编译，也让命令行具备真实可用性。

验收以 `moon check --deny-warn`、`moon fmt --check`、`moon info` 无漂移、四后端编译与
测试、命令行全部文档化用法与退出码的断言脚本，以及真实 sqlite3 数据迁移为准；
85 个测试在 wasm、wasm-gc、JavaScript、Native 四个后端上全部通过，库代码行覆盖率
626/632，其余为已在源码中注明的不可达防御分支。项目为原创实现，不移植第三方代码，
采用 Apache-2.0。

## 关键设计取舍

三个最有主张的选择——重命名为何必须显式提示、策略违规为何单独占一个退出码、SQLite 变更为何
合并成一次表重建——连同被否决的备选方案与各自的代价，记录在
[design-decisions.zh-CN.md](design-decisions.zh-CN.md)。

## 关于 AI 协作的说明

开发过程使用了 AI 编程工具。设计决策、边界取舍与验收标准由参赛者确定，所有对外行为都由
可重复执行的测试与脚本固定：`scripts/cli_smoke.sh` 断言每一条文档化命令的输出与退出码，
`scripts/sqlite_e2e.sh` 把生成的 SQL 灌进真实数据库并校验数据。任何一处实现改动如果
偏离文档，CI 会直接失败。
