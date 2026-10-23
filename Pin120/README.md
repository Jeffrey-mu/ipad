# Pin120 2.1

让 **60Hz 的 iPad Pro（2018 / 12.9" / A12X）** 上的游戏跑到 120fps。

## 为什么 v1 完全没用

| v1 做法 | 问题 |
|---|---|
| `Pin120.plist` 只过滤 SpringBoard / backboardd | **游戏进程根本没被注入**，插件对游戏零影响 |
| 在 SpringBoard 里挂一个 120Hz 的 CADisplayLink | 渲染帧率由**前台 App 自己**向系统申请，SpringBoard 说话不算数 |
| Pin120App 用 ReplayKit 广播"逼"系统锁 120Hz | 广播只是抓画面，**不会改变别的 App 的帧率**；在 60Hz 机型上更是无效 |

## 硬件前提（先看清楚再装）

* iPad Pro 2018 (A12X) 的屏幕**物理上只有 60Hz**，ProMotion 是 2020 年 M1 才开始有的。
* 插件能做的是：**让游戏按 120fps 渲染**（帧率数字变 120、输入延迟更低）。
* 屏幕本身仍然只能显示 60 帧。真·120Hz 顺滑需要 ProMotion 机型。

## v2 的做法（全部发生在游戏进程里）

1. **伪造 `UIScreen.maximumFramesPerSecond` → 120**
   游戏判断"这台设备支不支持 120 帧"用的就是它。60Hz 机型返回 60，游戏的 120 帧选项
   就被隐藏 / 降级，帧率被锁在 60/80。伪造后，**游戏设置里会重新出现 120 帧选项**。
2. **强制 `CADisplayLink` 的 `preferredFramesPerSecond` / `preferredFrameRateRange` → 120**
   引擎（Unity / Unreal）用它决定渲染节奏，游戏里往往写死 60/80。
3. **Unity 原生 `Application.targetFrameRate`（`UnityGet/SetTargetFrameRate`）→ 120**
   绕开游戏自己设置的帧率上限（80fps 基本就是从这条路来的）。
4. **可选：伪造机型 `hw.machine` → `iPad13,4`（M1 iPad Pro）**
   少数游戏是按机型白名单判断是否支持 120Hz 的。

注入范围：`Pin120.plist` **不带 Filter** → 所有进程都加载；`Tweak.x` 的 `%ctor` 里只对
第三方 App 启用 hook（系统进程 / 守护进程完全不受影响）。

## HUD 说明（游戏左上角）

* 收起状态：显示当前模式。**单击展开**。
* 展开状态：单击切换模式（关闭 / 标准 / 标准+机型伪装），**长按收起**。
* 收起状态长按 = 屏蔽当前 App（写进 `/var/mobile/Library/Preferences/com.wjf.pin120.plist`）。

展开后各字段含义：

| 字段 | 含义 |
|---|---|
| 上报刷新率 | `[UIScreen mainScreen].maximumFramesPerSecond` 的**实时**值。显示 120 说明伪造生效；还是 60 说明 hook 没生效 |
| 真 | 伪造前的真实值（这台机器是 60） |
| 实测 Hz | display link 回调频率 = 面板真实刷新率（60） |
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

先看 HUD 上的两个字段：

* **重压** 一直在涨、**引擎请求** 还是 120 → 插件这边没被改掉，掉帧是**性能/发热**问题：
  * **热:偏热 / 过热** 出现 → 确认是温度墙。A12X 长时间跑 120fps 的球球大作战顶不住，属正常现象。
    处理：降画质（分辨率/特效）、摘保护壳、别边充边玩、背面垫个散热器。
  * **低电:开** → iOS 会自动降 GPU 频率，关掉低电量模式。
  * 热:正常 但还是掉 → 纯 GPU 瓶颈，只能降画质。
* **引擎请求** 变成 80 → 游戏自己又改了，看门狗会在 1 秒内把它压回 120
  （HUD 的「重压」会继续涨，帧率会在 1 秒内回 120）。

> 注意：120fps 是**渲染帧率**。这台机器屏幕只有 60Hz，所以帧率掉到 80 时你**看不出画面变卡**，
> 但输入延迟会变差、发热会小一点。要不要一直顶着 120 跑，是性能和温度的取舍。

## 已知限制

* 面板 60Hz → 屏幕最多显示 60 帧，120fps 是"渲染帧率"。
* 部分游戏有反作弊 / 机型校验，`标准+机型伪装` 模式可能导致异常，异常就切回"标准"。
* 插件只对第三方 App 生效，系统 App 不受影响。
