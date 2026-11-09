# MoonNBD

[![持续集成](https://github.com/xlyyyyyy112/moon-nbd/actions/workflows/ci.yml/badge.svg)](https://github.com/xlyyyyyy112/moon-nbd/actions/workflows/ci.yml)

MoonNBD 是用 MoonBit 编写的网络块设备（NBD）客户端与服务端。客户端可以访问远端镜像、读取和修改数据、复制镜像、比较差异及检查数据完整性；服务端可以将内存或本地普通文件作为镜像导出，并与 QEMU 互通。

项目仍在开发，尚未发布到 Mooncakes。当前支持 native 后端和 TCP，每条连接一次只处理一个请求。项目不支持 TLS、身份认证、同一连接上的并发请求或旧式握手。命令行服务端只监听 `127.0.0.1`，不应直接暴露在不可信网络中。

## 环境准备

需要 MoonBit 0.10.18 或兼容版本、C 编译器，以及 `moonbitlang/async` 依赖。克隆仓库后，在项目根目录执行：

```sh
moon update
moon check --target native --deny-warn
moon test --target native --deny-warn
```

构建命令行程序：

```sh
moon build --target native cmd/nbd
```

## 端到端使用流程

下面以本地文件镜像为例，展示创建镜像、启动服务、查询信息、导出和比对的完整过程。先在 Linux 或 WSL 安装 QEMU 工具，并在仓库根目录打开两个终端。

在终端一创建一个新的 16 MiB 镜像，然后启动只读服务端：

```sh
qemu-img create -f raw demo.raw 16M
moon run --target native cmd/nbd -- serve demo.raw 11091
```

服务端会保持运行并监听本机 `127.0.0.1:11091`。该示例以只读方式导出文件。

在终端二查询导出信息，再将镜像完整导出到一个新文件：

```sh
moon run --target native cmd/nbd -- info 127.0.0.1 11091
moon run --target native cmd/nbd -- export 127.0.0.1 11091 backup.raw
qemu-img compare demo.raw backup.raw
```

`info` 显示镜像大小和能力。导出命令使用独占创建，不会覆盖已有的 `backup.raw`；导出过程中失败时可能留下不完整文件。比对命令成功退出表示两个镜像内容一致。完成后在终端一按 `Ctrl+C` 停止服务端。

若确实要允许客户端写入文件镜像，启动时必须明确加上 `--write`：

```sh
moon run --target native cmd/nbd -- serve demo.raw 11091 --write
```

写入、刷盘、TRIM 或写零请求发送后若连接中断，客户端会报告 `OutcomeUnknown`。服务端可能已经执行该操作，调用方应先检查数据，再决定后续处理，不要盲目重试。

## 命令行参考

命令均在仓库根目录执行：

```sh
# 列出服务端导出
moon run --target native cmd/nbd -- list 127.0.0.1 10809

# 查询默认导出信息
moon run --target native cmd/nbd -- info 127.0.0.1 10809

# 从偏移 0 读取 512 字节到新文件
moon run --target native cmd/nbd -- read 127.0.0.1 10809 0 512 sector.bin

# 完整导出到新文件
moon run --target native cmd/nbd -- export 127.0.0.1 10809 backup.raw

# 根据对端分配信息稀疏导出
moon run --target native cmd/nbd -- export-sparse 127.0.0.1 10809 sparse-backup.raw

# 以只读方式导出本地镜像
moon run --target native cmd/nbd -- serve demo.raw 11091
```

`info`、`read` 和两种导出命令可在末尾追加导出名称。`info` 通过 `NBD_OPT_INFO` 查询，不会进入数据传输阶段。服务端可用 `--name NAME` 设置导出名称，默认只读；只有显式指定 `--write` 才允许远端修改底层文件。

稀疏导出要求对端支持 `base:allocation`。它只跳过服务端明确标记为 `ZERO` 的区段；单独标记为 `HOLE` 的区段仍会读取，以免错误地把未知数据变成零。稀疏导出目标同样必须是新文件，源镜像在导出过程中应保持不变。

## MoonBit 库接口

```moonbit nocheck
let disk = @nbd.Client::connect("127.0.0.1", 10809, b"")
let data = disk.read_at(0UL, 512)
disk.disconnect()
```

客户端支持命名导出、导出列表、结构化读取、`base:allocation` 块状态、读写、刷盘、TRIM、写零、缓存提示和主动断开。单次读写最大为 16 MiB；操作默认超时 30 秒，可通过 `timeout_ms` 调整。服务端支持内存和本地普通文件后端。

备份与校验相关接口包括：

- `copy_to_file`：分块完整复制到空文件。
- `copy_sparse_to_file`：根据对端明确报告为零的区段稀疏复制。
- `copy_ranges_to_file`：将指定范围写入同尺寸的本地镜像，并在写入前检查全部范围。
- `copy_differences_to_file`：比较两个稳定的远端镜像，并将差异范围复制到本地镜像。差异会扩展到合法块边界，复制范围可能大于实际变化范围。
- `compare_ranges`：比较两个远端镜像并返回差异区间。
- `create_integrity_manifest` 和 `verify_integrity_manifest`：生成及检查分块 CRC32 清单。CRC32 可检测意外损坏，但不提供防篡改保证。
- `RangeSet`：校验、排序和合并范围，并提供并集、交集、差集操作。
- `CachedClient`：为稳定的只读镜像提供容量受限的 LRU 读取缓存。缓存不会并发请求；通过该客户端执行写入、TRIM 和写零时，会清除重叠缓存行。
- `ClientConfig::read_at_retry`：在稳定的只读导出发生传输故障时重连并重试读取，不会重试修改操作。

增量复制要求调用方保证本地镜像确实对应比较所用的基线。操作中途发生 I/O 错误时，目标可能只完成部分更新；该接口不提供原子替换或自动基线验证。文件服务端也要求调用方确保底层文件不会被其他程序并发改写。内存后端的数据在进程退出后丢失。

## 持续集成与本地联调

GitHub Actions 会在推送、拉取请求和手动触发时运行以下流程：更新依赖、检查、构建、测试、格式检查，并运行 QEMU 互操作脚本。CI 工作流位于 `.github/workflows/ci.yml`，状态显示在本页顶部。

在 Linux 或 WSL 安装 `qemu-utils` 后，可在本地逐项运行：

```sh
bash scripts/qemu-interop.sh
bash scripts/qemu-server-interop.sh
bash scripts/qemu-file-server-interop.sh
bash scripts/qemu-export-interop.sh
bash scripts/qemu-large-offset-interop.sh
bash scripts/qemu-sparse-export-interop.sh
```

这些脚本验证客户端连接 QEMU、QEMU 连接内存与文件服务端、完整和稀疏导出的字节一致性，以及 4 GiB 以上偏移。脚本会创建临时镜像并使用本机端口 `11089` 至 `11094`；端口被占用时，请先释放相应端口。

## 许可证

项目使用 Apache-2.0 许可证，网络实现依赖 `moonbitlang/async`。NBD 协议参考[官方规范](https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md)，QEMU 仅作为互操作测试工具。
