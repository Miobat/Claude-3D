const DB_NAME = 'scanview-3d';
const DB_VERSION = 1;

function openDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = (e) => {
      const db = e.target.result;
      if (!db.objectStoreNames.contains('projects')) {
        db.createObjectStore('projects', { keyPath: 'id' });
      }
      if (!db.objectStoreNames.contains('modelFiles')) {
        const store = db.createObjectStore('modelFiles', { keyPath: 'id' });
        store.createIndex('modelId', 'modelId', { unique: false });
      }
    };
    request.onsuccess = (e) => resolve(e.target.result);
    request.onerror = (e) => reject(e.target.error);
  });
}

function tx(storeName, mode = 'readonly') {
  return openDB().then((db) => {
    const transaction = db.transaction(storeName, mode);
    return transaction.objectStore(storeName);
  });
}

// ── Projects ──

export async function getProjects() {
  const store = await tx('projects');
  return new Promise((resolve, reject) => {
    const req = store.getAll();
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function saveProject(project) {
  const store = await tx('projects', 'readwrite');
  return new Promise((resolve, reject) => {
    const req = store.put(project);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

export async function deleteProject(projectId) {
  // Delete project metadata
  const store = await tx('projects', 'readwrite');
  await new Promise((resolve, reject) => {
    const req = store.delete(projectId);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

// ── Model Files ──

export async function saveModelFiles(modelId, files) {
  const db = await openDB();
  const transaction = db.transaction('modelFiles', 'readwrite');
  const store = transaction.objectStore('modelFiles');

  const promises = Object.entries(files).map(
    ([fileName, data]) =>
      new Promise((resolve, reject) => {
        const req = store.put({
          id: `${modelId}/${fileName}`,
          modelId,
          fileName,
          data,
        });
        req.onsuccess = () => resolve();
        req.onerror = () => reject(req.error);
      })
  );

  await Promise.all(promises);
}

export async function getModelFiles(modelId) {
  const db = await openDB();
  const transaction = db.transaction('modelFiles', 'readonly');
  const store = transaction.objectStore('modelFiles');
  const index = store.index('modelId');

  return new Promise((resolve, reject) => {
    const req = index.getAll(modelId);
    req.onsuccess = () => {
      const result = {};
      for (const entry of req.result) {
        result[entry.fileName] = entry.data;
      }
      resolve(result);
    };
    req.onerror = () => reject(req.error);
  });
}

export async function deleteModelFiles(modelId) {
  const db = await openDB();
  const transaction = db.transaction('modelFiles', 'readwrite');
  const store = transaction.objectStore('modelFiles');
  const index = store.index('modelId');

  const keys = await new Promise((resolve, reject) => {
    const req = index.getAllKeys(modelId);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });

  for (const key of keys) {
    store.delete(key);
  }
}

// ── Helpers ──

export function generateId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
}

export function createProject(name) {
  return {
    id: 'proj_' + generateId(),
    name,
    createdAt: Date.now(),
    models: [],
  };
}

export function createModelEntry(name, type, fileNames) {
  return {
    id: 'model_' + generateId(),
    name,
    type,
    fileNames,
    createdAt: Date.now(),
  };
}
