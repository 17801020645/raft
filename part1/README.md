# Part 1: Raft 选举实现

本目录包含 Raft 分布式共识算法的**第一部分实现**，专注于**领导者选举（Leader Election）**机制。代码来自 Eli Bendersky 的系列博客 [Implementing Raft](https://eli.thegreenplace.net/2020/implementing-raft-part-1-elections/)。

## 目录结构

| 文件 | 说明 |
|------|------|
| `raft.go` | Raft 共识模块核心实现：状态机、选举定时器、RequestVote/AppendEntries RPC |
| `server.go` | 服务器封装：RPC 服务、对等节点连接管理、RPC 代理（支持不可靠网络模拟） |
| `testharness.go` | 测试框架：集群创建、节点断开/重连、单领导者检查等 |
| `raft_test.go` | 选举相关单元测试 |
| `go.mod` / `go.sum` | Go 模块依赖 |
| `dotest.sh` | 运行指定测试并生成日志可视化 |
| `dochecks.sh` | 代码静态检查（go vet + staticcheck） |

## 前置要求

- **Go 1.23+**（或与 `go.mod` 中版本兼容）
- 网络可访问（用于下载 `github.com/fortytw2/leaktest` 测试依赖）

## 使用方法

### 1. 运行所有测试

```bash
cd part1
go test -v ./...
```

### 2. 带竞态检测运行测试

```bash
go test -v -race ./...
```

### 3. 运行指定测试

```bash
go test -v -run TestElectionBasic ./...
go test -v -run TestElectionLeaderDisconnect ./...
go test -v -run TestElectionLeaderAndAnotherDisconnect ./...
go test -v -run TestDisconnectAllThenRestore ./...
go test -v -run TestElectionLeaderDisconnectThenReconnect ./...
go test -v -run TestElectionLeaderDisconnectThenReconnect5 ./...
go test -v -run TestElectionFollowerComesBack ./...
go test -v -run TestElectionDisconnectLoop ./...
```

### 4. 使用 dotest.sh 并生成日志可视化

```bash
# 运行指定测试，输出保存到 ~/temp/rlog，并生成 HTML 可视化
mkdir -p ~/temp   # 若目录不存在需先创建

./dotest.sh TestElectionBasic
./dotest.sh TestElectionLeaderDisconnect
./dotest.sh TestElectionLeaderAndAnotherDisconnect
./dotest.sh TestDisconnectAllThenRestore
./dotest.sh TestElectionLeaderDisconnectThenReconnect
./dotest.sh TestElectionLeaderDisconnectThenReconnect5
./dotest.sh TestElectionFollowerComesBack
./dotest.sh TestElectionDisconnectLoop
```

然后打开生成的 HTML 文件（路径会打印在终端），可在浏览器中查看各节点的日志时间线。

### 5. 代码静态检查

```bash
./dochecks.sh
```

脚本会依次执行 `go vet` 和 `staticcheck`，对 `./...` 下所有包做静态分析。

| 工具 | 作用 |
|------|------|
| **go vet** | Go 内置静态分析器。检查常见错误：不可达代码、可疑 struct tag、格式化字符串参数不匹配、错误的 `printf` 占位符、`copy`/`append` 参数错误等。 |
| **staticcheck** | 第三方静态分析器，规则更丰富。检查未使用的变量/导入、可简化的逻辑、潜在的 nil 解引用、goroutine 泄漏风险、错误的 `sync` 用法等。 |

**静态检查主要解决什么问题？**

- **在运行前发现潜在 bug**：测试覆盖不到的逻辑分支、边界条件、并发问题等。
- **提升代码质量**：消除死代码、简化冗余逻辑、统一风格。
- **避免隐蔽错误**：如格式化字符串与参数类型不匹配、锁使用不当等，编译能通过但运行时会出错或产生难以排查的 bug。

## 环境变量（可选）

part1 支持以下环境变量，用于压力测试和模拟异常网络。**未设置时使用默认行为**。

| 变量 | 作用 | 默认行为 |
|------|------|----------|
| `RAFT_FORCE_MORE_REELECTION` | 约 1/3 概率将选举超时固定为 150ms（否则为 150–300ms 随机），使多节点同时超时，增加选举冲突和重新选举次数 | 选举超时在 150–300ms 间随机 |
| `RAFT_UNRELIABLE_RPC` | 对 RequestVote 和 AppendEntries：约 10% 概率丢弃 RPC，约 10% 概率延迟 75ms，其余正常（1–5ms 小延迟） | 每次 RPC 仅 1–5ms 小延迟 |

### 用法示例

```bash
# 模拟不可靠网络，验证领导者断开场景
RAFT_UNRELIABLE_RPC=1 go test -v -run TestElectionLeaderDisconnect ./...

# 强制更多重新选举，压力测试选举稳定性
RAFT_FORCE_MORE_REELECTION=1 go test -v -run TestElectionDisconnectLoop ./...

# 同时启用：不可靠网络 + 频繁重新选举
RAFT_UNRELIABLE_RPC=1 RAFT_FORCE_MORE_REELECTION=1 go test -v -run TestElectionLeaderAndAnotherDisconnect ./...

# 配合 dotest.sh 使用
RAFT_UNRELIABLE_RPC=1 ./dotest.sh TestElectionFollowerComesBack
```

## 核心概念

### ConsensusModule (CM)

Raft 的**共识状态机**，对应集群中的一个节点。每个 CM 有唯一 `id`，维护：

- **持久状态**：`currentTerm`（当前任期）、`votedFor`（本任期投票对象）、`log`（复制日志）
- **易失状态**：`state`（Follower/Candidate/Leader/Dead）、`electionResetEvent`（选举超时计时起点）

CM 负责选举逻辑：超时后发起选举、向其他节点发送 RequestVote、收到多数票后成为 Leader、定期发送 AppendEntries 心跳。它通过持有的 `*Server` 发起 RPC，不关心网络细节。

### Server

**网络层封装**，把 CM 暴露为可远程调用的 RPC 服务，并管理与其他节点的连接：

- 在随机端口上监听 TCP，将 `RequestVote` 和 `AppendEntries` 注册为 RPC 方法
- 维护 `peerClients`：到其他 Server 的 RPC 客户端连接
- 提供 `ConnectToPeer` / `DisconnectPeer`，用于建立或断开与某节点的连接

CM 调用 `server.Call(peerId, "ConsensusModule.RequestVote", ...)` 时，由 Server 通过对应 `peerClients` 发送 RPC。测试中通过断开连接来模拟网络分区。

### Harness

**测试辅助结构**，用于搭建和管理 Raft 集群：

- `NewHarness(t, n)`：创建 n 个 Server，互相连接，并关闭 `ready` 通道以启动选举
- `DisconnectPeer(id)`：断开节点 id 与所有其他节点的连接，模拟该节点被分区
- `ReconnectPeer(id)`：恢复节点 id 的连接
- `CheckSingleLeader()`：断言当前 exactly one 节点认为自己是 Leader
- `CheckNoLeader()`：断言当前没有节点认为自己是 Leader
- `Shutdown()`：关闭所有 Server，清理资源

测试通过 Disconnect/Reconnect 模拟网络故障，并用 Check 方法验证选举结果是否符合预期。

## 测试用例说明

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

## 与根目录 tools 的关系

`dotest.sh` 会调用 `../tools/raft-testlog-viz/main.go` 将测试日志转换为 HTML。请确保从 `part1` 目录运行，或 `tools` 目录在正确相对路径下。

---

## 代码运行评估

### 编译

- **结论**：代码可以正常编译（`go build ./...` 通过）。
- Raft 核心实现无外部依赖，仅测试代码依赖 `github.com/fortytw2/leaktest`。

### 测试

- **结论**：在能正常下载依赖的环境下，测试应能通过。
- 首次运行需联网下载 `leaktest`。若使用 `GOPROXY=goproxy.cn` 且出现证书或解析问题，可尝试：
  ```bash
  GOPROXY=https://proxy.golang.org,direct go test -v ./...
  ```
- `dotest.sh` 依赖 `../tools/raft-testlog-viz/main.go`，需在项目根目录下存在 `tools` 目录。

### 代码质量

- 结构清晰，符合 Raft 论文（Figure 2）的选举逻辑。
- 使用 `sync.Mutex` 保护并发访问，RPC 通过 `RPCProxy` 支持延迟和丢包模拟。
- `dochecks.sh` 可做静态检查，需安装 `staticcheck`：`go install honnef.co/go/tools/cmd/staticcheck@latest`。
