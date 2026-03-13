export default function Toolbar({
  measureActive,
  onToggleMeasure,
  showGrid,
  onToggleGrid,
  autoRotate,
  onToggleAutoRotate,
  onResetView,
  onClearMeasurements,
  measurements,
  onRemoveMeasurement,
  unit,
  onToggleUnit,
  isPointCloud,
  pointSize,
  onPointSizeChange,
  onFullscreen,
}) {
  return (
    <>
      {/* Floating toolbar */}
      <div className="toolbar">
        <button
          className={`toolbar-btn ${measureActive ? 'active' : ''}`}
          onClick={onToggleMeasure}
          title="Measure distance (M)"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M2 20h20M4 20V10l4-6h8l4 6v10" />
            <path d="M12 20v-6" />
            <path d="M8 20v-3" />
            <path d="M16 20v-3" />
          </svg>
          <span>Measure</span>
        </button>

        <div className="toolbar-divider" />

        <button
          className={`toolbar-btn ${showGrid ? 'active' : ''}`}
          onClick={onToggleGrid}
          title="Toggle grid (G)"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M3 3h18v18H3zM3 9h18M3 15h18M9 3v18M15 3v18" />
          </svg>
          <span>Grid</span>
        </button>

        <button
          className={`toolbar-btn ${autoRotate ? 'active' : ''}`}
          onClick={onToggleAutoRotate}
          title="Auto rotate"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M21 12a9 9 0 11-6.219-8.56" />
            <path d="M21 3v5h-5" />
          </svg>
          <span>Rotate</span>
        </button>

        <button
          className="toolbar-btn"
          onClick={onResetView}
          title="Reset camera (R)"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7" />
          </svg>
          <span>Reset</span>
        </button>

        <div className="toolbar-divider" />

        <button
          className="toolbar-btn"
          onClick={onToggleUnit}
          title="Toggle unit"
        >
          <span className="unit-label">{unit === 'm' ? 'Metric' : 'Imperial'}</span>
        </button>

        {isPointCloud && (
          <div className="toolbar-slider">
            <label>Size</label>
            <input
              type="range"
              min="0.001"
              max="0.05"
              step="0.001"
              value={pointSize}
              onChange={(e) => onPointSizeChange(parseFloat(e.target.value))}
            />
          </div>
        )}

        <div className="toolbar-divider" />

        <button
          className="toolbar-btn"
          onClick={onFullscreen}
          title="Fullscreen (F)"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M8 3H5a2 2 0 00-2 2v3M21 8V5a2 2 0 00-2-2h-3M3 16v3a2 2 0 002 2h3M16 21h3a2 2 0 002-2v-3" />
          </svg>
        </button>
      </div>

      {/* Measurement panel */}
      {measurements.length > 0 && (
        <div className="measure-panel">
          <div className="measure-panel-header">
            <span>Measurements</span>
            <button className="btn-icon-sm" onClick={onClearMeasurements} title="Clear all">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M3 6h18M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6M8 6V4a2 2 0 012-2h4a2 2 0 012 2v2" />
              </svg>
            </button>
          </div>
          <div className="measure-list">
            {measurements.map((m, i) => (
              <div key={i} className="measure-item">
                <span className="measure-index">M{i + 1}</span>
                <span className="measure-value">{m.formatted}</span>
                <button
                  className="btn-icon-sm"
                  onClick={() => onRemoveMeasurement(i)}
                >
                  <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M18 6L6 18M6 6l12 12" />
                  </svg>
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Measure mode hint */}
      {measureActive && (
        <div className="measure-hint">
          Click on the model to place measurement points. Press Esc to cancel.
        </div>
      )}
    </>
  );
}
