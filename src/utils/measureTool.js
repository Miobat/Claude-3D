import * as THREE from 'three';
import { CSS2DObject } from 'three/addons/renderers/CSS2DRenderer.js';

/**
 * Find closest points between two infinite lines.
 * Line A: pointA + t * dirA
 * Line B: pointB + s * dirB
 * Returns { closestOnLine: Vector3 (on line A), distToRay: number }
 */
function closestPointsBetweenLines(pointA, dirA, pointB, dirB) {
  const w0 = new THREE.Vector3().subVectors(pointA, pointB);
  const a = dirA.dot(dirA);
  const b = dirA.dot(dirB);
  const c = dirB.dot(dirB);
  const d = dirA.dot(w0);
  const e = dirB.dot(w0);

  const denom = a * c - b * b;
  let t;
  if (Math.abs(denom) < 1e-10) {
    // Lines are nearly parallel
    t = 0;
  } else {
    t = (b * e - c * d) / denom;
  }

  const closestOnLine = pointA.clone().addScaledVector(dirA, t);
  const s =
    Math.abs(denom) < 1e-10 ? e / c : (a * e - b * d) / denom;
  const closestOnRay = pointB.clone().addScaledVector(dirB, s);
  const distToRay = closestOnLine.distanceTo(closestOnRay);

  return { closestOnLine, distToRay };
}

export class MeasureTool {
  constructor(scene, camera, renderer) {
    this.scene = scene;
    this.camera = camera;
    this.renderer = renderer;
    this.active = false;
    this.unit = 'm'; // 'm' or 'ft'
    this.measurements = [];
    this.pendingPoint = null;
    this.pendingMarker = null;
    this.raycaster = new THREE.Raycaster();
    this.raycaster.params.Points.threshold = 0.02;
    this.mouse = new THREE.Vector2();
    this.modelObject = null;
    this.measureGroup = new THREE.Group();
    this.measureGroup.name = 'measurements';
    this.scene.add(this.measureGroup);

    // ── Snap mode ──
    // 'free' | 'axis' | 'perpendicular'
    this.snapMode = 'free';

    // Preview visuals group (axis lines, ghost marker, etc.)
    this.previewGroup = new THREE.Group();
    this.previewGroup.name = 'measure-preview';
    this.scene.add(this.previewGroup);

    // Throttle gate for mousemove preview
    this._previewRAF = null;

    // Cached first-point surface normal (for perpendicular mode)
    this._pendingNormal = null;

    // Computed snap point from preview (used on second click)
    this._previewSnapPoint = null;
    this._previewSnapAxis = null;

    // Track pointer-down position so we can distinguish a clean click
    // from a drag (orbit/pan). Without this, releasing a drag while
    // damping is still active would register as a measurement point.
    this._pointerDownPos = { x: 0, y: 0 };
    this._pointerDownTime = 0;

    // Debounce: minimum ms between two measurement point placements.
    // Prevents a single click from being double-registered.
    this._lastClickTime = 0;
    this._CLICK_DEBOUNCE = 200; // ms

    // Maximum pixel distance between pointerdown and click to count
    // as a "clean" click rather than the end of a drag.
    this._DRAG_THRESHOLD = 4; // px

    // Cached scale to avoid redundant measureGroup traversals.
    this._lastScale = -1;

    this._onClick = this._onClick.bind(this);
    this._onPointerDown = this._onPointerDown.bind(this);
    this._onKeyDown = this._onKeyDown.bind(this);
    this._onMouseMove = this._onMouseMove.bind(this);
  }

  setModel(object) {
    this.modelObject = object;
  }

  activate() {
    this.active = true;
    // Always show crosshair while in measure mode.
    this.renderer.domElement.style.cursor = 'crosshair';
    this.renderer.domElement.addEventListener('pointerdown', this._onPointerDown);
    this.renderer.domElement.addEventListener('click', this._onClick);
    this.renderer.domElement.addEventListener('mousemove', this._onMouseMove);
    window.addEventListener('keydown', this._onKeyDown);
  }

  deactivate() {
    this.active = false;
    this.renderer.domElement.style.cursor = '';
    this.renderer.domElement.removeEventListener('pointerdown', this._onPointerDown);
    this.renderer.domElement.removeEventListener('click', this._onClick);
    this.renderer.domElement.removeEventListener('mousemove', this._onMouseMove);
    window.removeEventListener('keydown', this._onKeyDown);
    this._clearPending();
  }

