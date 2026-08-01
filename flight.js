/* global Cesium */

window.DroneFlight = (() => {
  const MOVE_SPEED = 28; // m/s
  const CLIMB_SPEED = 10; // m/s
  const YAW_SPEED = Cesium.Math.toRadians(55); // rad/s
  const DEFAULT_AGL = 120; // 起飞后默认相对高度

  function createController(viewer, hooks = {}) {
    const keys = new Set();
    const state = {
      active: false,
      picking: false,
      takeoff: null, // { lon, lat, height }
      drone: null, // { lon, lat, height, heading }
      lookH: 0,
      lookP: -0.45,
      dragging: false,
      lastX: 0,
      lastY: 0,
      tipTimer: null,
    };

    const entities = {
      takeoff: null,
      drone: null,
      tether: null,
      fov: null,
    };

    const canvas = viewer.scene.canvas;
    let removeTick = null;
    let removeClick = null;

    function emit(name, payload) {
      if (typeof hooks[name] === "function") hooks[name](payload);
    }

    async function sampleHeight(lon, lat) {
      const carto = Cesium.Cartographic.fromDegrees(lon, lat);
      try {
        const updated = await viewer.scene.sampleHeightMostDetailed([carto]);
        if (updated[0] && Number.isFinite(updated[0].height)) {
          return updated[0].height;
        }
      } catch (_) {
        /* fall through */
      }

      const h = viewer.scene.globe.getHeight(carto);
      if (Number.isFinite(h)) return h;

      try {
        await viewer.terrainProvider.readyPromise;
      } catch (_) {
        /* ignore */
      }
      return 0;
    }

    function clearEntity(key) {
      if (entities[key]) {
        viewer.entities.remove(entities[key]);
        entities[key] = null;
      }
    }

    function clearFlightEntities() {
      clearEntity("drone");
      clearEntity("tether");
      clearEntity("fov");
    }

    function setTakeoffVisual(lon, lat, height) {
      clearEntity("takeoff");
      const ground = Cesium.Cartesian3.fromDegrees(lon, lat, height);
      entities.takeoff = viewer.entities.add({
        position: ground,
        point: {
          pixelSize: 14,
          color: Cesium.Color.fromCssColorString("#f5c542"),
          outlineColor: Cesium.Color.WHITE,
          outlineWidth: 2,
          disableDepthTestDistance: Number.POSITIVE_INFINITY,
        },
        label: {
          text: "起飞点",
          font: "600 14px Outfit, sans-serif",
          fillColor: Cesium.Color.fromCssColorString("#f5e6b8"),
          outlineColor: Cesium.Color.BLACK,
          outlineWidth: 3,
          style: Cesium.LabelStyle.FILL_AND_OUTLINE,
          pixelOffset: new Cesium.Cartesian2(0, -22),
          disableDepthTestDistance: Number.POSITIVE_INFINITY,
        },
      });
    }

    function dronePositionProperty() {
      return new Cesium.CallbackProperty(() => {
        if (!state.drone) return Cesium.Cartesian3.ZERO;
        const { lon, lat, height } = state.drone;
        return Cesium.Cartesian3.fromDegrees(lon, lat, height);
      }, false);
    }

    function droneOrientationProperty() {
      return new Cesium.CallbackProperty(() => {
        if (!state.drone) return Cesium.Quaternion.IDENTITY;
        const { lon, lat, height, heading } = state.drone;
        const hpr = new Cesium.HeadingPitchRoll(heading, 0, 0);
        return Cesium.Transforms.headingPitchRollQuaternion(
          Cesium.Cartesian3.fromDegrees(lon, lat, height),
          hpr
        );
      }, false);
    }

    function ensureFlightEntities() {
      if (entities.drone) return;

      entities.drone = viewer.entities.add({
        position: dronePositionProperty(),
        orientation: droneOrientationProperty(),
        point: {
          pixelSize: 16,
          color: Cesium.Color.fromCssColorString("#3aa0ff"),
          outlineColor: Cesium.Color.WHITE,
          outlineWidth: 2,
          disableDepthTestDistance: Number.POSITIVE_INFINITY,
        },
        billboard: {
          image: createArrowCanvas(),
          width: 42,
          height: 42,
          alignedAxis: Cesium.Cartesian3.UNIT_Z,
          rotation: new Cesium.CallbackProperty(() => {
            return state.drone ? -state.drone.heading : 0;
          }, false),
          disableDepthTestDistance: Number.POSITIVE_INFINITY,
        },
      });

      entities.tether = viewer.entities.add({
        polyline: {
          positions: new Cesium.CallbackProperty(() => {
            if (!state.takeoff || !state.drone) return [];
            return [
              Cesium.Cartesian3.fromDegrees(
                state.takeoff.lon,
                state.takeoff.lat,
                state.takeoff.height
              ),
              Cesium.Cartesian3.fromDegrees(
                state.drone.lon,
                state.drone.lat,
                state.drone.height
              ),
            ];
          }, false),
          width: 2,
          material: Cesium.Color.fromCssColorString("#f5c542").withAlpha(0.95),
          clampToGround: false,
        },
      });

      // 简易前视视场锥：前进方向半透明扇面
      entities.fov = viewer.entities.add({
        polygon: {
          hierarchy: new Cesium.CallbackProperty(() => {
            if (!state.drone) return new Cesium.PolygonHierarchy([]);
            const { lon, lat, height, heading } = state.drone;
            const range = 180;
            const half = Cesium.Math.toRadians(28);
            const left = destination(lon, lat, height, heading - half, range);
            const right = destination(lon, lat, height, heading + half, range);
            const tip = destination(lon, lat, height - 8, heading, range * 0.15);
            return new Cesium.PolygonHierarchy([
              Cesium.Cartesian3.fromDegrees(lon, lat, height),
              left,
              tip,
              right,
            ]);
          }, false),
          material: Cesium.Color.fromCssColorString("#5dff9a").withAlpha(0.22),
          outline: true,
          outlineColor: Cesium.Color.fromCssColorString("#5dff9a").withAlpha(0.65),
          perPositionHeight: true,
        },
      });
    }

    function createArrowCanvas() {
      const c = document.createElement("canvas");
      c.width = 64;
      c.height = 64;
      const ctx = c.getContext("2d");
      ctx.translate(32, 32);
      ctx.fillStyle = "#3aa0ff";
      ctx.strokeStyle = "#ffffff";
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.moveTo(0, -22);
      ctx.lineTo(16, 18);
      ctx.lineTo(0, 10);
      ctx.lineTo(-16, 18);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();
      return c.toDataURL();
    }

    function destination(lon, lat, height, heading, distance) {
      const start = Cesium.Cartesian3.fromDegrees(lon, lat, height);
      const enu = Cesium.Transforms.eastNorthUpToFixedFrame(start);
      const local = new Cesium.Cartesian3(
        Math.sin(heading) * distance,
        Math.cos(heading) * distance,
        0
      );
      return Cesium.Matrix4.multiplyByPoint(enu, local, new Cesium.Cartesian3());
    }

    function moveHorizontal(dt, forward, strafe) {
      if (!forward && !strafe) return;
      const { lon, lat, height, heading } = state.drone;
      const start = Cesium.Cartesian3.fromDegrees(lon, lat, height);
      const enu = Cesium.Transforms.eastNorthUpToFixedFrame(start);
      const dx = (Math.sin(heading) * forward + Math.sin(heading + Math.PI / 2) * strafe) * MOVE_SPEED * dt;
      const dy = (Math.cos(heading) * forward + Math.cos(heading + Math.PI / 2) * strafe) * MOVE_SPEED * dt;
      const local = new Cesium.Cartesian3(dx, dy, 0);
      const next = Cesium.Matrix4.multiplyByPoint(enu, local, new Cesium.Cartesian3());
      const c = Cesium.Cartographic.fromCartesian(next);
      state.drone.lon = Cesium.Math.toDegrees(c.longitude);
      state.drone.lat = Cesium.Math.toDegrees(c.latitude);
    }

    function updateCamera() {
      if (!state.drone) return;
      const { lon, lat, height } = state.drone;
      const target = Cesium.Cartesian3.fromDegrees(lon, lat, height);
      const range = 220;
      viewer.camera.lookAt(
        target,
        new Cesium.HeadingPitchRange(state.lookH, state.lookP, range)
      );
    }

    let lastTickMs = 0;

    function onTick() {
      if (!state.active || !state.drone) return;
      const now = performance.now();
      const dt = lastTickMs ? Math.min((now - lastTickMs) / 1000, 0.05) : 1 / 60;
      lastTickMs = now;

      let forward = 0;
      let strafe = 0;
      if (keys.has("KeyW")) forward += 1;
      if (keys.has("KeyS")) forward -= 1;
      if (keys.has("KeyA")) strafe -= 1;
      if (keys.has("KeyD")) strafe += 1;
      if (keys.has("KeyQ")) state.drone.heading -= YAW_SPEED * dt;
      if (keys.has("KeyE")) state.drone.heading += YAW_SPEED * dt;
      if (keys.has("KeyC")) state.drone.height += CLIMB_SPEED * dt;
      if (keys.has("KeyZ")) state.drone.height -= CLIMB_SPEED * dt;

      // 不低于起飞点上方 2m
      const minH = (state.takeoff?.height || 0) + 2;
      if (state.drone.height < minH) state.drone.height = minH;

      moveHorizontal(dt, forward, strafe);

      // 机头转向时，环顾方位跟随航向，保留相对偏移感：lookH 对齐航向
      if (!state.dragging) {
        state.lookH = state.drone.heading;
      }

      updateCamera();
      emit("telemetry", getTelemetry());
    }

    function getTelemetry() {
      if (!state.drone || !state.takeoff) return null;
      const altRel = state.drone.height - state.takeoff.height;
      const ground = Cesium.Cartesian3.fromDegrees(
        state.takeoff.lon,
        state.takeoff.lat,
        state.takeoff.height
      );
      const air = Cesium.Cartesian3.fromDegrees(
        state.drone.lon,
        state.drone.lat,
        state.drone.height
      );
      const dist = Cesium.Cartesian3.distance(ground, air);
      return {
        altRel,
        asl: state.drone.height,
        dist,
        headingDeg: Cesium.Math.toDegrees(state.drone.heading),
        pitchDeg: Cesium.Math.toDegrees(state.lookP),
      };
    }

    function bindInput() {
      const onKeyDown = (e) => {
        if (!state.active) return;
        keys.add(e.code);
        if (["KeyW", "KeyA", "KeyS", "KeyD", "KeyQ", "KeyE", "KeyC", "KeyZ"].includes(e.code)) {
          e.preventDefault();
        }
      };
      const onKeyUp = (e) => keys.delete(e.code);

      const onDown = (e) => {
        if (!state.active) return;
        state.dragging = true;
        state.lastX = e.clientX;
        state.lastY = e.clientY;
        emit("lookTip", false);
      };
      const onMove = (e) => {
        if (!state.active || !state.dragging) return;
        const dx = e.clientX - state.lastX;
        const dy = e.clientY - state.lastY;
        state.lastX = e.clientX;
        state.lastY = e.clientY;
        state.lookH += dx * 0.005;
        state.lookP = Cesium.Math.clamp(state.lookP - dy * 0.004, -1.2, -0.08);
      };
      const onUp = () => {
        state.dragging = false;
      };

      window.addEventListener("keydown", onKeyDown);
      window.addEventListener("keyup", onKeyUp);
      canvas.addEventListener("pointerdown", onDown);
      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onUp);

      return () => {
        window.removeEventListener("keydown", onKeyDown);
        window.removeEventListener("keyup", onKeyUp);
        canvas.removeEventListener("pointerdown", onDown);
        window.removeEventListener("pointermove", onMove);
        window.removeEventListener("pointerup", onUp);
      };
    }

    let unbindInput = null;

    async function setTakeoffFromClick(lon, lat) {
      const height = await sampleHeight(lon, lat);
      state.takeoff = { lon, lat, height };
      setTakeoffVisual(lon, lat, height);

      // 立体斜视靠近起飞点
      viewer.camera.flyTo({
        destination: Cesium.Cartesian3.fromDegrees(lon, lat, height + 550),
        orientation: {
          heading: Cesium.Math.toRadians(30),
          pitch: Cesium.Math.toRadians(-35),
          roll: 0,
        },
        duration: 1.2,
      });

      emit("takeoff", { ...state.takeoff });
      return state.takeoff;
    }

    function beginPick() {
      stopFlight();
      state.picking = true;
      canvas.style.cursor = "crosshair";
      emit("picking", true);

      if (removeClick) {
        removeClick();
        removeClick = null;
      }

      const handler = viewer.screenSpaceEventHandler;
      handler.setInputAction(async (click) => {
        const ray = viewer.camera.getPickRay(click.position);
        const cartesian = viewer.scene.globe.pick(ray, viewer.scene);
        if (!cartesian) {
          emit("status", { text: "未点中地表，请再试一次", type: "is-error" });
          return;
        }
        const c = Cesium.Cartographic.fromCartesian(cartesian);
        const lon = Cesium.Math.toDegrees(c.longitude);
        const lat = Cesium.Math.toDegrees(c.latitude);
        await setTakeoffFromClick(lon, lat);
        endPick();
      }, Cesium.ScreenSpaceEventType.LEFT_CLICK);

      removeClick = () => {
        handler.removeInputAction(Cesium.ScreenSpaceEventType.LEFT_CLICK);
      };
    }

    function endPick() {
      state.picking = false;
      canvas.style.cursor = "";
      if (removeClick) {
        removeClick();
        removeClick = null;
      }
      emit("picking", false);
    }

    async function startFlight() {
      if (!state.takeoff) {
        emit("status", { text: "请先设置起飞点", type: "is-error" });
        return false;
      }
      if (viewer.scene.mode !== Cesium.SceneMode.SCENE3D) {
        viewer.scene.morphTo3D(0.6);
      }

      endPick();
      const { lon, lat, height } = state.takeoff;
      // 起飞后刷新一次地面高，减少地形流加载误差
      const ground = await sampleHeight(lon, lat);
      state.takeoff.height = ground;
      setTakeoffVisual(lon, lat, ground);

      state.drone = {
        lon,
        lat,
        height: ground + DEFAULT_AGL,
        heading: Cesium.Math.toRadians(40),
      };
      state.lookH = state.drone.heading;
      state.lookP = -0.42;
      state.active = true;

      ensureFlightEntities();
      viewer.scene.screenSpaceCameraController.enableInputs = false;
      lastTickMs = 0;
      unbindInput = bindInput();
      removeTick = viewer.clock.onTick.addEventListener(onTick);
      updateCamera();
      emit("flight", true);
      emit("lookTip", true);
      if (state.tipTimer) clearTimeout(state.tipTimer);
      state.tipTimer = setTimeout(() => emit("lookTip", false), 4500);
      return true;
    }

    function stopFlight() {
      if (!state.active && !entities.drone) {
        state.active = false;
        return;
      }
      state.active = false;
      keys.clear();
      clearFlightEntities();
      state.drone = null;
      viewer.camera.lookAtTransform(Cesium.Matrix4.IDENTITY);
      viewer.scene.screenSpaceCameraController.enableInputs = true;
      if (unbindInput) {
        unbindInput();
        unbindInput = null;
      }
      if (removeTick) {
        removeTick();
        removeTick = null;
      }
      if (state.tipTimer) {
        clearTimeout(state.tipTimer);
        state.tipTimer = null;
      }
      emit("flight", false);
      emit("lookTip", false);
    }

    return {
      beginPick,
      endPick,
      startFlight,
      stopFlight,
      sampleHeight,
      getTakeoff: () => (state.takeoff ? { ...state.takeoff } : null),
      isActive: () => state.active,
      isPicking: () => state.picking,
    };
  }

  return { createController };
})();
