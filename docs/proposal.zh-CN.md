# moon_schema_plan 项目申报书

## 项目简介与生态定位

MoonBit 已有 SQLite/PostgreSQL 驱动、ORM、SQL parser，也有 ORM 内部的单表结构
diff；但我没有找到一个可独立复用、以“审查迁移风险”为核心的 schema migration
planner。现有能力解决的是连接数据库、生成模型或比较字段，本项目解决的是另一段链路：
给定两个明确的 schema，稳定地生成可审查的变更计划，并在默认路径阻止删表、删列、
危险类型转换等操作。它既可被 ORM 调用，也可独立用于 CI，不绑定数据库连接和运行时。

三个直接使用场景：

1. 应用升级前在 CI 中比较 v1/v2 schema；若出现 destructive step，构建直接失败。
2. ORM 或代码生成器把自身模型转换为本项目 IR，复用 PostgreSQL/SQLite 迁移规划，
   不再各写一套有分歧的 diff。
3. 教学或小型项目以 JSON 保存 schema 快照，先审查机器可读计划，再显式批准并生成 SQL；
   SQLite 遇到不支持的 ALTER 时自动生成可审计的表重建过程。

调研中最接近的是 [`oboard/morm`](https://mooncakes.io/docs/oboard/morm) 的
`diff_table`：它按名称列出单表 columns、indexes、
foreign keys 的增删改。`moon_schema_plan` 不做 ORM，而在此基础能力之外提供跨表依赖排序、
显式 rename hint、风险分级、默认拒绝破坏性 SQL、SQLite 数据复制/回填和 PostgreSQL
渲染。因此不是功能相同的重复包，也可以成为现有 ORM 的下游组件。

## 交付范围与边界

0.1.0 交付结构化 Schema/Plan JSON、完整 schema 校验、table/column/index/foreign-key
diff、显式表和列重命名、确定性及依赖排序、Safe/Review/Destructive 分级、SQLite 与
PostgreSQL SQL renderer、CLI、示例、CI、单元/黑盒/真实 SQLite 迁移测试。

明确不做：连接生产数据库、解析任意 DDL、猜测重命名、自动迁移业务数据、完整回滚、
MySQL 支持。类型和 default expression 是受限的方言片段，来自可信配置；本项目不是 SQL
防火墙。这个边界让纯规划核心可在 Wasm、Wasm-GC、JavaScript 和 Native 后端编译。

## 实现路径与验收

实现采用 `Schema -> validate -> deterministic diff -> risk gate -> dialect renderer` 五段
纯函数流水线。重命名不采用相似度猜测，避免误把 drop/add 包装成无损操作。PostgreSQL
新增表的外键延后到所有表创建完成，支持循环引用。SQLite 无法直接 ALTER 的变更进入
事务化 rebuild；nullable 改为 required 时，只有目标 schema 给出 default 才允许规划，
并先回填旧 NULL。

验收以 `moon check --deny-warn`、完整测试、四后端编译、CLI 双方言烟测和真实 sqlite3
数据迁移为准。项目为原创实现，不移植第三方代码，采用 Apache-2.0。
