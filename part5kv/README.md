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

### 6. 运行时分析（pprof / trace）

以 `Test5ServerConcurrentClientsPutsAndGets` 为例，采集 CPU、内存、调用栈、火焰图、调度/阻塞 trace。**在 part5kv 目录下执行**。

#### 6.1 采集 profile 和 trace

```bash
cd part5kv

# CPU 热点（整个测试运行期间采样，该用例约 0.6 秒）
# 注意：-cpuprofile/-memprofile/-trace 只能用于单包，用 . 不要用 ./...
go test -cpuprofile=cpu.prof -run Test5ServerConcurrentClientsPutsAndGets .

# 内存分配
go test -memprofile=mem.prof -run Test5ServerConcurrentClientsPutsAndGets .

# 调度与阻塞 trace（生成 trace.out）
go test -trace=trace.out -run Test5ServerConcurrentClientsPutsAndGets .
```

> 说明：分析时建议不加 `-race`，竞态检测会显著影响采样结果。

> **若 cpu.prof 为空或 pprof 报 "empty input file"**：测试需要绑定网络端口，若在受限环境（如无网络权限的沙盒）中运行会失败，导致 profile 为空。请在允许网络的环境中执行 `go test`，确保测试通过（输出 `ok`）后再用 pprof 分析。

> **若 pprof 报 "Could not execute dot; may need to install graphviz"**：Graph 视图需要 Graphviz。macOS 安装：`brew install graphviz`。安装后 pprof 的 Graph、Flame Graph 等视图可正常渲染。

#### 6.2 分析命令

| 分析类型 | 命令 | 说明 |
|----------|------|------|
| **CPU 热点** | `go tool pprof -http=:8080 cpu.prof` | 浏览器打开 http://localhost:8080，查看 Top / Graph |
| **内存分配** | `go tool pprof -http=:8080 mem.prof` | 同上，查看堆分配热点 |
| **调用栈（Top）** | `go tool pprof -top cpu.prof` | 终端输出最耗 CPU 的函数 |
| **调用栈（Traces）** | `go tool pprof -traces cpu.prof` | 终端输出采样调用栈 |
| **火焰图** | `go tool pprof -http=:8080 cpu.prof` | 在 Web UI 中选 **View → Flame Graph** |
| **调度/阻塞** | `go tool trace trace.out` | 浏览器打开，查看 Goroutine、调度、阻塞、GC 等 |

#### 6.3 火焰图导出

```bash
# 从 CPU profile 导出 SVG 火焰图
go tool pprof -svg -output=cpu_flame.svg cpu.prof

# 从内存 profile 导出
go tool pprof -svg -output=mem_flame.svg mem.prof
```

#### 6.4 其他测试用例

将 `Test5ServerConcurrentClientsPutsAndGets` 替换为任意测试名即可，例如：

```bash
go test -cpuprofile=cpu.prof -run TestConcurrentClientsPutsAndGets .
go test -memprofile=mem.prof -run TestCrashLeader .
```

#### 6.5 火焰图怎么看：业务 vs 系统调用

火焰图里大量是 `syscall`、`runtime`、`internal/poll` 等，**这是正常的**：短测试（~0.8 秒）中，大部分 CPU 花在 I/O 和调度上。要找到业务相关部分，可以这样做：

**1. 在 pprof Web UI 里用 Focus 过滤**

- 打开 http://localhost:8080/ui/flamegraph
- 在 **Refine** 输入：`github.com/eliben/raft`（只保留本项目的调用）
- 或输入：`part5kv|part3/raft`（KV 服务 + Raft 层）

**2. 业务相关调用链（以 Test5ServerConcurrentClientsPutsAndGets 为例）**

