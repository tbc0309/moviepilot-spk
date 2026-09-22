# MoviePilot 群晖套件

[![构建状态](https://github.com/tbc0309/moviepilot-spk/actions/workflows/build.yml/badge.svg)](https://github.com/tbc0309/moviepilot-spk/actions/workflows/build.yml)
[![许可证](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

本项目用于自动构建适用于 Synology DSM 7 的 MoviePilot SPK。仓库提供套件模板、构建脚本和 GitHub Actions 工作流；MoviePilot 主程序、前端、插件及资源文件均在构建时从官方项目获取。

MoviePilot 是新一代智能化个人媒体库管理工具，基于前后端分离设计架构，拥有丰富的插件生态系统。

## 支持范围

| DSM 版本 | 架构 | Node.js 依赖 | Python 依赖 | FFmpeg 依赖 |
| --- | --- | --- | --- | --- |
| DSM 7.1 | x86_64、armv8 | Node.js 18 | Python 3.14 | FFmpeg 8 ≥ 8.1.2-3 |
| DSM 7.2 | x86_64、armv8 | Node.js 22 | Python 3.14 | FFmpeg 8 ≥ 8.1.2-3 |

每个 MoviePilot 版本提供四个套件，分别对应 DSM 7.1、DSM 7.2 与两种处理器架构。

## 安装

1. 在 [Releases](https://github.com/tbc0309/moviepilot-spk/releases) 下载与 DSM 版本及处理器架构对应的 SPK。
2. 在群晖套件中心安装对应版本的 Node.js、Python 3.14 和 FFmpeg 8 依赖套件。
3. 在套件中心选择“手动安装”，上传 SPK 并按向导完成安装。
4. 安装完成后从 DSM 主菜单打开 MoviePilot。

升级套件时会保留 MoviePilot 配置和用户数据。升级前仍建议备份重要配置。

## 自动构建

- 主线工作流使用 SynoCommunity `spksrc` 与群晖官方工具链，为 DSM 7.1、DSM 7.2 的 x86_64、armv8 交叉编译必要的原生 Python 依赖。
- 交叉编译在 x86_64 GitHub 托管节点完成，完整 SPK 随后在对应架构的原生节点组装，避免通过 QEMU 运行完整工具链。
- 普通纯 Python 依赖及已有兼容 wheel 直接使用上游产物；只有 DSM 无法直接安装或存在 ABI 问题的依赖才进入交叉编译流程。
- DSM 7.1 会同时收集交叉编译扩展所需的非系统运行库，避免缺少 `libtiff.so.6` 等动态库。
- 构建时验证官方 Release 资源的 SHA256 摘要，并记录各上游项目的版本或提交。
- 四个 SPK 全部构建成功后才会发布正式 GitHub Release。
- 官方 Release 的定时检查目前已暂停，主线工作流由 Actions 页面手动触发；需要恢复时可取消 `build.yml` 中 `schedule` 配置的注释。

仓库同时保留 Manylinux 备用工作流，仅用于手动构建或排查交叉编译异常，不作为默认发布路径。

套件内的 `package.tgz` 使用 XZ（LZMA2、级别 6、CRC64）压缩，外层 SPK 使用未压缩 TAR，以兼顾体积和 DSM 套件格式兼容性。

## 上游内容

构建过程会获取以下官方内容：

- [MoviePilot](https://github.com/jxxghp/MoviePilot)：后端主程序与版本规则
- [MoviePilot-Frontend](https://github.com/jxxghp/MoviePilot-Frontend)：Web 前端
- [MoviePilot-Plugins](https://github.com/jxxghp/MoviePilot-Plugins)：内置插件
- [MoviePilot-Resources](https://github.com/jxxghp/MoviePilot-Resources)：站点资源与原生模块

插件目录、插件仓库分支及兼容标记会根据对应版本 MoviePilot 官方 Dockerfile 自动解析。若官方打包规则发生无法识别的变化，构建会直接停止，避免静默使用过期规则。最终采用的版本和提交记录在套件的 `BUILD-METADATA` 文件中。

## 手动构建

在仓库的 **Actions** 页面选择相应工作流：

- **MoviePilot｜群晖交叉编译并发布（主线）**：默认构建方式，`version` 可填写指定版本，留空时获取官方最新 Release。
- **MoviePilot｜Manylinux 构建（备用）**：仅在需要对比或排查问题时手动使用，只保存 Action artifacts，不修改 Release。

主线构建完成后会在对应的正式 GitHub Release 中发布四个 SPK。

## 许可证

本仓库中的套件模板、构建脚本和工作流采用 [MIT License](LICENSE) 开源。

MoviePilot 及构建过程中下载的前端、插件、资源和第三方依赖分别遵循其各自项目的许可证，本仓库的 MIT License 不会改变这些上游项目的授权条款。

本项目是第三方 Synology SPK 构建项目，与 MoviePilot 官方及 Synology Inc. 无隶属关系。
