# MacDuo

把 MacBook 变成一块会随开合角度折叠的屏幕——照 Apple 折叠屏参考实现的那套做法。

合到 90° 以下时，内建显示器上的画面会：

1. **被当成一块沿屏幕底边向下折的面板来看**：面板越折越低，画面按**固定正视投影**前缩到面板上
   ——内容不梯形、不斜切，只是朝铰链方向压扁，近铰链处几乎 1:1，越远压得越狠。
2. **面板之外是盖子背后的暗处**：面板远端那条线以上全黑。
3. **沿面板从铰链到远端逐渐糊掉**：铰链侧模糊半径为 0，面板远端达到设定的最大半径。
4. **远端同时压暗**：折过去的那一端像被看得越来越薄一样沉进黑里。

角度回到 90° 以上时，效果完全消失、覆盖窗口收起，屏幕恢复原样——而且是**逐像素**恢复：探针
比对过，进度为 0 时输出与捕获帧完全一致（0.000% 的采样点有差异）。

这套做法来自 Apple 折叠屏参考实现（[iPhone Duo · Fold Preview](https://github.com/chuspeeism/iphone-duo)，
在线演示 <https://iphone-duo-tawny.vercel.app/>），本项目的着色器就是它的 `screenShader` 逐行对照
移植过来的：

| 参考实现的参数 | 它的值 | MacDuo |
| --- | --- | --- |
| 折叠进度 | 滑杆 0…1 | 盖角 90°…0°（默认） |
| 折叠角 | `progress × π/2` | 同 |
| 画面投影 | 从固定眼睛射出的光线打到**摊平**的屏幕上取色 | 同，眼睛位置可调（默认 2.5 屏高） |
| `edge`（渐变坐标） | 在**面板**上量，0 = 铰链，1 = 远端 | 同 |
| `motion` | `smoothstep(0, 1, progress)` | 同 |
| 模糊半径 | `72 × motion × edge^1.35`（源图像像素） | 同（`远端最强模糊`，单位 pt） |
| 压暗 | `color *= 1 - min(1, effect × 2)`，`effect = motion × darkenGradient^1.35` | 同（`压暗强度` 默认就是 2.0） |
| 压暗起点 | `(edge - 0.2) / 0.8` | 同 |
| 模糊核 | 5×5 抽头，权重 1:4:6:4:1 归一化到 256，间距 = 半径，`lod = max(baseLod, log2(radius))` | 同 |
| 面板边缘 | 抽头乘上"这还在不在画面里"，颜色溶进黑边 | 同，只是本机画面铺满屏幕，所以只有面板远端那条边会溶进黑里 |
| 白雾 / 降饱和 | 没有 | 默认关闭（0 / 1.0），想更像玻璃可以自己加 |

三处必须不同，因为这是一台笔记本，屏幕本身就是显示器，而不是一个折叠手机的 3D 模型：

1. 它的铰链是手机的竖轴书脊、而且有内屏外屏两块；MacBook 沿屏幕**底边**折、只有一块屏，所以
   `edge` 是"从底边往上量"；
2. 这里的 `progress` 来自盖角传感器，不是滑杆；
3. 它的黑边是图片内部的一圈留白；本机画面铺满屏幕，所以只有面板远端那条边会溶进黑里，屏幕
   自己的左、右、下三条边是钳制延展。

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

不想真的去合盖子，就用菜单里的 **预览开合动画**：它会把捕获到的画面按一段循环动画反复折下去
再打开（开 → 合 → 停 → 开，8.6 秒一轮，两端是余弦缓动），在屏幕上直接看效果。再点一次停止。

没有 Xcode 的 Metal 离线工具链也没关系：应用会在运行时用内建的一份着色器源码现场编译（见下文
"关于着色器"）。

## 验证

```bash
./verify.sh                  # 跑运行时校验（不需 GUI）
./verify.sh /tmp/macduo-png  # 顺便导出四张效果预览图
MACDUO_PROBE_FLASH=1 ./.scratch/arm64-apple-macosx/release/MacDuoProbe
                             # 额外在内建屏上真实显示 3 秒半折状态（用合成帧，
                             # 不需要任何权限），可以直接肉眼看折叠
MACDUO_PROBE_BENCH=1 ./.scratch/arm64-apple-macosx/release/MacDuoProbe
                             # 额外按内建屏真实分辨率跑一遍性能（每像素 25 次采样）
```

性能实测（M1 Pro，3456×2234 全屏、每像素 25 次纹理采样、离屏同步等待）：

```
composite: 2.39 ms/frame — 418 fps of headroom
```

也就是说合盖动画里有大把余量；这也是"远端最强模糊"可以一路调到 200 pt 的原因。

`verify.sh` 会在离屏纹理上跑完整的管线，四张合成帧各验证一件事：

| 帧 | 图案 | 用来证明 |
| --- | --- | --- |
| measure | 棋盘渐变 + 首尾两条异色横带 | 折叠投影把画面送到该去的位置，静止时画面分毫未动 |
| uniform | 纯白 | 单独量出压暗渐变与面板远端那条边，并逐行与公式对账 |
| edge | 左黑右白 | 量出每一行真实的模糊半径（10–90 过渡宽度 ÷ 2.563） |
| preview | 一张仿桌面（壁纸、菜单栏、窗口、程序坞） | 输出五张预览 PNG，用眼睛看效果 |

实测输出（M1 Pro，1280×800 合成帧，显示比例 1:1，最强模糊 72 pt、falloff 1.35、压暗 2.0、
眼睛 2.5 屏高 / 0.5 屏高）：

```
== 1. with the lid at 90° the picture is exactly the picture
identity: 0.000% of samples differ by more than 2 (worst 0)
orientation: top row white, bottom row black — upright

== 2. the fold: the picture is foreshortened towards the hinge
  progress   panel visible   top band: row (want)   bottom band: row (want)
      0.25         87%          row  127 ( 124)        row  776 ( 776)
      0.50         66%          row  285 ( 284)        row  779 ( 779)
      0.75         41%          row  477 ( 476)        row  786 ( 786)

== 3. the blur ramp along the panel: sharp at the hinge, frosted far out
  panel   screen row   wanted sigma   measured sigma   detail kept
   0.059          760            0.8              0.8        66.3%
   0.248          642            5.5              5.5         0.6%
   0.449          529           12.2             12.5         0.2%
   0.650          427           20.1             21.1         0.3%
   0.848          335           28.8             30.4         0.3%

== 4. the far panel falls into the dark, and behind the lid is black
   panel   screen row   rendered   expected
   0.048          792      255.0      255.0
   0.199          770      255.0      255.0
   0.394          745      179.0      179.5
   0.591          723       61.0       60.9
   0.795          703        0.0        0.0
   0.942          690        0.0        0.0
panel edge: a shut lid leaves the bottom 14% of the screen
```

四组断言分别证明：

- **90° 时画面逐像素一致**（最坏差 0）——既没有形变，也没有翻转、位移或缩放；
- **折叠投影就是那条公式**：画面首尾两条横带落在预测行的 ±3 行内，`progress` 0.25 / 0.5 / 0.75
  下都成立，所以"面板可见高度"（87% / 66% / 41%）是真的；
- **模糊半径就是设定值**：每行量出来的 σ 与 `半径 × motion × edge^1.35` 相差不到 6%，从铰链的
  0.8 px 单调升到远端的 30 px；
- **压暗与公式逐行吻合**（误差 ≤ 0.5 灰阶），铰链一端原封不动，面板之上是纯黑。

## 它怎么工作

```
LidAngleSensor ──角度──▶ AppController ──折叠进度 0…1──▶ FrostOverlayController
   (IOKit HID)          (触发曲线 + 开合缓动)                │
                                                            ▼
CaptureEngine ──内建屏画面──▶ MetalFrostRenderer ──▶ 覆盖窗口 (NSWindow + MTKView)
(ScreenCaptureKit)            投影 + 渐进模糊 + 压暗
```

- **LidAngleSensor**：Apple VID `0x05AC` / PID `0x8104` 的 HID 节点，读 feature report 1，低字节
  在前组成角度值。同一个 VID/PID 下有好几个 HID 节点，所以会逐个试读、只认能读出报告的那个。
  60 Hz 轮询，带平滑。
- **AppController**：把角度换算成折叠进度（默认 90° → 0° 线性），再叠一层按时间常数（默认
  0.12 s）的指数缓动——传感器本身已经在平滑位置，这一层保证快速扳动盖子时画面是一段连续的
  折叠动画而不是跳变。它还管着预览动画的播放，以及"只在需要时才开捕获"的生命周期。
- **MetalFrostRenderer**：每帧三步——把捕获帧 1:1 拷进一张带 mip 的工作纹理、生成 mip 链、
  在合成时按投影取用画面并按面板坐标取用模糊与压暗。
- **FrostOverlayController**：内建屏大小的无边框窗口（`.normal` 层级、`canJoinAllSpaces`），
  进度为 0 时直接 `orderOut`，完全不影响正常使用。

### 关于着色器

`Sources/MacDuoCore/Render/MetalFrost.metal` 是唯一的着色器源码，只有三个函数：

- `frost_vertex`：普通全屏四边形，只负责把 NDC 映射成画面坐标（`uv = 0` 在画面左上角）。
- `frost_copy`：把捕获帧 1:1 写进工作纹理的第 0 级 mip。它的坐标取自 `[[position]]` 而不是
  插值出来的 uv，所以就算顶点的映射写反了它也不会翻面：第 (x, y) 个片元就读第 (x, y) 个纹素。
- `frost_fragment`：折叠本身。

折叠的核心是一行反解的正视投影。设 `s` 是这个像素离铰链的高度（屏幕高度为单位），`D` 是眼睛
到屏幕的距离、`E` 是眼睛高于铰链多少，那么视线打到面板上的位置是

```
h = D·s / (D·cos φ + (E − s)·sin φ)          φ = 进度 × π/2
```

- 盖子立在 90° 时 `h = s`，画面原样通过；
- 盖子折下去后 `h > s`，画面被前缩（越靠远端压得越狠），`h > 1` 的部分就是面板之外、盖子背后
  的暗处。

`h` 同时就是参考实现里的 `edge`，所以模糊与压暗都是在**面板坐标**上量的：

```
radius = 最大半径 × motion × h^falloff
effect = motion × ((h − 0.2) / 0.8)^falloff
color *= 1 − min(1, effect × 压暗强度)
```

模糊是一个 5×5 的加权抽头核，权重 `1 : 4 : 6 : 4 : 1`（归一化到 256），**抽头间距就是这一行的
模糊半径**，每个抽头再去 mip 链上取 `level = max(baseLod, log2(radius))` 那一级，并乘上"这个
抽头还在不在面板上"——面板远端之外的颜色就是这样溶进黑里的。

这样做有两个好处：**半径可以随位置连续变化**（不会出现"一层一层的模糊"），而且每个抽头的
足迹始终跟间距同量级，高频内容不会在重模糊区里产生采样走样。半径小于 0.35 px 时直接退化成
一次 `level(0)` 采样，所以铰链一侧是**逐像素精确**的原画面。

`Tools/embed-shader.py` 把着色器嵌成 `EmbeddedShader.swift`（每次构建自动重新生成，不要手改）。
`MetalFrostRenderer.makeShaderLibrary` 的查找顺序是：

1. bundle 里的 `default.metallib`（只有装了 Xcode 的 Metal 工具链、由 `build.sh` 预编译时才存在）；
2. 进程默认库；
3. **内嵌源码运行时编译**（默认路径，所以 `swift build` 出来的二进制也能直接用）。

## 设置

菜单栏图标下拉里可以快速开关和拖动最常用的两个参数；完整参数在「设置…」窗口里，分三页：

| 页 | 参数 | 说明 |
| --- | --- | --- |
| 效果 | 观察距离 | 眼睛离屏幕多远，单位是屏幕高度；越近画面压得越狠。参考实现的相机约在 3.6 屏高之外 |
| | 眼睛高度 | 眼睛高于铰链多少（0.5 = 屏幕正中）；坐得高一点，画面被压得轻一点 |
| | 远端最强模糊 | 面板远端（屏幕顶端一侧）的模糊半径，单位 pt；铰链一侧恒为 0。72 是参考实现的取值 |
| | 渐变曲线 | 模糊沿面板增长的幂次。参考实现是 1.35：近端可读，糊集中在远端 |
| | 铰链侧保持清晰 | 从铰链算起这一段面板高度完全不糊 |
| | 压暗强度 | 远端的压暗倍率；2.0（默认）就是参考实现的取值 |
| | 压暗起始位置 | 沿面板到这里才开始压暗，默认 0.2 |
| | 白雾浓度 / 保留色彩 | 额外的毛玻璃质感；参考实现没有这两项，所以默认是 0 和 1（关） |
| | 平滑时间 | 角度变化到画面跟上之间的时间常数，越大越像一段连续动画 |
| 角度 | 开始生效角度 | 默认 90°，达到或高于它时效果完全为零 |
| | 达到最强角度 | 默认 0°，也就是盖角 90°→0° 与折叠进度一一对应 |
| | 响应曲线 | 大于 1 时前半段保持轻微，接近合上才快速加深 |
| 硬件 | 角度偏移 / 角度倍率 | 读数不为 0 或方向相反时的校准 |

所有参数即时生效并存到 `UserDefaults`。**参数形状变了会带着版本号一起重置**：存下来的值如果
描述的是旧一版效果（比如上一版的梯形参数、或者在其他版本上调好的数值），会在启动时被丢弃，
避免拿旧旋钮去评价新效果。

### 角度与强度的关系

```
progress = (开始生效角度 − 当前角度) / (开始生效角度 − 达到最强角度)
折叠进度 = progress ^ 响应曲线        （裁剪到 0…1）
```

默认 `90° → 0°`、指数 1.0，也就是线性，和参考实现里"滑杆 180°→0°"是同一件事；角度 ≥ 90° 时
折叠进度恒为 0，覆盖窗口直接收起。进度之后再经过一层时间缓动才会送到渲染器，渲染器再把它变成
折叠角 `φ = 进度 × π/2`。

## 兼容性 / 排错

- **传感器读不到**：2019 款 16" MacBook Pro 之后的机器才有这个传感器。M1/M2 的部分机型会以
  厂商私有接口（UsagePage `0xFF00`）暴露，本应用读不到，菜单栏会显示"传感器节点存在，但无法
  读取角度"。合盖模式（接外接显示器合上盖子）下内建屏关闭，同样无法使用。
- **画面不动 / 菜单里"画面捕获"是未启动**：检查屏幕录制权限。**每次重新 `./build.sh` 之后都要
  重新授权**——ad-hoc 签名的 cdhash 每次构建都会变，macOS 会把它当成一个新 App。授权后回到菜单
  点一下"开始捕获"即可，通常不必重启。
- **效果方向反了**：在「硬件」页把角度倍率改成 `-1`，或者用角度偏移校正零点。
- **只有内建屏受影响**：外接显示器上不会出现任何效果，这是有意的（外接屏没有铰链）。
- **效果不符合口味**：模糊、压暗、渐变形状都是分开的参数，先把「远端压暗」调小可以让画面在
  远端保留更多内容。

### 已知限制

- 想用录屏/截图工具记录效果时会录到模糊后的画面，因为覆盖窗口本身也是屏幕内容（只有本应用
  自己的捕获会排除它）。
- 空间切换、全屏 App 上的表现取决于窗口层级：覆盖窗口是 `.normal` 层级 + `canJoinAllSpaces`，
  全屏 App 可能盖在它上面。如果这对你是刚需，可以在 `FrostOverlayController` 里把
  `window.level` 调到 `.screenSaver`。

## 源码结构

```
Sources/MacDuoCore/           效果核心（独立 library，便于被验证程序复用）
  Sensor/LidAngleSensor.swift     盖角传感器
  Model/FrostSettings.swift       全部参数 + 强度曲线
  Capture/CaptureEngine.swift     ScreenCaptureKit 捕获
  Render/DisplayResolver.swift    内建显示器定位
  Render/MetalFrost.metal         着色器（唯一源码）
  Render/MetalFrostRenderer.swift 拷贝 + mip 链 + 合成
  Render/EmbeddedShader.swift     自动生成的着色器副本
  Overlay/FrostOverlayController.swift  覆盖窗口
Sources/MacDuo/               菜单栏 App
  App/MacDuoApp.swift             入口与 AppDelegate
  App/AppController.swift         传感器 → 效果 + 开合缓动 + 预览动画
  UI/MenuBarLabel.swift           菜单栏图标与角度
  UI/MenuBarPanel.swift           下拉面板
  UI/SettingsView.swift           设置窗口
Tools/MacDuoProbe/main.swift  运行时验证程序
Tools/MipLodProbe.swift       单文件实验：mip 级显式采样到底插不插值
Tools/embed-shader.py         着色器嵌入脚本
build.sh / verify.sh
```

## 踩坑记录（改这个项目时值得先看）

- **捕获格式是 BGRA**。探针里所有取像素都走 `channel/red/green/blue` 这几个辅助函数——手写 byte
  偏移时漏了 2 个字节，结果把 `x=0,y=2` 读成了 `x=640,y=400`，白查了很久。
- **任何"按位置起作用"的效果都必须乘上 `progress × ramp`**。第一版里降饱和那一句写成了
  `mix(luma, color, frostSaturation)`，忘了乘行程掩码，于是**效果关闭时画面也被悄悄降了 8% 的
  饱和度**：棋盘图案的 `127/0/255` 变成 `120/4/238`。逐像素比对的断言一眼就看出来了——这也
  是"静止时画面必须逐像素一致"这条断言存在的意义。
- **`sample(sampler, uv, level(lod))` 配合 `mip_filter::linear` 是三分量插值的**：`Tools/MipLodProbe.swift`
  里放了一张第 0 级全黑、第 1 级全白的纹理，`lod = 0.25 / 0.5 / 0.75` 分别读回 `64 / 128 / 191`。
  所以半径可以连续变化而不会出现能看见的层级台阶，不必自己去混两级。
- **不要手写两套坐标映射**。拷贝那一趟用 `[[position]]` 自己算 uv，合成那一趟用插值 uv，两者
  各错各的，但错误会互相抵消（翻两次面就等于没翻）——所以"画面有没有翻"必须拿**捕获帧本身**
  去比，而不是拿另一趟渲染结果比。
- **`swift build` 与 Xcode 的 Metal 离线工具链无关**：着色器默认在运行时从内嵌源码编译，所以
  没装 MetalToolchain 也能直接跑。
- **别用 `NSLog` 打印 Swift 字符串**（会 SIGSEGV），用 `os.Logger`。
- **抽头覆盖度的单位要统一**。第一版里把"抽头足迹"写成了 `max(0.5·|d(uv)·尺寸|, 半径×0.75)`：
  前半截是纹素数、后半截是画面像素数，两者都拿去跟一个 uv 值比较了，于是每个模糊像素都被
  悄悄乘上约 0.6 的系数——糊的地方整体变暗，而铰链（走单次采样那条分支）完全正常。逐行与公式
  对账的断言一眼就看出来了。**凡是"按位置起作用"的掩码，先问一句：这几个数是什么单位。**
- **逐行的期望值要用那一行真实的坐标**，不能用取整前的目标值：面板远端附近渐变很陡，一行之差
  就能差出 6 个灰阶。

## 致谢

- 盖角传感器的读取方式来自 [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor)（MIT）。
- 渐进模糊与远端压暗的公式、以及"画面保持正视投影、折叠只由模糊与压暗表达"的思路，来自
  [chuspeeism/iphone-duo](https://github.com/chuspeeism/iphone-duo)（MIT）。
