/*
 * Experimental CPU skinned-mesh bounds for Roblox WebGL2.
 *
 * Uses read-only GPU buffer readback + the skinning math observed in the
 * captured vertex shader. Camera projection uses row-vector multiplication
 * because the shader expression is skinnedPosition * mat4(...). It never replays a game draw, starts transform
 * feedback, changes shaders, or changes vertex/index/UBO bindings.
 *
 * Intended for debugging your own Roblox WebClient experiences. Readbacks can
 * stall the renderer; this is a prototype, not a performance-optimized tool.
 *
 * Start: paste into DevTools.
 * Stop:  window.__greenBoxCpuBounds.stop()
 */
(() => {
  const KEY = "__greenBoxCpuBounds";
  window[KEY]?.stop?.();

  const gl = window.Module?.canvas?.getContext("webgl2");
  if (!gl || gl.isContextLost()) {
    console.error("[GreenBoxCPU] WebGL2 context not found at Module.canvas.");
    return;
  }

  const original = {
    drawElements: gl.drawElements,
    drawElementsInstanced: gl.drawElementsInstanced
  };
  const bufferCache = new WeakMap();
  const boxes = new Map();
  const programIds = new WeakMap();
  const programSkinningCache = new WeakMap();
  const objectIds = new WeakMap();
  let nextProgramId = 1;
  let nextObjectId = 1;
  let frameSerial = 0;
  let raf = 0;
  const seenThisFrame = new Set();
  const rigFrameSerial = new Map();
  const uniformFrameCache = new Map();
  let active = true;
  let overlay = null;
  let captured = 0;
  let skipped = 0;
  let drawCalls = 0;
  let programChecks = 0;
  let candidatePrograms = 0;
  let lastAttributes = [];

  const now = () => performance.now();
  const objectId = obj => {
    if (!obj) return 0;
    let id = objectIds.get(obj);
    if (!id) { id = nextObjectId++; objectIds.set(obj, id); }
    return id;
  };
  const enumName = v => "0x" + Number(v).toString(16);

  function readWholeBuffer(buffer) {
    if (!buffer) throw new Error("Missing WebGL buffer");
    const cached = bufferCache.get(buffer);
    if (cached) return cached;
    const old = gl.getParameter(gl.COPY_READ_BUFFER_BINDING);
    try {
      gl.bindBuffer(gl.COPY_READ_BUFFER, buffer);
      const size = gl.getBufferParameter(gl.COPY_READ_BUFFER, gl.BUFFER_SIZE);
      const bytes = new Uint8Array(size);
      gl.getBufferSubData(gl.COPY_READ_BUFFER, 0, bytes);
      bufferCache.set(buffer, bytes);
      return bytes;
    } finally {
      gl.bindBuffer(gl.COPY_READ_BUFFER, old);
    }
  }

  function readRange(buffer, start, size) {
    const old = gl.getParameter(gl.COPY_READ_BUFFER_BINDING);
    try {
      gl.bindBuffer(gl.COPY_READ_BUFFER, buffer);
      const bytes = new Uint8Array(size);
      gl.getBufferSubData(gl.COPY_READ_BUFFER, start, bytes);
      return bytes;
    } finally {
      gl.bindBuffer(gl.COPY_READ_BUFFER, old);
    }
  }

  function getAttribute(program, wantedName) {
    const n = gl.getProgramParameter(program, gl.ACTIVE_ATTRIBUTES);
    for (let i = 0; i < n; i++) {
      const info = gl.getActiveAttrib(program, i);
      if (!info || info.name !== wantedName) continue;
      const loc = gl.getAttribLocation(program, info.name);
      const buffer = gl.getVertexAttrib(loc, gl.VERTEX_ATTRIB_ARRAY_BUFFER_BINDING);
      return {
        buffer,
        bytes: readWholeBuffer(buffer),
        size: gl.getVertexAttrib(loc, gl.VERTEX_ATTRIB_ARRAY_SIZE),
        type: gl.getVertexAttrib(loc, gl.VERTEX_ATTRIB_ARRAY_TYPE),
        stride: gl.getVertexAttrib(loc, gl.VERTEX_ATTRIB_ARRAY_STRIDE),
        offset: gl.getVertexAttribOffset(loc, gl.VERTEX_ATTRIB_ARRAY_POINTER),
        normalized: gl.getVertexAttrib(loc, gl.VERTEX_ATTRIB_ARRAY_NORMALIZED),
        integer: gl.getVertexAttrib(loc, gl.VERTEX_ATTRIB_ARRAY_INTEGER),
        enabled: gl.getVertexAttrib(loc, gl.VERTEX_ATTRIB_ARRAY_ENABLED)
      };
    }
    throw new Error("Missing attribute " + wantedName);
  }

  function getBlock(program, wantedName) {
    const n = gl.getProgramParameter(program, gl.ACTIVE_UNIFORM_BLOCKS);
    for (let i = 0; i < n; i++) {
      if (gl.getActiveUniformBlockName(program, i) !== wantedName) continue;
      const binding = gl.getActiveUniformBlockParameter(program, i, gl.UNIFORM_BLOCK_BINDING);
      const size = gl.getActiveUniformBlockParameter(program, i, gl.UNIFORM_BLOCK_DATA_SIZE);
      const buffer = gl.getIndexedParameter(gl.UNIFORM_BUFFER_BINDING, binding);
      const start = gl.getIndexedParameter(gl.UNIFORM_BUFFER_START, binding);
      if (!buffer) throw new Error("No buffer bound for " + wantedName);
      const cacheKey = objectId(buffer) + ":" + start + ":" + size;
      let bytes = uniformFrameCache.get(cacheKey);
      if (!bytes) {
        bytes = readRange(buffer, start, size);
        uniformFrameCache.set(cacheKey, bytes);
      }
      return { bytes, size, start, buffer };
    }
    throw new Error("Missing uniform block " + wantedName);
  }

  function hasSkinningAttributes(program) {
    const cached = programSkinningCache.get(program);
    if (cached) return cached.match;
    programChecks++;
    const names = new Set();
    const n = gl.getProgramParameter(program, gl.ACTIVE_ATTRIBUTES);
    for (let i = 0; i < n; i++) {
      const a = gl.getActiveAttrib(program, i);
      if (a) names.add(a.name);
    }
    lastAttributes = Array.from(names);
    const match = names.has("POSITION") && names.has("TEXCOORD4") && names.has("TEXCOORD5");
    programSkinningCache.set(program, { match });
    if (match) candidatePrograms++;
    return match;
  }

  function getOverlay() {
    if (overlay?.isConnected) return overlay;
    const canvas = gl.canvas;
    const rect = canvas.getBoundingClientRect();
    overlay = document.createElement("canvas");
    overlay.width = canvas.width;
    overlay.height = canvas.height;
    Object.assign(overlay.style, {
      position: "fixed",
      left: rect.left + "px",
      top: rect.top + "px",
      width: rect.width + "px",
      height: rect.height + "px",
      pointerEvents: "none",
      zIndex: "2147483647"
    });
    document.body.appendChild(overlay);
    return overlay;
  }

  function renderOverlay() {
    if (!active) return;
    const canvas = getOverlay();
    const rect = gl.canvas.getBoundingClientRect();
    canvas.style.left = rect.left + "px";
    canvas.style.top = rect.top + "px";
    canvas.style.width = rect.width + "px";
    canvas.style.height = rect.height + "px";
    if (canvas.width !== gl.canvas.width || canvas.height !== gl.canvas.height) {
      canvas.width = gl.canvas.width;
      canvas.height = gl.canvas.height;
    }
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.strokeStyle = "#20e060";
    ctx.lineWidth = Math.max(1.5, canvas.width / 900);
    for (const item of boxes.values()) {
      ctx.strokeRect(item.x, item.y, item.w, item.h);
    }
  }

  function animationTick() {
    if (!active) return;
    renderOverlay();
    frameSerial++;
    seenThisFrame.clear();
    uniformFrameCache.clear();
    raf = requestAnimationFrame(animationTick);
  }

  function calculateBounds(count, type, indexOffset, indexBuffer, pos, boneIds, boneWeights, camera, bones) {
    if (!pos.enabled || !boneIds.enabled || !boneWeights.enabled) {
      throw new Error("A required skinning attribute is disabled");
    }
    if (pos.type !== gl.FLOAT || pos.size !== 3 ||
        boneIds.type !== gl.UNSIGNED_BYTE || boneIds.size !== 4 ||
        boneWeights.type !== gl.UNSIGNED_BYTE || boneWeights.size !== 4) {
      throw new Error("Attribute layout differs from the captured shader layout");
    }
    if (boneIds.buffer !== boneWeights.buffer) {
      throw new Error("Bone indices and weights are not in the same buffer");
    }

    const cam = new Float32Array(camera.bytes.buffer, camera.bytes.byteOffset,
      Math.floor(camera.bytes.byteLength / 4));
    const bmat = new Float32Array(bones.bytes.buffer, bones.bytes.byteOffset,
      Math.floor(bones.bytes.byteLength / 4));
    if (cam.length < 16 || bmat.length < 12) throw new Error("Uniform block too small");

    const indexBytes = readWholeBuffer(indexBuffer);
    let indices;
    if (type === gl.UNSIGNED_SHORT) {
      if (indexOffset % 2) throw new Error("Unaligned UNSIGNED_SHORT index offset");
      indices = new Uint16Array(indexBytes.buffer, indexBytes.byteOffset + indexOffset, count);
    } else if (type === gl.UNSIGNED_BYTE) {
      indices = indexBytes.subarray(indexOffset, indexOffset + count);
    } else if (type === gl.UNSIGNED_INT) {
      if (indexOffset % 4) throw new Error("Unaligned UNSIGNED_INT index offset");
      indices = new Uint32Array(indexBytes.buffer, indexBytes.byteOffset + indexOffset, count);
    } else {
      throw new Error("Unsupported index type " + enumName(type));
    }

    const pView = new DataView(pos.bytes.buffer, pos.bytes.byteOffset, pos.bytes.byteLength);
    const bView = new DataView(boneIds.bytes.buffer, boneIds.bytes.byteOffset, boneIds.bytes.byteLength);
    const wView = new DataView(boneWeights.bytes.buffer, boneWeights.bytes.byteOffset, boneWeights.bytes.byteLength);
    const viewport = gl.getParameter(gl.VIEWPORT);
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    let visible = 0;
    const visited = new Uint8Array(Math.ceil(pos.bytes.length / (pos.stride || 12)));

    for (let i = 0; i < indices.length; i++) {
      const vi = indices[i];
      if (vi >= visited.length || visited[vi]) continue;
      visited[vi] = 1;
      const po = pos.offset + vi * (pos.stride || 12);
      const bo = boneIds.offset + vi * (boneIds.stride || 4);
      const wo = boneWeights.offset + vi * (boneWeights.stride || 4);
      if (po + 12 > pos.bytes.length || bo + 4 > boneIds.bytes.length ||
          wo + 4 > boneWeights.bytes.length) continue;

      const px = pView.getFloat32(po, true);
      const py = pView.getFloat32(po + 4, true);
      const pz = pView.getFloat32(po + 8, true);
      let sx = 0, sy = 0, sz = 0;
      for (let j = 0; j < 4; j++) {
        const boneIndex = bView.getUint8(bo + j);
        const weight = wView.getUint8(wo + j) * (1 / 255);
        if (weight === 0) continue;
        const base = boneIndex * 12;
        if (base + 11 >= bmat.length) continue;
        sx += (px * bmat[base] + py * bmat[base + 1] +
          pz * bmat[base + 2] + bmat[base + 3]) * weight;
        sy += (px * bmat[base + 4] + py * bmat[base + 5] +
          pz * bmat[base + 6] + bmat[base + 7]) * weight;
        sz += (px * bmat[base + 8] + py * bmat[base + 9] +
          pz * bmat[base + 10] + bmat[base + 11]) * weight;
      }

      // GLSL mat4(CB0[0], CB0[1], CB0[2], CB0[3]) uses four column vectors.
      // The captured shader multiplies on the LEFT: skinnedPosition * mat4(...).
      // With CB0 vectors used as matrix columns, this is row-vector multiplication.
      const cx = sx * cam[0] + sy * cam[1] + sz * cam[2] + cam[3];
      const cy = sx * cam[4] + sy * cam[5] + sz * cam[6] + cam[7];
      const cz = sx * cam[8] + sy * cam[9] + sz * cam[10] + cam[11];
      const cw = sx * cam[12] + sy * cam[13] + sz * cam[14] + cam[15];
      if (!(cw > 0) || !Number.isFinite(cw)) continue;
      const nx = cx / cw, ny = cy / cw;
      if (!Number.isFinite(nx) || !Number.isFinite(ny)) continue;
      const x = viewport[0] + (nx * 0.5 + 0.5) * viewport[2];
      const y = viewport[1] + (1 - (ny * 0.5 + 0.5)) * viewport[3];
      minX = Math.min(minX, x); minY = Math.min(minY, y);
      maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
      visible++;
    }

    if (!visible || !Number.isFinite(minX)) return null;
    return { x: minX, y: minY, w: maxX - minX, h: maxY - minY, visible };
  }

  function onDraw(args, instanced) {
    if (!active) return;
    drawCalls++;
    const program = gl.getParameter(gl.CURRENT_PROGRAM);
    if (!program || !hasSkinningAttributes(program)) return;
    if (instanced) { skipped++; return; }

    const count = args[1], type = args[2], indexOffset = args[3];
    const viewport = Array.from(gl.getParameter(gl.VIEWPORT));
    if (viewport[0] !== 0 || viewport[1] !== 0 ||
        viewport[2] !== gl.drawingBufferWidth || viewport[3] !== gl.drawingBufferHeight) return;

    try {
      const pos = getAttribute(program, "POSITION");
      const boneIds = getAttribute(program, "TEXCOORD4");
      const boneWeights = getAttribute(program, "TEXCOORD5");
      const indexBuffer = gl.getParameter(gl.ELEMENT_ARRAY_BUFFER_BINDING);
      const camera = getBlock(program, "block_CB0");
      const bones = getBlock(program, "block_CB1");

      const rigKey = objectId(bones.buffer) + ":" + bones.start;
      // Geometry identity excludes shader/program so material passes cannot
      // create duplicate boxes for the same mesh.
      const meshKey = [
        rigKey,
        objectId(pos.buffer), pos.offset, pos.stride,
        objectId(boneIds.buffer), boneIds.offset, boneIds.stride,
        objectId(boneWeights.buffer), boneWeights.offset, boneWeights.stride,
        objectId(indexBuffer), count, type, indexOffset
      ].join(":");
      if (seenThisFrame.has(meshKey)) return;
      seenThisFrame.add(meshKey);

      const bounds = calculateBounds(
        count, type, indexOffset, indexBuffer,
        pos, boneIds, boneWeights, camera, bones
      );
      if (!bounds || bounds.w <= 1 || bounds.h <= 1) return;

      // All body-part draw calls using the same bone UBO range are one rig.
      // Union their bounds in the current frame, producing one full-body box.
      if (rigFrameSerial.get(rigKey) !== frameSerial) {
        boxes.set(rigKey, bounds);
        rigFrameSerial.set(rigKey, frameSerial);
      } else {
        const old = boxes.get(rigKey);
        if (old) {
          const x1 = Math.min(old.x, bounds.x);
          const y1 = Math.min(old.y, bounds.y);
          const x2 = Math.max(old.x + old.w, bounds.x + bounds.w);
          const y2 = Math.max(old.y + old.h, bounds.y + bounds.h);
          boxes.set(rigKey, { x: x1, y: y1, w: x2 - x1, h: y2 - y1 });
        } else {
          boxes.set(rigKey, bounds);
        }
      }
      captured++;
      if (boxes.size > 100) {
        const firstKey = boxes.keys().next().value;
        boxes.delete(firstKey);
        rigFrameSerial.delete(firstKey);
      }
    } catch (e) {
      skipped++;
      console.warn("[GreenBoxCPU] capture skipped:", e.message);
    }
  }

  gl.drawElements = function (...args) {
    try { onDraw(args, false); }
    catch (e) { console.warn("[GreenBoxCPU] draw inspection failed:", e); }
    return original.drawElements.apply(this, args);
  };
  gl.drawElementsInstanced = function (...args) {
    try { onDraw(args, true); }
    catch (e) { console.warn("[GreenBoxCPU] instanced draw inspection failed:", e); }
    return original.drawElementsInstanced.apply(this, args);
  };

  function stop() {
    if (!active) return;
    active = false;
    gl.drawElements = original.drawElements;
    gl.drawElementsInstanced = original.drawElementsInstanced;
    cancelAnimationFrame(raf);
    overlay?.remove();
    boxes.clear();
    console.info("[GreenBoxCPU] stopped. Successful bounds:", captured,
      "skipped captures:", skipped);
  }

  window[KEY] = { stop, stats: () => ({ active, captureMode: "one capture per unique mesh per frame", groupedByBonePalette: true, canvas: { width: gl.canvas.width, height: gl.canvas.height, id: gl.canvas.id, isModuleCanvas: gl.canvas === window.Module?.canvas }, drawCalls, programChecks, candidatePrograms, lastAttributes, captured, skipped, boxes: boxes.size }) };
  animationTick();
  console.info("[GreenBoxCPU] running experimental CPU bounds. Stop with " +
    "window.__greenBoxCpuBounds.stop()");
})();