  setSnapMode(mode) {
    this.snapMode = mode; // 'free' | 'axis' | 'perpendicular'
    this._clearPreview();
    // Notify UI of mode change
    if (this.onSnapModeChange) {
      this.onSnapModeChange(mode);
    }
  }

  _updateMouse(event) {
    const rect = this.renderer.domElement.getBoundingClientRect();
    this.mouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
    this.mouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;
  }

  /**
   * Raycast against the model. Returns { point, normal, face, distance }
   * or null if nothing was hit.
   * @param {Object} options - Optional overrides for ray origin/direction
   */
  _raycast(options = {}) {
    if (!this.modelObject) return null;

    if (options.origin && options.direction) {
      // Custom ray (e.g. for perpendicular mode)
      this.raycaster.set(options.origin, options.direction);
    } else {
      this.raycaster.setFromCamera(this.mouse, this.camera);
    }

    const targets = [];
    this.modelObject.traverse((child) => {
      if (child.isMesh || child.isPoints) targets.push(child);
    });
    const hits = this.raycaster.intersectObjects(targets, false);
    if (hits.length === 0) return null;

    const hit = hits[0];
    return {
      point: hit.point.clone(),
      face: hit.face, // may be null for point clouds
      normal: hit.face
        ? hit.face.normal
            .clone()
            .transformDirection(hit.object.matrixWorld)
            .normalize()
        : null,
      distance: hit.distance,
    };
  }

  // ── Pointer-down tracking ──
  _onPointerDown(event) {
    this._pointerDownPos.x = event.clientX;
    this._pointerDownPos.y = event.clientY;
    this._pointerDownTime = performance.now();
  }

  // ── Mouse move for snap preview ──
  _onMouseMove(event) {
    // Only show preview when we have a first point and snap mode is active
    if (!this.pendingPoint || this.snapMode === 'free') return;

    // Throttle via requestAnimationFrame — only one preview per frame
    if (this._previewRAF) return;
    this._previewRAF = requestAnimationFrame(() => {
      this._previewRAF = null;
      this._updatePreview(event);
    });
  }

  // ── Click handler with drag & debounce guard ──
  _onClick(event) {
    // 1. Ignore programmatic / zero-detail clicks
    if (event.detail === 0) return;

    // 2. If the pointer moved more than DRAG_THRESHOLD between down -> up,
    //    the user was orbiting / panning, not placing a point.
    const dx = event.clientX - this._pointerDownPos.x;
    const dy = event.clientY - this._pointerDownPos.y;
    if (Math.sqrt(dx * dx + dy * dy) > this._DRAG_THRESHOLD) return;

    // 3. Debounce — prevent double-registration from a single click
    const now = performance.now();
    if (now - this._lastClickTime < this._CLICK_DEBOUNCE) return;
    this._lastClickTime = now;

    this._updateMouse(event);

    if (!this.pendingPoint) {
      // ── First point — always raycast to surface ──
      const hitResult = this._raycast();
      if (!hitResult) return;

      this.pendingPoint = hitResult.point;
      this._pendingNormal = hitResult.normal; // store for perpendicular mode
      this.pendingMarker = this._createMarker(hitResult.point, 0x4cc9f0);
      this.measureGroup.add(this.pendingMarker);

      // In perpendicular mode, immediately compute and show the projection
      if (this.snapMode === 'perpendicular') {
        this._updatePerpendicularPreview();
      }
    } else {
      // ── Second point ──
      let p2;
      let snapType = null;

      if (this.snapMode === 'perpendicular' && this._previewSnapPoint) {
        // Perpendicular mode: use the pre-computed normal projection hit
        p2 = this._previewSnapPoint;
        snapType = 'perp';
      } else if (this.snapMode === 'axis' && this._previewSnapPoint) {
        // Axis mode: use the pre-computed axis snap point
        p2 = this._previewSnapPoint;
        snapType = this._previewSnapAxis?.label || 'axis';
      } else {
        // Free mode: raycast to surface as before
        const hitResult = this._raycast();
        if (!hitResult) return;
        p2 = hitResult.point;
      }

      const p1 = this.pendingPoint;
      const distance = p1.distanceTo(p2);
      const measurement = this._createMeasurement(p1, p2, distance, snapType);
      this.measurements.push(measurement);
      this._clearPending();

      if (this.onMeasure) {
        this.onMeasure(this.getMeasurements());
      }
    }
  }

