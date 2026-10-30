/*
 * Experimental CPU skinned-mesh bounds for Roblox WebGL2.
 *
 * Uses read-only GPU buffer readback + the skinning math observed in the
 * captured vertex shader. It never replays a game draw, starts transform
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
  const lastCapture = new Map();
  const boxes = new Map();
  const hookedPrograms = new WeakSet();
  let active = true;
  let overlay = null;
  let raf = 0;
  let captured = 0;
  let skipped = 0;

  const now = () => performance.now();
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
      return { bytes: readRange(buffer, start, size), size, start };
    }
    throw new Error("Missing uniform block " + wantedName);
  }

  function hasSkinningAttributes(program) {
    const names = new Set();
    const n = gl.getProgramParameter(program, gl.ACTIVE_ATTRIBUTES);
    for (let i = 0; i < n; i++) {
      const a = gl.getActiveAttrib(program, i);
      if (a) names.add(a.name);
    }
    return names.has("POSITION") && names.has("TEXCOORD4") && names.has("TEXCOORD5");
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

  function render() {
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
    raf = requestAnimationFrame(render);
  }

  function calculateBounds(program, count, type, indexOffset, indexBuffer) {
    const pos = getAttribute(program, "POSITION");
    const boneIds = getAttribute(program, "TEXCOORD4");
    const boneWeights = getAttribute(program, "TEXCOORD5");
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

    const camera = getBlock(program, "block_CB0");
    const bones = getBlock(program, "block_CB1");
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

    for (let i = 0; i < indices.length; i++) {
      const vi = indices[i];
      const po = pos.offset + vi * (pos.stride || 12);
      const bo = boneIds.offset + vi * (boneIds.stride || 4);
      const wo = boneWeights.offset + vi * (boneWeights.stride || 4);
      if (po + 12 > pos.bytes.length || bo + 4 > boneIds.bytes.length ||
          wo + 4 > boneWeights.bytes.length) continue;

      const px = pView.getFloat32(po, true);
      const py = pView.getFloat32(po + 4, true);
      const pz = pView.getFloat32(po + 8, true);
      const ids = [bView.getUint8(bo), bView.getUint8(bo + 1),
                   bView.getUint8(bo + 2), bView.getUint8(bo + 3)];
      const weights = [wView.getUint8(wo) / 255, wView.getUint8(wo + 1) / 255,
                       wView.getUint8(wo + 2) / 255, wView.getUint8(wo + 3) / 255];

      let sx = 0, sy = 0, sz = 0;
      for (let j = 0; j < 4; j++) {
        const base = ids[j] * 12;
        if (base + 11 >= bmat.length) continue;
        const weight = weights[j];
        const d = px * bmat[base] + py * bmat[base + 1] +
                  pz * bmat[base + 2] + bmat[base + 3];
        const e = px * bmat[base + 4] + py * bmat[base + 5] +
                  pz * bmat[base + 6] + bmat[base + 7];
        const f = px * bmat[base + 8] + py * bmat[base + 9] +
                  pz * bmat[base + 10] + bmat[base + 11];
        sx += d * weight; sy += e * weight; sz += f * weight;
      }

      // GLSL mat4(CB0[0], CB0[1], CB0[2], CB0[3]) uses four column vectors.
      const cx = cam[0] * sx + cam[4] * sy + cam[8] * sz + cam[12];
      const cy = cam[1] * sx + cam[5] * sy + cam[9] * sz + cam[13];
      const cz = cam[2] * sx + cam[6] * sy + cam[10] * sz + cam[14];
      const cw = cam[3] * sx + cam[7] * sy + cam[11] * sz + cam[15];
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
    const program = gl.getParameter(gl.CURRENT_PROGRAM);
    if (!program || !hasSkinningAttributes(program)) return;
    if (instanced) { skipped++; return; }

    const count = args[1], type = args[2], offset = args[3];
    const indexBuffer = gl.getParameter(gl.ELEMENT_ARRAY_BUFFER_BINDING);
    const key = [count, type, offset,
      gl.getVertexAttribOffset(gl.getAttribLocation(program, "POSITION"),
        gl.VERTEX_ATTRIB_ARRAY_POINTER)].join(":");
    const t = now();
    if (t - (lastCapture.get(key) || 0) < 120) return;
    lastCapture.set(key, t);

    try {
      const bounds = calculateBounds(program, count, type, offset, indexBuffer);
      if (bounds && bounds.w > 1 && bounds.h > 1) {
        boxes.set(key, bounds);
        captured++;
      } else {
        boxes.delete(key);
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

  window[KEY] = { stop, stats: () => ({ active, captured, skipped, boxes: boxes.size }) };
  render();
  console.info("[GreenBoxCPU] running experimental CPU bounds. Stop with " +
    "window.__greenBoxCpuBounds.stop()");
})();
