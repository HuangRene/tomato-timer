# TomatoTimer 🍅

macOS 選單列蕃茄鐘。一顆浮在所有視窗上層的果凍蕃茄：滑上去會 QQ 彈開成剖面，四個果室就是 15／30／45／60 分鐘，中間果核控制開始、暫停、重來。時間到會抖動加響鈴，點一下進入 10 分鐘休息（變綠），休息完再提醒。

- 選單列顯示剩餘時間（`🍅 24:13`、休息中 `🌿 08:42`）
- 左鍵點選單列圖示：顯示／隱藏蕃茄；右鍵：開機自動啟動、結束
- 蕃茄可以拖曳，會記住位置

## 需求

macOS 13 以上、Swift 5.9 以上（只要 Command Line Tools，不需要 Xcode）。

## 編譯與安裝

```bash
scripts/build-app.sh   # 產出 build/TomatoTimer.app
scripts/install.sh     # 編譯、複製到 /Applications 並開啟（第一次從這裡開會設定開機自動啟動）
```

測試用參數：`open build/TomatoTimer.app --args --fast --show --start`
（`--fast` 讓 1 分鐘 = 1 秒、`--show` 開啟時直接顯示蕃茄、`--start` 直接開始倒數）

## 專案結構

| 檔案 | 內容 |
|---|---|
| `Sources/TomatoTimer/TimerEngine.swift` | 計時狀態機（工作／休息、以結束時間計算，睡眠喚醒後仍準確） |
| `Sources/TomatoTimer/JellyTomatoView.swift` | 果凍蕃茄的繪製、彈簧物理、滑鼠互動 |
| `Sources/TomatoTimer/FloatingPanel.swift` | 浮動視窗、放大縮小時的視窗尺寸、拖曳與位置記憶 |
| `Sources/TomatoTimer/StatusBarController.swift` | 選單列圖示與選單 |
| `prototype/jelly-tomato.html` | 果凍蕃茄的網頁原型（調整手感用） |
