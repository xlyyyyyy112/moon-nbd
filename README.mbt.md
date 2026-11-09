# MoonNBD

MoonNBD 是开发中的 MoonBit 网络块设备客户端与服务端。它通过 NBD 协议访问远端块设备，也可以把内存或本地普通文件作为块设备导出。协议实现使用 MoonBit 和 `moonbitlang/async`，可以与 QEMU 互通。

## 当前状态

此项目仍在开发，尚未发布到 Mooncakes。当前支持 native 后端和 TCP；客户端与每个服务端导出同时只处理一个请求或连接。客户端支持选择命名导出、列表查询、无副作用的 `NBD_OPT_INFO` 探测、`NBD_OPT_GO`（不支持时回退）、大小约束、结构化读取、`base:allocation`、读写、刷盘、TRIM、写零和主动断开。服务端支持单个默认或命名导出、结构化读取与基础块状态，内存和文件后端均可用。

暂不支持 TLS、身份认证、同一连接多请求在途、自动重连、旧式握手或完整 NBD 扩展。CLI 服务端只监听 `127.0.0.1`；库使用者应限制网络访问。块状态如果无法判断是否为洞或零，服务端会保守地返回未标记状态，不代表已经确认物理分配。

写操作、刷盘、TRIM 和写零若发送后连接中断，返回 `OutcomeUnknown`：服务器可能已执行操作，调用方需要自行确认结果，不能盲目重试。即使收到服务端写入错误，也不能假设底层文件完全未修改。文件服务需由调用方保证后端文件的大小和内容不被其他程序并发修改；内存后端是易失性的。

## 本地检查

使用 MoonBit 0.10.18 或兼容版本、C 编译器及 `moonbitlang/async`：

```sh
moon update
moon check --target native --deny-warn
moon test --target native --deny-warn
```

## QEMU 联调

在 Linux 或 WSL 安装 `qemu-utils`，依次运行：

```sh
bash scripts/qemu-interop.sh
bash scripts/qemu-server-interop.sh
bash scripts/qemu-file-server-interop.sh
bash scripts/qemu-export-interop.sh
bash scripts/qemu-large-offset-interop.sh
bash scripts/qemu-sparse-export-interop.sh
```

脚本仅操作新建临时文件，分别验证客户端连接 QEMU、QEMU 连接内存和文件服务端、普通及稀疏导出的逐字节比对，以及 4 GiB 以上偏移。测试使用本机端口 11089–11094；有占用时需先释放端口。服务端示例和客户端联调程序使用固定端口，切勿将它们指向重要数据。

## 库接口

```moonbit nocheck
let disk = @nbd.Client::connect("127.0.0.1", 11089, b"")
let data = disk.read_at(0UL, 512)
disk.disconnect()
```

调用方可设置 `structured=true, allocation=true`，使用 `block_status` 或 `scan_allocation` 查询分配信息；可用 `write_at`、`flush`、`trim`、`write_zeroes` 和无副作用的 `cache` 提示操作服务器支持的能力。单次读写上限为 16 MiB；`copy_to_file` 分块复制到空文件，失败可能留下不完整文件。

`copy_sparse_to_file` 也只接受新建的空普通文件，并且要求连接时已启用 `allocation=true`。它会先把目标扩展到原始逻辑大小，仅跳过服务器明确标记为 `ZERO` 的区段；**只标记为 HOLE 的区段不会跳过**，避免把无法确认的内容错误地变为零。源端在导出过程中必须保持不变，失败后的目标文件同样不应当作完整备份使用。`compare_ranges` 比较两个稳定导出的字节并返回差异区间，超出设定范围数量会报错，不会返回伪装成完整的结果。

对于重复扫描同一个稳定镜像的场景，可使用 `CachedClient::connect` 建立容量受限的 LRU 读取缓存。缓存不并发请求，写入、TRIM 和写零会先失效重叠缓存行；如果外部程序会修改导出内容，请关闭并重新建立缓存。

`ClientConfig` 可保存连接参数，并通过 `read_at_retry` 在**稳定的只读导出**发生传输中断后重新建立连接并重试读取。它不会重试任何修改操作，也不应用于可能在重连期间变化的导出。

`create_integrity_manifest` 可为稳定导出生成分块 CRC32 清单；`verify_integrity_manifest` 会重新读取并给出精确的不一致块。清单可用 `IntegrityManifest::encode` 保存、用 `decode` 恢复。CRC32 用于检测意外损坏，并不提供签名或抗篡改保证。

## 命令行

以下命令在仓库根目录执行：

```sh
moon run --target native cmd/nbd -- list 127.0.0.1 10809
moon run --target native cmd/nbd -- info 127.0.0.1 10809
moon run --target native cmd/nbd -- read 127.0.0.1 10809 0 512 sector.bin
moon run --target native cmd/nbd -- export 127.0.0.1 10809 output.raw
moon run --target native cmd/nbd -- export-sparse 127.0.0.1 10809 output.raw
moon run --target native cmd/nbd -- serve disk.raw 11091
```

`info`、`read`、`export` 和 `export-sparse` 的末尾可追加导出名称。`info` 使用 `NBD_OPT_INFO`，不会进入传输阶段。`serve` 默认只读，可追加 `--name NAME`；只有明确追加 `--write` 才允许远端写入。`read` 和两种 `export` 使用独占创建，拒绝覆盖已存在的输出文件；导出失败可能留下部分文件。`export-sparse` 需要对端支持 `base:allocation`，并且只跳过服务端明确声明为 `ZERO` 的区段。客户端操作默认超时 30 秒，可用 `timeout_ms` 调整。

协议参考 [NBD 官方规范](https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md)，QEMU 仅作为外部互操作测试工具。项目使用 Apache-2.0 许可证，网络实现依赖 `moonbitlang/async`。
