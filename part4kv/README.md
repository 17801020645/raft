# Part 4: 基于 Raft 的 KV 数据库

本目录包含基于 Raft 共识算法构建的**分布式键值数据库（KV Service）**实现。代码来自 Eli Bendersky 的系列博客 [Implementing Raft - Part 4: Key/Value database](https://eli.thegreenplace.net/2024/implementing-raft-part-4-keyvalue-database/)。

Part 4 在 **Part 3 的 Raft** 之上构建了一个完整的 KV 服务：客户端通过 REST API 执行 Get/Put/CAS 操作，命令经 Raft 复制并提交后应用到各节点的 DataStore，实现**复制状态机（Replicated State Machine）**。

## 目录结构

| 文件/目录 | 说明 |
|-----------|------|
| `api/api.go` | REST API 数据结构：PutRequest、GetRequest、CASRequest 及对应 Response |
| `kvservice/kvservice.go` | KV 服务主实现：HTTP 处理、Raft 提交、commitChan 订阅、DataStore 更新 |
| `kvservice/command.go` | 命令类型：CommandGet、CommandPut、CommandCAS，提交到 Raft log |
| `kvservice/datastore.go` | 内存键值存储，支持 Get、Put、CAS |
| `kvservice/json.go` | JSON 请求/响应编解码 |
| `kvservice/datastore_test.go` | DataStore 单元测试 |
| `kvclient/kvclient.go` | 客户端库：自动发现 Leader、重试、Get/Put/CAS |
| `testharness.go` | 测试框架：集群管理、Disconnect/Crash/Restart、客户端创建 |
| `system_test.go` | 系统测试：端到端 Put/Get/CAS、网络故障、崩溃恢复 |
| `go.mod` / `go.sum` | Go 模块依赖（依赖 part3/raft） |
| `dotest.sh` | 运行指定测试并生成日志可视化 |
| `dochecks.sh` | 代码静态检查（go vet + staticcheck） |

## 前置要求

- **Go 1.23+**（或与 `go.mod` 中版本兼容）
- **part3/raft** 已就绪（part4kv 通过 `replace` 引用 `../part3/raft`）
- 网络可访问（用于下载 `github.com/fortytw2/leaktest` 等测试依赖）

## 使用方法

### 1. 运行所有测试

```bash
cd part4kv
go test -v ./...
```

### 2. 带竞态检测运行测试

```bash
go test -v -race ./...
```

### 3. 运行指定测试

```bash
# 基础功能
go test -v -run TestSetupHarness ./...
go test -v -run TestBasicPutGetSingleClient ./...
go test -v -run TestPutPrevValue ./...
go test -v -run TestBasicPutGetDifferentClients ./...
go test -v -run TestCASBasic ./...
go test -v -run TestCASConcurrent ./...

# 并发与多客户端
go test -v -run TestConcurrentClientsPutsAndGets ./...
go test -v -run Test5ServerConcurrentClientsPutsAndGets ./...

# 网络故障与崩溃恢复
go test -v -run TestDisconnectLeaderAfterPuts ./...
go test -v -run TestDisconnectLeaderAndFollower ./...
go test -v -run TestCrashFollower ./...
go test -v -run TestCrashLeader ./...
go test -v -run TestCrashThenRestartLeader ./...
```

### 4. 使用 dotest.sh 并生成日志可视化

```bash
# 在 part4kv 目录下运行，rlog 和 HTML 输出到 /Users/shentang/temp/

# 基础功能
./dotest.sh TestSetupHarness
./dotest.sh TestClientRequestBeforeConsensus
./dotest.sh TestBasicPutGetSingleClient
./dotest.sh TestPutPrevValue
./dotest.sh TestBasicPutGetDifferentClients
./dotest.sh TestCASBasic
./dotest.sh TestCASConcurrent

# 并发与多客户端
./dotest.sh TestConcurrentClientsPutsAndGets
./dotest.sh Test5ServerConcurrentClientsPutsAndGets

# 网络故障与崩溃恢复
./dotest.sh TestDisconnectLeaderAfterPuts
./dotest.sh TestDisconnectLeaderAndFollower
./dotest.sh TestCrashFollower
./dotest.sh TestCrashLeader
./dotest.sh TestCrashThenRestartLeader
```

然后打开生成的 HTML 文件（路径会打印在终端），可在浏览器中查看日志时间线。

### 5. 代码静态检查

```bash
./dochecks.sh
```

脚本会依次执行 `go vet` 和 `staticcheck`，对 `./...` 下所有包做静态分析。

## 核心概念

### 复制状态机

- **Raft log**：KV 命令（Get/Put/CAS）作为 Command 提交到 Raft
- **commitChan**：Raft 提交后通过 channel 通知 KV 服务
- **runUpdater**：从 commitChan 读取已提交命令，应用到 DataStore
- **createCommitSubscription**：HTTP 处理函数订阅指定 log index 的提交，等待后返回客户端

### API 与命令

| 操作 | HTTP 路径 | 命令类型 | 说明 |
|------|-----------|----------|------|
| Put | POST /put/ | CommandPut | 写入 key=value |
| Get | POST /get/ | CommandGet | 读取 key 的值 |
| CAS | POST /cas/ | CommandCAS | 若 key==compare 则赋值为 value |

### 响应状态

| 状态 | 含义 |
|------|------|
| StatusOK | 操作成功 |
| StatusNotLeader | 当前节点非 Leader，客户端应重试其他节点 |
| StatusFailedCommit | 提交失败（如 Leader 切换），客户端应重试 |

### Harness 能力

| 方法 | 说明 |
|------|------|
| `DisconnectServiceFromPeers(id)` | 断开节点与集群的网络连接 |
| `ReconnectServiceToPeers(id)` | 重连节点 |
| `CrashService(id)` | 崩溃并关闭节点 |
| `RestartService(id)` | 用原 Storage 重启节点 |
| `CheckSingleLeader()` | 检查集群有唯一 Leader |
| `CheckPut` / `CheckGet` / `CheckCAS` | 通过客户端执行并校验操作 |

## 测试用例说明

### 基础功能

| 测试 | 验证内容 |
|------|----------|
| `TestSetupHarness` | Harness 能正确创建 3 节点集群 |
| `TestClientRequestBeforeConsensus` | 客户端在 Leader 选出前能通过重试完成请求 |
| `TestBasicPutGetSingleClient` | 单客户端 Put 后 Get 能读到正确值 |
| `TestPutPrevValue` | Put 返回正确的 prevValue 和 keyFound |
| `TestBasicPutGetDifferentClients` | 不同客户端间数据可见 |
| `TestCASBasic` | CAS 基本语义正确 |
| `TestCASConcurrent` | 并发 CAS 正确性 |

### 并发与多节点

| 测试 | 验证内容 |
|------|----------|
| `TestConcurrentClientsPutsAndGets` | 多客户端并发 Put/Get |
| `Test5ServerConcurrentClientsPutsAndGets` | 5 节点集群下的并发 Put/Get |

### 网络故障与崩溃恢复

| 测试 | 验证内容 |
|------|----------|
| `TestDisconnectLeaderAfterPuts` | Leader 断开后能选出新 Leader，客户端仍可读写 |
| `TestDisconnectLeaderAndFollower` | 断开 Leader 和一 Follower 后无共识；重连 Follower 后恢复 |
| `TestCrashFollower` | 崩溃 Follower 后，其余节点仍可服务 |
| `TestCrashLeader` | 崩溃 Leader 后，新 Leader 能继续服务 |
| `TestCrashThenRestartLeader` | Leader 崩溃后重启，能从 Storage 恢复并追上集群 |

## 与 Part 3 的关系

- Part 4 依赖 **part3/raft** 作为共识层
- KV 命令封装为 `Command`，通过 `gob.Register` 注册后提交到 Raft
- Part 3 的 `Storage` 用于 Raft 持久化；Crash/Restart 时 KV 服务通过同一 Storage 恢复
- Part 4 的 `dotest.sh`、`dochecks.sh` 风格与 Part 3 保持一致

## 与根目录 tools 的关系

`dotest.sh` 会调用 `../tools/raft-testlog-viz/main.go` 将测试日志转换为 HTML。请确保从 `part4kv` 目录运行，且 `tools` 目录在正确相对路径下。