  _onKeyDown(event) {
    if (event.key === 'Escape') {
      this._clearPending();
    } else if (event.key === 'Tab' && this.active) {
      // Cycle snap modes: free -> axis -> perpendicular -> free
      event.preventDefault();
      const modes = ['free', 'axis', 'perpendicular'];
      const idx = modes.indexOf(this.snapMode);
      const nextMode = modes[(idx + 1) % modes.length];
      this.setSnapMode(nextMode);
    }
  }

  _clearPending() {
    if (this.pendingMarker) {
      this.measureGroup.remove(this.pendingMarker);
      this.pendingMarker = null;
    }
    this.pendingPoint = null;
    this._pendingNormal = null;
    this._clearPreview();
  }

  // ── Preview system ──

  _clearPreview() {
    // Remove all CSS2D label elements to prevent DOM leaks
    this.previewGroup.traverse((child) => {
      if (child instanceof CSS2DObject && child.element) {
        child.element.remove();
      }
    });
    // Remove all children
    while (this.previewGroup.children.length > 0) {
      this.previewGroup.remove(this.previewGroup.children[0]);
    }
    this._previewSnapPoint = null;
    this._previewSnapAxis = null;
    if (this._previewRAF) {
      cancelAnimationFrame(this._previewRAF);
      this._previewRAF = null;
    }
  }

  _updatePreview(event) {
    this._clearPreview();
    this._updateMouse(event);

    if (this.snapMode === 'axis') {
      this._updateAxisPreview();
    } else if (this.snapMode === 'perpendicular') {
      this._updatePerpendicularPreview();
    }
  }

  _updateAxisPreview() {
    const p1 = this.pendingPoint;
    if (!p1) return;

    this.raycaster.setFromCamera(this.mouse, this.camera);
    const rayOrigin = this.raycaster.ray.origin.clone();
    const rayDir = this.raycaster.ray.direction.clone();

    const axes = [
      { dir: new THREE.Vector3(1, 0, 0), color: 0xff4444, label: 'X' },
      { dir: new THREE.Vector3(0, 1, 0), color: 0x44ff44, label: 'Y' },
      { dir: new THREE.Vector3(0, 0, 1), color: 0x4444ff, label: 'Z' },
    ];

    let bestAxis = null;
    let bestSnapPoint = null;
    let bestRayDist = Infinity;

    for (const axis of axes) {
      // Find closest points between ray and axis line through p1
      const { closestOnLine, distToRay } = closestPointsBetweenLines(
        p1,
        axis.dir,
        rayOrigin,
        rayDir
      );
      if (distToRay < bestRayDist) {
        bestRayDist = distToRay;
        bestSnapPoint = closestOnLine;
        bestAxis = axis;
      }
    }

    if (!bestAxis || !bestSnapPoint) return;

    // Draw all three axis guide lines (dimmed), highlight the selected one
    for (const axis of axes) {
      const isBest = axis === bestAxis;
      const extent = 50; // line length in each direction
      const start = p1.clone().addScaledVector(axis.dir, -extent);
      const end = p1.clone().addScaledVector(axis.dir, extent);
      const lineGeo = new THREE.BufferGeometry().setFromPoints([start, end]);
      const lineMat = new THREE.LineDashedMaterial({
        color: axis.color,
        dashSize: 0.05,
        gapSize: 0.03,
        opacity: isBest ? 0.8 : 0.15,
        transparent: true,
        depthTest: false,
      });
      const line = new THREE.Line(lineGeo, lineMat);
      line.computeLineDistances();
      line.renderOrder = 997;
      this.previewGroup.add(line);
    }

    // Ghost marker at snap point
    const ghost = this._createMarker(bestSnapPoint, bestAxis.color);
    ghost.material.opacity = 0.6;
    ghost.material.transparent = true;
    this.previewGroup.add(ghost);

    // Connector line from p1 to snap point
    const connGeo = new THREE.BufferGeometry().setFromPoints([p1, bestSnapPoint]);
    const connMat = new THREE.LineDashedMaterial({
      color: bestAxis.color,
      dashSize: 0.03,
      gapSize: 0.02,
      depthTest: false,
      opacity: 0.6,
      transparent: true,
    });
    const connLine = new THREE.Line(connGeo, connMat);
    connLine.computeLineDistances();
    connLine.renderOrder = 998;
    this.previewGroup.add(connLine);

    // Preview distance label
    const dist = p1.distanceTo(bestSnapPoint);
    if (dist > 0.001) {
      const midpoint = new THREE.Vector3().lerpVectors(p1, bestSnapPoint, 0.5);
      const label = this._createPreviewLabel(dist, bestAxis.label);
      label.position.copy(midpoint);
      this.previewGroup.add(label);
    }

    // Store the computed snap point for use when the user clicks
    this._previewSnapPoint = bestSnapPoint;
    this._previewSnapAxis = bestAxis;
  }

