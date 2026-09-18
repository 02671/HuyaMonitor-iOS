# 虎牙监控 iOS 版

原 Windows 版 `HuyaDanmu`（Python + Tkinter）的 iOS 原生移植。功能一致：输入虎牙房号，看实时弹幕、听直播音频。自用签名安装，不上架 App Store。

## 功能对照

| 原版功能 | iOS 实现 |
| --- | --- |
| 房号查询房间信息 | `HuyaAPI.fetchRoom`，接口与原版一致（`mp.huya.com/cache.php`） |
| 按主播名搜索 | `HuyaAPI.searchAnchors`（`search.cdn.huya.com`），开播的排前面并显示绿色 |
| 弹幕（TARS 协议 WebSocket） | `Tars.swift` + `DanmakuClient.swift`，基于 Network.framework 自建 WebSocket 连接 `cdnws.api.huya.com:443`，30 秒心跳，断线自动重连（单飞 + 退避，上限 30 秒） |
| 贵族弹幕颜色 | `DanmakuClient.parseChat` 读取颜色字段，`Color(hex:)` 渲染 |
| 音频播放（原版 ffplay） | `AudioPlayer.swift` + `StreamProxy`：AVPlayer 播 HLS，本机 HTTP 反代给每个播放列表和分片补浏览器 UA/Referer，避免 CDN 403 |
| 省流量 | 自动读取虎牙画质列表 `rateArray`，固定使用最低画质「流畅」（如 500 kbps） |
| 音频换链 | 播放中每 90 秒重叠换链；403 / 地址过期时在同一条线立刻重签，连续失败再升一档画质或换线 |
| 独立开关弹幕 / 音频 | 「弹幕」「音频」两个独立按钮 |
| 历史房号 + 删除 | `RoomHistoryStore`，存到 App 沙盒 `Documents/history.json` |
| 清屏 / 音量 / 置顶 / 隐藏 | 清屏、音量保留；置顶与悬浮隐藏属于桌面端窗口概念，iOS 不需要 |
| 弹幕上限 500 条自动裁剪 | 同原版，超过 500 条删掉最早 400 条 |

## 后台播放与锁屏播放

这是本移植版重点保证的能力，通过三处配置共同实现：

1. `Info.plist` 里的 `UIBackgroundModes = audio`
2. `AudioPlayer.configureSession()` 把 `AVAudioSession` 设为 `.playback` 类别
3. `AVPlayer` 持有媒体播放，切到后台或锁屏时音频继续

另外锁屏控制中心和耳机线控可以播放/暂停（`MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`）。

弹幕使用的是 WebSocket。iOS 在后台会挂起网络任务，所以锁屏期间弹幕会暂停刷新，回到前台时 `handleForeground()` 会自动重连；音频不受影响。

## 技术说明

- 原版播放的是 FLV 流，AVPlayer 不支持 FLV。iOS 版优先使用同房间的 **HLS（m3u8）** 地址，这也是 iOS 上能实现后台播放的前提。签名算法（`processAnticode`）与原版完全一致，只是把 `sFlvUrl` 换成了 `sHlsUrl`。若房间确实只提供 FLV，音频会连接失败并自动重试。
- 画质由 `ratio` 参数决定，其取值就是画质列表里的 `iBitRate`。`ratio` 不参与 `wsSecret` 签名计算，所以修改它不会让链接失效。
- 所有网络请求的 UA / Referer 与原版保持一致。音频经本机 `http://127.0.0.1` 反代（`StreamProxy`）拉 HLS：播放列表和 TS 分片都会带上 `User-Agent`、`Referer`、`Origin`。AVPlayer 对普通 `https://` 地址只会给首个播放列表带头，后续分片会变成 `AppleCoreMedia`，虎牙 CDN 会 403。自定义 scheme 加 `AVAssetResourceLoaderDelegate` 喂 TS 会被 CoreMedia 以 -12881（custom url not redirect）拒绝，所以必须走 HTTP 反代。
- 弹幕 TARS 编解码为逐行移植，字段号、心跳包、URI 1400 均未改动。
- 弹幕没有使用 `URLSessionWebSocketTask`，而是基于 `Network.framework` 自建了极简 WebSocket 客户端。原因是 `URLSessionWebSocketTask` 在升级请求里会带上 `Sec-WebSocket-Extensions: permessage-deflate`，虎牙 CDN 接受后会下发 RSV1 压缩帧，而 iOS 的 WebSocket 层处理这些帧时报 EPROTO（界面上表现为「Protocol error」）。自建客户端不发送该扩展头，服务器就不会启用压缩，帧始终是明文。这一点已用底层 socket 实测确认：不协商压缩时连续 70 余秒内所有帧 `rsv1=0`；协商压缩后服务器立刻开始发送 RSV1 帧。
- 弹幕重连采用「单飞」模型：每次连接分配一个 token，所有异步回调都会校验 token，拆除连接时先递增 token 再取消任务，避免重连风暴。断线后按 1.5 倍退避重连，成功握手即重置为 2.5 秒。
- 逐字节解析协议：客户端发出的帧带掩码（mask），服务端下发的帧不带掩码；同时处理 126/127 扩展长度、分片消息（continuation）、ping/pong 和 close 帧。

