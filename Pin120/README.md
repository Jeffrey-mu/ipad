# Pin120 2.1

让 **iPad Pro（2018 / 12.9" / A12X）的 ProMotion 稳定停在 120Hz**。

## 为什么 v1 完全没用

| v1 做法 | 问题 |
|---|---|
| `Pin120.plist` 只过滤 SpringBoard / backboardd | **游戏进程根本没被注入**，插件对游戏零影响 |
| 在 SpringBoard 里挂一个 120Hz 的 CADisplayLink | 渲染帧率由**前台 App 自己**向系统申请，SpringBoard 说话不算数 |
| Pin120App 用 ReplayKit 广播"逼"系统锁 120Hz | 广播只是抓画面，**不会改变别的 App 的帧率** |

## 硬件前提

* iPad Pro 2018 (12.9" 3rd gen / A12X) 是 **ProMotion 120Hz 屏**（ProMotion 从 2017 款开始就有）。
* 但 iOS 的 ProMotion 是自适应的，会在 **120 / 80 / 60** 之间自己跳，
  所以"玩一会儿掉到 80"是系统/游戏在降档，不是插件失效。
* 插件的工作：把前台 App 的请求和所有 display link **钉死在 120**，并每秒重压一次。

## v2 的做法（全部发生在游戏进程里）

1. **`UIScreen.maximumFramesPerSecond` → 恒为 120**
   游戏判断"这台设备支不支持 120 帧"用的就是它。
2. **强制 `CADisplayLink` 的 `preferredFramesPerSecond` / `preferredFrameRateRange` → 120**
   引擎（Unity / Unreal）用它决定渲染节奏，游戏里往往写死 60/80。
3. **Unity 原生 `Application.targetFrameRate`（`UnityGet/SetTargetFrameRate`）→ 120**
   绕开游戏自己设置的帧率上限。
4. **每秒看门狗重压**：所有还活着的 display link 重新压回 120，游戏改回去也会被 1 秒内压回。
5. **可选（标准+机型伪装）**：伪造机型 `hw.machine` → `iPad13,4`（M1 iPad Pro），
   并把 `thermalState` 伪装成正常、低电量伪装成关闭 —— 有些游戏是看这些自己降档的。

注入范围：`Pin120.plist` **不带 Filter** → 所有进程都加载；`Tweak.x` 的 `%ctor` 里只对
第三方 App 启用 hook（系统进程 / 守护进程完全不受影响）。

## HUD 说明

### 桌面悬浮条（2.3+，最重要）

装好 respring 后，**桌面上**（不用进游戏）就会出现一个小条：

* 收起：`P120 ▸ 点我`（还没收到游戏状态）或 `P120 120Hz ✓`（游戏在线）
* 点一下展开：`Pin120 2.3 · SpringBoard 已注入 ✓` + 游戏是否在线 + 模式/温度/低电/重压
* 按住可以拖动位置

**看到这个条子 = 插件确实被加载了**。如果桌面上连它都没有，说明 deb 没被注入
（装错架构 / 没 respring / 被 RootHide 挡了），跟游戏本身无关。

### 游戏内挂件

* 收起状态：显示当前模式。**单击展开**。
* 展开状态：单击切换模式（关闭 / 标准 / 标准+机型伪装），**长按收起**。
* 收起状态长按 = 屏蔽当前 App（写进 `/var/mobile/Library/Preferences/com.wjf.pin120.plist`）。

展开后各字段含义：

| 字段 | 含义 |
|---|---|
| 上报刷新率 | `[UIScreen mainScreen].maximumFramesPerSecond` 的**实时**值（这台机器本来就是 120） |
| 真 | 插件接管前读到的值 |
| **实测 Hz** | display link 回调频率 = **屏幕当前真实刷新率**。掉到 80 时这里会显示 80，是最关键的判断依据 |
| 热 / 低电 | 系统温度状态 / 低电量模式（强力模式下会被伪装成正常/关闭） |
| 重压 | 看门狗已经重新压了多少次（每秒一次，正常会一直涨） |
| 引擎请求 | 游戏自己想要的 `preferredFramesPerSecond`（原值）。**显示 80 就说明 80 是游戏自己写的**，不是系统锁的 |
| 区间 | 游戏请求的 `preferredFrameRateRange` 上限 |
| Unity target | Unity `Application.targetFrameRate`（原值） |

## 构建 / 安装

### 没有 Mac：用 GitHub Actions（推荐）

仓库已配好 `.github/workflows/build-deb.yml`，云端 macOS 自动编译：

1. `git push` 到 `main`（或在仓库 Actions 页面点 **Run workflow**）。
2. 等 2~4 分钟，Release 里就有固定地址：
   * `https://github.com/Jeffrey-mu/ipad/releases/latest/download/Pin120.deb`
   * `https://github.com/Jeffrey-mu/ipad/releases/latest/download/BallKey.deb`
3. iPad 上 Safari 打开上面的 URL → 用 Sileo / Filza 装；也可以 `git pull` 后从
   `Pin120/packages/` 里拿。

### 有 Mac / Linux / WSL

```bash
cd Pin120
./build.sh          # = make package FINALPACKAGE=1
# 产物：Pin120/packages/com.wjf.pin120_2.1.0_iphoneos-arm64e.deb
```

装到 iPad 后**重启 SpringBoard（respring）**，因为没有 Filter，需要重新注入到游戏进程。

## 排查顺序

1. 装完进游戏，左上角应该出现 `P120 标准` 的小挂件 → 说明注入成功。
2. 展开看「上报刷新率」：显示 **120** → 伪造生效。
3. 看「引擎请求」：
   * 显示 **80** → 80 是游戏自己设的上限，插件已经改成 120 强制执行；
     如果计数器还是 80，说明 **A12X 显卡扛不住**（球球大作战人多时很吃 GPU），降画质即可。
   * 显示 **60** → 引擎还是按 60 跑，试一次"标准+机型伪装"模式（有些游戏按机型判断）。
4. 回游戏设置里看画质 / 帧率选项，**此时应该多出 120 帧**这一档，选它。

### 玩一会儿从 120 掉回 80？

先看 HUD 上的 **实测 Hz** 和 **重压**：

* **实测 Hz 掉到 80** → 是**屏幕本身**被降档了（ProMotion 自适应 / 发热 / 低电量）：
  * **热:偏热 / 过热** → 温度墙。A12X 长时间 120Hz 的球球大作战顶不住，属正常现象。
    处理：降画质（分辨率/特效）、摘保护壳、别边充边玩、背面垫散热器。
  * **低电:开** → iOS 会自动降 GPU 频率并限制刷新率，关掉低电量模式。
  * 热:正常、低电:关 还是掉 → iOS 的 ProMotion 调速器在按内容降档，试试「标准+机型伪装」。
* **实测 Hz 还是 120**，只有游戏自己的计数器显示 80 → 那是**游戏在降自己的渲染帧率**，
  看门狗会在 1 秒内把 display link 压回 120；如果一直不回来，说明游戏内部还有别的限制点。

## 已知限制

* ProMotion 是自适应的，系统在极端发热时会强制降档，插件对抗不了硬件温度。
* 部分游戏有反作弊 / 机型校验，`标准+机型伪装` 模式可能导致异常，异常就切回"标准"。
* 插件只对第三方 App 生效，系统 App 不受影响。
