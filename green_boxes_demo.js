(() => {
  const KEY = "__robloxGreenBoxes";
  if (window[KEY]?.stop) window[KEY].stop();
  window.__greenWireOverlay?.stop?.();
  window.__wireframeStop?.();
  window.__wireframeCycleStop?.();

  const gl = Module.canvas?.getContext("webgl2");
  if (!gl || gl.isContextLost() || !gl.transformFeedbackVaryings) {
    console.error("WebGL2 transform feedback is unavailable.");
    return;
  }

  // "palette" = one box per CB1 range; "all" = one combined box.
  const GROUP_MODE = "palette";
  const CAPTURE_MS = 80;
  const STALE_MS = 350;
  const gameCanvas = Module.canvas;
  const originalDraw = gl.drawElements;
  const programCache = new WeakMap();
  const programIds = new WeakMap();
  const objectIds = new WeakMap();
  const lastCapture = new Map();
  const latestMeshes = new Map();
  const resources = new Set();
  let nextProgramId = 1, nextObjectId = 1, active = true, raf = 0;

  const id = (obj, map, next) => {
    if (!obj) return 0;
    if (!map.has(obj)) map.set(obj, next());
    return map.get(obj);
  };
  const programId = p => id(p, programIds, () => nextProgramId++);
  const objectId = o => id(o, objectIds, () => nextObjectId++);

  function isSkinned(p) {
    const names = new Set();
    const n = gl.getProgramParameter(p, gl.ACTIVE_ATTRIBUTES);
    for (let i = 0; i < n; i++) {
      const a = gl.getActiveAttrib(p, i);
      if (a) names.add(a.name);
    }
    return ["POSITION", "NORMAL", "TEXCOORD4", "TEXCOORD5"]
      .every(name => names.has(name));
  }

  function getBoneRange(p) {
    const index = gl.getUniformBlockIndex(p, "block_CB1");
    if (index === gl.INVALID_INDEX || index === 0xFFFFFFFF) return null;
    const binding = gl.getActiveUniformBlockParameter(
      p, index, gl.UNIFORM_BLOCK_BINDING
    );
    return {
      offset: gl.getIndexedParameter(gl.UNIFORM_BUFFER_START, binding)
    };
  }

  function makeCaptureProgram(original) {
    const attached = gl.getAttachedShaders(original) || [];
    const sourceShader = attached.find(s =>
      gl.getShaderParameter(s, gl.SHADER_TYPE) === gl.VERTEX_SHADER
    );
    if (!sourceShader) throw new Error("Original vertex shader not found.");

    const vs = gl.createShader(gl.VERTEX_SHADER);
    gl.shaderSource(vs, gl.getShaderSource(sourceShader));
    gl.compileShader(vs);
    if (!gl.getShaderParameter(vs, gl.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(vs);
      gl.deleteShader(vs);
      throw new Error("Vertex shader copy failed: " + log);
    }

    const fs = gl.createShader(gl.FRAGMENT_SHADER);
    gl.shaderSource(fs, `#version 300 es
precision highp float;
out vec4 unusedColor;
void main(){ unusedColor=vec4(0.0); }
`);
    gl.compileShader(fs);
    if (!gl.getShaderParameter(fs, gl.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(fs);
      gl.deleteShader(vs); gl.deleteShader(fs);
      throw new Error("Capture fragment shader failed: " + log);
    }

    const p = gl.createProgram();
    if (!p) {
      gl.deleteShader(vs); gl.deleteShader(fs);
      throw new Error("Could not create capture program.");
    }

    try {
      const n = gl.getProgramParameter(original, gl.ACTIVE_ATTRIBUTES);
      for (let i = 0; i < n; i++) {
        const a = gl.getActiveAttrib(original, i);
        if (!a) continue;
        const loc = gl.getAttribLocation(original, a.name);
        if (loc >= 0) gl.bindAttribLocation(p, loc, a.name);
      }

      gl.attachShader(p, vs);
      gl.attachShader(p, fs);
      gl.transformFeedbackVaryings(p, ["gl_Position"], gl.INTERLEAVED_ATTRIBS);
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
        throw new Error("Capture program link failed: " + gl.getProgramInfoLog(p));
      }
      const varying = gl.getTransformFeedbackVarying(p, 0);
      if (!varying || varying.name !== "gl_Position") {
        throw new Error("gl_Position transform feedback was not linked.");
      }

      const blocks = gl.getProgramParameter(original, gl.ACTIVE_UNIFORM_BLOCKS);
      for (let i = 0; i < blocks; i++) {
        const name = gl.getActiveUniformBlockName(original, i);
        const oldIndex = gl.getUniformBlockIndex(original, name);
        const newIndex = gl.getUniformBlockIndex(p, name);
        if (newIndex === gl.INVALID_INDEX || newIndex === 0xFFFFFFFF) continue;
        const binding = gl.getActiveUniformBlockParameter(
          original, oldIndex, gl.UNIFORM_BLOCK_BINDING
        );
        gl.uniformBlockBinding(p, newIndex, binding);
      }

      const state = {
        program: p,
        feedback: gl.createTransformFeedback(),
        buffer: gl.createBuffer(),
        bytes: 0
      };
      if (!state.feedback || !state.buffer) {
        throw new Error("Could not allocate transform-feedback objects.");
      }
      resources.add(state);
      return state;
    } catch (e) {
      gl.deleteProgram(p);
      throw e;
    } finally {
      gl.detachShader(p, fs);
      gl.detachShader(p, vs);
      gl.deleteShader(fs);
      gl.deleteShader(vs);
    }
  }

  function getCaptureProgram(original) {
    if (programCache.has(original)) return programCache.get(original);
    try {
      const state = makeCaptureProgram(original);
      programCache.set(original, state);
      return state;
    } catch (e) {
      programCache.set(original, null);
      throw e;
    }
  }

  function capturePositions(state, args, receiver) {
    const count = args[1];
    if (!Number.isInteger(count) || count <= 0 || count > 200000) return null;
    if (gl.getParameter(gl.TRANSFORM_FEEDBACK_ACTIVE)) return null;
    const bytes = count * 16;
    const oldProgram = gl.getParameter(gl.CURRENT_PROGRAM);
    const oldFeedback = gl.getParameter(gl.TRANSFORM_FEEDBACK_BINDING);
    const oldTFBuffer = gl.getParameter(gl.TRANSFORM_FEEDBACK_BUFFER_BINDING);
    const wasDiscard = gl.isEnabled(gl.RASTERIZER_DISCARD);
    let begun = false;

    try {
      gl.bindTransformFeedback(gl.TRANSFORM_FEEDBACK, state.feedback);
      gl.bindBufferBase(gl.TRANSFORM_FEEDBACK_BUFFER, 0, state.buffer);
      gl.bindBuffer(gl.TRANSFORM_FEEDBACK_BUFFER, state.buffer);
      if (state.bytes < bytes) {
        gl.bufferData(gl.TRANSFORM_FEEDBACK_BUFFER, bytes, gl.DYNAMIC_READ);
        state.bytes = bytes;
      }
      gl.useProgram(state.program);
      if (!wasDiscard) gl.enable(gl.RASTERIZER_DISCARD);
      gl.beginTransformFeedback(gl.TRIANGLES);
      begun = true;
      originalDraw.apply(receiver, args);
      gl.endTransformFeedback();
      begun = false;
      gl.bindBuffer(gl.TRANSFORM_FEEDBACK_BUFFER, state.buffer);
      const out = new Float32Array(count * 4);
      gl.getBufferSubData(gl.TRANSFORM_FEEDBACK_BUFFER, 0, out);
      return out;
    } finally {
      if (begun) { try { gl.endTransformFeedback(); } catch (_) {} }
      if (!wasDiscard) gl.disable(gl.RASTERIZER_DISCARD);
      gl.bindTransformFeedback(gl.TRANSFORM_FEEDBACK, oldFeedback);
      gl.bindBuffer(gl.TRANSFORM_FEEDBACK_BUFFER, oldTFBuffer);
      gl.useProgram(oldProgram);
    }
  }

  function boundsFromClip(out, viewport, rect) {
    const dw = gl.drawingBufferWidth, dh = gl.drawingBufferHeight;
    if (!dw || !dh || !rect.width || !rect.height) return null;
    const [vx, vy, vw, vh] = viewport;
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (let i = 0; i < out.length; i += 4) {
      const w = out[i + 3];
      if (!Number.isFinite(w) || w <= 0.00001) continue;
      const x = out[i] / w, y = out[i + 1] / w;
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
      const px = vx + (x * 0.5 + 0.5) * vw;
      const py = vy + (y * 0.5 + 0.5) * vh;
      minX = Math.min(minX, px); maxX = Math.max(maxX, px);
      minY = Math.min(minY, py); maxY = Math.max(maxY, py);
    }
    if (!Number.isFinite(minX)) return null;
    minX = Math.max(vx, Math.min(vx + vw, minX));
    maxX = Math.max(vx, Math.min(vx + vw, maxX));
    minY = Math.max(vy, Math.min(vy + vh, minY));
    maxY = Math.max(vy, Math.min(vy + vh, maxY));
    if (maxX <= minX || maxY <= minY) return null;
    const sx = rect.width / dw, sy = rect.height / dh;
    return {
      left: rect.left + minX * sx,
      right: rect.left + maxX * sx,
      top: rect.top + (dh - maxY) * sy,
      bottom: rect.top + (dh - minY) * sy
    };
  }

  function meshSignature(p, args, paletteOffset) {
    const loc = gl.getAttribLocation(p, "POSITION");
    const buffer = loc >= 0
      ? gl.getVertexAttrib(loc, gl.VERTEX_ATTRIB_ARRAY_BUFFER_BINDING) : null;
    const pointer = loc >= 0
      ? gl.getVertexAttribOffset(loc, gl.VERTEX_ATTRIB_ARRAY_POINTER) : -1;
    const indexBuffer = gl.getParameter(gl.ELEMENT_ARRAY_BUFFER_BINDING);
    return [programId(p), objectId(buffer), pointer, objectId(indexBuffer),
      args[1], args[2], args[3], paletteOffset].join("|");
  }

  const wrapper = function (...args) {
    if (!active || args[0] !== gl.TRIANGLES) return originalDraw.apply(this, args);
    const p = gl.getParameter(gl.CURRENT_PROGRAM);
    if (!p || !isSkinned(p) || !gl.isEnabled(gl.DEPTH_TEST) ||
        !gl.getParameter(gl.DEPTH_WRITEMASK)) {
      return originalDraw.apply(this, args);
    }
    const bone = getBoneRange(p);
    if (!bone || !Number.isFinite(bone.offset)) return originalDraw.apply(this, args);

    const sig = meshSignature(p, args, bone.offset);
    const now = performance.now();
    if (now - (lastCapture.get(sig) || 0) >= CAPTURE_MS) {
      lastCapture.set(sig, now);
      try {
        const state = getCaptureProgram(p);
        if (state) {
          const out = capturePositions(state, args, this);
          if (out) {
            const viewport = Array.from(gl.getParameter(gl.VIEWPORT));
            const bounds = boundsFromClip(out, viewport, gameCanvas.getBoundingClientRect());
            if (bounds) {
              latestMeshes.set(sig, {
                group: GROUP_MODE === "all" ? "all" : String(bone.offset),
                bounds,
                seen: now
              });
            }
          }
        }
      } catch (e) {
        console.warn("Green box capture skipped:", e);
      }
    }
    return originalDraw.apply(this, args);
  };

  const overlay = document.createElement("canvas");
  overlay.id = "roblox-green-model-boxes";
  overlay.style.cssText = "position:fixed;inset:0;width:100vw;height:100vh;pointer-events:none;z-index:2147483647";
  document.documentElement.appendChild(overlay);
  const ctx = overlay.getContext("2d");

  function render() {
    if (!active) return;
    const dpr = window.devicePixelRatio || 1;
    const w = Math.max(1, Math.round(innerWidth * dpr));
    const h = Math.max(1, Math.round(innerHeight * dpr));
    if (overlay.width !== w || overlay.height !== h) {
      overlay.width = w;
      overlay.height = h;
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, innerWidth, innerHeight);

    const now = performance.now();
    const groups = new Map();
    for (const [sig, item] of latestMeshes) {
      if (now - item.seen > STALE_MS) {
        latestMeshes.delete(sig);
        continue;
      }
      let b = groups.get(item.group);
      if (!b) {
        b = { left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity };
        groups.set(item.group, b);
      }
      b.left = Math.min(b.left, item.bounds.left);
      b.top = Math.min(b.top, item.bounds.top);
      b.right = Math.max(b.right, item.bounds.right);
      b.bottom = Math.max(b.bottom, item.bounds.bottom);
    }

    ctx.strokeStyle = "#00ff55";
    ctx.lineWidth = 2;
    ctx.shadowColor = "rgba(0,255,85,.55)";
    ctx.shadowBlur = 5;
    for (const b of groups.values()) {
      const bw = b.right - b.left, bh = b.bottom - b.top;
      if (bw > 2 && bh > 2) ctx.strokeRect(b.left, b.top, bw, bh);
    }
    ctx.shadowBlur = 0;
    raf = requestAnimationFrame(render);
  }

  gl.drawElements = wrapper;
  raf = requestAnimationFrame(render);

  function stop() {
    if (!active) return "Already stopped.";
    active = false;
    cancelAnimationFrame(raf);
    if (gl.drawElements === wrapper) gl.drawElements = originalDraw;
    overlay.remove();
    if (!gl.isContextLost()) {
      for (const r of resources) {
        gl.deleteProgram(r.program);
        gl.deleteTransformFeedback(r.feedback);
        gl.deleteBuffer(r.buffer);
      }
      const ext = gl.getExtension("WEBGL_polygon_mode");
      if (ext) ext.polygonModeWEBGL(gl.FRONT_AND_BACK, ext.FILL_WEBGL);
    }
    latestMeshes.clear();
    lastCapture.clear();
    delete window[KEY];
    console.log("Green boxes stopped; original rendering restored.");
    return "Stopped.";
  }

  window[KEY] = { stop };
  console.log("Green model boxes enabled. Grouping:", GROUP_MODE);
  console.log("Stop with window.__robloxGreenBoxes.stop()");
  return "Bounding-box demo installed.";
})();