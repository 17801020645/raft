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
```

### 4. 使用 dotest.sh 并生成日志可视化

```bash
# 运行指定测试，输出保存到 ~/temp/rlog，并生成 HTML 可视化
mkdir -p ~/temp   # 若目录不存在需先创建
./dotest.sh TestElectionFollowerComesBack
```

然后打开生成的 HTML 文件（路径会打印在终端），可在浏览器中查看各节点的日志时间线。

### 5. 代码静态检查

```bash
./dochecks.sh
```

会执行 `go vet` 和 `staticcheck`。

## 环境变量（可选）

| 变量 | 作用 |
|------|------|
| `RAFT_FORCE_MORE_REELECTION` | 任意非空值时，约 1/3 概率使用固定短超时，增加重新选举，用于压力测试 |
| `RAFT_UNRELIABLE_RPC` | 任意非空值时，RPC 可能被丢弃或延迟，模拟不可靠网络 |

示例：

```bash
RAFT_UNRELIABLE_RPC=1 go test -v -run TestElectionLeaderDisconnect ./...
```

## 核心概念

- **ConsensusModule (CM)**：单节点 Raft 共识模块，维护 term、votedFor、log 等状态
- **Server**：包装 CM，提供 TCP RPC 服务，管理与其他节点的连接
- **Harness**：测试用集群管理，支持断开/重连节点以模拟网络分区

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
