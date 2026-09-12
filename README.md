# Synology SPK Auto Builder

私有的群晖套件自动更新框架。仓库只保存打包规则和套件空壳，不保存上游项目源码。

## 工作方式

- 每 6 小时检查一次上游 GitHub Release。
- 发现新版本后自动触发对应套件构建。
- 同时构建 DSM 7.2 的 `x86_64` 和 `armv8` 套件。
- 构建成功后创建 GitHub Release，并附带 SPK 与 SHA256 文件。
- 已发布的版本不会重复构建。

目前启用：`jxxghp/MoviePilot`。以后在 `packages.json` 增加项目即可。

## 构建节点

完全使用 GitHub 托管节点，不依赖本地服务器：

- `ubuntu-24.04` 原生构建 x86_64。
- `ubuntu-24.04-arm` 原生构建 armv8。
- Python 3.14 依赖在 manylinux 2.28 容器中构建，以控制 glibc 兼容性。
- Node.js 22 依赖在相应架构的原生节点安装。

构建时动态下载 MoviePilot、Frontend Release、Resources 和 Plugins，仓库只保留 SPK 空壳。

## 手动构建

在 Actions 中运行 `Build package`，选择 `moviepilot`，可填写指定版本；留空则构建上游最新 Release。