| 调用链 | 含义 |
|--------|------|
| `net/http.(*conn).serve` → ... → `syscall` | HTTP 处理请求/响应（入口） |
| `raft.(*ConsensusModule).leaderSendAEs` → `Server.Call` → `net/rpc` → ... | Leader 发 AppendEntries RPC |
| `raft.(*RPCProxy).Call` | Raft 节点间 RPC |
| `kvservice.handlePut` / `handleGet` | KV 的 Put/Get 处理（若出现） |
| `encoding/gob.Decode` | RPC 编解码 |

**3. 常见“非业务”栈（可忽略）**

| 栈 | 含义 |
|----|------|
| `runtime.findRunnable` / `schedule` / `park_m` | 调度、等待 goroutine |
| `runtime.pthread_cond_wait` | 线程同步 |
| `internal/poll.ignoringEINTRIO` | 网络 I/O |
| `syscall.syscall` / `syscall.write` / `syscall.read` | 系统调用 |
| `net.cgoLookupHostIP` | DNS 解析 |

**4. 想看更多业务热点时**

可延长测试或提高负载，例如：

```bash
# 多次运行同一测试，增加采样
go test -cpuprofile=cpu.prof -run Test5ServerConcurrentClientsPutsAndGets -count=10 .
```

#### 6.6 火焰图逐项解析（Test5ServerConcurrentClientsPutsAndGets，-count=10）

以下基于 6.73s 运行、930ms 采样的 profile，按调用链逐项说明火焰图中各块的含义。

---

**一、Profile 概览**

| 指标 | 值 |
|------|-----|
| 总采样 | 930ms（约 14% 的 CPU 时间） |
| 运行时长 | 6.73s |
| flat 占比 Top 5 | syscall.syscall 40.86%、runtime.kevent 16.13%、runtime.pthread_cond_wait 10.75%、runtime.pthread_cond_signal 8.60%、runtime.madvise 6.45% |

---

**二、按调用链分类**

**1. 业务入口与测试框架**

| 调用链（自顶向下） | cum | 含义 |
|--------------------|-----|------|
| `Test5ServerConcurrentClientsPutsAndGets` → `testing.tRunner` | 30ms | 测试主 goroutine |
| `Test5ServerConcurrentClientsPutsAndGets.func1` → `CheckPut` → `KVClient.Put` → `send` | 10ms | 并发 Put 协程 |
| `Test5ServerConcurrentClientsPutsAndGets.func2` → `CheckGet` → `KVClient.Get` → `send` | 20ms | 并发 Get 协程 |
| `NewHarness` → `kvservice.New` → `raft.(*Server).Serve` | 10ms | 启动 5 个 KV 服务 |
| `leaktest.CheckContext/CheckTimeout` → `interestingGoroutines` | 20ms | 泄漏检测 |

**2. KV 服务层（part5kv）**

| 调用链 | cum | 含义 |
|--------|-----|------|
| `net/http.(*conn).serve` → `ServeMux.ServeHTTP` → `HandlerFunc` → `handleGet` | 30ms | HTTP Get 处理 |
| `handleGet` → `Server.Submit` → `ConsensusModule.Submit` | 30ms | Get 提交到 Raft |
| `handlePut` → `Server.Submit` → `ConsensusModule.Submit` | 10ms | Put 提交到 Raft |
| `handleGet` → `Submit` → `dlog` → `log.Printf` → `os.(*File).Write` → `syscall.write` | 10ms | Get 路径上的调试日志 |
| `handlePut` → `Submit` → `dlog` → ... → `syscall.write` | 10ms | Put 路径上的调试日志 |

**3. Raft 共识层（part3/raft）**

