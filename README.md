# A Console

通过 USB 连接自己的测试 iPhone，在 macOS 或 Windows 上预览和回放 GPX、KMZ 或 KML 轨迹。控制台支持定位到轨迹起点、暂停与继续、调整回放配速和圈数，也可以查看预计完成时间。

手机无需安装额外 App、越狱或开发者账号。本工具用于定位与轨迹的开发测试，其他 App 是否显示模拟位置取决于各自的处理方式。

## 一、下载 macOS & Windows 版本

- **macOS 2.0.45** · [下载 macOS 安装包（DMG）](https://github.com/Seisen8783/A-Console/releases/download/macos-v2.0.45/A-Console-2.0.45-macOS.dmg)
- **Windows 0.1.5 测试版** · [下载 Windows x64 安装包（EXE）](https://github.com/Seisen8783/A-Console/releases/download/windows-v0.1.5/A-Console-0.1.5-Windows-x64.exe)

macOS 版适用于 Apple 芯片 Mac、macOS 14 或以上，并需要一台运行 iOS 17 或以上的 iPhone。项目现名为 A Console，历史安装包使用 NoReal Console 或 UnReal Console 名称。

Windows 版面向 Windows 11 x64 和 iOS 17.4 或以上。[查看 Windows 安装指南](#四windows-从安装到回放)。

## 二、实现原理

1. **解析轨迹。** 控制台读取 GPX、KML 或 KMZ 中的坐标，并根据轨迹时间戳或设定配速安排回放进度。
2. **建立 USB 会话。** macOS 和 Windows 版共用基于 `pymobiledevice3` 的设备桥接程序，通过 USB 连接已信任此电脑、且已开启开发者模式的 iPhone，访问 iOS 的 DVT 定位模拟服务。
3. **回放与恢复。** 播放时，桥接程序依次向定位模拟服务发送坐标。点击「重置位置」或「恢复真实定位」时，控制台请求清除模拟位置。

更多细节见 [iOS 定位模拟方案](docs/iOS-定位模拟方案.md)。

## 三、macOS 从安装到回放

### 1. 安装控制台

1. 点击上方的新版 DMG 链接，等待下载完成。
2. 在 Mac 的「下载」文件夹中双击 `A-Console-2.0.45-macOS.dmg`。
3. 把窗口里的 **A Console.app** 拖到 **Applications（应用程序）** 文件夹图标上。
4. 打开访达，在左侧点击「应用程序」，找到并打开已安装的应用。
5. 如果 Mac 提示无法验证开发者，这是因为安装包使用临时签名，尚未经过 Apple 公证。确认文件来自本仓库后，可按 [Apple 的说明](https://support.apple.com/zh-cn/102445)在系统设置中选择是否打开。

### 2. 离线启动

安装包内置 Python、USB 设备桥接依赖和便携版 uv，USB 连接使用 macOS 自带的服务。首次打开应用和刷新 USB 设备列表可离线完成。定位模拟优先使用设备上已启用的开发者服务，再检查兼容的本机开发者镜像。缺少镜像或需要 Apple 个性化授权时可能需要联网。

### 3. 准备并连接 iPhone

1. 使用支持数据传输的 USB 数据线将 iPhone 连接到 Mac。
2. 解锁 iPhone。如果手机询问是否信任此电脑，点击「信任」并输入锁屏密码。
3. 在 iPhone 打开「设置 → 隐私与安全性 → 开发者模式」，开启后按提示重启并确认。若看不到此选项，请先在 Mac 的 Xcode 设备窗口确认手机已配对，详见 [Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。
4. 回到控制台，在「USB 设备」旁点击刷新按钮，然后选择你的 iPhone。

### 4. 选择并回放轨迹

1. 「轨迹来源」默认使用内置轨迹。要使用自己的轨迹，选择「本地导入」，然后选择 GPX、KML 或 KMZ 文件；也可以直接把文件拖入预览区域。
2. 默认坐标基准为 **WGS-84**，上报口径为 **原样**。如果你确定导入文件使用其他坐标基准，再在侧栏修改；不确定时先用默认值检查位置。
3. 点击「**接管定位权限**」，等待状态提示已定位到起点，再在手机上检查起点。
4. 根据需要设置配速和「总圈数」或「公里数」，点击「**开始回放**」。右侧显示轨迹进度和预计完成时间。
5. 回放中可点击「暂停」，需要时调整可编辑的配速或圈数，有效设置会自动同步并更新总时长，再点击「继续回放」；也可以拖动时间轴跳转。回放结束后，控制台会尝试把位置移回起点。
6. 使用完毕后，点击「**重置位置**」，向 iPhone 发送恢复真实定位的请求。如果连接中断或状态显示待确认，请重新连接同一台 iPhone 后再重试，并在手机上检查位置。

回放期间请保持 USB 连接。开发者服务连接短暂中断时，控制台会尝试重连同一台 iPhone，从中断处继续。如果重连失败，请检查数据线、解锁手机后重新连接。配速、轨迹数据和手机定位精度也可能影响实际显示。

**校园跑小程序的两条链**：打卡桩只验有没有撞库（刷脸），里程与配速看手机上报的轨迹。所以顺序是——小程序点「开始跑步」→ 起点桩刷脸 → 立刻开始回放 → 沿路每个桩都刷一次。回放期间手机要留在操场上，离开围栏会被标「非校园区域」，中途也不要暂停或拔线。配速按「实际耗时 ÷ 公里数」填，既落在正常跑步区间，又和桩链的时间跨度对得上。完整说明见 [macos/README.md 的「校园跑：桩只验撞库，数据看手机」](macos/README.md)。

## 四、Windows 从安装到回放

Windows 版为测试版，目标环境为 **Windows 11 x64** 和 **iOS 17.4 或以上**，通过 USB 连接。Windows 构建和自动化测试已通过，Windows 与 iPhone 的完整真机流程仍待验收。

### 1. 安装控制台和 USB 组件

1. [下载 A Console 0.1.5 Windows x64 安装包](https://github.com/Seisen8783/A-Console/releases/download/windows-v0.1.5/A-Console-0.1.5-Windows-x64.exe)，双击运行。
2. 如果尚未安装 Apple Mobile Device Service，安装向导会默认选中 **Install Apple device support with iTunes**。安装器会校验并打开 iTunes 安装程序。按提示授予管理员权限，并完成 Apple 安装向导。
3. 离线安装时，提前从 [Apple 下载此版本的 iTunes](https://secure-appldnld.apple.com/itunes12/142-28289-20261026-6acff6c8-72eb-4045-84eb-fd35239ac645/iTunes64Setup.exe)，把原名为 `iTunes64Setup.exe` 的文件和 A Console 安装包放在同一目录。安装器会优先使用本地文件。若同目录没有该文件，安装器会从 Apple 下载。
4. 安装包内置便携版 uv。安装器仅在 PATH 中找不到 uv 时将其放入 A Console 自己的工具目录。

### 2. 连接 iPhone

1. 使用支持数据传输的 USB 线连接 Windows 电脑和 iPhone。解锁手机，轻点「信任」，按提示输入锁屏密码。
2. 在 iPhone 上进入「设置 → 隐私与安全性 → 开发者模式」，开启后按提示重启并确认。若看不到该开关，见 [Windows 控制台说明](windows/README.md)。
3. 在 A Console 点击「刷新 USB」，从列表选择你的 iPhone。首次连接开发者服务可能要联网准备开发者镜像。

### 3. 导入并回放轨迹

1. 启动后会自动预览内置默认轨迹。也可以点击「导入 GPX / KML / KMZ」或拖入轨迹文件，点击「默认轨迹」即可切回。可以用 [20 秒测试轨迹](macos/Tests/Fixtures/sample.gpx) 试跑。GPX 回放需要完整时间戳，缺少时间戳的 KML/KMZ 按设定配速生成时间。
2. 按需设置坐标基准、配速、圈数或目标距离。请在开始回放前完成这些设置。
3. 点击「定位到起点」，在 iPhone 上核对位置，再点「开始回放」。回放期间保持 USB 连接，可暂停、继续或拖动时间轴跳转。
4. 回放结束后会返回轨迹起点。使用完毕后点击「恢复真实定位」，并在 iPhone 上确认。若 USB 已断开，重新连接原 iPhone 再执行恢复。

## 更多信息

- [控制台详细说明](macos/README.md)
- [20 秒测试轨迹](macos/Tests/Fixtures/sample.gpx)
- [控制台方案与实现](docs/macOS-定位回放控制台方案.md)
- [iOS 定位模拟方案](docs/iOS-定位模拟方案.md)
- [历史 macOS 2.0.36 安装包](https://github.com/Seisen8783/A-Console/releases/download/macos-v2.0.36/UnReal-Console-2.0.36-macOS.dmg)
- [历史 macOS 0.2.0 发布页](https://github.com/Seisen8783/A-Console/releases/tag/macos-v0.2.0)
- [历史 Android 版本](https://github.com/Seisen8783/A-Console/releases/tag/v1.0)

## 从源码构建

```bash
./macos/build-app.sh
swift test --package-path macos
"macos/build/A Console.app/Contents/Resources/python/bin/python3" -I -B -m unittest discover -s macos/Tests/Python -v
```

运行 `./macos/build-dmg.sh` 可生成带 Finder 布局的 DMG。构建产物位于 `macos/build/A Console.app`。每次构建会递增仓库根目录中的 `VERSION`。

维护者发布桌面安装包时，使用[双平台发布流程](docs/desktop-release.md)将同一份安装包和 SHA-256 上传到 GitHub 与 Gitee。

## 许可证

MIT，见 [LICENSE](LICENSE)。
