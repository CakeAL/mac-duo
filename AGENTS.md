# AGENTS.md — MacDuo 开发说明

给改这个仓库的人/agent 看。用户向的说明在 [`README.md`](README.md)。

## 需求（一句话）

截内建屏整幅画面 → 画布清成黑色 → 把截图当梯形画上去（**底边钉死**、顶端随盖角收窄）→
沿画面自上而下套一层递减的高斯模糊（顶端最强、铰链端为 0）。**只在这个区间有效果：盖角 0–90°。**

## 管线

```
LidAngleSensor ──角度──▶ AppController ──折叠进度 0…1──▶ FrostOverlayController
   (IOKit HID)          (角度映射 + 开合缓动)                │
                                                            ▼
CaptureEngine ──内建屏画面──▶ MetalFrostRenderer ──▶ 覆盖窗口 (NSWindow + MTKView)
(ScreenCaptureKit)            梯形拉伸 + 自上而下模糊
```

- **LidAngleSensor**：Apple VID `0x05AC` / PID `0x8104` 的 HID 节点，读 feature report 1，低字节
  在前。同一 VID/PID 下有多个节点，逐个试读、只认能读出报告的。60 Hz 轮询 + 平滑。
- **CaptureEngine**：`SCStream` 抓内建显示器，全分辨率 BGRA，只在盖角接近生效区间时才启动
  （省 GPU / 省电）。细节见下面"捕获三条硬规矩"。
- **AppController**：角度 → 折叠进度，再叠一层时间常数 `responseSmoothing`（默认 0.06 s）的指数
  缓动，把"掀盖子"这个突变补成一次连续折叠；同时管预览动画与捕获生命周期。
- **MetalFrostRenderer**：每帧三步——捕获帧 1:1 拷进带 mip 的工作纹理 → `generateMipmaps` → 合成。
- **FrostOverlayController**：内建屏大小的无边框窗口，进度小于 0.004 直接 `orderOut`（此时显示
  捕获副本只会平白背上捕获延迟）。

## 着色器

`Sources/MacDuoCore/Render/MetalFrost.metal`，四个函数：

- `frost_vertex`：把全屏四边形画成梯形。**只有远端那对顶点会动**（`anchor = 0` 时是上面两个角），
  近端两个角的 scale 恒为 1，所以那条边钉死。画面坐标 0…1 铺满梯形——**是拉伸，不是裁切**。
- `frost_vertex_flat`：同样的四边形但不带梯形。拷贝那一趟必须用它（见踩坑）。
- `frost_copy`：捕获帧 1:1 写进工作纹理的第 0 级 mip。坐标取自 `[[position]]` 而不是插值 uv。
- `frost_fragment`：模糊。

```
ramp   = (1 - uv.y) ^ 渐变曲线       // 顶端 1，铰链端 0；anchor = 1 时反过来
radius = 顶端最强模糊 × 进度 × ramp
```

5×5 加权抽头核，权重 `1 : 4 : 6 : 4 : 1`（归一化 256），**抽头间距就是这一行的半径**，每个抽头去
mip 链取 `level = max(baseLod, log2(radius))`。半径 < 0.35 px 时退化成一次 `level(0)` 采样——
所以底边逐像素精确，90° 时整屏也是。

`Tools/embed-shader.py` 把着色器嵌成 `EmbeddedShader.swift`（每次构建自动重生成，不要手改）。
`MetalFrostRenderer.makeShaderLibrary` 顺序：bundle 的 `default.metallib` → 进程默认库 →
**内嵌源码运行时编译**（默认路径，所以没装 MetalToolchain 也能跑）。

## 角度映射（与参考实现同形）