| 调用链 | cum | 含义 |
|--------|-----|------|
| `ConsensusModule.leaderSendAEs.func1` → `Server.Call` → `RPCProxy.Call` → `net/rpc.(*Client).Call` → `send` → `gobClientCodec.WriteRequest` → `bufio.Flush` → `FD.Write` → `syscall.write` | 30ms | Leader 发 AppendEntries RPC |
| `leaderSendAEs` → `dlog` → `log.Printf` → ... → `syscall.write` | 20ms | Leader 发 AE 时的调试日志 |
| `ConsensusModule.AppendEntries` → `RPCProxy.AppendEntries` | 50ms | 处理 AppendEntries 请求 |
| `ConsensusModule.Submit` → `dlog` | 20ms | 提交命令时的日志 |
| `ConsensusModule.Submit` → `persistToStorage` → `gob.Encoder.Encode` → `writeMessage` | 10ms | 持久化 Raft 状态 |
| `Server.Serve.func1.1` → `ServeConn` → `ServeCodec` → `readRequest` → `gob.Decoder.Decode` → `bufio.Read` → `FD.Read` → `syscall.read` | 60ms | Raft RPC 服务端读请求 |
| `Server.Serve` → `Listen` → `socket` → `syscall.Listen` | 10ms | Raft 监听端口 |
| `Server.Serve.func1` → `Accept` → `syscall` | 10ms | 接受 Raft 连接 |

**4. KV 客户端（kvclient）**

| 调用链 | cum | 含义 |
|--------|-----|------|
| `KVClient.send` → `clientlog` → `log.Printf` → `fmt.Appendf` → `printValue` → `fmtInteger` | 20ms | 客户端日志（含重试、NotLeader 等） |
| `KVClient.Get` / `Put` → `send` | 30ms | 客户端发送请求 |

**5. 网络与 I/O**

| 调用链 | cum | 含义 |
|--------|-----|------|
| `internal/poll.(*FD).Write` → `ignoringEINTRIO` → `syscall.syscall` | 210ms | 所有写 syscall（RPC、HTTP、日志） |
| `internal/poll.(*FD).Read` → ... → `syscall.read` | 90ms | 所有读 syscall |
| `net.(*sysDialer).dialParallel/dialSerial/dialTCP` → `internetSocket` → `socket` → `syscall.Socket/Connect` | 60ms | 客户端建连（Put/Get 到 KV） |
| `net/http.(*persistConn).readLoop` → `Peek` → `fill` → `FD.Read` | 40ms | HTTP 长连接读 |
| `net/http.(*persistConn).writeLoop` → `Flush` → `FD.Write` | 20ms | HTTP 长连接写 |

**6. 编解码**

| 调用链 | cum | 含义 |
|--------|-----|------|
| `encoding/gob.(*Decoder).Decode` → `DecodeValue` → `decodeTypeSequence` → `recvMessage` → `decodeUintReader` → `bufio.Read` | 60ms | RPC 请求解码（Raft 收 AppendEntries） |
| `encoding/gob.(*Encoder).Encode` → `EncodeValue` → `encode` → `encodeInterface` → `writeMessage` | 10ms | Raft 状态持久化编码 |

**7. 日志**

| 调用链 | cum | 含义 |
|--------|-----|------|
| `log.Printf` → `Logger.output` → `os.(*File).Write` | 130ms | 所有日志输出（Raft dlog、kvclient clientlog） |

**8. 运行时（可忽略）**

| 调用链 | cum | 含义 |
|--------|-----|------|
| `runtime.schedule` → `findRunnable` → `netpoll` → `kevent` | 150ms | 网络轮询、找可运行 G |
| `runtime.schedule` → `park_m` → `mcall` | 340ms | 调度、让出 CPU |
| `runtime.findRunnable` → `semasleep` → `notesleep` → `pthread_cond_wait` | 100ms | 等待条件变量 |
| `runtime.startm` → `notewakeup` → `semawakeup` → `pthread_cond_signal` | 80ms | 唤醒 M |
| `runtime.madvise` | 60ms | 内存管理 |
| `runtime.copystack` → `newstack` → `morestack` | 30ms | 栈扩展 |
| `runtime.gcBgMarkWorker` → `gcDrain` | 30ms | GC 标记 |

---

**三、火焰图自底向上读法**

