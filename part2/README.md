# Part 2: Raft 命令与日志复制

本目录包含 Raft 分布式共识算法的**第二部分实现**，在 Part 1 的基础上增加了**命令提交与日志复制（Commands and Log Replication）**机制。代码来自 Eli Bendersky 的系列博客 [Implementing Raft](https://eli.thegreenplace.net/2020/implementing-raft-part-2-commands-and-log-replication/)。

## 目录结构

| 文件 | 说明 |
|------|------|
| `raft.go` | Raft 共识模块核心实现：状态机、选举、日志复制、Submit、Commit 通道 |
| `server.go` | 服务器封装：RPC 服务、对等节点连接管理、RPC 代理（支持不可靠网络模拟） |
| `testharness.go` | 测试框架：集群创建、节点断开/重连、提交检查、命令提交 |
| `raft_test.go` | 选举相关 + 日志复制相关单元测试 |
| `go.mod` / `go.sum` | Go 模块依赖 |
| `dotest.sh` | 运行指定测试并生成日志可视化 |
| `dochecks.sh` | 代码静态检查（go vet + staticcheck） |

## 前置要求

- **Go 1.23+**（或与 `go.mod` 中版本兼容）
- 网络可访问（用于下载 `github.com/fortytw2/leaktest` 测试依赖）

## 使用方法

### 1. 运行所有测试

```bash
cd part2
go test -v ./...
```

### 2. 带竞态检测运行测试

```bash
go test -v -race ./...
```

### 3. 运行指定测试

```bash
# 选举相关测试
go test -v -run TestElectionBasic ./...
go test -v -run TestElectionLeaderDisconnect ./...
go test -v -run TestElectionLeaderAndAnotherDisconnect ./...
go test -v -run TestDisconnectAllThenRestore ./...
go test -v -run TestElectionLeaderDisconnectThenReconnect ./...
go test -v -run TestElectionLeaderDisconnectThenReconnect5 ./...
go test -v -run TestElectionFollowerComesBack ./...
go test -v -run TestElectionDisconnectLoop ./...

# 日志复制相关测试
go test -v -run TestCommitOneCommand ./...
go test -v -run TestSubmitNonLeaderFails ./...
go test -v -run TestCommitMultipleCommands ./...
go test -v -run TestCommitWithDisconnectionAndRecover ./...
go test -v -run TestNoCommitWithNoQuorum ./...
go test -v -run TestCommitsWithLeaderDisconnects ./...
```

### 4. 使用 dotest.sh 并生成日志可视化

```bash
# 运行指定测试，rlog 和 HTML 可视化文件输出到 /Users/shentang/temp/（目录不存在时会自动创建）

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
./dotest.sh TestSubmitNonLeaderFails
./dotest.sh TestCommitMultipleCommands
./dotest.sh TestCommitWithDisconnectionAndRecover
./dotest.sh TestNoCommitWithNoQuorum
./dotest.sh TestCommitsWithLeaderDisconnects
```

然后打开生成的 HTML 文件（路径会打印在终端），可在浏览器中查看各节点的日志时间线。

### 5. 代码静态检查

```bash
./dochecks.sh
```

脚本会依次执行 `go vet` 和 `staticcheck`，对 `./...` 下所有包做静态分析。

| 工具 | 作用 |
|------|------|
| **go vet** | Go 内置静态分析器。检查常见错误：不可达代码、可疑 struct tag、格式化字符串参数不匹配等。 |
| **staticcheck** | 第三方静态分析器，规则更丰富。检查未使用的变量/导入、可简化的逻辑、潜在的 nil 解引用、goroutine 泄漏风险等。 |

## 环境变量（可选）

part2 支持以下环境变量，用于压力测试和模拟异常网络。**未设置时使用默认行为**。

| 变量 | 作用 | 默认行为 |
|------|------|----------|
| `RAFT_FORCE_MORE_REELECTION` | 约 1/3 概率将选举超时固定为 150ms，增加选举冲突和重新选举次数 | 选举超时在 150–300ms 间随机 |
| `RAFT_UNRELIABLE_RPC` | 对 RequestVote 和 AppendEntries：约 10% 概率丢弃 RPC，约 10% 概率延迟 75ms | 每次 RPC 仅 1–5ms 小延迟 |

### 用法示例

```bash
RAFT_UNRELIABLE_RPC=1 go test -v -run TestCommitWithDisconnectionAndRecover ./...
RAFT_FORCE_MORE_REELECTION=1 go test -v -run TestElectionDisconnectLoop ./...
RAFT_UNRELIABLE_RPC=1 ./dotest.sh TestCommitOneCommand
```

## 核心概念

### 相对 Part 1 的扩展

Part 2 在 Part 1 的选举基础上增加：

- **CommitEntry**：已达成共识的命令条目，包含 `Command`、`Index`、`Term`
- **commitChan**：客户端通过该通道接收已提交的命令，用于应用到状态机
- **Submit(cmd)**：客户端向 Leader 提交命令，由 Leader 复制到多数节点后提交
- **LogEntry**：日志条目，包含 `Command` 和 `Term`

### ConsensusModule (CM)

Raft 的**共识状态机**，在 Part 1 的基础上增加了：

- **持久状态**：`log`（复制日志，含命令和任期）
- **Commit 通道**：通过 `commitChan` 通知客户端已提交的命令
- **Submit 逻辑**：仅 Leader 接受客户端命令，追加到本地日志后通过 AppendEntries 复制

### Harness 扩展

测试框架新增方法：

- `SubmitToServer(serverId, cmd)`：向指定节点提交命令，返回是否为 Leader
- `CheckCommitted(cmd)`：检查命令是否在所有已连接节点上以相同索引提交
- `CheckCommittedN(cmd, n)`：检查命令是否在恰好 n 个节点上提交
- `CheckNotCommitted(cmd)`：检查命令尚未被任何节点提交
- `collectCommits(i)`：后台 goroutine 收集节点 i 的提交记录

## 测试用例说明

### 选举相关（与 Part 1 相同）

| 测试 | 验证内容 |
|------|----------|
| `TestElectionBasic` | 3 节点集群能选出唯一领导者 |
| `TestElectionLeaderDisconnect` | 领导者断开后，剩余节点能选出新领导者 |
| `TestElectionLeaderAndAnotherDisconnect` | 断开 2 个节点后无领导者，重连 1 个后恢复 |
| `TestDisconnectAllThenRestore` | 全部断开后无领导者，全部重连后恢复 |
| `TestElectionLeaderDisconnectThenReconnect` | 原领导者重连后应服从新领导者 |
| `TestElectionLeaderDisconnectThenReconnect5` | 5 节点下的类似场景 |
| `TestElectionFollowerComesBack` | Follower 断开后重连，term 应发生变化 |
| `TestElectionDisconnectLoop` | 多轮断开/重连，验证稳定性 |

### 日志复制相关（Part 2 新增）

| 测试 | 验证内容 |
|------|----------|
| `TestCommitOneCommand` | 向 Leader 提交单条命令，能在多数节点上提交 |
| `TestSubmitNonLeaderFails` | 向非 Leader 提交命令应失败 |
| `TestCommitMultipleCommands` | 多条命令按顺序提交且索引递增 |
| `TestCommitWithDisconnectionAndRecover` | 断开 1 个节点时提交仍可达成多数；重连后该节点能追上 |
| `TestNoCommitWithNoQuorum` | 多数节点断开时 Leader 无法提交；重连后 term 变化，旧命令不提交 |
| `TestCommitsWithLeaderDisconnects` | Leader 断开后新 Leader 能提交；原 Leader 重连后服从新 Leader，旧未提交命令不提交 |

## 与根目录 tools 的关系

`dotest.sh` 会调用 `../tools/raft-testlog-viz/main.go` 将测试日志转换为 HTML。请确保从 `part2` 目录运行，或 `tools` 目录在正确相对路径下。

## 与 Part 1 的关系

- Part 2 是 Part 1 的**直接扩展**，保留选举逻辑，仅增加日志复制和提交。
- 每个目录是独立的 Go 模块，可单独阅读和测试。
- 使用图形 diff 工具对比 part1 与 part2 的差异，有助于理解实现演进。