参考实现（[chuspeeism/iphone-duo](https://github.com/chuspeeism/iphone-duo)）：
`foldAngle = (180 − 滑杆值)/180 × π`，`progress = clamp(foldAngle / (π/2), 0, 1)`。

这里把"折角"取成**离立起来还差多少**：`折角 = 开始生效角度 − 盖角`。盖角 90° 时折角 0、画面干净；
盖角 0°（合上）时折角 90°、效果拉满。于是

```
progress = clamp(折角 / (π/2), 0, 1)
         = clamp((开始生效角度 − 盖角) / (开始生效角度 − 满强度角度), 0, 1)
折叠进度 = progress ^ 响应曲线
```

默认（生效 90°、满强度 0°）：

| 盖角 | 111° | 90° | 80° | 60° | 45° | 30° | 15° | 0° |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 进度 | 0 | 0 | 0.11 | 0.33 | 0.50 | 0.67 | 0.83 | **1** |
| 顶端宽度 | 100% | 100% | 96% | 90% | 85% | 81% | 77% | **74%** |
| 顶端模糊 | 0 | 0 | 8 pt | 24 | 36 | 48 | 60 | **72 pt** |

**别把 90° 当零点**（踩坑里有详细说明）。

## 构建与验证

```bash
./build.sh                    # release + 打包 + ad-hoc 签名 → dist/MacDuo.app
./verify.sh                   # 构建并跑 Tools/MacDuoProbe（离屏，无需 GUI/权限）
./verify.sh /tmp/macduo-png   # 顺便导出五张预览图 lid-90…lid-00

MACDUO_PROBE_FLASH=1   ./.scratch/arm64-apple-macosx/release/MacDuoProbe   # 屏幕上真显示 3 秒
MACDUO_PROBE_BENCH=1   …   # 按内建屏真实分辨率跑性能
MACDUO_PROBE_MAP=1     …   # 打印角度 → 进度 → 顶端宽度/模糊 的对照表并校验单调性
MACDUO_PROBE_SENSOR=1  …   # 打印 3 秒实时盖角读数（判断方向对不对）
MACDUO_PROBE_CAPTURE=1 …   # 真实捕获的反馈检查（会短暂全屏纯红，见踩坑）
```

四张合成帧各验证一件事：

| 帧 | 图案 | 证明 |
| --- | --- | --- |
| measure | 棋盘渐变 + 首尾两条异色横带 | 静止时画面分毫未动、方向没翻、糊的程度 |
| white | 纯白 | 梯形四条边与外面的黑，逐行与公式对账 |
| edge | 左黑右白 | 每一行的真实模糊半径（10–90 过渡宽度 ÷ 2.563） |
| preview | 仿桌面 | 五张预览 PNG |

实测（M1 Pro，1280×800 合成帧，顶端收窄 0.35、模糊 72 pt、渐变 1.2）：

```
identity: 0.000% of samples differ by more than 2 (worst 0)
trapezoid:  顶端 952 px（公式 952）· 中间 1114（1114）· 底边 1276（1277）；镜像时顶端 1278 满宽、底端 950
blur sigma: 52.4→54.2 · 41.0→39.4 · 27.2→28.5 · 12.7→14.4 · 0.6→0.8（最后一行保留 100% 细节）
composite:  2.4 ms/frame @3456×2234（每像素 25 次采样）
```

## 源码结构

```
Sources/MacDuoCore/           效果核心（独立 library，验证程序复用同一份代码）
  Sensor/LidAngleSensor.swift     盖角传感器
  Model/FrostSettings.swift       全部参数 + 角度映射 + settingsVersion
  Capture/CaptureEngine.swift     ScreenCaptureKit 捕获 + makeBuiltInFilter()
  Render/DisplayResolver.swift    内建显示器定位
  Render/MetalFrost.metal         着色器（唯一源码）
  Render/MetalFrostRenderer.swift 拷贝 + mip 链 + 合成
  Render/EmbeddedShader.swift     自动生成的着色器副本（勿手改）
  Overlay/FrostOverlayController.swift  覆盖窗口
Sources/MacDuo/               菜单栏 App
  App/MacDuoApp.swift             入口与 AppDelegate
  App/AppController.swift         角度 → 进度、缓动、预览动画、捕获生命周期
  UI/MenuBarLabel.swift           菜单栏图标（缺权限时变橙色感叹号）
  UI/MenuBarPanel.swift           下拉面板
  UI/SettingsView.swift           设置窗口
Tools/MacDuoProbe/main.swift  运行时验证程序（所有断言都在这里）
Tools/MipLodProbe.swift       单文件实验：mip 级显式采样到底插不插值
Tools/embed-shader.py         着色器嵌入脚本
build.sh / verify.sh
```

## 捕获三条硬规矩

1. **按应用排除自己**，不要按窗口列 —— 否则会出现捕获反馈（见踩坑第 1 条）。
2. **`colorSpaceName = .sRGB`**，并且覆盖层的 `CAMetalLayer.colorspace` 设成同一个 —— 渲染器
   原样搬运像素，不标记的话 macOS 会按显示器自己的空间解释，覆盖层一出现整屏发灰。
3. **`showsCursor = false`**：覆盖窗口铺满整屏，抓进来的光标会在真光标旁边留一个慢半拍的影子。
   另外 `queueDepth` 越小越好，每一帧缓冲都是画面落后现实的一帧。

## 踩坑记录

- **捕获反馈 = "液体效果"**。覆盖窗口铺满整屏、显示的就是捕获画面：只要它被拍进去一帧，这一帧
  就成了下一帧的输入，模糊与拉伸逐帧累积，屏幕上出现一层流动的糊 + 拖影 + 整体发灰。而覆盖
  窗口在进度为 0 时是 `orderOut` 的，用 `onScreenWindowsOnly: true` **根本列不到它**，排除列表
  就是空的。正确写法：

  ```swift
  SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
  SCContentFilter(display: display, excludingApplications: [自己整个进程], exceptingWindows: [])
  ```

  回归检查 `MACDUO_PROBE_CAPTURE=1`：放一个纯红窗口占满内建屏，用同一个过滤器截一帧，中心像素
  必须**不是**红的（实测 `255 255 255`）。修之前必然是 `255 0 0`。
- **两趟渲染不能共用同一个顶点函数**。拷贝那趟若也走梯形顶点，画面会先在纹理里压一次、合成时
  再压一次：梯形外轮廓看着对，内容却挤了两遍、上角还会露出第一趟留下的黑块，模糊半径的测量也
  整体失真。所以有 `frost_vertex_flat`。**任何"进纹理"的中间趟都必须 1:1。**
- **别把 90° 当零点**。需求是"盖角 0–90° 有效果"（越合越强），早期版本把 90° 当成零效果点、
  90–180° 才有渐变，完全拧了。探针现在钉死：生效角度及以上必须 0、满强度角度必须是 1、
  区间中点既不能是 0 也不能是 1（防止退化成恒零/恒满）。
- **逐行的期望值要用那一行真实的坐标**，不能用取整前的目标值：顶端附近渐变很陡，一行之差就能
  差出好几个灰阶。
- **任何"按位置起作用"的效果都必须乘上 `progress × ramp`**。曾经降饱和那行写成
  `mix(luma, color, frostSaturation)` 而忘了乘掩码，于是**效果关闭时画面也被悄悄降了 8% 饱和度**
  （棋盘 `127/0/255` → `120/4/238`）。"静止时画面必须逐像素一致"这条断言就是为它准备的。
- **抽头覆盖度的单位要统一**。曾经把"抽头足迹"写成 `max(0.5·|d(uv)·尺寸|, 半径×0.75)`：前半截
  是纹素数、后半截是画面像素数，两者还拿去跟 uv 值比较，于是每个模糊像素都被乘上约 0.6 的系数，
  糊的地方整体变暗而铰链端正常。凡"按位置起作用"的掩码，先问一句：这几个数是什么单位。
- **不要手写两套坐标映射**。拷贝趟用 `[[position]]` 算 uv、合成趟用插值 uv，两者各错各的但错误
  会互相抵消（翻两次面等于没翻）——所以"画面有没有翻"必须拿**捕获帧本身**比，不能拿另一趟渲染
  结果比。
- **`sample(sampler, uv, level(lod))` 配合 `mip_filter::linear` 是三分量插值的**：
  `Tools/MipLodProbe.swift` 里第 0 级全黑、第 1 级全白，`lod = 0.25 / 0.5 / 0.75` 读回
  `64 / 128 / 191`。所以半径可以连续变化，不会出现能看见的层级台阶。
- **捕获格式是 BGRA**，所有取像素都走探针里的 `red/green/blue` 辅助函数——手写 byte 偏移漏 2 个
  字节时，会把 `x=0,y=2` 读成 `x=640,y=400`。
- **参数形状变了就把 `settingsVersion` +1**：旧版本存下来的值描述的是另一套效果，留着只会误导
  （`FrostSettings` 会在版本不一致时清空自己那几个 key）。
- **`swift build` 与 Xcode 的 Metal 离线工具链无关**：着色器默认运行时从内嵌源码编译。
- **别用 `NSLog` 打印 Swift 字符串**（会 SIGSEGV），用 `os.Logger`。
- **改探针时用 `s.index(anchor, start)` 定位**：这个仓库的文件是用脚本改的，`s.index` 找到的是
  第一次出现的位置，同名代码片段（比如 `CVPixelBufferLockBaseAddress`）会让区间反过来，把文件
  切出重复块。

## 致谢

- 盖角传感器读法来自 [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor)（MIT）。
- "整屏截图拉成梯形 + 自上而下递减的高斯模糊"这个效果参照
  [chuspeeism/iphone-duo](https://github.com/chuspeeism/iphone-duo)（MIT）里折叠屏的观感；实现是
  按需求重写的，没有共用它的代码。