- **最底层**：`syscall.syscall`、`runtime.kevent` 等，表示 CPU 实际消耗点。
- **往上**：`internal/poll.(*FD).Write/Read` → `bufio` → `net.(*conn)`，表示 I/O 路径。
- **再往上**：`net/rpc`、`encoding/gob`、`net/http`，表示协议与传输层。
- **最上层**：`raft.(*ConsensusModule)`、`kvservice.handleGet/handlePut`、`kvclient.send`，表示业务逻辑。

**在火焰图中找业务**：从顶部往下找 `github.com/eliben/raft`，其下方的整条栈即业务相关调用链。

---

**四、优化启示**

| 热点 | 占比 | 建议 |
|------|------|------|
| `raft.(*ConsensusModule).dlog` → `log.Printf` | 90ms (9.68%) | 关闭或降低 Raft 调试日志级别 |
| `kvclient.clientlog` → `log.Printf` | 30ms (3.23%) | 关闭或降低客户端日志 |
| `encoding/gob` 编解码 | 70ms (7.5%) | 考虑更轻量 RPC 编码（如 protobuf） |
| `internal/poll.(*FD).Write` | 210ms (22.58%) | 主要为 I/O 等待，优化空间有限 |

#### 6.7 过滤视图详解：`?p=part5kv|part3/raft`

在火焰图 URL 后加 `?p=part5kv%7Cpart3%2Fraft`（即 `p=part5kv|part3/raft`）会启用 **Refine 过滤**，只保留调用栈中包含 `part5kv` 或 `part3/raft` 的路径。

---

**一、先搞清一个关键点：分层 ≠ 火焰图上的区域**

README 里的「1～5 层」是**逻辑分层**，不是火焰图上的「从上到下五条横带」。

火焰图更像**多棵并排的树**：

- 最上面是 `root`（多个根，代表不同的 goroutine）
- 每个根下面是一**列**，从上到下是：谁调用了谁
- **同一列**里，可能同时出现「第 1 层」到「第 5 层」的函数，从上到下依次堆叠

所以：**README 的分层 = 函数的「身份标签」；火焰图 = 这些函数按调用关系堆成的「一列一列的栈」**。

---

**二、火焰图怎么读（外行人版）**

把程序想象成一家公司：

- **宽度**：这个函数（及其调用的所有人）总共花了多少时间，越宽越忙
- **上下关系**：上面的函数是「老板」，下面的函数是「下属」，老板叫下属干活
- **左右关系**：不同的列 = 不同的工作线（不同的 goroutine），互不隶属

**过滤 `p=part5kv|part3/raft` 的作用**：只保留和 part5kv、part3/raft 有关的「工作线」，其它无关的栈会被隐藏。

---

**三、在截图中怎么找到 README 的每一层**

下面用「在截图中往哪看」的方式，把 README 的分层和火焰图对应起来。

**第 1 层：顶层（测试与入口）**

- **在哪看**：最上面，`root` 下面那一排
- **找什么**：
  - `testing.tRunner`：Go 测试框架入口
  - `Test5ServerConcurrentClientsPutsAndGets`：你的测试主函数
  - 它下面会分出 `func1`（Put 协程）、`func2`（Get 协程）
  - 还有 `NewHarness`（建集群）、`CheckTimeout.func1` / `CheckContext.func1`（泄漏检测）
- **对应 README**：表格「1. 顶层：测试与入口」里列出的那些块

**第 2 层：part5kv 层**

- **在哪看**：在 `func1`、`func2` 的**正下方**，或者从 `http.(*conn).serve` 往**上**看
- **找什么**：
  - 从 `func1` 往下：`(*Harness).CheckPut` → `(*KVClient).Put` → `(*KVClient).send`
  - 从 `func2` 往下：`(*Harness).CheckGet` → `(*KVClient).Get` → `(*KVClient).send`
  - 从 `http` 往上：`handleGet`、`handlePut`（在 `HandlerFunc.ServeHTTP` 下面）
- **对应 README**：表格「2. part5kv 层」

**第 3 层：part3/raft 层**

