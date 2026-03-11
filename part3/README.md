# Part 3: Raft 持久化与优化

本目录包含 Raft 分布式共识算法的**第三部分实现**，在 Part 2 的基础上增加了**持久化（Persistence）**和**若干优化**。代码来自 Eli Bendersky 的系列博客 [Implementing Raft](https://eli.thegreenplace.net/2020/implementing-raft-part-3-persistence-and-optimizations/)。

**注意**：Part 3 的 Raft 代码位于 `raft/` 子目录，以便被 part4kv、part5kv 等后续模块导入使用。

## 目录结构

| 文件 | 说明 |
|------|------|
| `raft/raft.go` | Raft 共识模块：状态机、选举、日志复制、持久化、triggerAE 优化 |
| `raft/server.go` | 服务器封装：RPC 服务、对等节点连接管理、RPC 代理 |
| `raft/storage.go` | 持久化接口与 MapStorage 实现（测试用内存存储） |
| `raft/testharness.go` | 测试框架：集群、断开/重连、崩溃/重启、RPC 丢包模拟 |
| `raft/raft_test.go` | 选举、日志复制、持久化、崩溃恢复等单元测试 |
| `raft/go.mod` / `raft/go.sum` | Go 模块依赖 |
| `raft/dotest.sh` | 运行指定测试并生成日志可视化 |
| `raft/dochecks.sh` | 代码静态检查（go vet + staticcheck） |

## 前置要求

- **Go 1.23+**（或与 `go.mod` 中版本兼容）
- 网络可访问（用于下载 `github.com/fortytw2/leaktest` 测试依赖）

## 使用方法

### 1. 运行所有测试

```bash
cd part3/raft
go test -v ./...
```

### 2. 带竞态检测运行测试

```bash
go test -v -race ./...
```

### 3. 运行指定测试

```bash
# 选举相关
go test -v -run TestElectionBasic ./...
go test -v -run TestElectionLeaderDisconnect ./...
# ... 其他选举测试

# 日志复制相关
go test -v -run TestCommitOneCommand ./...
go test -v -run TestCommitAfterCallDrops ./...
go test -v -run TestSubmitNonLeaderFails ./...
go test -v -run TestCommitMultipleCommands ./...
go test -v -run TestCommitWithDisconnectionAndRecover ./...
go test -v -run TestNoCommitWithNoQuorum ./...
go test -v -run TestCommitsWithLeaderDisconnects ./...

# 持久化与崩溃恢复相关
go test -v -run TestDisconnectLeaderBriefly ./...
go test -v -run TestCrashFollower ./...
go test -v -run TestCrashThenRestartFollower ./...
go test -v -run TestCrashThenRestartLeader ./...
go test -v -run TestCrashThenRestartAll ./...
go test -v -run TestReplaceMultipleLogEntries ./...
go test -v -run TestCrashAfterSubmit ./...
go test -v -run TestDisconnectAfterSubmit ./...
```

### 4. 使用 dotest.sh 并生成日志可视化

```bash
# 在 part3/raft 目录下运行，rlog 和 HTML 输出到 /Users/shentang/temp/

# 选举相关
./dotest.sh TestElectionBasic
./dotest.sh TestElectionLeaderDisconnect
./dotest.sh TestElectionLeaderAndAnotherDisconnect
./dotest.sh TestDisconnectAllThenRestore
./dotest.sh TestElectionLeaderDisconnectThenReconnect
./dotest.sh TestElectionLeaderDisconnectThenReconnect5
./dotest.sh TestElectionFollowerComesBack
./dotest.sh TestElectionDisconnectLoop

# 日志复制相关
./dotest.sh TestCommitOneCommand
./dotest.sh TestCommitAfterCallDrops
./dotest.sh TestSubmitNonLeaderFails
./dotest.sh TestCommitMultipleCommands
./dotest.sh TestCommitWithDisconnectionAndRecover
./dotest.sh TestNoCommitWithNoQuorum
./dotest.sh TestCommitsWithLeaderDisconnects

# 持久化与崩溃恢复相关
./dotest.sh TestDisconnectLeaderBriefly
./dotest.sh TestCrashFollower
./dotest.sh TestCrashThenRestartFollower
./dotest.sh TestCrashThenRestartLeader
./dotest.sh TestCrashThenRestartAll
./dotest.sh TestReplaceMultipleLogEntries
./dotest.sh TestCrashAfterSubmit
./dotest.sh TestDisconnectAfterSubmit
```

然后打开生成的 HTML 文件（路径会打印在终端），可在浏览器中查看各节点的日志时间线。

### 5. 代码静态检查

```bash
./dochecks.sh
```

脚本会依次执行 `go vet` 和 `staticcheck`，对 `./...` 下所有包做静态分析。

## 环境变量（可选）

part3 支持以下环境变量，用于压力测试和模拟异常网络。

| 变量 | 作用 | 默认行为 |
|------|------|----------|
| `RAFT_FORCE_MORE_REELECTION` | 约 1/3 概率将选举超时固定为 150ms | 选举超时在 150–300ms 间随机 |
| `RAFT_UNRELIABLE_RPC` | 对 RequestVote 和 AppendEntries：约 10% 概率丢弃 RPC，约 10% 概率延迟 75ms | 每次 RPC 仅 1–5ms 小延迟 |

## 核心概念

### 相对 Part 2 的扩展

| 扩展 | 说明 |
|------|------|
| **Storage 接口** | 持久化接口：`Set`、`Get`、`HasData`，用于保存 currentTerm、votedFor、log |
| **restoreFromStorage** | 启动时从持久化恢复状态 |
| **persistToStorage** | 状态变更时持久化到 Storage |
| **triggerAEChan** | 有日志变更时立即触发 AppendEntries，减少心跳延迟 |
| **CrashPeer / RestartPeer** | 测试框架支持节点崩溃与重启，验证持久化恢复 |

### Storage 与持久化

- **Storage**：抽象持久化层，生产环境可替换为磁盘、WAL 等
- **MapStorage**：测试用内存实现，Crash 后保留，Restart 时用于恢复
- **持久化内容**：currentTerm、votedFor、log（按 Raft 论文 Figure 2）

### Harness 扩展

- `CrashPeer(id)`：断开并关闭节点，保留其 Storage
- `RestartPeer(id)`：用原 Storage 创建新 Server，重连并启动
- `PeerDropCallsAfterN(id, n)`：让节点在接下来 n 次 RPC 后开始丢包
- `PeerDontDropCalls(id)`：停止丢包

## 测试用例说明

### 选举相关（与 Part 1/2 相同）

| 测试 | 验证内容 |
|------|----------|
| `TestElectionBasic` | 3 节点能选出唯一领导者 |
| `TestElectionLeaderDisconnect` | 领导者断开后能选出新领导者 |
| `TestElectionLeaderAndAnotherDisconnect` | 断开 2 个后无领导者，重连 1 个后恢复 |
| `TestDisconnectAllThenRestore` | 全部断开后无领导者，全部重连后恢复 |
| `TestElectionLeaderDisconnectThenReconnect` | 原领导者重连后服从新领导者 |
| `TestElectionLeaderDisconnectThenReconnect5` | 5 节点下的类似场景 |
| `TestElectionFollowerComesBack` | Follower 断开后重连，term 应变化 |
| `TestElectionDisconnectLoop` | 多轮断开/重连，验证稳定性 |

### 日志复制相关（与 Part 2 相同 + 新增）

| 测试 | 验证内容 |
|------|----------|
| `TestCommitOneCommand` | 向 Leader 提交单条命令，能在多数节点上提交 |
| `TestCommitAfterCallDrops` | Leader 前几次 RPC 丢包后，命令仍能最终提交 |
| `TestSubmitNonLeaderFails` | 向非 Leader 提交命令应失败 |
| `TestCommitMultipleCommands` | 多条命令按顺序提交且索引递增 |
| `TestCommitWithDisconnectionAndRecover` | 断开 1 个节点时仍可提交；重连后追上 |
| `TestNoCommitWithNoQuorum` | 多数节点断开时无法提交；重连后 term 变化 |
| `TestCommitsWithLeaderDisconnects` | Leader 断开后新 Leader 能提交；原 Leader 重连后服从 |

### 持久化与崩溃恢复（Part 3 新增）

| 测试 | 验证内容 |
|------|----------|
| `TestDisconnectLeaderBriefly` | Leader 短暂断开（小于选举超时）后重连，仍为 Leader |
| `TestCrashFollower` | 崩溃一个 Follower 后，其余节点仍能提交 |
| `TestCrashThenRestartFollower` | Follower 崩溃后重启，能从 Storage 恢复并追上 |
| `TestCrashThenRestartLeader` | Leader 崩溃后重启，能从 Storage 恢复并追上 |
| `TestCrashThenRestartAll` | 全部崩溃后重启，能恢复并选出新 Leader |
| `TestReplaceMultipleLogEntries` | 旧 Leader 的未复制日志被新 Leader 覆盖 |
| `TestCrashAfterSubmit` | Leader 提交后立即崩溃，新 Leader 能提交该命令 |
| `TestDisconnectAfterSubmit` | 类似 TestCrashAfterSubmit，但用断开代替崩溃 |

## 与根目录 tools 的关系

`dotest.sh` 会调用 `../../tools/raft-testlog-viz/main.go` 将测试日志转换为 HTML。请确保从 `part3/raft` 目录运行，或 `tools` 目录在正确相对路径下。

## 与 Part 2 的关系

- Part 3 在 Part 2 基础上增加：**持久化**、**triggerAE 优化**、**崩溃/重启测试**。
- Part 3 的 `raft` 作为独立包，可被 part4kv、part5kv 导入。
- `Submit` 返回值改为 `int`：Leader 返回 log index，非 Leader 返回 -1。