## 构建与安装

需要 **macOS + Xcode 16 或更高版本**（工程使用了 Xcode 16 的同步文件夹格式）。

1. 用 Xcode 打开 `HuyaMonitor.xcodeproj`
2. 选中 `HuyaMonitor` Target → Signing & Capabilities
3. 勾选 `Automatically manage signing`，Team 选择你自己的 Apple ID（免费个人账号即可）
4. 如果 `com.selfuse.HuyaMonitor` 提示被占用，改成任意唯一值，例如 `com.你的名字.HuyaMonitor`
5. 数据线连接 iPhone，选择该设备，点 Run

免费个人账号签名的 App 有效期为 7 天，到期后重新 Run 一次即可；也可以用 AltStore / SideStore 自动续签。因为是自用，不需要 App Store 审核，也不需要付费开发者账号。

### 如果 .xcodeproj 打不开

说明 Xcode 版本低于 16。可以手动建一个新工程：

1. Xcode → File → New → Project → iOS → App
2. Product Name 填 `HuyaMonitor`，Interface 选 SwiftUI，Language 选 Swift
3. 把 `HuyaMonitor/` 目录下的所有 `.swift` 文件和 `Assets.xcassets` 拖进新工程
4. 在 Target → Info 里新增 `UIBackgroundModes`，类型 Array，值 `audio`
5. 把 `CFBundleDisplayName` 设为 `虎牙监控`

### 没有 Mac 怎么办

仓库里带了 GitHub Actions 工作流 `.github/workflows/ios-build.yml`。把仓库推到 GitHub 后，在 Actions 页面手动触发 `Build iOS app`，它会用 macOS 云端机器编译出未签名的 `HuyaMonitor-unsigned.ipa`，作为 artifact 下载。

拿到未签名 IPA 后，用 Sideloadly、AltStore 或 SideStore 配上自己的 Apple ID 重签名安装即可。

## 目录结构

```
ios/
├── HuyaMonitor.xcodeproj/          工程文件
├── Info.plist                      应用配置（后台音频、显示名、ATS）
├── HuyaMonitor/
│   ├── HuyaMonitorApp.swift        入口
│   ├── Models.swift                数据模型与错误类型
│   ├── HuyaAPI.swift               房间/搜索/匿名 uid/签名/HLS 地址
│   ├── Tars.swift                  TARS 协议编解码
│   ├── DanmakuClient.swift         弹幕 WebSocket 客户端
│   ├── AudioPlayer.swift           AVPlayer 音频 + 后台播放 + 120 秒换链重叠
│   ├── StreamLoader.swift          本机 HTTP 反代，给每个 HLS 分片补浏览器头
│   ├── RoomHistoryStore.swift      历史房号持久化
│   ├── MonitorViewModel.swift      状态与业务编排
│   ├── ContentView.swift           主界面
│   ├── DanmakuListView.swift       弹幕列表
│   ├── HistorySheet.swift          历史房号
│   ├── SearchSheet.swift           搜索主播
│   ├── VolumeSheet.swift           音量
│   └── Assets.xcassets             图标与主题色
```

## 使用

1. 打开 App，输入房号（支持直接粘贴 `https://www.huya.com/12345` 形式的链接）
2. 点「启动」同时拉起弹幕和音频
3. 也可以只点「弹幕」或「音频」单独开启
4. 点房号框右侧的时钟图标查看历史记录，放大镜图标按主播名搜索
5. 锁屏或切到后台，音频继续播放

## 注意

- 仅供个人自用。请遵守虎牙平台的使用条款，不要用于批量抓取或分发。
- 直播流地址带有签名和时效，App 会自动重新签名，不需要手动干预。
- 如果某个房间音频一直连不上，多为该房间未提供 HLS 流，可先确认原 Windows 版能否正常出声。
