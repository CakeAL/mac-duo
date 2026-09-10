# MacDuo

把 MacBook 变成一块会随开合角度变化的毛玻璃。

盖上盖子（或把屏幕压到 90° 以下）时，内建显示器上的画面会变成一块斜靠着的毛玻璃：

1. **画面仍然"在 90° 的位置"** —— 把画面当作一块沿屏幕底边（铰链）向外倒下的平板，从正面看就是一个**上窄下宽的梯形**：顶端约 78% 宽，铰链端保持满宽，两侧是直的斜边，行距向上逐渐收紧。
2. **是裁切，不是压扁** —— 梯形之外（上方两角、以及面板占不到的地方）露出的是画面之后的空间，用屏幕边缘颜色延续并压暗。画面本身一列都不缩。
3. **从顶端向下渐强地糊掉** —— 顶端最模糊（几乎全糊），铰链一侧保持清晰，中间分三层叠出来，所以过渡里有"层次"而不只是一片糊。
4. **叠加毛玻璃质感** —— 轻微白雾 + 降饱和 + 压暗，都乘在同一条渐变上。

角度回到 90° 以上时，效果完全消失、覆盖窗口收起，屏幕恢复原样。

## 快速开始

```bash
./build.sh                    # 编译并打包出 dist/MacDuo.app
open dist/MacDuo.app          # 启动（菜单栏会出现一个角度图标）
```

首次运行需要授予**屏幕录制**权限（用来读取内建显示器的画面）：

```
系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 MacDuo
```

授予后通常不需要重启应用；如果菜单里"画面捕获"仍显示未启动，点一下"开始捕获"即可。

没有 Xcode 的 Metal 离线工具链也没关系：应用会在运行时用内建的一份着色器源码现场编译（见下文"关于着色器"）。

## 验证

```bash
./verify.sh                  # 跑运行时校验（不需 GUI）
./verify.sh /tmp/macduo-png  # 顺便导出三张效果预览图
MACDUO_PROBE_FLASH=1 ./.scratch/arm64-apple-macosx/release/MacDuoProbe
                             # 额外在内建屏上真实显示 2.5 秒效果（用合成帧，
                             # 不需要任何权限），可以直接肉眼看梯形与渐变
```

`verify.sh` 会在离屏纹理上跑完整的模糊 + 合成管线，并断言：

- 三个着色器函数都能编译出管线；
- 四个方向的清晰端都能渲染；
- 清晰度沿渐变方向单调变化（顶端最糊、底端最清晰）；
- 梯形形变确实收窄了远端、而近端宽度不变。

实测输出（M1 Pro，1280×800 合成帧，折叠量 0.30）：

```
row%   panel edges (folded)   folded width   full width
   2%     145 … 1134           989         1279
  20%     118 … 1161          1043         1279
  40%      89 … 1190          1101         1279
  60%      59 … 1220          1161         1279
  80%      29 … 1250          1221         1279
  98%       3 … 1276          1273         1279

panel width  top: 989  hinge: 1273  (ratio 0.78, expected 0.77)
panel left edge at the top row: 145  first picture pixel: 145

detail kept, relative to the same fold without any frost:
  top edge   (row  16):     1%
  mid panel  (row 480):    20%
  hinge      (row 784):   100%
```

三组断言分别证明了三件事：**面板确实是上窄下宽的直边梯形**（每一行宽度都要落在同一条直线上）；**画面是被裁切的**（面板左边缘处读到的仍是画面自己的第一列，红通道读数是列号，所以这个比较是精确的）；**磨砂确实是上强下弱**（同一个折角、开/关磨砂两组渲染相比，顶端只剩 1% 细节，铰链端 100%）。

## 它怎么工作

```
LidAngleSensor ──角度──▶ AppController ──强度 0…1──▶ FrostOverlayController
   (IOKit HID)              (触发曲线)                    │
                                                          ▼
CaptureEngine ──内建屏画面──▶ MetalFrostRenderer ──▶ 覆盖窗口 (NSWindow + MTKView)
(ScreenCaptureKit)           渐进模糊 + 毛玻璃
```

