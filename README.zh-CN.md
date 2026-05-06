# stagent

[English](./README.md) | **简体中文** | [日本語](./README.ja.md) | [한국어](./README.ko.md) | [Français](./README.fr.md) | [Deutsch](./README.de.md) | [Español](./README.es.md)

一个把**配置驱动的开发工作流**当作状态机来跑的 Claude Code 插件。你在一个 `workflow.json` 里声明 stage、转换和输入；插件的 hooks 和脚本负责驱动循环。

两种模式：
- **Cloud**（默认）—— 状态镜像到[托管的 webapp](https://stagent.worldstatelabs.com/)，浏览器里能实时看，跨机器恢复，项目目录零落地。
- **Local** —— 状态和 artifact 落在 `<project>/.stagent/` 下，全程离线。

## Quick Start

### 安装

在 **Claude Code session 里**运行下面的 slash 命令。Cloud 模式默认启用 —— 不用配置、不用 key；匿名 session 就能用 `/stagent:start` 和 `/stagent:continue`。只有发布 workflow 到 hub 或者要登记认证所有权时才需要 `/stagent:login`。

```
/plugin marketplace add jie-worldstatelabs/stagent
/plugin install stagent@stagent
```

已经安装过？更新插件：

```
/plugin update stagent@stagent
```

依赖：[Claude Code](https://claude.ai/claude-code)、`jq`、`curl`、`git`（cloud 模式还会用到 `sha256sum` / `shasum` 这类 POSIX 工具）。

### 跑一个 workflow

**可选但推荐：** 先登录，claim session 所有权、更好管理你过去的 sessions。

```
/stagent:login
```

启动默认开发 workflow —— 它会照你的描述构建：

```
/stagent:start --flow=cloud://demo "Build a journaling app with MBTI insights inferred from journal entries"
```

skill 会打印一个实时 UI 链接。**未登录**时这是一个**匿名、任何人凭链接都能查看**的 session —— 拿到链接的人都能实时跟踪状态机运行（stage 时间线、渲染好的 artifact、`git diff baseline..HEAD` 通过 SSE 实时更新），且没有 owner。

要完全离线跑就切到 local 模式：

```
/stagent:start --mode=local "Build a journaling app with MBTI insights inferred from journal entries"
```

### 创建你自己的 workflow 模板

用一句自然语言描述你的 workflow，stagent 会把 stage 搭出来：

```
/stagent:create "plan, implement, critique & score UX"
```

这条命令默认走 **cloud** 模式：planning + writing 阶段完成后，新模板会自动发布到你的 hub 账号。如果还没登录，先登录：

```
/stagent:login
```

完全离线跑（模板存到本地 `~/.config/stagent/workflows/<name>/`，不推到 hub）切换到 local 模式：

```
/stagent:create --mode=local "plan, implement, critique & score UX"
```

需要灵感？翻翻 [cookbook](https://stagent.worldstatelabs.com/cookbook)，里面有 12 个经过实战检验的 workflow 模板，可以直接 fork 或改造。

## 默认 workflow

不带 `--flow` 时：

- **Cloud 模式**（默认）从 hub 拉 `cloud://demo` —— 一份托管模板，可能会独立于本 README 演进
- **Local 模式**用插件内置的 workflow（`skills/stagent/workflow/`，离线兜底）—— 也是下面这套循环的权威来源

内置 workflow 跑的是一个 **plan → execute → verify → review → QA → deploy** 循环：

1. **Planning** *(可中断)* —— 跟你交互式一问一答：澄清问题、提出方案、写 plan 文件。你确认后才会动手。
2. **Executing** —— subagent（opus）按 plan 实现：要求 test-first 时就先写测试，做最小、聚焦的改动。
3. **Verifying** —— 跑快速测试（unit/integration），inline 执行。FAIL → 回 Execute；PASS/SKIPPED → Review。
4. **Reviewing** —— subagent 对着 baseline commit 做对抗式 code review。PASS → QA；FAIL → 回 Execute。
5. **QA-ing** —— subagent 跑真实的用户旅程测试（Playwright、XcodeBuildMCP 等等）。区分测试 bug 和应用 bug —— 只有确认是应用 bug 才会卡进度。PASS → Deploy；FAIL → 回 Execute。
6. **Deploy** *(可中断)* —— inline 跑 Vercel CLI：`vercel whoami`、首次 `vercel link`、同步 production env vars、`vercel --prod`、smoke check URL。可中断是因为首次配置可能要去另一个终端 `vercel login`，或者要你提供环境变量。完成 → terminal `complete`。

`execute → verify → review → QA` 循环在你确认 plan 之后**自动**跑。Stop hook 保证循环跑完（直到 QA 通过；之后 deploy 作为最后一个、可中断的 stage 跑）。循环停止有三种情况：deploy 完成（terminal `complete`）、撞到 `max_epoch`（默认 `20`，在 `workflow.json` → `.max_epoch` 里配；用来断掉无限迭代，强制 terminal `escalated`）、或者你用 `/stagent:interrupt`（暂停）/ `/stagent:cancel`（terminal `cancelled`）介入。三个 terminal 状态 —— `complete`、`escalated`、`cancelled` —— 都在 `workflow.json` → `.terminal_stages` 里声明。

## 自定义 workflow

插件本身是**通用的** —— 任何 stage 形态只要符合 schema 都能跑。`/stagent:create`（见 Quick Start）会派一个内部 stagent 来面试你，写出 `workflow.json` + 各 stage 的指令文件到 `~/.config/stagent/workflows/<name>/`，在重试循环里校验，然后把整包发到 hub（仅 cloud 模式）。复用方式：

```
/stagent:start --flow=cloud://<you>/<name> <task>
```

`workflow.json` schema 见 [ARCHITECTURE.md](./ARCHITECTURE.md)。

不知道把什么变成 workflow？看 [cookbook](https://stagent.worldstatelabs.com/cookbook) —— 12 个针对 Claude Code 常见失败模式的开箱即用 workflow（goal pursuit、research-first、end-to-end v1、scope lock-down、invariant guardrails、root-cause forced、real bug hunt、strict TDD、real-journey suite、visual QA gate、perf gate、compliance gate），每个都用 `/stagent:start --flow=cloud://...` 直接启动。

## 命令

| 命令 | 用途 |
|---|---|
| `/stagent:start [--mode=cloud\|local] [--flow=<ref>] <task>` | 开一个新 run |
| `/stagent:interrupt` | 暂停当前 run，不清状态（stage 中途也可以调；用 `/stagent:continue` 恢复）|
| `/stagent:continue [--session <id>]` | 恢复被中断的 run（`--session` 用于跨机器云端接管）|
| `/stagent:cancel [--hard]` | 取消 run。默认归档；`--hard` 硬删。Local 模式相应地归档/删除文件；cloud 模式下本地影子两种情况都会清，差别只在服务端（归档 vs 硬删）|
| `/stagent:create [--mode=cloud\|local] [--flow=<ref>] <description>` | 创建新 workflow 或编辑已有的 |
| `/stagent:publish <dir> [--name <n>] [--description <d>] [--dry-run]` | 把本地 workflow 发到 hub |
| `/stagent:login` / `:logout` / `:whoami` | 管理 hub 身份 |

**`--flow=<ref>`** 接受：
- *(省略)* —— cloud 模式从 hub 拉 `cloud://demo`；local 模式用插件内置 workflow
- `cloud://author/name` —— 从 hub 拉（cloud 模式）
- `/abs/path` 或 `./rel/path` —— 本地 workflow 目录
- `<bare-name>` —— 先按插件内置 workflow 解析，否则当作 `cloud://<bare-name>` 去 hub 找

**环境变量：**

| 变量 | 默认值 | 作用 |
|---|---|---|
| `STAGENT_DEFAULT_MODE` | `cloud` | 设成 `local` 让 shell 里所有 run 默认走 local |

## Local vs Cloud

| 关注点 | Local | Cloud |
|---|---|---|
| 权威状态 | `<project>/.stagent/<session>/state.md` | Postgres `sessions` 行；本地影子做镜像 |
| 文件落在哪 | 项目 worktree | `~/.cache/stagent/sessions/<session>/` —— terminal 时清掉 |
| 实时浏览 | 没有 —— 自己看文件 | `https://stagent.worldstatelabs.com/s/<session_id>` |
| 跨机器 continue | 不支持 | `/stagent:continue --session <id>`，带 project-fingerprint 校验 |
| 要不要加 `.gitignore` | `echo '/.stagent/' >> .gitignore` | 不用 |

### 跨机器 / 跨 clone 接管的注意事项

`/stagent:continue --session <id>` 把 workflow 的**状态**（`state.md`、stage 报告，加上 `baseline` run 文件 —— workflow 启动时锁定的 git SHA）镜像到新机器。它**不**复制项目源码。代码住在你的 git repo 里，不在插件里。

`continue-workflow.sh` 会校验：

1. 新 workdir 是同一个 repo（用 root-commit fingerprint 判断）。
2. 新 workdir 的 HEAD 没有落后于 / 偏离 workflow 上次见到的 HEAD（`state.md` 里的 `last_seen_head`，每次 stage 转换和 `/interrupt` 时更新）。落后 / 偏离的 HEAD 是**硬阻止**，除非加 `--force-project-mismatch` —— 否则恢复的 stage 会跑在过期代码上，重做或者推翻已完成的工作。
3. 新 workdir 里有未提交改动只是软警告 —— 可能跟下一个 stage 的输出冲突。

如果原 session 在中断前把 subagent 的工作 commit 掉了，新机器上跑 `git fetch && git checkout <last_seen_head>`（或 merge 那个分支）就能在 `/continue` 之前同步好。

## 关键设计决策

- **配置驱动** —— stage、转换、可中断标志、subagent 类型/模型、输入依赖全部住在 `workflow.json` 里。加 stage 或者改转换是改配置，不是改代码。
- **一个通用 subagent** —— 每个 subagent stage 都跑在同一个 `workflow-subagent` 下；每个 stage 的协议放在 `<workflow-dir>/<stage>.md`，subagent 在运行时读。没有 per-stage 的 `subagent_type` 字段。
- **必需输入卡转换** —— `update-status.sh` 在任何 `required` 输入 artifact 缺失时拒绝进入 stage。状态机层级强制。
- **Artifact 带 epoch 戳** —— 每个 stage 的 artifact 带上当时的 epoch。stop hook 只信任 epoch 跟 `state.md` 一致的 artifact —— 上一轮迭代的过期 artifact 直接忽略。
- **自包含** —— skill 指示 agent 不要调外部 skill，避免流程被劫持。
- **优雅退出会自动 interrupt** —— Claude Code session 干净退出时（比如 `/exit`、关窗口），stagent 的 `SessionEnd` hook 会把当前 workflow 翻成 `interrupted`，方便另一个 Claude session 用 `/stagent:continue` 接手。崩溃 / `kill -9` 不会触发这个；cloud 模式下，服务端 stale 检测做兜底。
- **一个 session = 一个 run** —— 每个 Claude session 的 run 住在独立的、按 session-key 切的子目录里。同一个 worktree 里多个 Claude session 跑各自的 workflow 互不干扰。

## 架构与内部实现

见 [ARCHITECTURE.md](./ARCHITECTURE.md)：
- 插件目录布局
- 运行时文件布局（local + cloud）
- `workflow.json` schema reference
- 状态机协议（epoch、result、transitions）
- Stop hook 行为
- 端到端循环走查

## License

MIT
