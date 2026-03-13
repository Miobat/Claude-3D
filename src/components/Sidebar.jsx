import { useState, useRef } from 'react';

export default function Sidebar({
  projects,
  activeModelId,
  onSelectModel,
  onAddProject,
  onRenameProject,
  onDeleteProject,
  onImportModel,
  onDeleteModel,
  onRenameModel,
  modelInfo,
  collapsed,
  onToggleCollapse,
}) {
  const [editingId, setEditingId] = useState(null);
  const [editValue, setEditValue] = useState('');
  const [expandedProjects, setExpandedProjects] = useState({});
  const fileInputRef = useRef(null);
  const folderInputRef = useRef(null);
  const [importTargetProject, setImportTargetProject] = useState(null);

  const toggleExpand = (projectId) => {
    setExpandedProjects((prev) => ({ ...prev, [projectId]: !prev[projectId] }));
  };

  const startEdit = (id, currentName) => {
    setEditingId(id);
    setEditValue(currentName);
  };

  const commitEdit = (type, projectId, modelId) => {
    if (editValue.trim()) {
      if (type === 'project') {
        onRenameProject(projectId, editValue.trim());
      } else {
        onRenameModel(projectId, modelId, editValue.trim());
      }
    }
    setEditingId(null);
  };

  const handleImportClick = (projectId, useFolder) => {
    setImportTargetProject(projectId);
    if (useFolder) {
      folderInputRef.current?.click();
    } else {
      fileInputRef.current?.click();
    }
  };

  const handleFilesSelected = (e) => {
    const files = Array.from(e.target.files);
    if (files.length > 0 && importTargetProject) {
      onImportModel(importTargetProject, files);
    }
    e.target.value = '';
    setImportTargetProject(null);
  };

  const formatNumber = (n) => {
    if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + 'M';
    if (n >= 1_000) return (n / 1_000).toFixed(1) + 'K';
    return n.toString();
  };

  if (collapsed) {
    return (
      <div className="sidebar collapsed">
        <button className="sidebar-toggle" onClick={onToggleCollapse} title="Expand sidebar">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M9 18l6-6-6-6" />
          </svg>
        </button>
      </div>
    );
  }

  return (
    <div className="sidebar">
      <div className="sidebar-header">
        <div className="sidebar-title">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5" />
          </svg>
          <span>ScanView 3D</span>
        </div>
        <button className="sidebar-toggle" onClick={onToggleCollapse} title="Collapse sidebar">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M15 18l-6-6 6-6" />
          </svg>
        </button>
      </div>

      <div className="sidebar-section">
        <div className="section-header">
          <span>Projects</span>
          <button className="btn-icon" onClick={onAddProject} title="New project">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M12 5v14M5 12h14" />
            </svg>
          </button>
        </div>

        <div className="project-list">
          {projects.length === 0 && (
            <div className="empty-state">
              <p>No projects yet</p>
              <p className="hint">Create a project or drag & drop scan files</p>
            </div>
          )}

          {projects.map((project) => {
            const isExpanded = expandedProjects[project.id] !== false;
            return (
              <div key={project.id} className="project-item">
                <div
                  className="project-header"
                  onClick={() => toggleExpand(project.id)}
                >
                  <svg
                    width="14"
                    height="14"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    className={`chevron ${isExpanded ? 'expanded' : ''}`}
                  >
                    <path d="M9 18l6-6-6-6" />
                  </svg>

                  {editingId === project.id ? (
                    <input
                      className="edit-input"
                      value={editValue}
                      onChange={(e) => setEditValue(e.target.value)}
                      onBlur={() => commitEdit('project', project.id)}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter') commitEdit('project', project.id);
                        if (e.key === 'Escape') setEditingId(null);
                      }}
                      autoFocus
                      onClick={(e) => e.stopPropagation()}
                    />
                  ) : (
                    <span className="project-name">{project.name}</span>
                  )}

                  <div className="project-actions" onClick={(e) => e.stopPropagation()}>
                    <button
                      className="btn-icon-sm"
                      onClick={() => handleImportClick(project.id, false)}
                      title="Import files"
                    >
                      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                        <path d="M12 5v14M5 12h14" />
                      </svg>
                    </button>
                    <button
                      className="btn-icon-sm"
                      onClick={() => startEdit(project.id, project.name)}
                      title="Rename"
                    >
                      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                        <path d="M17 3a2.83 2.83 0 114 4L7.5 20.5 2 22l1.5-5.5L17 3z" />
                      </svg>
                    </button>
                    <button
                      className="btn-icon-sm danger"
                      onClick={() => onDeleteProject(project.id)}
                      title="Delete project"
                    >
                      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                        <path d="M18 6L6 18M6 6l12 12" />
                      </svg>
                    </button>
                  </div>
                </div>

                {isExpanded && (
                  <div className="model-list">
                    {project.models.map((model) => (
                      <div
                        key={model.id}
                        className={`model-item ${model.id === activeModelId ? 'active' : ''}`}
                        onClick={() => onSelectModel(project.id, model.id)}
                      >
                        <div className="model-icon">
                          {model.type === 'ply' && model.isPointCloud ? (
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
                              <circle cx="4" cy="4" r="2" /><circle cx="12" cy="4" r="2" />
                              <circle cx="20" cy="4" r="2" /><circle cx="4" cy="12" r="2" />
                              <circle cx="12" cy="12" r="2" /><circle cx="20" cy="12" r="2" />
                              <circle cx="4" cy="20" r="2" /><circle cx="12" cy="20" r="2" />
                              <circle cx="20" cy="20" r="2" />
                            </svg>
                          ) : (
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                              <path d="M12 2L2 7l10 5 10-5-10-5z" />
                              <path d="M2 17l10 5 10-5" />
                            </svg>
                          )}
                        </div>

                        {editingId === model.id ? (
                          <input
                            className="edit-input"
                            value={editValue}
                            onChange={(e) => setEditValue(e.target.value)}
                            onBlur={() => commitEdit('model', project.id, model.id)}
                            onKeyDown={(e) => {
                              if (e.key === 'Enter') commitEdit('model', project.id, model.id);
                              if (e.key === 'Escape') setEditingId(null);
                            }}
                            autoFocus
                            onClick={(e) => e.stopPropagation()}
                          />
                        ) : (
                          <span className="model-name">{model.name}</span>
                        )}

                        <span className="model-badge">{model.type.toUpperCase()}</span>

                        <div className="model-actions" onClick={(e) => e.stopPropagation()}>
                          <button
                            className="btn-icon-sm"
                            onClick={() => startEdit(model.id, model.name)}
                            title="Rename"
                          >
                            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                              <path d="M17 3a2.83 2.83 0 114 4L7.5 20.5 2 22l1.5-5.5L17 3z" />
                            </svg>
                          </button>
                          <button
                            className="btn-icon-sm danger"
                            onClick={() => onDeleteModel(project.id, model.id)}
                            title="Delete model"
                          >
                            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                              <path d="M18 6L6 18M6 6l12 12" />
                            </svg>
                          </button>
                        </div>
                      </div>
                    ))}

                    {project.models.length === 0 && (
                      <div className="empty-models">
                        <span>No models</span>
                      </div>
                    )}

                    <div className="import-buttons">
                      <button
                        className="btn-import"
                        onClick={() => handleImportClick(project.id, false)}
                      >
                        + Import Files
                      </button>
                      <button
                        className="btn-import"
                        onClick={() => handleImportClick(project.id, true)}
                      >
                        + Import Folder
                      </button>
                    </div>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </div>

      {/* Model info panel */}
      {modelInfo && (
        <div className="sidebar-section model-info">
          <div className="section-header">
            <span>Model Info</span>
          </div>
          <div className="info-grid">
            <div className="info-item">
              <span className="info-label">Vertices</span>
              <span className="info-value">{formatNumber(modelInfo.vertices)}</span>
            </div>
            <div className="info-item">
              <span className="info-label">Faces</span>
              <span className="info-value">{formatNumber(modelInfo.faces)}</span>
            </div>
            <div className="info-item">
              <span className="info-label">Type</span>
              <span className="info-value">
                {modelInfo.isPointCloud ? 'Point Cloud' : 'Mesh'}
              </span>
            </div>
          </div>
        </div>
      )}

      {/* Hidden file inputs */}
      <input
        ref={fileInputRef}
        type="file"
        multiple
        accept=".obj,.mtl,.ply,.dae,.jpg,.jpeg,.png,.bmp,.tga"
        style={{ display: 'none' }}
        onChange={handleFilesSelected}
      />
      <input
        ref={folderInputRef}
        type="file"
        // @ts-ignore
        webkitdirectory=""
        style={{ display: 'none' }}
        onChange={handleFilesSelected}
      />
    </div>
  );
}
