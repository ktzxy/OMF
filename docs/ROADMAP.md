# OMF 平台化/可视化演进设计方案（Roadmap）

> 本文档是**设计方案**，非已实现功能。记录审视报告（项目总负责人/产品运营/高级运维/高级 DBA 视角）中识别出的"偏平台化/可视化、工作量较大、需部署环境验证"的待评估项，供后续决策是否落地。
> 已实现的审视项见 `docs/CHANGELOG.md`（v1.64 版本治理 / v1.65 hooks / v1.66 fleet / v1.67 SQL 收敛）。

---

## 总览

| # | 方案 | 价值 | 工作量 | 依赖环境 | 优先级 |
|---|------|------|--------|----------|--------|
| 1 | CI 真实 Oracle 集成测试 | 高（兜住最大回归风险） | 中 | Docker + 19c 镜像 | ★★★ |
| 2 | 监控可视化（Prometheus + Grafana 模板） | 高（运维可读性） | 低 | Prometheus/Grafana 部署 | ★★★ |
| 3 | 多实例告警聚合 Dashboard | 高（fleet 的观测层） | 中 | 依赖方案 2 | ★★ |
| 4 | 审计查询增强 | 中（合规/回溯） | 低 | 无 | ★★ |
| 5 | 每日备份/健康 HTML 报表 | 中（运营汇报） | 低 | 无 | ★ |
| 6 | `omf fleet` 并行执行 | 中（批量效率） | 低 | 无 | ★ |

---

## 方案 1：CI 真实 Oracle 集成测试

### 背景
当前 selftest(45) + harness(21) 全是**静态/行为回归**，没有一条真的连库跑 SQL。跨发行版、DBCA、RMAN、expdp、DG 这些高风险路径全靠手工验证（`TEST_REPORT.md` 已标注"历史快照、可能脱节"）。

### 方案
新增 `tests/integration.sh`，在 Docker 容器里跑真实 Oracle 冒烟：

```yaml
# .github/workflows/integration.yml (nightly)
jobs:
  oracle19c:
    runs-on: ubuntu-latest
    services:
      oracle:
        image: gvenzl/oracle-xe:21-slim
        ports: [1521:1521]
        env: { ORACLE_PASSWORD: "TestOnly_123" }
    steps:
      - uses: actions/checkout@v4
      - run: bash tests/integration.sh   # 连库冒烟
```

`integration.sh` 覆盖的最小闭环：
1. `omf sql init`（建模式/表空间 + 执行 init SQL）——验证 `_create_schema.sql` 动态数据文件循环
2. `omf backup auto`（逻辑 expdp + RMAN 物理）——验证备份链路
3. `omf backup restore --rman --validate`——验证可恢复性
4. `omf sql import --check`——验证 impdp parfile 生成
5. `omf check monitor --alert`——验证监控采集 + 告警判定

### 关键设计
- **镜像**：`gvenzl/oracle-xe`（21c slim，CI 友好，免 systemd）。
- **配置注入**：用环境变量覆盖 `ORACLE_*`，不用真实 conf。
- **幂等**：每次全新容器，无残留。
- **失败判定**：任一步非 0 即整体失败，并上传日志 artifact。

### 价值
- 兜住"建库/备份/恢复/导入"这条最核心链路的回归，替代手工 TEST_REPORT。
- 让"跨发行版适配"（Ubuntu 24.04 等）在 CI 里可验证。

### 风险/取舍
- Docker 里跑 Oracle 需镜像许可合规（XE 免费，SE/EE 需许可）。
- 建库慢（5-10 分钟），适合 nightly 非 PR 阻塞。

---

## 方案 2：监控可视化（Prometheus + Grafana）

### 背景
`omf check monitor` 已输出 Prometheus 文本格式（`omf check monitor prom`）与 JSONL 历史快照，但**没有可视化**。运维要"一眼看趋势"，而非逐条看指标。

### 方案
1. **`omf check monitor prom` 已是标准格式**，用 `node_exporter`/`textfile_collector` 或 `pushgateway` 采集到 Prometheus：

```yaml
# prometheus.yml (textfile 方式, 无需 OMF 改动)
scrape_configs:
  - job_name: omf
    static_configs: [{ targets: ["omf-host:9100"] }]  # node_exporter + textfile
```

2. 提供 `conf/grafana/omf_dashboard.json`（Grafana Dashboard 模板），展示：
   - 库存活 `omf_db_up`
   - 磁盘使用率 `omf_disk_usage_pct{mount=...}`
   - 可用内存 `omf_mem_free_pct`
   - 无效对象 `omf_invalid_objects`
   - 表空间水位 `omf_tbs_max_pct`
   - 备份时效 `omf_backup_age_days`
   - DG 延迟 `omf_dg_lag_sec`
   - FRA 使用率 `omf_arch_used_pct`
   - CPU `omf_cpu_pct` / 活动会话 `omf_active_sessions` / redo 速率 `omf_redo_mbps`

