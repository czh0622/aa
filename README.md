# 天地图影像 · 2D / 3D 切换示例

基于 **Cesium** 加载天地图影像底图（`img_w`）与注记（`cia_w`），并在同一场景中切换 **3D / 2D / 2.5D（哥伦布视图）**。

## 快速开始

1. 在 [天地图控制台](https://console.tianditu.gov.cn/) 申请浏览器端 `tk`
2. 在项目根目录启动本地静态服务：

```bash
python3 -m http.server 8080
```

3. 打开 `http://localhost:8080`
4. 在页面右下角填入 Token，点击「加载影像底图」
5. 使用 **3D / 2D / 2.5D** 按钮切换场景模式

也可通过 URL 传参：`http://localhost:8080/?tk=你的token`

## 实现要点

- 天地图提供的是 **WMTS / 瓦片影像服务**，本身不是 3D 引擎
- 用 Cesium 承载影像图层后，通过：
  - `viewer.scene.morphTo3D()`
  - `viewer.scene.morphTo2D()`
  - `viewer.scene.morphToColumbusView()`
  完成模式切换
- Token 会缓存在 `localStorage`（键名 `tdt_imagery_tk`）

## 文件

| 文件 | 说明 |
| --- | --- |
| `index.html` | 页面结构 |
| `styles.css` | 样式 |
| `app.js` | Cesium 初始化、天地图加载、模式切换 |
