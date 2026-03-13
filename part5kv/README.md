# Part 5: 生产级 KV 数据库（幂等与 Append）

本目录包含在 Part 4 基础上增强的**分布式键值数据库**实现，主要新增 **Append 操作**、**ClientID/RequestID 幂等去重**、**线性化测试** 等能力。代码来自 Eli Bendersky 的系列博客 [Implementing Raft](https://eli.thegreenplace.net/2024/implementing-raft-part-4-keyvalue-database/)。

Part 5 在 **Part 3 的 Raft** 之上构建 KV 服务，与 Part 4 相比：

- **Append**：支持对 key 追加字符串（`Store[Key] += Value`）
- **幂等性**：通过 ClientID + RequestID 去重，应对网络重试导致的重复请求
- **线性化测试**：验证延迟、崩溃场景下的 Append 正确性

## 目录结构

| 文件/目录 | 说明 |
|-----------|------|
| `api/api.go` | REST API 数据结构：Put、Get、Append、CAS 的 Request/Response，含 ClientID/RequestID |
| `kvservice/kvservice.go` | KV 服务主实现：HTTP 处理、Raft 提交、commitChan 订阅、DataStore 更新、幂等去重 |
| `kvservice/command.go` | 命令类型：CommandGet、CommandPut、**CommandAppend**、CommandCAS |
| `kvservice/datastore.go` | 内存键值存储，支持 Get、Put、**Append**、CAS |
| `kvservice/json.go` | JSON 请求/响应编解码 |
| `kvservice/datastore_test.go` | DataStore 单元测试 |
| `kvclient/kvclient.go` | 客户端库：ClientID/RequestID、自动发现 Leader、重试、Get/Put/Append/CAS |
| `testharness.go` | 测试框架：集群管理、Disconnect/Crash/Restart、DelayNextHTTPResponse、随机地址客户端 |
| `system_test.go` | 系统测试：Append、CAS、线性化、网络故障、崩溃恢复 |
| `go.mod` / `go.sum` | Go 模块依赖（依赖 part3/raft） |
| `dotest.sh` | 运行指定测试并生成日志可视化 |
| `dochecks.sh` | 代码静态检查（go vet + staticcheck） |

## 前置要求

- **Go 1.23+**（或与 `go.mod` 中版本兼容）
- **part3/raft** 已就绪（part5kv 通过 `replace` 引用 `../part3/raft`）
- 网络可访问（用于下载 `github.com/fortytw2/leaktest` 等测试依赖）

## 使用方法

### 1. 运行所有测试

```bash
cd part5kv
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
go test -v -run TestClientRequestBeforeConsensus ./...
go test -v -run TestBasicPutGetSingleClient ./...
go test -v -run TestPutPrevValue ./...
go test -v -run TestBasicPutGetDifferentClients ./...
go test -v -run TestCASBasic ./...
go test -v -run TestCASConcurrent ./...

# Append 相关
go test -v -run TestBasicAppendSameClient ./...
go test -v -run TestBasicAppendDifferentClients ./...
go test -v -run TestAppendDifferentLeaders ./...
go test -v -run TestAppendLinearizableAfterDelay ./...
go test -v -run TestAppendLinearizableAfterCrash ./...

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
# 在 part5kv 目录下运行，txt 和 HTML 输出到 /Users/shentang/temp/

# 基础功能
./dotest.sh TestSetupHarness
./dotest.sh TestClientRequestBeforeConsensus
./dotest.sh TestBasicPutGetSingleClient
./dotest.sh TestPutPrevValue
./dotest.sh TestBasicPutGetDifferentClients
./dotest.sh TestCASBasic
./dotest.sh TestCASConcurrent

# Append 相关
./dotest.sh TestBasicAppendSameClient
./dotest.sh TestBasicAppendDifferentClients
./dotest.sh TestAppendDifferentLeaders
./dotest.sh TestAppendLinearizableAfterDelay
./dotest.sh TestAppendLinearizableAfterCrash

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

## 核心概念

### 与 Part 4 的差异

| 特性 | Part 4 | Part 5 |
|------|--------|--------|
| 操作 | Get、Put、CAS | Get、Put、**Append**、CAS |
| 幂等性 | 无 | ClientID + RequestID 去重 |
| 响应状态 | OK、NotLeader、FailedCommit | 同上 + **StatusDuplicateRequest** |
| 测试 | 基础 + 故障 | 同上 + Append、线性化、Delay 模拟 |

### 幂等性与去重

- 每个请求携带 `ClientID`（客户端唯一）和 `RequestID`（该客户端内单调递增）
- 服务端 `runUpdater` 维护 `lastRequestIDPerClient`，若 `RequestID <= lastRequestID` 则视为重复
- 重复请求不再次应用到 DataStore，但返回 `StatusDuplicateRequest`，客户端可识别并忽略

### API 与命令

| 操作 | HTTP 路径 | 命令类型 | 说明 |
|------|-----------|----------|------|
| Put | POST /put/ | CommandPut | 写入 key=value |
| Get | POST /get/ | CommandGet | 读取 key 的值 |
| Append | POST /append/ | CommandAppend | 追加 value 到 key（key 不存在则创建） |
| CAS | POST /cas/ | CommandCAS | 若 key==compare 则赋值为 value |

### 响应状态

| 状态 | 含义 |
|------|------|
| StatusOK | 操作成功 |
| StatusNotLeader | 当前节点非 Leader，客户端应重试其他节点 |
| StatusFailedCommit | 提交失败（如 Leader 切换），客户端应重试 |
| StatusDuplicateRequest | 请求已执行过（幂等去重），客户端可忽略 |

### Harness 能力

| 方法 | 说明 |
|------|------|
| `DisconnectServiceFromPeers(id)` | 断开节点与集群的网络连接 |
| `ReconnectServiceToPeers(id)` | 重连节点 |
| `CrashService(id)` | 崩溃并关闭节点 |
| `RestartService(id)` | 用原 Storage 重启节点 |
| `DelayNextHTTPResponseFromService(id)` | 延迟该节点下一次 HTTP 响应（用于测试重试/线性化） |
| `NewClient()` | 创建客户端，地址顺序为存活节点顺序 |
| `NewClientWithRandomAddrsOrder()` | 创建客户端，地址顺序随机 |
| `NewClientSingleService(id)` | 创建仅连接指定节点的客户端 |
| `CheckPut` / `CheckGet` / `CheckAppend` / `CheckCAS` | 执行并校验操作 |
| `CheckGetTimesOut` | 校验 Get 在无共识时超时 |

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

### Append 相关

| 测试 | 验证内容 |
|------|----------|
| `TestBasicAppendSameClient` | 单客户端 Append：存在 key 追加、不存在 key 创建 |
| `TestBasicAppendDifferentClients` | 不同客户端 Append 后数据一致 |
| `TestAppendDifferentLeaders` | Leader 崩溃后新 Leader 上 Append 正确 |
| `TestAppendLinearizableAfterDelay` | 延迟响应导致客户端重试时，Append 只执行一次（线性化） |
| `TestAppendLinearizableAfterCrash` | Leader 延迟响应后崩溃，新 Leader 上 Append 只执行一次 |

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

## 与 Part 4 的关系

- Part 5 在 Part 4 基础上扩展：新增 Append、幂等去重、线性化测试
- 两者均依赖 **part3/raft** 作为共识层
- Part 5 的 Command 增加 `ClientID`、`RequestID`、`IsDuplicate` 等字段
- Part 5 的 KVClient 维护 `clientID`、`requestID`，每次请求自增
- Part 5 的 harness 支持 `DelayNextHTTPResponseFromService`、`NewClientWithRandomAddrsOrder`、`CheckGetTimesOut`

## 与根目录 tools 的关系

`dotest.sh` 会调用 `../tools/raft-testlog-viz/main.go` 将测试日志转换为 HTML。请确保从 `part5kv` 目录运行，且 `tools` 目录在正确相对路径下。
