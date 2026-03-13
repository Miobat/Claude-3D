import * as THREE from 'three';
import { CSS2DObject } from 'three/addons/renderers/CSS2DRenderer.js';

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
  }

  setModel(object) {
    this.modelObject = object;
  }

  activate() {
    this.active = true;
    // Always show crosshair while in measure mode.
    // We no longer raycast on mousemove — that was the main cause of
    // navigation slowdown on large models (raycasting 1M+ faces per frame).
    this.renderer.domElement.style.cursor = 'crosshair';
    this.renderer.domElement.addEventListener('pointerdown', this._onPointerDown);
    this.renderer.domElement.addEventListener('click', this._onClick);
    window.addEventListener('keydown', this._onKeyDown);
  }

  deactivate() {
    this.active = false;
    this.renderer.domElement.style.cursor = '';
    this.renderer.domElement.removeEventListener('pointerdown', this._onPointerDown);
    this.renderer.domElement.removeEventListener('click', this._onClick);
    window.removeEventListener('keydown', this._onKeyDown);
    this._clearPending();
  }

  _updateMouse(event) {
    const rect = this.renderer.domElement.getBoundingClientRect();
    this.mouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
    this.mouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;
  }

  _raycast() {
    if (!this.modelObject) return null;
    this.raycaster.setFromCamera(this.mouse, this.camera);
    const targets = [];
    this.modelObject.traverse((child) => {
      if (child.isMesh || child.isPoints) targets.push(child);
    });
    const hits = this.raycaster.intersectObjects(targets, false);
    return hits.length > 0 ? hits[0].point.clone() : null;
  }

  // ── Pointer-down tracking ──
  _onPointerDown(event) {
    this._pointerDownPos.x = event.clientX;
    this._pointerDownPos.y = event.clientY;
    this._pointerDownTime = performance.now();
  }

  // ── Click handler with drag & debounce guard ──
  _onClick(event) {
    // 1. Ignore programmatic / zero-detail clicks
    if (event.detail === 0) return;

    // 2. If the pointer moved more than DRAG_THRESHOLD between down → up,
    //    the user was orbiting / panning, not placing a point.
    const dx = event.clientX - this._pointerDownPos.x;
    const dy = event.clientY - this._pointerDownPos.y;
    if (Math.sqrt(dx * dx + dy * dy) > this._DRAG_THRESHOLD) return;

    // 3. Debounce — prevent double-registration from a single click
    const now = performance.now();
    if (now - this._lastClickTime < this._CLICK_DEBOUNCE) return;
    this._lastClickTime = now;

    this._updateMouse(event);
    const point = this._raycast();
    if (!point) return;

    if (!this.pendingPoint) {
      // First point
      this.pendingPoint = point;
      this.pendingMarker = this._createMarker(point, 0x4cc9f0);
      this.measureGroup.add(this.pendingMarker);
    } else {
      // Second point — complete measurement
      const p1 = this.pendingPoint;
      const p2 = point;
      const distance = p1.distanceTo(p2);
      const measurement = this._createMeasurement(p1, p2, distance);
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
    }
  }

  _clearPending() {
    if (this.pendingMarker) {
      this.measureGroup.remove(this.pendingMarker);
      this.pendingMarker = null;
    }
    this.pendingPoint = null;
  }

  _createMarker(position, color = 0x4cc9f0) {
    const geometry = new THREE.SphereGeometry(0.015, 16, 16);
    const material = new THREE.MeshBasicMaterial({ color, depthTest: false });
    const sphere = new THREE.Mesh(geometry, material);
    sphere.position.copy(position);
    sphere.renderOrder = 999;
    return sphere;
  }

  _createMeasurement(p1, p2, distance) {
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
    this.measureGroup.traverse((child) => {
      if (child.isMesh && child.geometry.type === 'SphereGeometry') {
        child.scale.setScalar(scale);
      }
    });
  }

  dispose() {
    this.deactivate();
    this.clearAll();
    this.scene.remove(this.measureGroup);
  }
}
