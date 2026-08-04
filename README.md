# DAC Match

一个针对 Apple Music 的 macOS 菜单栏工具：读取当前曲目的源采样率，并通过 Core Audio 自动匹配指定输出 DAC。

![DAC Match 图标](Resources/AppIcon.png)

## 本地运行

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run --disable-sandbox DACMatch
```

首次读取 Apple Music 时，macOS 会询问是否允许 DAC Match 控制 Music。

## 生成 App

```bash
chmod +x Scripts/package_app.sh
Scripts/package_app.sh
```

如需从母版重新生成 macOS 图标：

```bash
chmod +x Scripts/make_icon.sh
Scripts/make_icon.sh
```

生成结果位于 `outputs/DAC Match.app`。本地构建使用 ad-hoc 签名；若要分发，需要使用 Apple Developer ID 签名并公证。

## 当前范围

- 每 0.4 秒检查一次 Apple Music 当前曲目和播放状态。
- 每 2 秒刷新音频设备并跟随 macOS 默认输出；从菜单选择设备会真正切换系统输出。
- 菜单栏面板保持打开时会实时刷新曲目、源格式、DAC 输出和匹配状态。
- 全新状态卡片界面集中呈现专辑封面、播放状态和采样率路径。
- 面板显示 Apple Music 当前曲目的专辑封面，云端封面尚未就绪时会自动重试加载。
- 通过稳定时间窗口确认 DAC 格式，瞬时读数不再直接判定成功或失败。
- 偶发失败会按退避时间自动重试，并在面板中显示具体失败阶段。
- Apple Music 暂停或停止时会预匹配已选曲目，但不会擅自开始播放。
- 只在曲目变化且采样率不同时修改 DAC。
- 切换前短暂暂停 Apple Music，等待 DAC 锁定新时钟后自动恢复，避免 USB DAC 丢失音频流。
- 切换到 Sony Walkman 时会先暂停 Apple Music，确认系统路由、采样率和实际音频流后再恢复播放；若没有检测到音频流，会自动重建一次，并且不会清空流媒体当前曲目。
- 如果播放器显示正在播放但实际静音，可使用“恢复声音”重建音频流。
- DAC 锁定等待时间可设为 0.5–5 秒，默认 2 秒以兼容 Sony Walkman 等需要较长重锁时间的设备。
- 修改等待时间后会立即允许当前曲目重新匹配；也可使用“立即重新匹配”手动重试。
- 恢复播放后再次验证实时输出采样率，避免界面误报“已匹配”。
- 只进行精确采样率匹配；设备不支持时不会擅自选择近似值。
- 不提供独占模式、DSD/DoP 或系统混音绕过。