- **LidAngleSensor**：Apple VID `0x05AC` / PID `0x8104` 的 HID 节点，读 feature report 1，低字节在前组成角度值。同一个 VID/PID 下有好几个 HID 节点，所以会逐个试读、只认能读出报告的那个。60 Hz 轮询，带平滑。
- **CaptureEngine**：`SCStream` 抓内建显示器（`CGDisplayIsBuiltin`），全分辨率 BGRA，并在过滤时排除自己的覆盖窗口，避免自反馈。抓一个 6 MP 屏幕的代价不低，所以它**只在盖子进入磨砂区间时才启动**（角度 < 生效角度+10°），回到上面 8 秒后自动停止——合着盖子的时候不会白耗 GPU。
- **MetalFrostRenderer**：把捕获帧降采样后做三次链式高斯（半径 1 : √(near·far) : far），再在片元着色器里沿渐变轴把三个层级混起来，同时施加梯形形变与毛玻璃着色。
- **FrostOverlayController**：内建屏大小的无边框窗口（`.normal` 层级、`canJoinAllSpaces`），强度为 0 时直接 `orderOut`，完全不影响正常使用。

### 关于梯形形变

折叠在**顶点阶段**完成：屏幕矩形被画成面板的梯形，贴图坐标 0…1 铺满这个梯形，于是画面在超出屏幕的部分自然被裁掉——这就是"画面没变、只是被挡住了"的效果。收窄比例随强度线性增长：

```
顶端宽度 / 铰链端宽度 = 1 / (1 + trapezoidAmount × intensity)
```

默认 `trapezoidAmount = 0.24`，也就是完全合上时顶端约为铰链端的 81%（探针里用 0.30 测出 0.78）。

**为什么不在片元阶段做反向映射**：那条路要么得自己插值 UV（本项目的踩坑记录：顶点插值在某些组合下整片表面都是同一个值），要么得处理"钳制取样导致整个屏幕都被判定成面板内部"的边界问题。让光栅化器去做梯形，两个问题都不存在。

梯形之外露出来的部分取屏幕边缘像素的钳制采样并压暗（`backgroundDim`，默认 0.55），看起来像玻璃后面退远了的空间。

### 关于着色器

`Sources/MacDuoCore/Render/MetalFrost.metal` 是唯一的着色器源码。
`Tools/embed-shader.py` 把它嵌成 `EmbeddedShader.swift`（每次构建自动重新生成，不要手改）。
`MetalFrostRenderer.makeShaderLibrary` 的查找顺序是：

1. bundle 里的 `default.metallib`（只有装了 Xcode 的 Metal 工具链、由 `build.sh` 预编译时才存在）；
2. 进程默认库；
3. **内嵌源码运行时编译**（默认路径，所以 `swift build` 出来的二进制也能直接用）。

## 设置

菜单栏图标下拉里可以快速开关和拖动最常用的两个参数；完整参数在「设置…」窗口里，分三页：

| 页 | 参数 | 说明 |
| --- | --- | --- |
| 效果 | 梯形倾斜量 | 最强时顶端相对铰链端的收窄比例，0 = 普通矩形 |
| | 画面后方的暗度 | 梯形之外露出的背景压多暗 |
| | 顶端最强模糊 | 顶端（最糊一侧）的模糊半径，单位 pt。30 pt 以上文字就已经不可读了 |
| | 底端基础模糊 | 铰链一侧保留的模糊，默认 2 pt |
| | 底部保持清晰的高度 | 从铰链算起这一段基本清晰，往上才开始起雾 |
| | 层次融合 | 0 = 三层模糊分明（叠起来的玻璃），1 = 融成一条连续渐变 |
| | 白雾浓度 / 保留色彩 / 压暗 | 毛玻璃质感的三个成分 |
| 角度 | 开始生效角度 | 默认 90°，达到或高于它时效果完全为零 |
| | 达到最强角度 | 默认 15°，达到或低于它时效果拉满 |
| | 响应曲线 | 大于 1 时前半段保持轻微，接近合上才快速加深 |
| 硬件 | 角度偏移 / 角度倍率 | 读数不为 0 或方向相反时的校准 |

