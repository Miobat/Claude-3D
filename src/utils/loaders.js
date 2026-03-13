import * as THREE from 'three';
import { OBJLoader } from 'three/addons/loaders/OBJLoader.js';
import { MTLLoader } from 'three/addons/loaders/MTLLoader.js';
import { PLYLoader } from 'three/addons/loaders/PLYLoader.js';
import { ColladaLoader } from 'three/addons/loaders/ColladaLoader.js';

/**
 * Detect the primary format from a collection of files.
 */
export function detectFormat(fileNames) {
  const names = fileNames.map((n) => n.toLowerCase());
  if (names.some((n) => n.endsWith('.obj'))) return 'obj';
  if (names.some((n) => n.endsWith('.ply'))) return 'ply';
  if (names.some((n) => n.endsWith('.dae'))) return 'dae';
  return null;
}

/**
 * Load model from raw file data (stored as { fileName: ArrayBuffer }).
 * Returns { object: THREE.Object3D, info: { vertices, faces } }
 */
export async function loadModel(fileDataMap) {
  const names = Object.keys(fileDataMap);
  const format = detectFormat(names);

  switch (format) {
    case 'obj':
      return loadOBJ(fileDataMap);
    case 'ply':
      return loadPLY(fileDataMap);
    case 'dae':
      return loadDAE(fileDataMap);
    default:
      throw new Error(`Unsupported format. Files: ${names.join(', ')}`);
  }
}

/**
 * Read user-selected File objects into { fileName: ArrayBuffer } map.
 */
export async function readFiles(fileList) {
  const result = {};
  const promises = Array.from(fileList).map(
    (file) =>
      new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => {
          result[file.name] = reader.result;
          resolve();
        };
        reader.onerror = () => reject(reader.error);
        reader.readAsArrayBuffer(file);
      })
  );
  await Promise.all(promises);
  return result;
}

// ── OBJ Loading ──

async function loadOBJ(fileDataMap) {
  const blobUrls = {};
  const names = Object.keys(fileDataMap);

  // Create blob URLs for all files
  for (const [name, data] of Object.entries(fileDataMap)) {
    const mime = getMimeType(name);
    const blob = new Blob([data], { type: mime });
    blobUrls[name] = URL.createObjectURL(blob);
  }

  // Custom loading manager to resolve filenames to blob URLs
  const manager = new THREE.LoadingManager();
  manager.setURLModifier((url) => {
    // Extract just the filename from the URL
    const filename = url.split('/').pop().split('\\').pop();
    // Check case-insensitive match
    for (const [name, blobUrl] of Object.entries(blobUrls)) {
      if (name.toLowerCase() === filename.toLowerCase()) {
        return blobUrl;
      }
    }
    return url;
  });

  const objFileName = names.find((n) => n.toLowerCase().endsWith('.obj'));
  const mtlFileName = names.find((n) => n.toLowerCase().endsWith('.mtl'));

  let materials = null;

  if (mtlFileName) {
    const mtlLoader = new MTLLoader(manager);
    const mtlText = new TextDecoder().decode(fileDataMap[mtlFileName]);
    materials = mtlLoader.parse(mtlText, '');
    materials.preload();
  }

  const objLoader = new OBJLoader(manager);
  if (materials) {
    objLoader.setMaterials(materials);
  }

  const objText = new TextDecoder().decode(fileDataMap[objFileName]);
  const object = objLoader.parse(objText);

  // If no materials, apply a default material with vertex colors support
  if (!materials) {
    object.traverse((child) => {
      if (child.isMesh) {
        child.material = new THREE.MeshStandardMaterial({
          color: 0xcccccc,
          vertexColors: child.geometry.hasAttribute('color'),
          side: THREE.DoubleSide,
        });
      }
    });
  }

  const info = getModelInfo(object);

  // Cleanup blob URLs after a delay (textures need time to load)
  setTimeout(() => {
    Object.values(blobUrls).forEach(URL.revokeObjectURL);
  }, 5000);

  return { object, info };
}

// ── PLY Loading ──