3. **可选增强**：给 `omf check monitor prom` 加 `--push <pushgateway_url>`，把指标推到 pushgateway（适合 fleet 多实例场景，见方案 3）。

### 关键设计
- **不改 monitor 采集逻辑**，纯可视化层（复用现有 prom 输出）。
- Grafana 模板用 JSON 文件交付，`omf check monitor` 的字段名即面板变量。

### 价值
- 把"逐条数字"变成"趋势图/告警面板"，运维可读性大增。
- 与 fleet 结合可做多实例大盘。

### 风险/取舍
- 依赖外部 Prometheus/Grafana 部署（非 OMF 内置）。
- textfile 方式需 node_exporter，pushgateway 方式需网络可达。

---

## 方案 3：多实例告警聚合 Dashboard

### 背景
`omf fleet`（v1.66）已能批量执行 `check monitor --alert`，但告警是**逐实例输出**，没有一个聚合视图。

### 方案
在 fleet + monitor 基础上做聚合：
1. **`omf fleet monitor --push <pushgateway>`**：对清单内所有实例执行 `check monitor prom`，统一推到 pushgateway，按 `instance` 标签区分。
2. Grafana 面板用 `instance` 分组，一张大盘看所有库的健康（绿/黄/红）。
3. **聚合告警**：Grafana alerting 按阈值统一告警，替代逐实例 webhook。

### 关键设计
- 复用 `fleet_run` 的调度逻辑，新增子命令 `omf fleet monitor`。
- 依赖方案 2 的 pushgateway 通路。

### 价值
- 运维从"逐台看告警"变成"一张大盘看全局"。
- 是 OMF 从"工具"到"平台"的观测层闭环。

### 风险/取舍
- 依赖 Prometheus 生态；需统一各实例的指标命名/标签。

---

## 方案 4：审计查询增强

### 背景
v1.64 已有 `omf log audit`（查看 `logs/audit.log` 高危操作留痕），但只有基础的"看最近 N 条"。

### 方案
增强 `omf log audit`：
- `--since <日期>` / `--actor <用户>`：按时间/操作者过滤
- `--cmd <命令>`：按命令过滤（如只看 `db dg failover`）
- `--count`：统计各命令/操作者出现次数（合规审计 Top）
- 可选：`--export csv` 导出审计到 CSV 供审计平台

### 关键设计
- 纯 `awk`/`grep` 解析 JSONL，无新依赖。
- 不破坏现有 `--json`/`--all`。

### 价值
- 合规审计（"谁在什么时候做了什么"）从"手工 cat"变"可查询可导出"。

### 风险/取舍
- 低风险，纯增量。

---

## 方案 5：每日备份/健康 HTML 报表

### 背景
`backup_report`（v1.62）已生成文本报告，`monitor_history.jsonl` 持续累积，但无汇总报表。

### 方案
- `omf report daily`：汇总当日备份结果 + 健康指标，生成一份 HTML 报表（含表格式指标 + 简单趋势），落盘 `logs/reports/`，可随 webhook 推送。
- 复用 `lib/sql.sh`（v1.67）的查询 + `backup_report` + `monitor_history.jsonl`。

### 关键设计
- 纯 shell 生成 HTML，无 JS 依赖。
- cron 每日定时（接入 `clean schedule` 类似的 `report schedule`）。

### 价值
- 运营/交接汇报友好，不用截图终端。

### 风险/取舍
- 低风险；HTML 美化有限（纯 shell），可接受。

---

## 方案 6：`omf fleet` 并行执行

### 背景
当前 `fleet run` 是**串行**（逐实例执行），实例多时耗时长。

### 方案
给 `fleet_run` 加 `--parallel <N>`（默认串行）：
- 用 `&` 后台并发 + `wait` 汇总，限并发数避免 SSH 风暴。
- 输出缓冲，避免多实例输出交错。

### 关键设计
- 复用现有 `_fleet_exec`，只改调度层。
- 失败汇总逻辑不变。

### 价值
- 20 台库批量巡检从"20 倍串行"变"N 路并行"，效率数量级提升。

### 风险/取舍
- 需控制并发数（建议 4-8），避免 SSH 连接数过大。

---

## 建议落地优先级

| 批次 | 方案 | 理由 |
|------|------|------|
| **第一批（低风险、立即收益）** | 方案 6（fleet 并行）、方案 4（审计增强） | 纯增量、无外部依赖、改动可控 |
| **第二批（需环境）** | 方案 1（CI 集成）、方案 2（监控可视化） | 需要 Docker/Prometheus 环境 |
| **第三批（平台化整合）** | 方案 3（告警聚合）、方案 5（HTML 报表） | 依赖前两批 |

> 决策建议：若目标是"尽快减负"，先做方案 6 + 4（一两个半天）；若目标是"平台化观测"，先搭方案 2 + 3（Prometheus 生态）。