所有参数即时生效并存到 `UserDefaults`。

### 角度与强度的关系

```
progress = (开始生效角度 − 当前角度) / (开始生效角度 − 达到最强角度)
强度     = progress ^ 响应曲线        （裁剪到 0…1）
```


默认 `90° → 15°`、指数 1.0，也就是线性；角度 ≥ 90° 时强度恒为 0，覆盖窗口直接收起。

## 兼容性 / 排错

- **传感器读不到**：2019 款 16" MacBook Pro 之后的机器才有这个传感器。M1/M2 的部分机型会以厂商私有接口（UsagePage `0xFF00`）暴露，本应用读不到，菜单栏会显示"传感器节点存在，但无法读取角度"。合盖模式（接外接显示器合上盖子）下内建屏关闭，同样无法使用。
- **画面不动 / 菜单里"画面捕获"是未启动**：检查屏幕录制权限。**每次重新 `./build.sh` 之后都要重新授权**——ad-hoc 签名的 cdhash 每次构建都会变，macOS 会把它当成一个新 App。授权后回到菜单点一下"开始捕获"即可，通常不必重启。
- **效果方向反了**：在「硬件」页把角度倍率改成 `-1`，或者用角度偏移校正零点。
- **只有内建屏受影响**：外接显示器上不会出现任何效果，这是有意的（外接屏没有铰链）。

### 已知限制

- 想用录屏/截图工具记录效果时会录到模糊后的画面，因为覆盖窗口本身也是屏幕内容（只有本应用自己的捕获会排除它）。
- 空间切换、全屏 App 上的表现取决于窗口层级：覆盖窗口是 `.normal` 层级 + `canJoinAllSpaces`，全屏 App 可能盖在它上面。如果这对你是刚需，可以在 `FrostOverlayController` 里把 `window.level` 调到 `.screenSaver`。

## 源码结构

```
Sources/MacDuoCore/           效果核心（独立 library，便于被验证程序复用）
  Sensor/LidAngleSensor.swift     盖角传感器
  Model/FrostSettings.swift       全部参数 + 强度曲线
  Capture/CaptureEngine.swift     ScreenCaptureKit 捕获
  Render/DisplayResolver.swift    内建显示器定位
  Render/MetalFrost.metal         着色器（唯一源码）
  Render/MetalFrostRenderer.swift 模糊金字塔 + 合成
  Render/EmbeddedShader.swift     自动生成的着色器副本
  Overlay/FrostOverlayController.swift  覆盖窗口
Sources/MacDuo/               菜单栏 App
  App/MacDuoApp.swift             入口与 AppDelegate
  App/AppController.swift         传感器 → 效果的接线
  UI/MenuBarLabel.swift           菜单栏图标与角度
  UI/MenuBarPanel.swift           下拉面板
  UI/SettingsView.swift           设置窗口
Tools/MacDuoProbe/main.swift  运行时验证程序
Tools/embed-shader.py         着色器嵌入脚本
build.sh / verify.sh
```

## 踩坑记录（改这个项目时值得先看）

- **捕获格式是 BGRA**。探针里所有取像素都走 `channel/red/green/blue` 这几个辅助函数——手写 byte 偏移时漏了 2 个字节，结果把 `x=0,y=2` 读成了 `x=640,y=400`，白查了很久。
- **不要在片元里自己插值 UV**。折叠改成顶点阶段实现之后，`[[position]]` 与 UV 插值的不确定性就不再影响结果。
- **`swift build` 与 Xcode 的 Metal 离线工具链无关**：着色器默认在运行时从内嵌源码编译，所以没装 MetalToolchain 也能直接跑。
- **别用 `NSLog` 打印 Swift 字符串**（会 SIGSEGV），用 `os.Logger`。
- **MPS 高斯不允许原地读写**，三级模糊必须各自有目标纹理。

## 致谢

盖角传感器的读取方式来自 [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor)（MIT）。
