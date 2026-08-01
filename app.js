(() => {
  const TOKEN_KEY = "tdt_imagery_tk";
  const SUBDOMAINS = ["0", "1", "2", "3", "4", "5", "6", "7"];
  const TERRAIN_URL =
    "https://elevation3d.arcgis.com/arcgis/rest/services/WorldElevation3D/Terrain3D/ImageServer";

  const tokenInput = document.getElementById("tdtToken");
  const applyBtn = document.getElementById("applyToken");
  const statusEl = document.getElementById("status");
  const modeButtons = Array.from(document.querySelectorAll(".mode-btn"));
  const pickBtn = document.getElementById("pickTakeoff");
  const flightBtn = document.getElementById("toggleFlight");
  const endFlightBtn = document.getElementById("endFlight");
  const takeoffMeta = document.getElementById("takeoffMeta");
  const hud = document.getElementById("flightHud");
  const brand = document.getElementById("brand");
  const panel = document.getElementById("panel");
  const lookTip = document.getElementById("lookTip");
  const altRelEl = document.getElementById("altRel");
  const altAslEl = document.getElementById("altAsl");
  const groundDistEl = document.getElementById("groundDist");
  const compassRing = document.getElementById("compassRing");
  const pitchReadout = document.getElementById("pitchReadout");

  let viewer = null;
  let loadedToken = "";
  let flight = null;
  let terrainReady = false;

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
    return new Cesium.UrlTemplateImageryProvider({
      url: `https://t{s}.tianditu.gov.cn/DataServer?T=${layerName}&x={x}&y={y}&l={z}&tk=${token}`,
      subdomains: SUBDOMAINS,
      maximumLevel: 18,
      credit: `天地图 ${layerName}`,
    });
  }

  async function enableTerrain() {
    try {
      const provider = await Cesium.ArcGISTiledElevationTerrainProvider.fromUrl(TERRAIN_URL);
      viewer.terrainProvider = provider;
      terrainReady = true;
      viewer.scene.globe.depthTestAgainstTerrain = true;
    } catch (err) {
      console.warn("地形服务加载失败，海拔将回退为椭球高", err);
      terrainReady = false;
      viewer.terrainProvider = new Cesium.EllipsoidTerrainProvider();
    }
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
      baseLayer: false,
      terrainProvider: new Cesium.EllipsoidTerrainProvider(),
      orderIndependentTranslucency: false,
      requestRenderMode: false,
      contextOptions: {
        webgl: { alpha: true },
      },
    });

    viewer.imageryLayers.removeAll();
    viewer.scene.globe.baseColor = Cesium.Color.fromCssColorString("#1c2f38");
    viewer.scene.globe.enableLighting = false;
    viewer.scene.skyAtmosphere.show = true;
    viewer.scene.fog.enabled = true;
    viewer.cesiumWidget.creditContainer.style.display = "none";

    viewer.camera.setView({
      destination: Cesium.Cartesian3.fromDegrees(123.38, 41.8, 1800),
      orientation: {
        heading: Cesium.Math.toRadians(20),
        pitch: Cesium.Math.toRadians(-28),
        roll: 0,
      },
    });

    flight = window.DroneFlight.createController(viewer, {
      takeoff: (pt) => {
        renderTakeoffMeta(pt);
        flightBtn.disabled = false;
        setStatus(
          `起飞点已设置：海拔 ${pt.height.toFixed(1)} m（ASL）`,
          "is-ok"
        );
      },
      picking: (on) => {
        pickBtn.classList.toggle("is-active", on);
        pickBtn.textContent = on ? "点选中…再点取消" : "设置起飞点";
        if (on) setStatus("请在影像上点击设置起飞点", "");
      },
      flight: (on) => {
        document.body.classList.toggle("is-flying", on);
        hud.hidden = !on;
        brand.hidden = on;
        panel.hidden = on;
        flightBtn.textContent = on ? "结束虚拟飞行" : "开始虚拟飞行";
        flightBtn.classList.toggle("is-danger", on);
        if (on) {
          setStatus("虚拟飞行中：WASD 平移，QE 转向，CZ 升降", "is-ok");
        } else if (flight.getTakeoff()) {
          setStatus("已结束虚拟飞行", "is-ok");
          // 飞回起飞点附近斜视
          const t = flight.getTakeoff();
          viewer.camera.flyTo({
            destination: Cesium.Cartesian3.fromDegrees(t.lon, t.lat, t.height + 600),
            orientation: {
              heading: Cesium.Math.toRadians(25),
              pitch: Cesium.Math.toRadians(-40),
              roll: 0,
            },
            duration: 1.1,
          });
        }
      },
      lookTip: (show) => {
        lookTip.classList.toggle("is-visible", !!show);
      },
      telemetry: (t) => {
        if (!t) return;
        altRelEl.textContent = t.altRel.toFixed(1);
        altAslEl.textContent = t.asl.toFixed(1);
        groundDistEl.textContent = `${t.dist.toFixed(1)}m`;
        pitchReadout.textContent = `${Math.abs(t.pitchDeg).toFixed(1)}°`;
        compassRing.style.transform = `rotate(${-t.headingDeg}deg)`;
      },
      status: ({ text, type }) => setStatus(text, type),
    });

    enableTerrain();
    return viewer;
  }

  function renderTakeoffMeta(pt) {
    takeoffMeta.innerHTML = `
      <p><span>经度</span><strong>${pt.lon.toFixed(6)}°</strong></p>
      <p><span>纬度</span><strong>${pt.lat.toFixed(6)}°</strong></p>
      <p><span>海拔 ASL</span><strong>${pt.height.toFixed(1)} m</strong>
        ${terrainReady ? "" : "<em>（椭球近似）</em>"}
      </p>
    `;
  }

  function loadImagery(token) {
    const v = ensureViewer();
    v.imageryLayers.removeAll();
    v.imageryLayers.addImageryProvider(createTdtProvider("img_w", token));
    v.imageryLayers.addImageryProvider(createTdtProvider("cia_w", token));
    loadedToken = token;
    localStorage.setItem(TOKEN_KEY, token);
    document.body.classList.add("is-ready");
    setStatus("影像已加载。建议 3D 下设置起飞点并开始虚拟飞行", "is-ok");
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
    if (flight?.isActive()) {
      setStatus("请先结束虚拟飞行再切换场景模式", "is-error");
      return;
    }

    const v = ensureViewer();
    const duration = 0.85;
    if (mode === "2D") v.scene.morphTo2D(duration);
    else if (mode === "CV") v.scene.morphToColumbusView(duration);
    else v.scene.morphTo3D(duration);

    const end = Date.now() + duration * 1000 + 50;
    const tick = () => {
      syncModeButtons(v.scene.mode);
      if (Date.now() < end) requestAnimationFrame(tick);
    };
    tick();

    if (!loadedToken) setStatus("模式已切换；填入 Token 后可加载天地图影像", "");
    else setStatus(`已切换至 ${mode === "CV" ? "2.5D" : mode} 视图`, "is-ok");
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

  pickBtn.addEventListener("click", () => {
    ensureViewer();
    if (flight.isPicking()) {
      flight.endPick();
      setStatus("已取消起飞点点选", "");
      return;
    }
    if (viewer.scene.mode !== Cesium.SceneMode.SCENE3D) {
      switchMode("3D");
    }
    flight.beginPick();
  });

  flightBtn.addEventListener("click", async () => {
    ensureViewer();
    if (flight.isActive()) {
      flight.stopFlight();
      return;
    }
    await flight.startFlight();
  });

  endFlightBtn.addEventListener("click", () => {
    if (flight?.isActive()) flight.stopFlight();
  });

  ensureViewer();
  syncModeButtons(viewer.scene.mode);

  if (tokenInput.value.trim()) {
    loadImagery(tokenInput.value.trim());
  } else {
    setStatus("可先加载影像，或直接在 3D 中设置起飞点体验虚拟飞行", "");
  }
})();