- **在哪看**：分散在多列里
  - 从 `handlePut` 往下：`(*ConsensusModule).Submit`
  - 左侧较宽的一列：`leaderSendAEs.func1`、`dlog`（Raft 日志，通常很宽）
  - 最左侧一列：`(*Server).Serve.func1.1`（Raft 收 RPC）
- **对应 README**：表格「3. part3/raft 层」

**第 4 层：下层（基础设施）**

- **在哪看**：在 part5kv、raft 块的**正下方**
- **找什么**：
  - `handleGet`/`handlePut` 下面：`http.(*conn).serve`、`HandlerFunc.ServeHTTP`
  - `leaderSendAEs` 下面：`rpc.(*Client).Call`、`WriteRequest`
  - `Serve.func1.1` 下面：`rpc.(*Server).ServeCodec`、`gob.Decode`
  - 各种日志路径下面：`log.Printf`、`os.(*File).Write`
- **对应 README**：表格「4. 下层：被业务调用的基础设施」

**第 5 层：最底层（系统调用）**

- **在哪看**：每一列的**最底部**
- **找什么**：`syscall.syscall`、`syscall.write`、`syscall.read`、`runtime.kevent` 等
- **对应 README**：表格「5. 最底层：系统调用」

---

**四、用一条完整路径串起来**

以 **Put 操作**为例，在火焰图中可以这样追踪一列：

```
Test5ServerConcurrentClientsPutsAndGets.func1     ← 第 1 层：测试入口
  └─ (*Harness).CheckPut                          ← 第 2 层：part5kv
       └─ (*KVClient).Put
            └─ (*KVClient).send
                 └─ (发 HTTP 到 KV 服务端...)
```

服务端收到请求后，在**另一列**里：

```
http.(*conn).serve                                ← 第 4 层：基础设施
  └─ HandlerFunc.ServeHTTP
       └─ (*KVService).handlePut                  ← 第 2 层：part5kv
            └─ (*ConsensusModule).Submit           ← 第 3 层：raft
                 └─ dlog → log.Printf              ← 第 3 层 + 第 4 层
                      └─ os.(*File).Write          ← 第 4 层
                           └─ syscall.write       ← 第 5 层：系统调用
```

所以：**同一列 = 一条调用链；从上到下 = 从 README 第 1 层一路到第 5 层**。

---

**五、为什么「对不上」？**

常见困惑来源：

1. **分层是逻辑标签，不是空间分区**：第 2 层、第 3 层的函数会出现在不同列、不同高度，不会整齐排成「第二行」「第三行」。
2. **同一函数会出现在多列**：比如 `dlog` 既在 `Submit` 下面，也在 `leaderSendAEs` 下面，因为多处会打日志。
3. **要「跟一列」而不是「扫一行」**：看火焰图时，选一列从上跟到下，才能看到完整的 1→2→3→4→5 的调用链。

---

**六、速查：README 表格 ↔ 火焰图**

| README 分层 | 在火焰图里怎么找 |
|-------------|------------------|
| 1. 顶层     | 最上面，`root` 下，找 `Test5...`、`func1`、`func2`、`NewHarness` |
| 2. part5kv  | `func1`/`func2` 下面，或 `http` 上面，找 `CheckPut`、`KVClient`、`handleGet`、`handlePut` |
| 3. raft     | 分散在多列，找 `Submit`、`leaderSendAEs`、`AppendEntries`、`dlog`、`Serve.func1.1` |
| 4. 基础设施 | part5kv、raft 块的直接下方，找 `http`、`rpc`、`gob`、`log.Printf` |
| 5. 系统调用 | 每列最底部，找 `syscall`、`runtime.kevent` |

---

**七、小结**

- README 的 1～5 层是**函数身份**，火焰图是**调用关系**。
- 看火焰图时：**选一列，从上跟到下**，就能看到从测试入口到系统调用的完整路径。
- 过滤 `p=part5kv|part3/raft` 后，只保留和业务相关的列，更容易找到这些路径。

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
