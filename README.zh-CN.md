# Bookoo MT80（MOTTO80）Decaid 插件

**简体中文** | [English](https://github.com/Sofronio/decaid-bookoo-mt80/blob/main/README.md)

一个 [Decaid](https://github.com/decentespresso/decaid) 插件，添加 Bookoo
MT80 磨豆机（以 MOTTO80 销售）。插件拥有设备协议；Decaid 负责设备发现、BLE
连接生命周期和 device surface。

无需 Decaid 发版即可使用；添加其他设备也不需要 Decaid 发版。

## 截图

![Compact 设置窗口（中文）](https://github.com/Sofronio/decaid-bookoo-mt80/releases/download/v0.2.7/mt80-compact-zh-20261024-120616.png)

![Full 设置窗口（中文）](https://github.com/Sofronio/decaid-bookoo-mt80/releases/download/v0.2.7/mt80-full-zh-20261024-120611.png)

## 驱动类型

MT80 声明 `grinder` 驱动类型。它暴露 Bookoo 发布协议实际记录的两个控制——
`grindSetting` 和 `rpmControl`——并发布 `state`、`setting`、`rpm` 作为快照。
研磨启动和停止刻意不声明；见“不在范围内”。

早期版本因为 Decaid 还没有 grinder 类型而声明 Sensor；现在不再需要。

## 安装

通过 Decaid REST API 安装仓库最新 release：

```bash
curl -X POST http://localhost:8080/api/v1/plugins/install/github-release \
  -H 'content-type: application/json' \
  -d '{"repo": "Sofronio/decaid-bookoo-mt80"}'
```

也可以在 Decaid 的 Plugins 设置页从仓库安装，直接填
`Sofronio/decaid-bookoo-mt80` 即可。

公共设备 ID 是 `plugin:bookoo-mt80.reaplugin:mt80:<physical id>`。插件加载后会
接管该广播，并抑制同一设备的原生候选。

## 匹配

广播名包含 `mt80`（大小写不敏感）。匹配器刻意声明 **没有** service UUIDs：
Bookoo 的集成说明指出 Custom Service 不在广播数据里，实机扫描也确认它只广播
`FFFF` 和名字 `BOOKOO MT80 xxxxxxxx`。`serviceUuids` 约束永远不会匹配。

## 协议

服务 `4d543830-0001-4b80-8f00-424f4f4b4f4f`；RX（写）`...-0002`，TX（通知）
`...-0003`。

消息是 UTF-8 JSON，装在 `A5 01` 分片里，带 8 字节头，所有多字节字段小端：

| 偏移 | 长度 | 字段 |
| --- | --- | --- |
| 0 | 1 | `magic` = `0xA5` |
| 1 | 1 | `version` = `0x01` |
| 2 | 2 | `sequence`，同一消息的各分片相同 |
| 4 | 2 | 完整 JSON 的 `totalLength` |
| 6 | 2 | 本分片在该 JSON 中的 `offset` |
| 8 | N | payload |

分片用带响应写入，并按 `offset` 重组；offset `0` 的分片开启新消息，不完整的
消息两秒后过期。驱动每片发送 12 字节 payload，对应参考客户端的 20 字节包和默认
ATT MTU 23。

订阅后，客户端发送 `{"request":{"appHello":{"op":"handshake"}}}`。设备先回一次
`baseInfo`，然后以 5 Hz 发送 `periodInfo`；第一个 `periodInfo` 就是就绪。每次断开
都会让订阅和握手失效，所以重连后会重新订阅、重新握手。

请求只带一个业务对象，响应也在同一对象下返回，所以驱动只保留一个在途请求，并按
该 key 关联，而不是按 `sequence`——规范明确禁止用 `sequence` 做关联。

## 快照

驱动发布 `{state, setting, rpm}`：

| 字段 | `periodInfo` 来源 | 映射 |
| --- | --- | --- |
| `state` | `devState` | `IDLE` → `idle`；`GRINDING`、`HIGHSPEEDCLEAN` 和 `ADJUSTMENTPURGE` → `grinding`；`WARNING` → `error`；其他 → `unknown` |
| `setting` | `bladeGap` | 字符串，需要 `grindSetting` |
| `rpm` | `grindRpm` | 整数，需要 `rpmControl` |

设备词汇是自己的；只有这四个状态进入 host，未识别的值报 `unknown`，不去猜。
查找忽略大小写，并覆盖两代固件：`HighSpeedClean` 在固件 `v1.3.11.1020` 里改名为
`HIGHSPEEDCLEAN`，同时新增 `ADJUSTMENTPURGE`（调磨清粉）。两个清粉状态都映射为
`grinding`。

**就绪是发布，不是到达。** host 要求磨豆机可用前先收到一个有效初始快照，所以
`connect` 只有在 host 接受首次发布后才完成——被拒绝的快照会让 connect 失败，而不是
留下一个半就绪设备。

其他文档化的 `periodInfo` 字段——下豆 RPM、湿度、网络状态、累计研磨次数、杯检、
自动停止、强力清粉、亮度、熄屏和当前预设——在 grinder 快照里没有位置。它们在控制页
仍然可见，页面读驱动自己的缓存。

## 控制

| 能力 | Handler | 声明的控制 |
| --- | --- | --- |
| `grindSetting` | `setGrindSetting(setting)` | 数字 0–999，步进 1（`bladeGap`） |
| `rpmControl` | `setRpm(rpm)` | 数字 500–1500，步进 10（`grindRpm`） |

每个都写一个 `geneSetting` 字段并等待设备响应。host 在调用 handler 前按声明的控制
校验值，所以驱动只做归一化和取整。

页面还通过插件自己的 HTTP endpoint 驱动更宽的命令面——设置、研磨段和预设 CRUD。
那些是页面的命令，不属于 grinder 契约。

## 控制页

插件在 `/api/v1/plugins/bookoo-mt80.reaplugin/ui` 提供实时控制页，通过类型为
`http` 的 `api` 条目暴露：

```
GET  /api/v1/plugins/bookoo-mt80.reaplugin/ui            -> 页面
GET  /api/v1/plugins/bookoo-mt80.reaplugin/ui?state=1    -> 缓存的 JSON 状态
POST /api/v1/plugins/bookoo-mt80.reaplugin/ui            -> {commandId, params}
```

页面镜像应用内的磨豆机调试视图：大的研磨度读数带下豆和刀盘 RPM、实时状态表、
250 ms 防抖发送的滑杆、布尔开关、预设和研磨段芯片，以及按种类区分的发送/响应/广播
日志。它支持中英文切换。

`?view=settings` 渲染 dashboard surface 使用的紧凑视图：只读读数、状态表和日志
隐藏，只留设置、预设和研磨段；页面会把内容尺寸上报给 skin。设备管理里的 settings
surface 打开完整页面。

紧凑窗口头部有 **Full / Compact** 切换。Full 会显示只读读数、状态表和日志，并把
弹窗撑到 skin 允许的最大 overlay 尺寸（1100×760，或屏幕 94%×90%）；Compact 回到
fitted 卡片。真正的边到边 `size:"full"` overlay 在皮肤打开页面时就固定了——协议
没有消息能把已打开的 overlay 切成全屏——所以 Full 使用 overlay 能请求的最大尺寸。

它的 `POST` body 是 `{commandId, params}`：

| 命令 | 用途 |
| --- | --- |
| `getSettings` | 读取每个 `geneSetting` 字段 |
| `setSettings` | 写入 `geneSetting` 字段；body 就是字段集合 |
| `getSections` | 读取所有研磨段 |
| `setSections` | 用 `sections` 写入所有研磨段 |
| `getPresets` | 读取所有可见预设 |
| `addPreset` | 添加预设；没有 UID 时自动生成 |
| `updatePreset` | 编辑 `name`、`note`、`bladeGap`、`feedingRpm`、`grindRpm` |
| `deletePreset` | 把预设移到回收站 |
| `restorePreset` | 恢复已删除预设，可指定 `index` |
| `reorderPreset` | 把预设移到新的 `index` |
| `importPresets` | 用 `presets` 替换预设列表 |
| `getRecycleBin` | 列出已删除预设 |

调用方不提供 UID 时，`addPreset` 按规范用 FNV-1a 64 位算法生成 32 字符 UID，并
复现公开测试向量 `ae8f0ec693f96e37140fc424ab5df303`。实现跑在 32 位 limb 上，
因为不能假设插件运行时支持 `BigInt`。

滑杆发 `setSettings`，预设芯片发 `setSettings {selectPreset}`，研磨段芯片发
`setSettings {bladeGap}`。HTTP 层只是传输，不是第二套词汇：每个命令都落到 grinder
控制使用的同一条 `geneSetting` 请求路径。

轮询读缓存的 `periodInfo`，从不访问设备，因为驱动只保留一个在途请求，轮询请求会
阻塞真实命令。滑杆使用**公开的** `geneSetting` 范围，而不是参考 GUI 更宽的范围，
因为设备会拒绝范围外的值。

`handleHttpRequest` 必须定义在 `createPlugin` 返回的对象上，而不是驱动工厂返回的
device 上；loader 会从那里取别名。页面本身与设备无关，所以在任何 MT80 绑定前就能
渲染，只报告“未连接”。

分段芯片只写入该范围对应的研磨度值，不会移动物理刀盘：Bookoo 的说明指出 MT80 是
手动调节，写 `bladeGap` 不会改变物理间距。

## 模拟设备

如果要在没有磨豆机的情况下开发，打开 `mockDevice` 插件设置：

```bash
curl -X POST http://localhost:8080/api/v1/plugins/bookoo-mt80.reaplugin/settings \
  -H 'Content-Type: application/json' -d '{"mockDevice": true}'
```

Decaid 会重载插件，并在真实设备旁边注册一个内存中的 MT80，设备 ID 为
`plugin:bookoo-mt80.reaplugin:mt80:simulated`，名字是 “Bookoo MT80
(simulated)”。像其他设备一样连接即可。

它每秒发布同样的 `{state, setting, rpm}` 快照，携带同样的声明控制，并用设备自己的
拒绝规则响应控制页命令——范围、布尔、`selectPreset` 等，预设和研磨段的*编辑*会报告
不支持。它不碰无线电，状态在内存里，重载即重置，设置默认关闭。

真实 MT80 连接时优先：控制页和 dashboard surfaces 服务当前连接的磨豆机，硬件优先。

## Dashboard surfaces

遵循 Streamline plugin-surfaces 协议的皮肤可以为回答 `skin` endpoint 的插件绘制
一组固定的 UI 小组件，并且只执行它认识的动作——皮肤里不运行插件代码。插件用
`GET /api/v1/plugins/bookoo-mt80.reaplugin/skin` 回答这台磨豆机能提供什么：

| Surface | 类型 | 位置 | 显示 |
| --- | --- | --- | --- |
| `mt80-state` | `tile-line` | Grind 标签下方 | 刀盘转速或 `warning`；研磨中显示为开启，点击打开皮肤的 RPM 数字键盘来设置 |
| `mt80-step` | `tile-hint` | Grind tile 的 pill | 研磨度的粗/细 `±10` / `±1` 步进 |
| `mt80-sync` | `tile-sync` | Grind tile 自己的数值 | 磨豆机读到的研磨度，移动时写回 workflow |
| `mt80-page` | `header-button` | dashboard 顶部 | 设置窗口 |
| `mt80-saver` | `screensaver-button` | 屏保上方 | 设置窗口 |

两个按钮以 fitted `overlay` 打开 settings-only 视图，而不是同 frame 的 `page`：
窗口按可编辑卡片（设置、预设和研磨段）调整大小，只读实时表和日志不绘制；关闭后回到
原样的 dashboard，不跳转也不重载皮肤。页面加载时发 `streamline:ready`，用
`streamline:size` 上报内容尺寸，返回按钮发 `streamline:close`；皮肤自己也会画关闭
按钮。如果皮肤退回成 page（三秒内没收到 ready），或者页面在皮肤外打开，返回按钮会
使用 surface 协议添加的 `returnTo`，所以仍能回到来处。

`ui` 响应发送 `Content-Security-Policy: frame-ancestors 'self' <Origin/Referer
origin>`，因为皮肤可能跑在另一个端口（平板上是 `:25123`），否则 overlay 的 iframe
会被 Decaid 的 `X-Frame-Options: SAMEORIGIN` 拒绝。

状态行是 `rpmControl` 所在，因为 grinder 快照只带一个数字，tile 把它花在研磨度上。
它是 `line` 而不是 `hint`，因为 hint 和 pill 共享槽位，而皮肤每个 tile 只画各一个。
`stepsize` 是唯一能到达 tile 自己的 `-`/`+` 又不占文本槽位的动作。

**Grind 上刻意没有 `tile-mode`。** mode 会占 tile 的标签槽，皮肤随后就*不管选哪个
选项*都不再画该 tile 的 `tile-line`——`modeTiles.has(tile)` 在解析回答时决定，而不是
在用户切换时。提供 mode 会永久牺牲状态行，而它能加的无非是给每个豆子只设一次的
数字加 `±` 步进。状态行的 `input` 动作到达同一个 `rpm` endpoint。

pill 自身不带 `text`。皮肤根据用户在该设备上选的尺寸写标签，在 `±10` 和 `±1` 之间
循环；回答里的 `text` 优先于该标签并会把它冻住。

### tile 的数字和磨豆机的数字

Grind tile 的数字是 workflow 的 `context.grinderSetting`——当前 profile 对一个设置
的记忆，它不说明刀盘实际在哪。有人在磨豆机上转一下刻度，两者就会分叉，而且没有东西
去调和：Decaid 里没有代码读 `GrinderSnapshot.setting`，唯一写磨豆机的路由是
`PUT /api/v1/grinder/setting`，应用和皮肤都不调用它。

`tile-sync` 补上这个缺口。值被绘制期间，皮肤把*变化过的*值写进 workflow，就像用户
自己输入的一样，于是 tile 和 profile 的记忆跟随刀盘；之后输入的值会一直有效，直到
刀盘再次移动。这个类型比本插件新，还不认识它的皮肤会忽略它并绘制其他东西，所以
surface 可以先于会响应它的皮肤发布。

按钮只在设备已连接时声明。皮肤总共只画一个 header 按钮，所以断开的磨豆机把槽位让给
已连接的磨豆机；它的完整页面仍可从 Decaid 设备管理打开，页面自己会报告“未连接”。
grind surfaces 遵循同样的规则。

### 保持皮肤同步

回答里的 `live` 指向 `changed` websocket。皮肤保持它打开，并在每条消息时重新读取
`skin`，所以插件只在 surface 实际显示的值移动时推送 `{"what": "skin"}`，并且一秒
内不会推两次。消息体说明 workflow 没有变化，这里始终成立：本插件从不写 workflow，
用户的 `set` 或 `step` 走 Decaid 自己的 setter。

`stream` socket 保持它独立的意义——每次广播都发完整 `periodInfo`，给宁愿订阅而不是
轮询的客户端。把 `live` 指向那个消防水管会让皮肤一秒内重新读取自己三次。

### 从皮肤写入

`POST /api/v1/plugins/bookoo-mt80.reaplugin/rpm` 带 `{"rpm": 1000}`，是状态行上的
一次点击在皮肤数字键盘得到数字后最终调用的东西。它不是第二套词汇：数字落到页面
`setSettings` 命令使用的同一条 `geneSetting` 请求路径。在此之前会做范围检查，因为
任何人都能 POST 到这里，而 host 的控制校验不在这条路径上。

## Device surface

与上面的 dashboard surfaces 分开：manifest 声明一个驱动 surface `settings`，指向
控制页自己的 endpoint。设备管理通过 `PluginDeviceSurfaceAuthority` 消费它，并针对
该设备在 `localhost` 打开页面，不需要先连接。插件拥有身份校验；所有权从不从设备
ID 推断。

## 不在范围内

研磨启动和停止**不声明**。Bookoo 的集成说明把 BLE 研磨启停列为安全评估中、不在公开
SDK 内，因此没有记录它的帧格式。驱动因此只声明 `grindSetting` 和 `rpmControl`，
start/stop 在任何 handler 运行前就以 `unsupported_operation` 失败。不要在这里加
猜测的帧。

## 发布

`scripts/package.sh` 生成 `dist/bookoo-mt80.reaplugin-<version>.zip`。推送 `vX.Y.Z`
tag 会在 CI 里运行同一个脚本并发布 release。

Decaid 强制要求脚本保持同步的三件事：

- release tag 是 `X.Y.Z` 或 `vX.Y.Z`，且与 `manifest.version` 完全一致
- release 恰好带一个 `.zip` 资产
- 压缩包只有一个顶层 `bookoo-mt80.reaplugin/` 目录，里面有 `manifest.json` 和
  `plugin.js`

所以 bump `manifest.version` 并打同样的 tag。tag 与 manifest 不一致的 release 在
安装时会被拒绝。

## 已验证

在真实 MT80 上验证过。插件接管广播并抑制原生候选，connect 找到 Custom Service、
订阅，并在首个快照被接受后进入就绪。`getSettings`、`getSections` 和 `getPresets`
返回了磨豆机的真实配置，包括中文的分段和预设名——这也覆盖了 UTF-8 跨分片边界的
路径。

写操作也在同一台机器上验证并恢复。把当前设置写回会被接受并回显；修改 `brightness`
会传播到 `getSettings` 和实时 `periodInfo` 流，然后恢复；与测试前备份逐字段对比完全
一致，预设列表未变，回收站保持为空。预设添加和删除刻意未测试——删除会留下协议没有
办法清除的 tombstone。

Dashboard surfaces 由插件自己的测试覆盖，测试按皮肤的方式读 `skin` 回答，并通过
web server 使用的同一个 seam 驱动 `rpm` endpoint。它们还没有在运行中的皮肤上验证；
surface 限制——每个 tile 一个 hint 和一个 line，总共一个 header 按钮——属于皮肤，
所以插件只能做到它赢得的槽位允许的程度。

模拟设备同样被覆盖：设置会注册它、不设置则不注册；它能连接和发布；控制页和
surfaces 能读它；它会按设备的方式拒绝。和这里其他东西一样，仅靠本仓库的测试不能
在 Decaid 构建里运行——它们需要一个 Decaid checkout。

协议遵循 Bookoo 发布的
[open-scale-protocol](https://github.com/BooKooCode/OpenSource/tree/main/bookoo_motto80)
MT80 BLE GATT SDK（最低固件 `v1.2.19.0820`；状态名遵循为固件 `v1.3.11.1020`
更新的 `devState` 表）。

## 许可证

尚未选择。在添加之前，本仓库默认保留所有权利。
