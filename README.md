# GPUBar

A native macOS menu bar app for monitoring GPU resources and training jobs on Qianhai ACP and Jiuzhang HyperTrain, with desktop notifications when jobs succeed or fail.

GPUBar 将前海 ACP 和九章极核训练的 GPU 资源、任务状态与完成通知集中到 macOS 菜单栏。查看剩余资源、跟踪训练任务，或在任务结束时收到提醒，无需反复打开平台控制台。

## 界面示例

<img src="docs/images/overview.png" alt="GPUBar 界面示例：菜单栏摘要、前海 GPU 未分配量、九章规格库存，以及排队和运行中的任务" width="496">

原生界面渲染，使用示例数据；面板加高以完整展示任务列表。

## 功能

| 功能 | 使用方式 |
|---|---|
| 菜单栏资源摘要 | 同时显示两个平台的数字，例如 `Q 16 · J 37`，随后台刷新更新 |
| 双平台总览 | 点击菜单栏查看两平台资源卡片，也可切换到前海或九章单独查看 |
| GPU 资源明细 | 前海展示总量、健康节点未分配量和比例条；九章展示 GPU 型号及 1／2／4／8 卡等规格的库存 |
| 任务进展跟踪 | 查看排队、启动、运行、暂停、完成、失败和取消状态，以及等待时间或运行时长 |
| 任务筛选与详情 | 按名称筛选最近任务，查看 GPU 数量、节点数、时间和平台返回的状态详情，复制任务 ID 或打开控制台 |
| 桌面通知 | 任务成功或失败时发送 macOS 通知，显示平台、结果和任务名称 |
| 自动刷新 | 可选 30 秒、60 秒、2 分钟或 5 分钟，也可随时手动刷新 |
| 登录启动 | 登录 Mac 后自动运行，在菜单栏持续监控 |

### 跟踪任务进展

在“设置 → 任务名称包含”中输入项目名、实验前缀或用户名，例如 `demo`。筛选忽略大小写，留空可查看所选资源范围内的所有任务。面板按创建时间从新到旧显示最近 10 个匹配任务；总览合并两个平台，单平台标签只显示该平台任务。

每条任务显示名称、状态、所属平台、GPU 数量和耗时。排队或启动中的任务显示等待时间，运行中的任务显示已运行时长，结束任务在平台提供起止时间时显示总用时。资源卡片同时统计匹配任务的运行数和排队数。

点击任务可查看完整名称、任务 ID、节点数、创建／启动／结束时间、原始状态及平台返回的详情。详情窗口提供“复制 ID”和“打开平台控制台”入口，便于继续检查任务。

### 接收任务通知

1. 打开“设置 → 通用”，开启“任务完成或失败时通知”。
2. 在 macOS 授权提示中允许通知；也可在“系统设置 → 通知 → GPUBar”中调整通知展示方式。
3. 保持 GPUBar 运行。当刷新检测到已跟踪任务从未结束状态转为成功或失败时，应用发送通知。

例如，`demo-model-train` 成功结束后，通知标题为 **“前海 · 已完成”**，正文为任务名称；九章任务失败时，标题为 **“九章 · 失败”**。

通知遵循任务名称筛选和资源范围，触发时间取决于刷新间隔。首次读取任务时建立状态基线，之后提醒检测到的变化，同次运行中相同事件只通知一次。通知开关默认关闭。

### 自动刷新与后台运行

默认每 60 秒刷新资源和任务。点击面板右上角的刷新按钮可立即查询；打开面板时，距上次更新超过 15 秒的数据会自动刷新。

两个平台独立更新。查询暂时失败时，面板保留最后成功数据并标记过期状态，随后自动重试。Mac 休眠时暂停轮询，唤醒或网络恢复后重新查询。需要开机后持续使用时，可将应用放入 Applications，并在设置中开启“登录时启动 GPUBar”。

## 构建与启动

需要 **macOS 15+、Swift 6 工具链和 Apple Command Line Tools**。界面为中文，无第三方包依赖。

```sh
git clone https://github.com/haowen-xiong/GPUBar.git
cd GPUBar
./scripts/test.sh
./scripts/package.sh
open dist/GPUBar.app
```

启动后，点击菜单栏中的 `Q — · J —`，进入“设置”配置平台。应用可移至 Applications 使用。

构建采用当前 Mac 的处理器架构，已在 Apple Silicon 上验证；打包脚本使用本机 ad hoc 签名。

## 首次配置

