(() => {
  const TOKEN_KEY = "tdt_imagery_tk";
  const SUBDOMAINS = ["0", "1", "2", "3", "4", "5", "6", "7"];

  const tokenInput = document.getElementById("tdtToken");
  const applyBtn = document.getElementById("applyToken");
  const statusEl = document.getElementById("status");
  const modeButtons = Array.from(document.querySelectorAll(".mode-btn"));

  let viewer = null;
  let loadedToken = "";

  const saved = localStorage.getItem(TOKEN_KEY) || "";
  if (saved) tokenInput.value = saved;

  const params = new URLSearchParams(window.location.search);
  const urlToken = params.get("tk");
  if (urlToken) tokenInput.value = urlToken;

  function setStatus(text, type = "") {
    statusEl.textContent = text;
    statusEl.classList.remove("is-error", "is-ok");
    if (type) statusEl.classList.add(type);
  }

  function createTdtProvider(layerName, token) {
    // img_w / cia_w：Web 墨卡托影像与注记
    return new Cesium.UrlTemplateImageryProvider({
      url: `https://t{s}.tianditu.gov.cn/DataServer?T=${layerName}&x={x}&y={y}&l={z}&tk=${token}`,
      subdomains: SUBDOMAINS,
      maximumLevel: 18,
      credit: `天地图 ${layerName}`,
    });
  }

  function ensureViewer() {
    if (viewer) return viewer;

    viewer = new Cesium.Viewer("cesiumContainer", {
      animation: false,
      timeline: false,
      baseLayerPicker: false,
      geocoder: false,
      homeButton: false,
      sceneModePicker: false,
      navigationHelpButton: false,
      fullscreenButton: false,
      infoBox: false,
      selectionIndicator: false,
      imageryProvider: false,
      terrainProvider: new Cesium.EllipsoidTerrainProvider(),
      orderIndependentTranslucency: false,
      contextOptions: {
        webgl: {
          alpha: true,
        },
      },
    });

    viewer.scene.globe.baseColor = Cesium.Color.fromCssColorString("#0b171c");
    viewer.scene.skyAtmosphere.show = true;
    viewer.scene.fog.enabled = true;
    viewer.scene.globe.depthTestAgainstTerrain = false;
    viewer.cesiumWidget.creditContainer.style.display = "none";

    viewer.camera.setView({
      destination: Cesium.Cartesian3.fromDegrees(104.06, 30.67, 1_800_000),
    });

    return viewer;
  }

  function loadImagery(token) {
    const v = ensureViewer();
    v.imageryLayers.removeAll();
    v.imageryLayers.addImageryProvider(createTdtProvider("img_w", token));
    v.imageryLayers.addImageryProvider(createTdtProvider("cia_w", token));
    loadedToken = token;
    localStorage.setItem(TOKEN_KEY, token);
    document.body.classList.add("is-ready");
    setStatus("影像底图已加载，可切换 2D / 3D / 2.5D", "is-ok");
  }

  function syncModeButtons(mode) {
    const key =
      mode === Cesium.SceneMode.SCENE2D
        ? "2D"
        : mode === Cesium.SceneMode.COLUMBUS_VIEW
          ? "CV"
          : "3D";

    modeButtons.forEach((btn) => {
      btn.classList.toggle("is-active", btn.dataset.mode === key);
    });
  }

  function switchMode(mode) {
    const v = ensureViewer();
    const duration = 0.85;

    if (mode === "2D") {
      v.scene.morphTo2D(duration);
    } else if (mode === "CV") {
      v.scene.morphToColumbusView(duration);
    } else {
      v.scene.morphTo3D(duration);
    }

    // morph 结束后再对齐一次按钮状态
    const end = Date.now() + duration * 1000 + 50;
    const tick = () => {
      syncModeButtons(v.scene.mode);
      if (Date.now() < end) requestAnimationFrame(tick);
    };
    tick();

    if (!loadedToken) {
      setStatus("模式已切换；填入 Token 后可加载天地图影像", "");
    } else {
      setStatus(`已切换至 ${mode === "CV" ? "2.5D" : mode} 视图`, "is-ok");
    }
  }

  applyBtn.addEventListener("click", () => {
    const token = tokenInput.value.trim();
    if (!token) {
      setStatus("请先填写天地图 Token（tk）", "is-error");
      tokenInput.focus();
      return;
    }
    try {
      loadImagery(token);
    } catch (err) {
      console.error(err);
      setStatus("加载失败，请检查 Token 或网络", "is-error");
    }
  });

  tokenInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") applyBtn.click();
  });

  modeButtons.forEach((btn) => {
    btn.addEventListener("click", () => switchMode(btn.dataset.mode));
  });

  // 先初始化三维球，便于无 Token 时也能预览模式切换
  ensureViewer();
  syncModeButtons(viewer.scene.mode);

  if (tokenInput.value.trim()) {
    loadImagery(tokenInput.value.trim());
  }
})();
