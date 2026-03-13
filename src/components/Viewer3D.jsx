import { useEffect, useRef, useImperativeHandle, forwardRef, useCallback, useState } from 'react';
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { CSS2DRenderer } from 'three/addons/renderers/CSS2DRenderer.js';
import { MeasureTool } from '../utils/measureTool';
import { getModelBounds } from '../utils/loaders';

const Viewer3D = forwardRef(function Viewer3D(
  { onDrop, onMeasure, onContextAction, showGrid, autoRotate, pointSize },
  ref
) {
  const containerRef = useRef(null);
  const sceneRef = useRef(null);
  const cameraRef = useRef(null);
  const rendererRef = useRef(null);
  const labelRendererRef = useRef(null);
  const controlsRef = useRef(null);
  const measureToolRef = useRef(null);
  const modelRef = useRef(null);
  const gridRef = useRef(null);
  const frameIdRef = useRef(null);
  const lightGroupRef = useRef(null);
  const mousePosRef = useRef(new THREE.Vector2());
  const zoomRaycasterRef = useRef(new THREE.Raycaster());

  // Context menu state
  const [contextMenu, setContextMenu] = useState(null);

  // Initialize Three.js scene
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    // Scene
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x0d1117);
    scene.fog = new THREE.FogExp2(0x0d1117, 0.002);
    sceneRef.current = scene;

    // Camera
    const camera = new THREE.PerspectiveCamera(
      50,
      container.clientWidth / container.clientHeight,
      0.01,
      1000
    );
    camera.position.set(3, 2, 3);
    cameraRef.current = camera;

    // Renderer
    const renderer = new THREE.WebGLRenderer({
      antialias: true,
      alpha: false,
      powerPreference: 'high-performance',
    });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setSize(container.clientWidth, container.clientHeight);
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.6;
    container.appendChild(renderer.domElement);
    rendererRef.current = renderer;

    // CSS2D Renderer (for measurement labels)
    const labelRenderer = new CSS2DRenderer();
    labelRenderer.setSize(container.clientWidth, container.clientHeight);
    labelRenderer.domElement.style.position = 'absolute';
    labelRenderer.domElement.style.top = '0';
    labelRenderer.domElement.style.left = '0';
    labelRenderer.domElement.style.pointerEvents = 'none';
    container.appendChild(labelRenderer.domElement);
    labelRendererRef.current = labelRenderer;

    // Controls
    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;
    controls.rotateSpeed = 0.8;
    controls.panSpeed = 0.8;
    controls.zoomSpeed = 1.2;
    controls.minDistance = 0.05;
    controls.maxDistance = 500;
    controls.target.set(0, 0, 0);

    // ── Mouse button remapping ──
    // Left = orbit, Middle = pan, Right = free (for context menu)
    controls.mouseButtons = {
      LEFT: THREE.MOUSE.ROTATE,
      MIDDLE: THREE.MOUSE.PAN,
      RIGHT: -1,
    };
    // Also support two-finger pan on trackpad
    controls.touches = {
      ONE: THREE.TOUCH.ROTATE,
      TWO: THREE.TOUCH.DOLLY_PAN,
    };

    controlsRef.current = controls;

    // Lighting
    const lightGroup = new THREE.Group();
    lightGroupRef.current = lightGroup;

    const ambient = new THREE.AmbientLight(0xffffff, 1.8);
    lightGroup.add(ambient);

    const hemi = new THREE.HemisphereLight(0xffffff, 0xb97a20, 0.6);
    lightGroup.add(hemi);

    const dirLight = new THREE.DirectionalLight(0xffffff, 1.2);
    dirLight.position.set(5, 10, 5);
    lightGroup.add(dirLight);

    const dirLight2 = new THREE.DirectionalLight(0xffffff, 0.8);
    dirLight2.position.set(-5, 6, -5);
    lightGroup.add(dirLight2);

    const dirLight3 = new THREE.DirectionalLight(0xffffff, 0.5);
    dirLight3.position.set(0, -5, 0);
    lightGroup.add(dirLight3);

    scene.add(lightGroup);

    // Grid
    const grid = new THREE.GridHelper(20, 40, 0x30363d, 0x21262d);
    grid.material.transparent = true;
    grid.material.opacity = 0.6;
    gridRef.current = grid;
    scene.add(grid);

    // Measure tool
    const measureTool = new MeasureTool(scene, camera, renderer);
    measureToolRef.current = measureTool;

    // ── Track mouse position (for zoom-to-cursor pivot) ──
    const mousePos = mousePosRef.current;
    const onMouseMove = (event) => {
      const rect = renderer.domElement.getBoundingClientRect();
      mousePos.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
      mousePos.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;
    };
    renderer.domElement.addEventListener('mousemove', onMouseMove);

    // ── Dynamic orbit pivot on scroll zoom (session-based) ──
    //
    // How it works:
    //   1. First scroll of a new session → raycast from cursor to model
    //      surface and record the hit as `currentAnchor`.
    //   2. On EVERY scroll tick, controls.target is lerped toward
    //      currentAnchor by a small factor (LERP_FACTOR). Because the
    //      camera is actively moving (OrbitControls dolly), this gradual
    //      drift is imperceptible — no visible snap or jump.
    //   3. Over ~20 ticks of scrolling the target converges to the anchor.
    //      When the user finishes scrolling and starts orbiting/panning,
    //      the pivot is already where they expect it.
    //   4. A new session starts when:
    //        a. The user pauses scrolling for ZOOM_IDLE_MS, OR
    //        b. The mouse has moved > MOUSE_THRESHOLD (NDC) from the
    //           last anchor position before scrolling again.
    //
    const zoomRaycaster = zoomRaycasterRef.current;
    zoomRaycaster.params.Points.threshold = 0.05;

    const MOUSE_THRESHOLD = 0.15; // ~7.5 % of viewport width in NDC
    const ZOOM_IDLE_MS = 1500;    // ms of no-scroll before session expires
    const LERP_FACTOR = 0.12;     // target drift per scroll tick

    let zoomSessionActive = false;
    let zoomSessionTimer = null;
    const zoomAnchorNDC = new THREE.Vector2(Infinity, Infinity);
    let currentAnchor = null;

    const onWheel = () => {
      if (!modelRef.current) return;

      const movedFarEnough =
        mousePos.distanceTo(zoomAnchorNDC) > MOUSE_THRESHOLD;
      const isNewSession = !zoomSessionActive || movedFarEnough;

      if (isNewSession) {
        zoomRaycaster.setFromCamera(mousePos, camera);
        const targets = [];
        modelRef.current.traverse((child) => {
          if (child.isMesh || child.isPoints) targets.push(child);
        });
        const hits = zoomRaycaster.intersectObjects(targets, false);
        if (hits.length > 0) {
          currentAnchor = hits[0].point.clone();
          zoomAnchorNDC.copy(mousePos);
        }
      }

      // Gradually drift the orbit target toward the anchor while the
      // user is actively scrolling. Each tick shifts by only 12 % of
      // the remaining distance — completely masked by zoom motion.
      if (currentAnchor) {
        controls.target.lerp(currentAnchor, LERP_FACTOR);
      }

      zoomSessionActive = true;
      clearTimeout(zoomSessionTimer);
      zoomSessionTimer = setTimeout(() => {
        zoomSessionActive = false;
      }, ZOOM_IDLE_MS);
    };
    renderer.domElement.addEventListener('wheel', onWheel, { passive: true });

    // ── Right-click context menu ──
    const onContextMenu = (event) => {
      event.preventDefault();
      // Close any existing context menu first
      setContextMenu(null);
      // Calculate position relative to the container
      const rect = container.getBoundingClientRect();
      const x = event.clientX - rect.left;
      const y = event.clientY - rect.top;

      // Raycast to see if we right-clicked on the model
      const rc = new THREE.Raycaster();
      rc.params.Points.threshold = 0.05;
      const m = new THREE.Vector2(
        ((event.clientX - rect.left) / rect.width) * 2 - 1,
        -((event.clientY - rect.top) / rect.height) * 2 + 1
      );
      rc.setFromCamera(m, camera);

      let hitPoint = null;
      if (modelRef.current) {
        const meshes = [];
        modelRef.current.traverse((child) => {
          if (child.isMesh || child.isPoints) meshes.push(child);
        });
        const hits = rc.intersectObjects(meshes, false);
        if (hits.length > 0) hitPoint = hits[0].point.clone();
      }

      // Show context menu after a microtask so React batches properly
      requestAnimationFrame(() => {
        setContextMenu({ x, y, hitPoint });
      });
    };
    renderer.domElement.addEventListener('contextmenu', onContextMenu);

    // Animation loop
    function animate() {
      frameIdRef.current = requestAnimationFrame(animate);
      controls.update();

      // Scale measurement markers based on camera distance
      if (measureTool.measurements.length > 0) {
        const dist = camera.position.distanceTo(controls.target);
        measureTool.updateMarkerScale(dist);
      }

      renderer.render(scene, camera);
      labelRenderer.render(scene, camera);
    }
    animate();

    // Resize handler
    const onResize = () => {
      const w = container.clientWidth;
      const h = container.clientHeight;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
      labelRenderer.setSize(w, h);
    };
    const resizeObserver = new ResizeObserver(onResize);
    resizeObserver.observe(container);

    return () => {
      resizeObserver.disconnect();
      cancelAnimationFrame(frameIdRef.current);
      clearTimeout(zoomSessionTimer);
      renderer.domElement.removeEventListener('mousemove', onMouseMove);
      renderer.domElement.removeEventListener('wheel', onWheel);
      renderer.domElement.removeEventListener('contextmenu', onContextMenu);
      measureTool.dispose();
      controls.dispose();
      renderer.dispose();
      container.removeChild(renderer.domElement);
      container.removeChild(labelRenderer.domElement);
    };
  }, []);

  // Update grid visibility
  useEffect(() => {
    if (gridRef.current) {
      gridRef.current.visible = showGrid;
    }
  }, [showGrid]);

  // Update auto rotate
  useEffect(() => {
    if (controlsRef.current) {
      controlsRef.current.autoRotate = autoRotate;
      controlsRef.current.autoRotateSpeed = 1.5;
    }
  }, [autoRotate]);

  // Update point size
  useEffect(() => {
    if (modelRef.current) {
      modelRef.current.traverse((child) => {
        if (child.isPoints && child.material) {
          child.material.size = pointSize;
        }
      });
    }
  }, [pointSize]);

  // Forward measure callback
  useEffect(() => {
    if (measureToolRef.current) {
      measureToolRef.current.onMeasure = onMeasure;
    }
  }, [onMeasure]);

  // Close context menu on any click outside
  useEffect(() => {
    if (!contextMenu) return;
    const close = () => setContextMenu(null);
    window.addEventListener('click', close);
    window.addEventListener('wheel', close, { passive: true });
    return () => {
      window.removeEventListener('click', close);
      window.removeEventListener('wheel', close);
    };
  }, [contextMenu]);

  // Expose methods to parent
  useImperativeHandle(
    ref,
    () => ({
      loadObject(object) {
        const scene = sceneRef.current;
        const camera = cameraRef.current;
        const controls = controlsRef.current;
        if (!scene || !camera || !controls) return;

        // Remove existing model
        if (modelRef.current) {
          scene.remove(modelRef.current);
          modelRef.current = null;
        }

        // Add new model
        scene.add(object);
        modelRef.current = object;
        measureToolRef.current.setModel(object);

        // Center and frame the model
        const { size, center } = getModelBounds(object);
        const maxDim = Math.max(size.x, size.y, size.z);

        // Reset the model position to center it
        object.position.sub(center);

        // Adjust grid
        if (gridRef.current) {
          const gridSize = Math.max(maxDim * 3, 10);
          gridRef.current.scale.set(gridSize / 20, 1, gridSize / 20);
          gridRef.current.position.y = -size.y / 2;
        }

        // Position camera
        const dist = maxDim * 1.8;
        camera.position.set(dist * 0.8, dist * 0.6, dist * 0.8);
        camera.near = maxDim * 0.001;
        camera.far = maxDim * 100;
        camera.updateProjectionMatrix();

        controls.target.set(0, 0, 0);
        controls.update();

        // Update zoom raycaster threshold based on model scale
        zoomRaycasterRef.current.params.Points.threshold = maxDim * 0.002;

        // Update fog — keep it very subtle so scans stay visible
        scene.fog = new THREE.FogExp2(0x0d1117, 0.08 / maxDim);
      },

      clearModel() {
        if (modelRef.current) {
          sceneRef.current.remove(modelRef.current);
          modelRef.current = null;
          measureToolRef.current.setModel(null);
        }
      },

      resetView() {
        const controls = controlsRef.current;
        const camera = cameraRef.current;
        if (!controls || !camera) return;

        if (modelRef.current) {
          const { size } = getModelBounds(modelRef.current);
          const maxDim = Math.max(size.x, size.y, size.z) || 5;
          const dist = maxDim * 1.8;
          camera.position.set(dist * 0.8, dist * 0.6, dist * 0.8);
        } else {
          camera.position.set(3, 2, 3);
        }
        controls.target.set(0, 0, 0);
        controls.update();
      },

      setMeasureActive(active) {
        if (active) {
          measureToolRef.current.activate();
        } else {
          measureToolRef.current.deactivate();
        }
      },

      setMeasureUnit(unit) {
        measureToolRef.current.setUnit(unit);
      },

      clearMeasurements() {
        measureToolRef.current.clearAll();
      },

      removeMeasurement(index) {
        measureToolRef.current.removeMeasurement(index);
      },

      focusOnPoint(point) {
        const controls = controlsRef.current;
        const camera = cameraRef.current;
        if (!controls || !camera) return;

        // Move orbit target to the clicked point, keeping camera distance
        const dist = camera.position.distanceTo(controls.target);
        controls.target.copy(point);

        // Move camera to maintain same relative distance and angle
        const dir = camera.position.clone().sub(controls.target).normalize();
        camera.position.copy(point).add(dir.multiplyScalar(dist * 0.5));
        controls.update();
      },
    }),
    []
  );

  // Context menu action handler
  const handleContextAction = useCallback(
    (action) => {
      setContextMenu(null);
      if (onContextAction) {
        onContextAction(action, contextMenu?.hitPoint);
      }
    },
    [onContextAction, contextMenu]
  );

  // Drag and drop
  const handleDragOver = useCallback((e) => {
    e.preventDefault();
    e.stopPropagation();
    containerRef.current?.classList.add('drag-over');
  }, []);

  const handleDragLeave = useCallback((e) => {
    e.preventDefault();
    e.stopPropagation();
    containerRef.current?.classList.remove('drag-over');
  }, []);

  const handleDrop = useCallback(
    (e) => {
      e.preventDefault();
      e.stopPropagation();
      containerRef.current?.classList.remove('drag-over');

      const items = e.dataTransfer.items;
      const files = [];

      // Handle folder drops
      const entries = [];
      for (let i = 0; i < items.length; i++) {
        const entry = items[i].webkitGetAsEntry?.();
        if (entry) {
          entries.push(entry);
        } else {
          files.push(items[i].getAsFile());
        }
      }

      if (entries.length > 0) {
        readAllEntries(entries).then((allFiles) => {
          if (onDrop && allFiles.length > 0) onDrop(allFiles);
        });
      } else if (e.dataTransfer.files.length > 0) {
        if (onDrop) onDrop(Array.from(e.dataTransfer.files));
      }
    },
    [onDrop]
  );

  return (
    <div
      ref={containerRef}
      className="viewer-container"
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      <div className="drag-overlay">
        <div className="drag-overlay-content">
          <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
            <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M7 10l5 5 5-5M12 15V3" />
          </svg>
          <span>Drop files to import</span>
        </div>
      </div>

      {/* Right-click context menu */}
      {contextMenu && (
        <div
          className="context-menu"
          style={{ left: contextMenu.x, top: contextMenu.y }}
          onClick={(e) => e.stopPropagation()}
        >
          <button
            className="context-menu-item"
            onClick={() => handleContextAction('measure')}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M2 20h20M4 20V10l4-6h8l4 6v10" />
              <path d="M12 20v-6M8 20v-3M16 20v-3" />
            </svg>
            Measure
          </button>
          <button
            className="context-menu-item"
            onClick={() => handleContextAction('resetView')}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7" />
            </svg>
            Reset View
          </button>
          <button
            className="context-menu-item"
            onClick={() => handleContextAction('toggleGrid')}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M3 3h18v18H3zM3 9h18M3 15h18M9 3v18M15 3v18" />
            </svg>
            Toggle Grid
          </button>
          <div className="context-menu-divider" />
          <button
            className="context-menu-item"
            onClick={() => handleContextAction('focusHere')}
            disabled={!contextMenu.hitPoint}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <circle cx="12" cy="12" r="3" />
              <path d="M12 2v4M12 18v4M2 12h4M18 12h4" />
            </svg>
            Focus Here
          </button>
        </div>
      )}
    </div>
  );
});

// Recursively read files from dropped directory entries
async function readAllEntries(entries) {
  const files = [];

  async function readEntry(entry) {
    if (entry.isFile) {
      const file = await new Promise((resolve) => entry.file(resolve));
      files.push(file);
    } else if (entry.isDirectory) {
      const reader = entry.createReader();
      const subEntries = await new Promise((resolve) =>
        reader.readEntries(resolve)
      );
      for (const sub of subEntries) {
        await readEntry(sub);
      }
    }
  }

  for (const entry of entries) {
    await readEntry(entry);
  }
  return files;
}

export default Viewer3D;
