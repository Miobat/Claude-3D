import { useState, useEffect, useRef, useCallback } from 'react';
import Viewer3D from './components/Viewer3D';
import Sidebar from './components/Sidebar';
import Toolbar from './components/Toolbar';
import {
  getProjects,
  saveProject,
  deleteProject as deleteProjectDB,
  saveModelFiles,
  getModelFiles,
  deleteModelFiles,
  createProject,
  createModelEntry,
} from './utils/storage';
import { readFiles, loadModel, detectFormat, loadModelFromURL } from './utils/loaders';

export default function App() {
  const viewerRef = useRef(null);
  const [projects, setProjects] = useState([]);
  const [activeModelId, setActiveModelId] = useState(null);
  const [modelInfo, setModelInfo] = useState(null);
  const [loading, setLoading] = useState(false);
  const [loadingMessage, setLoadingMessage] = useState('');
  const [error, setError] = useState(null);

  // Tool states
  const [measureActive, setMeasureActive] = useState(false);
  const [measurements, setMeasurements] = useState([]);
  const [showGrid, setShowGrid] = useState(true);
  const [autoRotate, setAutoRotate] = useState(false);
  const [unit, setUnit] = useState('m');
  const [pointSize, setPointSize] = useState(0.01);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);

  // Load projects from DB on mount
  useEffect(() => {
    getProjects().then((saved) => {
      if (saved.length > 0) {
        setProjects(saved.sort((a, b) => b.createdAt - a.createdAt));
      }
    });
  }, []);

  // Keyboard shortcuts
  useEffect(() => {
    const onKey = (e) => {
      if (e.target.tagName === 'INPUT') return;
      switch (e.key.toLowerCase()) {
        case 'm':
          setMeasureActive((v) => !v);
          break;
        case 'g':
          setShowGrid((v) => !v);
          break;
        case 'r':
          viewerRef.current?.resetView();
          break;
        case 'f':
          toggleFullscreen();
          break;
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  // Sync measure active state to viewer
  useEffect(() => {
    viewerRef.current?.setMeasureActive(measureActive);
    if (!measureActive) {
      // Keep measurements visible, just stop adding new ones
    }
  }, [measureActive]);

  // Sync unit to viewer
  useEffect(() => {
    viewerRef.current?.setMeasureUnit(unit);
  }, [unit]);

  // ── Project Management ──

  const handleAddProject = useCallback(() => {
    const name = prompt('Project name:');
    if (!name?.trim()) return;
    const project = createProject(name.trim());
    setProjects((prev) => {
      const next = [project, ...prev];
      saveProject(project);
      return next;
    });
  }, []);

  const handleRenameProject = useCallback((projectId, newName) => {
    setProjects((prev) => {
      const next = prev.map((p) =>
        p.id === projectId ? { ...p, name: newName } : p
      );
      const updated = next.find((p) => p.id === projectId);
      if (updated) saveProject(updated);
      return next;
    });
  }, []);

  const handleDeleteProject = useCallback(
    (projectId) => {
      if (!confirm('Delete this project and all its models?')) return;
      const project = projects.find((p) => p.id === projectId);
      if (project) {
        for (const model of project.models) {
          deleteModelFiles(model.id);
          if (model.id === activeModelId) {
            viewerRef.current?.clearModel();
            setActiveModelId(null);
            setModelInfo(null);
          }
        }
      }
      deleteProjectDB(projectId);
      setProjects((prev) => prev.filter((p) => p.id !== projectId));
    },
    [projects, activeModelId]
  );

  // ── Model Management ──

  const importFilesToProject = useCallback(
    async (projectId, files) => {
      if (files.length === 0) return;

      // Filter to supported file types
      const supported = files.filter((f) => {
        const ext = f.name.toLowerCase().split('.').pop();
        return [
          'obj', 'mtl', 'ply', 'dae',
          'jpg', 'jpeg', 'png', 'bmp', 'tga', 'webp',
        ].includes(ext);
      });

      if (supported.length === 0) {
        setError('No supported files found. Use OBJ, PLY, or DAE formats.');
        setTimeout(() => setError(null), 4000);
        return;
      }

      const fileNames = supported.map((f) => f.name);
      const format = detectFormat(fileNames);

      if (!format) {
        setError('Could not detect format. Include an .obj, .ply, or .dae file.');
        setTimeout(() => setError(null), 4000);
        return;
      }

      setLoading(true);
      setLoadingMessage('Reading files...');

      try {
        // Read files into ArrayBuffers
        const fileDataMap = await readFiles(supported);

        // Determine model name from the main file
        const mainFile = fileNames.find((n) =>
          n.toLowerCase().endsWith(`.${format}`)
        );
        const modelName = mainFile
          ? mainFile.replace(/\.[^.]+$/, '')
          : 'Imported Model';

        setLoadingMessage('Loading 3D model...');

        // Load into Three.js
        const { object, info } = await loadModel(fileDataMap);

        // Create model entry
        const modelEntry = createModelEntry(modelName, format, fileNames);

        // Save to IndexedDB
        await saveModelFiles(modelEntry.id, fileDataMap);

        // Update project
        setProjects((prev) => {
          const next = prev.map((p) => {
            if (p.id === projectId) {
              const updated = { ...p, models: [...p.models, modelEntry] };
              saveProject(updated);
              return updated;
            }
            return p;
          });
          return next;
        });

        // Display in viewer
        viewerRef.current?.loadObject(object);
        setActiveModelId(modelEntry.id);
        setModelInfo(info);
        setMeasurements([]);
        viewerRef.current?.clearMeasurements();
      } catch (err) {
        console.error('Import error:', err);
        setError(`Failed to load model: ${err.message}`);
        setTimeout(() => setError(null), 5000);
      } finally {
        setLoading(false);
        setLoadingMessage('');
      }
    },
    []
  );

  const handleImportModel = useCallback(
    (projectId, files) => {
      importFilesToProject(projectId, files);
    },
    [importFilesToProject]
  );

  const handleSelectModel = useCallback(
    async (projectId, modelId) => {
      if (modelId === activeModelId) return;

      setLoading(true);
      setLoadingMessage('Loading model...');
      setMeasureActive(false);

      try {
        const fileDataMap = await getModelFiles(modelId);
        const { object, info } = await loadModel(fileDataMap);

        viewerRef.current?.loadObject(object);
        setActiveModelId(modelId);
        setModelInfo(info);
        setMeasurements([]);
        viewerRef.current?.clearMeasurements();
      } catch (err) {
        console.error('Load error:', err);
        setError(`Failed to load model: ${err.message}`);
        setTimeout(() => setError(null), 5000);
      } finally {
        setLoading(false);
        setLoadingMessage('');
      }
    },
    [activeModelId]
  );

  const handleDeleteModel = useCallback(
    (projectId, modelId) => {
      if (!confirm('Delete this model?')) return;

      deleteModelFiles(modelId);

      if (modelId === activeModelId) {
        viewerRef.current?.clearModel();
        setActiveModelId(null);
        setModelInfo(null);
      }

      setProjects((prev) => {
        const next = prev.map((p) => {
          if (p.id === projectId) {
            const updated = {
              ...p,
              models: p.models.filter((m) => m.id !== modelId),
            };
            saveProject(updated);
            return updated;
          }
          return p;
        });
        return next;
      });
    },
    [activeModelId]
  );

  const handleRenameModel = useCallback((projectId, modelId, newName) => {
    setProjects((prev) => {
      const next = prev.map((p) => {
        if (p.id === projectId) {
          const updated = {
            ...p,
            models: p.models.map((m) =>
              m.id === modelId ? { ...m, name: newName } : m
            ),
          };
          saveProject(updated);
          return updated;
        }
        return p;
      });
      return next;
    });
  }, []);

  // ── Drag & Drop Handler ──

  const handleDrop = useCallback(
    (files) => {
      // Find or create a target project
      let targetProjectId;
      if (projects.length > 0) {
        targetProjectId = projects[0].id;
      } else {
        const project = createProject('My Scans');
        setProjects((prev) => {
          saveProject(project);
          return [project, ...prev];
        });
        targetProjectId = project.id;
      }
      importFilesToProject(targetProjectId, files);
    },
    [projects, importFilesToProject]
  );

  // ── Load demo model from public/ (for testing) ──

  const handleLoadDemo = useCallback(async () => {
    setLoading(true);
    setLoadingMessage('Loading Forus scan...');
    try {
      const { object, info } = await loadModelFromURL(
        '/test-model/',
        'textured_output.obj',
        'textured_output.mtl'
      );

      // Create or find project
      let targetProjectId;
      if (projects.length > 0) {
        targetProjectId = projects[0].id;
      } else {
        const project = createProject('Forus');
        setProjects((prev) => {
          saveProject(project);
          return [project, ...prev];
        });
        targetProjectId = project.id;
      }

      const modelEntry = createModelEntry('Forus Scan', 'obj', [
        'textured_output.obj',
        'textured_output.mtl',
        'textured_output.jpg',
      ]);

      setProjects((prev) => {
        const found = prev.find((p) => p.id === targetProjectId);
        if (!found) return prev;
        return prev.map((p) => {
          if (p.id === targetProjectId) {
            const updated = { ...p, models: [...p.models, modelEntry] };
            saveProject(updated);
            return updated;
          }
          return p;
        });
      });

      viewerRef.current?.loadObject(object);
      setActiveModelId(modelEntry.id);
      setModelInfo(info);
      setMeasurements([]);
      viewerRef.current?.clearMeasurements();
    } catch (err) {
      console.error('Demo load error:', err);
      setError(`Failed to load demo: ${err.message}`);
      setTimeout(() => setError(null), 5000);
    } finally {
      setLoading(false);
      setLoadingMessage('');
    }
  }, [projects]);

  const handleLoadStorebaug = useCallback(async () => {
    setLoading(true);
    setLoadingMessage('Loading Storebaug scan...');
    try {
      const { object, info } = await loadModelFromURL(
        '/storebaug/',
        'textured_output.obj',
        'textured_output.mtl'
      );

      let targetProjectId;
      if (projects.length > 0) {
        targetProjectId = projects[0].id;
      } else {
        const project = createProject('Storebaug');
        setProjects((prev) => {
          saveProject(project);
          return [project, ...prev];
        });
        targetProjectId = project.id;
      }

      const modelEntry = createModelEntry('Storebaug Scan', 'obj', [
        'textured_output.obj',
        'textured_output.mtl',
        'textured_output.jpg',
      ]);

      setProjects((prev) => {
        const found = prev.find((p) => p.id === targetProjectId);
        if (!found) return prev;
        return prev.map((p) => {
          if (p.id === targetProjectId) {
            const updated = { ...p, models: [...p.models, modelEntry] };
            saveProject(updated);
            return updated;
          }
          return p;
        });
      });

      viewerRef.current?.loadObject(object);
      setActiveModelId(modelEntry.id);
      setModelInfo(info);
      setMeasurements([]);
      viewerRef.current?.clearMeasurements();
    } catch (err) {
      console.error('Demo load error:', err);
      setError(`Failed to load Storebaug: ${err.message}`);
      setTimeout(() => setError(null), 5000);
    } finally {
      setLoading(false);
      setLoadingMessage('');
    }
  }, [projects]);

  // ── Tool Handlers ──

  // ── Context menu handler ──

  const handleContextAction = useCallback(
    (action, hitPoint) => {
      switch (action) {
        case 'measure':
          setMeasureActive(true);
          break;
        case 'resetView':
          viewerRef.current?.resetView();
          break;
        case 'toggleGrid':
          setShowGrid((v) => !v);
          break;
        case 'focusHere':
          if (hitPoint) {
            // Animate the orbit target to the clicked 3D point
            const controls = viewerRef.current;
            // Access the controls target through the imperative handle is limited,
            // so we set focus by calling a dedicated method
            viewerRef.current?.focusOnPoint(hitPoint);
          }
          break;
      }
    },
    []
  );

  const toggleFullscreen = () => {
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen();
    } else {
      document.exitFullscreen();
    }
  };

  return (
    <div className="app">
      <Sidebar
        projects={projects}
        activeModelId={activeModelId}
        onSelectModel={handleSelectModel}
        onAddProject={handleAddProject}
        onRenameProject={handleRenameProject}
        onDeleteProject={handleDeleteProject}
        onImportModel={handleImportModel}
        onDeleteModel={handleDeleteModel}
        onRenameModel={handleRenameModel}
        modelInfo={modelInfo}
        collapsed={sidebarCollapsed}
        onToggleCollapse={() => setSidebarCollapsed((v) => !v)}
      />

      <div className="main-content">
        <Viewer3D
          ref={viewerRef}
          onDrop={handleDrop}
          onMeasure={setMeasurements}
          onContextAction={handleContextAction}
          showGrid={showGrid}
          autoRotate={autoRotate}
          pointSize={pointSize}
        />

        <Toolbar
          measureActive={measureActive}
          onToggleMeasure={() => setMeasureActive((v) => !v)}
          showGrid={showGrid}
          onToggleGrid={() => setShowGrid((v) => !v)}
          autoRotate={autoRotate}
          onToggleAutoRotate={() => setAutoRotate((v) => !v)}
          onResetView={() => viewerRef.current?.resetView()}
          onClearMeasurements={() => {
            viewerRef.current?.clearMeasurements();
            setMeasurements([]);
          }}
          measurements={measurements}
          onRemoveMeasurement={(i) => {
            viewerRef.current?.removeMeasurement(i);
          }}
          unit={unit}
          onToggleUnit={() =>
            setUnit((v) => (v === 'm' ? 'ft' : 'm'))
          }
          isPointCloud={modelInfo?.isPointCloud}
          pointSize={pointSize}
          onPointSizeChange={setPointSize}
          onFullscreen={toggleFullscreen}
        />

        {/* Loading overlay */}
        {loading && (
          <div className="loading-overlay">
            <div className="loading-spinner" />
            <span>{loadingMessage}</span>
          </div>
        )}

        {/* Error toast */}
        {error && (
          <div className="error-toast">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <circle cx="12" cy="12" r="10" />
              <path d="M12 8v4M12 16h.01" />
            </svg>
            <span>{error}</span>
          </div>
        )}

        {/* Empty state */}
        {!activeModelId && !loading && (
          <div className="empty-viewport">
            <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1" opacity="0.3">
              <path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5" />
            </svg>
            <p>Drag & drop scan files here</p>
            <p className="hint">Supports OBJ, PLY, and DAE formats</p>
            <div className="demo-buttons">
              <button className="btn-load-demo" onClick={handleLoadDemo}>
                Load Forus Scan
              </button>
              <button className="btn-load-demo" onClick={handleLoadStorebaug}>
                Load Storebaug Scan
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