  _updatePerpendicularPreview() {
    const p1 = this.pendingPoint;
    const normal = this._pendingNormal;
    if (!p1) return;

    if (!normal) {
      // No normal available (e.g., point cloud) — show a hint
      this._previewSnapPoint = null;
      return;
    }

    // Cast ray from p1 along the inverted normal (into the surface)
    // to find intersection with the opposite surface
    const backHit = this._raycast({
      origin: p1.clone().addScaledVector(normal, -0.01),
      direction: normal.clone().negate(),
    });

    // Also try the forward direction
    const forwardHit = this._raycast({
      origin: p1.clone().addScaledVector(normal, 0.01),
      direction: normal.clone(),
    });

    // Use whichever hit is valid — prefer backward (opposite wall)
    const hit = backHit || forwardHit;
    const perpColor = 0xffaa00;

    if (!hit) {
      // Show the normal line but no snap point
      const end = p1.clone().addScaledVector(normal, 2);
      const lineGeo = new THREE.BufferGeometry().setFromPoints([p1, end]);
      const lineMat = new THREE.LineDashedMaterial({
        color: perpColor,
        dashSize: 0.05,
        gapSize: 0.03,
        opacity: 0.4,
        transparent: true,
        depthTest: false,
      });
      const line = new THREE.Line(lineGeo, lineMat);
      line.computeLineDistances();
      line.renderOrder = 997;
      this.previewGroup.add(line);

      // "No surface" label
      const div = document.createElement('div');
      div.className = 'measure-label measure-label-preview';
      div.textContent = 'No surface found';
      div.style.color = '#d29922';
      div.style.borderColor = '#d29922';
      const noLabel = new CSS2DObject(div);
      noLabel.position.copy(end);
      noLabel.layers.set(0);
      this.previewGroup.add(noLabel);

      this._previewSnapPoint = null;
      return;
    }

    // Draw perpendicular line from p1 to hit point
    const p2 = hit.point;
    const lineGeo = new THREE.BufferGeometry().setFromPoints([p1, p2]);
    const lineMat = new THREE.LineDashedMaterial({
      color: perpColor,
      dashSize: 0.05,
      gapSize: 0.03,
      opacity: 0.8,
      transparent: true,
      depthTest: false,
    });
    const line = new THREE.Line(lineGeo, lineMat);
    line.computeLineDistances();
    line.renderOrder = 997;
    this.previewGroup.add(line);

    // Ghost marker at hit point
    const ghost = this._createMarker(p2, perpColor);
    ghost.material.opacity = 0.6;
    ghost.material.transparent = true;
    this.previewGroup.add(ghost);

    // Right-angle indicator at p1
    this._addRightAngleIndicator(p1, normal);

    // Preview label
    const dist = p1.distanceTo(p2);
    const midpoint = new THREE.Vector3().lerpVectors(p1, p2, 0.5);
    const label = this._createPreviewLabel(dist, '\u22A5');
    label.position.copy(midpoint);
    this.previewGroup.add(label);

    this._previewSnapPoint = p2;
  }

  _addRightAngleIndicator(point, normal) {
    // Find two vectors perpendicular to the normal
    const up =
      Math.abs(normal.y) < 0.9
        ? new THREE.Vector3(0, 1, 0)
        : new THREE.Vector3(1, 0, 0);
    const tangent1 = new THREE.Vector3()
      .crossVectors(normal, up)
      .normalize();

    const size = 0.03; // small indicator
    const a = point.clone().addScaledVector(tangent1, size);
    const b = a.clone().addScaledVector(normal.clone().negate(), size);
    const c = point
      .clone()
      .addScaledVector(normal.clone().negate(), size);

    const geo = new THREE.BufferGeometry().setFromPoints([a, b, c]);
    const mat = new THREE.LineBasicMaterial({
      color: 0xffaa00,
      depthTest: false,
      opacity: 0.8,
      transparent: true,
    });
    const indicator = new THREE.Line(geo, mat);
    indicator.renderOrder = 999;
    this.previewGroup.add(indicator);
  }

