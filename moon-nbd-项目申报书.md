# MoonNBD 项目申报书

**基本信息**
- 项目名称：MoonNBD：MoonBit 网络块设备客户端与服务端
- 参赛者：xlyyyyyy112
- 联系方式：19257724755
- GitHub 仓库：https://github.com/xlyyyyyy112/moon-nbd
- 项目方向：MoonBit 存储基础设施 / 网络块设备
- 是否为移植项目：否，依据公开的 NBD 协议实现

**项目简介**
MoonNBD 是用 MoonBit 编写的 Network Block Device（NBD）客户端与服务端，为 MoonBit 程序访问远程块设备镜像提供库接口和命令行工具，可用于镜像备份恢复、复制、比较和远程数据检查。

**核心功能范围**
- 一致性目标：客户端与服务端在功能矩阵列出的协议子集内实现可复现互操作；不宣称完整覆盖 NBD 协议，未支持项以矩阵为准。
- 实现 NBD 握手、能力协商、导出列表和信息查询，以及读、写、FLUSH、TRIM、写零等常用请求。
- 提供内存与普通文件服务端后端，支持只读或显式启用写入，并通过 QEMU 进行互操作验证。
- 提供完整及稀疏导出、本地镜像导入、差异比较与复制、分配状态查询和分块 CRC32 完整性清单。
- 提供范围集合、LRU 只读缓存、读取重试、超时控制、CLI、测试和 QEMU 联调脚本。

**预期验收产物与实施安排**
- 交付 MoonBit 库、CLI、中文 README、示例、测试和 GitHub Actions；模块 `xlyyyyyy112/moon-nbd@0.1.1` 已发布至 Mooncakes。
- 持续维护协议处理、镜像传输及错误路径；当前最新 GitHub CI 已通过检查、构建、测试、格式检查和 6 项 QEMU 互操作脚本。
- 客户端与服务端的协议能力、后端差异及暂不支持范围见仓库 `docs/功能矩阵.md`。

**参考与许可说明**
- 协议参考：Network Block Device 文档：https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md；QEMU 仅作互操作测试工具，本项目并非代码移植。
- 项目采用 Apache-2.0 许可证；异步网络与文件 I/O 使用 `moonbitlang/async@0.22.1`（Apache-2.0）。
- 当前面向 native 后端和 TCP；未实现 TLS、身份认证、旧式握手及单连接并发请求。服务端命令默认仅监听本机地址。
