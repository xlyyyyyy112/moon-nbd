# MoonNBD 项目申报书
**基本信息**
- 项目名称：MoonNBD：MoonBit 网络块设备客户端与服务端
- 参赛者：xlyyyyyy112
- 联系方式：19257724755
- GitHub 仓库：https://github.com/xlyyyyyy112/moon-nbd
- 项目方向：MoonBit 存储基础设施 / 网络块设备
- 是否为移植项目：否，依据公开的 NBD 协议实现

**项目简介**　MoonNBD 提供 MoonBit 网络块设备客户端、服务端和 CLI，用于远程镜像备份、恢复、复制和比较。
**完整协议一致性目标**
以 [NBD 协议固定修订](https://github.com/NetworkBlockDevice/nbd/blob/6725f91e6a33bc9f62d31d82798c04ec1cde1c73/doc/proto.md) 为基线。最终在客户端与服务端完整实现 Fixed Newstyle 的握手、协商和传输，覆盖标准选项、命令、标志、错误及合法回退。按后端实际能力公告可选特性，并验证历史握手的兼容路径。

| 协议能力 | 客户端现状 | 服务端现状 | 最终验收 |
| --- | --- | --- | --- |
| Fixed Newstyle、NO_ZEROES、EXPORT_NAME、LIST、ABORT | 已有 | 已有 | 双向互操作与回退 |
| INFO / GO、导出属性与块大小 | 部分 | 部分 | 补齐规范信息项、块大小约束及错误回复 |
| STARTTLS、STRUCTURED_REPLY、EXTENDED_HEADERS | 已有结构化回复 | 已有结构化回复 | 补齐 TLS、扩展头及不同回复类型 |
| LIST / SET_META_CONTEXT、BLOCK_STATUS | 已有 SET 与查询 | 已有 SET 与基本状态 | 补齐 LIST、扩展状态和后端分配状态 |
| READ / WRITE / DISC、FLUSH / TRIM / CACHE / WRITE_ZEROES | 已有，依赖对端公告 | 已有，依赖后端 | 验证只读、边界、错误及 FUA、DF、FAST_ZERO 等标准标志 |
| RESIZE、并发请求、多连接一致性 | 待做 | 待做 | 验证容量变化、连接间可见性及请求句柄匹配 |
| 旧式握手和废弃选项 | 未实现旧式握手 | 未实现旧式握手 | 检查历史兼容及规范允许的拒绝路径 |

**预期验收产物与实施安排**
- 交付 MoonBit 库、CLI、中文 README、示例、测试和 GitHub Actions；模块 `xlyyyyyy112/moon-nbd@0.1.1` 已发布至 Mooncakes。
- 当前有 6 项 QEMU 互操作脚本，覆盖两个方向、普通及稀疏导出和 4 GiB 以上偏移。后续把矩阵中待做项的双向成功、错误和能力降级用例纳入 CI。
- [详细功能矩阵](docs/功能矩阵.md)记录当前后端差异和复现入口。

- 项目采用 Apache-2.0。异步网络与文件 I/O 使用 `moonbitlang/async@0.22.1`（Apache-2.0）。QEMU 用于互操作测试。