  _createPreviewLabel(distance, axisLabel) {
    const div = document.createElement('div');
    div.className = 'measure-label measure-label-preview';
    div.textContent = `${axisLabel}: ${this._formatDistance(distance)}`;
    const label = new CSS2DObject(div);
    label.layers.set(0);
    return label;
  }

  // ── Visual creation helpers ──

  _createMarker(position, color = 0x4cc9f0) {
    const geometry = new THREE.SphereGeometry(0.015, 16, 16);
    const material = new THREE.MeshBasicMaterial({ color, depthTest: false });
    const sphere = new THREE.Mesh(geometry, material);
    sphere.position.copy(position);
    sphere.renderOrder = 999;
    return sphere;
  }

  _createMeasurement(p1, p2, distance, snapType = null) {
    const group = new THREE.Group();
    group.name = 'measurement';

    // Markers
    const m1 = this._createMarker(p1, 0x4cc9f0);
    const m2 = this._createMarker(p2, 0x4cc9f0);
    group.add(m1);
    group.add(m2);

    // Line
    const lineGeo = new THREE.BufferGeometry().setFromPoints([p1, p2]);
    const lineMat = new THREE.LineBasicMaterial({
      color: 0x4cc9f0,
      depthTest: false,
      linewidth: 2,
    });
    const line = new THREE.Line(lineGeo, lineMat);
    line.renderOrder = 998;
    group.add(line);

    // Label
    const midpoint = new THREE.Vector3().lerpVectors(p1, p2, 0.5);
    const label = this._createLabel(distance);
    label.position.copy(midpoint);
    group.add(label);

    this.measureGroup.add(group);

    return {
      group,
      p1: p1.clone(),
      p2: p2.clone(),
      distance,
      label,
      snapType,
    };
  }

  _createLabel(distance) {
    const div = document.createElement('div');
    div.className = 'measure-label';
    div.textContent = this._formatDistance(distance);

    const label = new CSS2DObject(div);
    label.layers.set(0);
    return label;
  }

  _formatDistance(meters) {
    if (this.unit === 'ft') {
      const feet = meters * 3.28084;
      return feet < 1
        ? `${(feet * 12).toFixed(1)} in`
        : `${feet.toFixed(2)} ft`;
    }
    return meters < 1
      ? `${(meters * 100).toFixed(1)} cm`
      : `${meters.toFixed(3)} m`;
  }

  setUnit(unit) {
    this.unit = unit;
    for (const m of this.measurements) {
      const div = m.label.element;
      div.textContent = this._formatDistance(m.distance);
    }
  }

  getMeasurements() {
    return this.measurements.map((m, i) => ({
      index: i,
      distance: m.distance,
      formatted: this._formatDistance(m.distance),
      snapType: m.snapType || null,
    }));
  }

  removeMeasurement(index) {
    if (index >= 0 && index < this.measurements.length) {
      const m = this.measurements[index];
      // CSS2DRenderer uses a WeakMap cache and cannot auto-remove orphaned
      // DOM elements — we must pull the label div out of the document ourselves.
      if (m.label && m.label.element) m.label.element.remove();
      this.measureGroup.remove(m.group);
      this.measurements.splice(index, 1);
      if (this.onMeasure) {
        this.onMeasure(this.getMeasurements());
      }
    }
  }

  clearAll() {
    for (const m of this.measurements) {
      if (m.label && m.label.element) m.label.element.remove();
      this.measureGroup.remove(m.group);
    }
    this.measurements = [];
    this._clearPending();
    if (this.onMeasure) {
      this.onMeasure([]);
    }
  }

  updateMarkerScale(cameraDistance) {
    const scale = Math.max(0.3, cameraDistance * 0.008);
    // Skip traversal if scale hasn't changed meaningfully
    if (Math.abs(scale - this._lastScale) < 0.01) return;
    this._lastScale = scale;

    // Scale markers in both measureGroup and previewGroup
    const scaleMarkers = (group) => {
      group.traverse((child) => {
        if (child.isMesh && child.geometry.type === 'SphereGeometry') {
          child.scale.setScalar(scale);
        }
      });
    };
    scaleMarkers(this.measureGroup);
    scaleMarkers(this.previewGroup);
  }

  dispose() {
    this.deactivate();
    this.clearAll();
    this._clearPreview();
    this.scene.remove(this.measureGroup);
    this.scene.remove(this.previewGroup);
  }
}