async function loadPLY(fileDataMap) {
  const names = Object.keys(fileDataMap);
  const plyFileName = names.find((n) => n.toLowerCase().endsWith('.ply'));
  const data = fileDataMap[plyFileName];

  const loader = new PLYLoader();
  const geometry = loader.parse(data);
  geometry.computeVertexNormals();

  let object;
  const hasColors = geometry.hasAttribute('color');

  if (geometry.index !== null) {
    // Mesh PLY
    const material = new THREE.MeshStandardMaterial({
      vertexColors: hasColors,
      color: hasColors ? 0xffffff : 0xcccccc,
      side: THREE.DoubleSide,
    });
    object = new THREE.Mesh(geometry, material);
  } else {
    // Point cloud PLY
    const material = new THREE.PointsMaterial({
      size: 0.01,
      vertexColors: hasColors,
      color: hasColors ? 0xffffff : 0x58a6ff,
      sizeAttenuation: true,
    });
    object = new THREE.Points(geometry, material);
  }

  const info = getModelInfo(object);
  info.isPointCloud = !geometry.index;

  return { object, info };
}

// ── DAE (Collada) Loading ──

async function loadDAE(fileDataMap) {
  const blobUrls = {};
  const names = Object.keys(fileDataMap);

  for (const [name, data] of Object.entries(fileDataMap)) {
    const mime = getMimeType(name);
    const blob = new Blob([data], { type: mime });
    blobUrls[name] = URL.createObjectURL(blob);
  }

  const manager = new THREE.LoadingManager();
  manager.setURLModifier((url) => {
    const filename = url.split('/').pop().split('\\').pop();
    for (const [name, blobUrl] of Object.entries(blobUrls)) {
      if (name.toLowerCase() === filename.toLowerCase()) {
        return blobUrl;
      }
    }
    return url;
  });

  const daeFileName = names.find((n) => n.toLowerCase().endsWith('.dae'));
  const daeText = new TextDecoder().decode(fileDataMap[daeFileName]);

  const loader = new ColladaLoader(manager);
  const collada = loader.parse(daeText, '');
  const object = collada.scene;

  const info = getModelInfo(object);

  setTimeout(() => {
    Object.values(blobUrls).forEach(URL.revokeObjectURL);
  }, 5000);

  return { object, info };
}

// ── Helpers ──

function getMimeType(fileName) {
  const ext = fileName.toLowerCase().split('.').pop();
  const mimes = {
    obj: 'text/plain',
    mtl: 'text/plain',
    ply: 'application/octet-stream',
    dae: 'text/xml',
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    png: 'image/png',
    bmp: 'image/bmp',
    tga: 'image/x-tga',
    tiff: 'image/tiff',
    webp: 'image/webp',
  };
  return mimes[ext] || 'application/octet-stream';
}

function getModelInfo(object) {
  let vertices = 0;
  let faces = 0;
  let isPointCloud = false;

  object.traverse((child) => {
    if (child.isMesh && child.geometry) {
      const geo = child.geometry;
      vertices += geo.attributes.position ? geo.attributes.position.count : 0;
      faces += geo.index ? geo.index.count / 3 : (geo.attributes.position?.count || 0) / 3;
    }
    if (child.isPoints && child.geometry) {
      vertices += child.geometry.attributes.position?.count || 0;
      isPointCloud = true;
    }
  });

  return { vertices, faces: Math.floor(faces), isPointCloud };
}

/**
 * Load an OBJ model directly from URLs (for pre-staged files in public/).
 * basePath should end with '/' e.g. '/test-model/'
 */
export async function loadModelFromURL(basePath, objName, mtlName, textures = []) {
  return new Promise((resolve, reject) => {
    const manager = new THREE.LoadingManager();
    const mtlLoader = new MTLLoader(manager);
    mtlLoader.setPath(basePath);

    mtlLoader.load(mtlName, (materials) => {
      materials.preload();

      const objLoader = new OBJLoader(manager);
      objLoader.setMaterials(materials);
      objLoader.setPath(basePath);

      objLoader.load(
        objName,
        (object) => {
          // Ensure double-sided rendering for scans
          object.traverse((child) => {
            if (child.isMesh && child.material) {
              child.material.side = THREE.DoubleSide;
            }
          });
          const info = getModelInfo(object);
          resolve({ object, info });
        },
        (progress) => {
          // Progress is available for UI if needed
        },
        (err) => reject(new Error('Failed to load OBJ: ' + err.message))
      );
    },
    undefined,
    (err) => reject(new Error('Failed to load MTL: ' + err.message))
    );
  });
}

export function getModelBounds(object) {
  const box = new THREE.Box3().setFromObject(object);
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());
  return { box, size, center };
}