可连接一个或两个平台。为要使用的平台填写资源范围，点击“保存监控设置”，再在“平台凭据”中输入 Access Key 和 Secret Key，点击“保存并连接”。

### 前海 ACP

展开“前海 ACP 资源范围”，填写以下字段：

| 字段 | 含义 |
|---|---|
| 订阅 ID | 账号可访问的 subscription ID |
| 资源组 | 资源所在的 resource group，默认 `default` |
| 节点可用区 | ACP 资源池所在可用区，默认 `cn-sz-01a` |
| 任务可用区 | ACP 工作空间所在可用区，默认 `cn-sz-01z` |
| 资源池标识 | API 中的资源池名称 |
| 工作空间标识 | 训练任务所属 workspace |

这些标识可从已有任务配置或平台控制台获取。当前支持前海深圳 ACP，连接 `aec2.cn-sz-01.qhsgaiccapi.com`，使用 HMAC AK/SK 认证。

### 九章

展开“九章智算中心”，填写账号可访问的 **智算中心 ID（`aidcId`）**。可选填“显示名称”，用于在资源卡片上标注机房。

智算中心 ID 可参考[智算中心列表 API](https://docs.alayanew.com/en/docs/api-reference/aidc)。当前连接 `api.alayanew.com/api/osm/v1/`，使用 HMAC Access Key／Secret Key 凭据。

## 资源数字的含义

| 平台 | 菜单栏数字 | 面板明细 |
|---|---|---|
| 前海 Q | 健康、启用节点的 GPU 容量减去已分配量 | GPU 总量、未分配量、比例条和型号 |
| 九章 J | 所选机房唯一 1 卡规格的库存数 `remainingCount` | 各 GPU 规格的库存份数和型号 |

九章不同规格可能共享库存，不能相加；库存是资源参考，实际调度还取决于节点状态、CPU／内存、配额和任务条件。数据缺失或库存异常时，摘要显示 `—`。

任务资源优先展示已确认的分配量：前海运行任务通过 Worker 查询确认，其他情况显示申请量；九章显示申请量。任务进展以平台状态和时间表示。

## 本地数据

GPUBar 直接通过 HTTPS 查询平台 API，无需 SSH 或常驻后端。凭据与监控设置保存在本机：

| 数据 | 存放位置 |
|---|---|
| Access Key／Secret Key | macOS 钥匙串，服务 `io.github.haowen-xiong.GPUBar.platform-credentials` |
| 资源范围、筛选、刷新设置 | `com.haowen.GPUBar` 的 UserDefaults |
| 最近成功快照 | `~/Library/Application Support/GPUBar/snapshots.json`，权限 600 |

## 开发与诊断

```sh
# 使用模拟数据预览界面。
open dist/GPUBar.app --args --preview

# 用普通窗口查看总览。
open dist/GPUBar.app --args --dashboard

# 使用本机配置查询平台，并输出资源和任务 JSON。
dist/GPUBar.app/Contents/MacOS/GPUBar --probe
```

切换启动参数前先退出正在运行的 GPUBar。可用 `GPUBAR_BUILD_DIR` 指定构建缓存目录；`package.sh` 第一个参数指定应用输出目录。

也可以从 JSON 导入资源范围。复制示例并填写自己的配置：

```sh
cp examples/config.example.json config.local.json
# 编辑 config.local.json，然后导入：
dist/GPUBar.app/Contents/MacOS/GPUBar --import-config < config.local.json
```

凭据可在设置中输入。自动化场景中，`--import-credentials` 从标准输入读取 `{ "qianhai": { "accessKey": "…", "secretKey": "…" }, "jiuzhang": { "accessKey": "…", "secretKey": "…" } }`。

`*.local.json` 已被 Git 忽略；分享配置或诊断输出时，请移除凭据和私人任务信息。

`./scripts/test.sh` 运行无网络的独立 Swift 检查程序，覆盖签名、时区、筛选、配置校验、范围隔离、共享库存、库存异常、健康节点统计、GPU 计数、多节点申请和分页处理。GitHub Actions 自动执行检查并构建应用。

## 贡献与许可

欢迎通过 issue 或 pull request 提交问题和改进。报告问题时请提供 macOS／Swift 版本、复现步骤和相关错误信息；扩展平台接口时可附上示例响应和检查用例。

界面组织参考 [CodexBar](https://github.com/steipete/CodexBar) 的菜单栏监控方式。九章资源字段可参考[规格接口文档](https://docs.alayanew.com/en/docs/api-reference/distributed-training/product-list)。

[MIT License](LICENSE) · Copyright © 2026 Haowen Xiong
