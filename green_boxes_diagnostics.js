/*
 * Roblox WebGL2 skinned-mesh diagnostics (read-only observer)
 *
 * Collects vertex attribute layouts, index-buffer details, uniform-block
 * bindings/ranges, and draw parameters for skinned draws.
 * Does NOT replay draws, start transform feedback, alter shaders, or draw
 * an overlay. It wraps drawElements/drawElementsInstanced only to inspect
 * state immediately before the game's original draw.
 *
 * Run in DevTools. Stop with:
 *   window.__greenBoxDiagnostics.stop()
 * Copy report with:
 *   copy(window.__greenBoxDiagnostics.report())
 */
(() => {
  const KEY = "__greenBoxDiagnostics";
  window[KEY]?.stop?.();

  const gl = window.Module?.canvas?.getContext("webgl2");
  if (!gl || gl.isContextLost()) {
    console.error("[GreenBoxDiag] WebGL2 context not found at Module.canvas.");
    return;
  }

  const original = {
    drawElements: gl.drawElements,
    drawElementsInstanced: gl.drawElementsInstanced
  };
  const programIds = new WeakMap();
  const bufferIds = new WeakMap();
  let nextProgramId = 1;
  let nextBufferId = 1;
  let active = true;
  let totalSkinnedDraws = 0;
  const records = new Map();
  const MAX_RECORDS = 40;
  const enumCache = new Map();

  const enumName = value => {
    if (enumCache.has(value)) return enumCache.get(value);
    let name = "0x" + Number(value).toString(16);
    for (const key of Object.keys(gl)) {
      try {
        if (gl[key] === value && /^[A-Z0-9_]+$/.test(key)) {
          name = key;
          break;
        }
      } catch (_) {}
    }
    enumCache.set(value, name);
    return name;
  };
  const objectId = (obj, map, next) => {
    if (!obj) return null;
    if (!map.has(obj)) map.set(obj, next());
    return map.get(obj);
  };
  const pid = p => objectId(p, programIds, () => nextProgramId++);
  const bid = b => objectId(b, bufferIds, () => nextBufferId++);

  function readBufferSize(buffer) {
    if (!buffer) return null;
    const old = gl.getParameter(gl.COPY_READ_BUFFER_BINDING);
    try {
      gl.bindBuffer(gl.COPY_READ_BUFFER, buffer);
      return gl.getBufferParameter(gl.COPY_READ_BUFFER, gl.BUFFER_SIZE);
    } catch (_) {
      return null;
    } finally {
      gl.bindBuffer(gl.COPY_READ_BUFFER, old);
    }
  }

  function isSkinned(program) {
    const names = new Set();
    const n = gl.getProgramParameter(program, gl.ACTIVE_ATTRIBUTES);
    for (let i = 0; i < n; i++) {
      const a = gl.getActiveAttrib(program, i);
      if (a) names.add(a.name);
    }
    return ["POSITION", "TEXCOORD4", "TEXCOORD5"].every(x => names.has(x));
  }

  function inspectAttributes(program) {
    const result = [];
    const n = gl.getProgramParameter(program, gl.ACTIVE_ATTRIBUTES);
    for (let i = 0; i < n; i++) {
      const info = gl.getActiveAttrib(program, i);
      if (!info) continue;
      const location = gl.getAttribLocation(program, info.name);
      if (location < 0) continue;
      const buffer = gl.getVertexAttrib(location, gl.VERTEX_ATTRIB_ARRAY_BUFFER_BINDING);
      result.push({
        name: info.name,
        shaderType: enumName(info.type),
        sizeInShader: info.size,
        location,
        enabled: !!gl.getVertexAttrib(location, gl.VERTEX_ATTRIB_ARRAY_ENABLED),
        bufferId: bid(buffer),
        bufferBytes: readBufferSize(buffer),
        components: gl.getVertexAttrib(location, gl.VERTEX_ATTRIB_ARRAY_SIZE),
        componentType: enumName(gl.getVertexAttrib(location, gl.VERTEX_ATTRIB_ARRAY_TYPE)),
        normalized: !!gl.getVertexAttrib(location, gl.VERTEX_ATTRIB_ARRAY_NORMALIZED),
        integer: !!gl.getVertexAttrib(location, gl.VERTEX_ATTRIB_ARRAY_INTEGER),
        strideBytes: gl.getVertexAttrib(location, gl.VERTEX_ATTRIB_ARRAY_STRIDE),
        offsetBytes: gl.getVertexAttribOffset(location, gl.VERTEX_ATTRIB_ARRAY_POINTER),
        divisor: gl.getVertexAttrib(location, gl.VERTEX_ATTRIB_ARRAY_DIVISOR)
      });
    }
    return result;
  }

  function inspectUniformBlocks(program) {
    const result = [];
    const n = gl.getProgramParameter(program, gl.ACTIVE_UNIFORM_BLOCKS);
    for (let i = 0; i < n; i++) {
      const name = gl.getActiveUniformBlockName(program, i);
      const binding = gl.getActiveUniformBlockParameter(program, i, gl.UNIFORM_BLOCK_BINDING);
      const dataSize = gl.getActiveUniformBlockParameter(program, i, gl.UNIFORM_BLOCK_DATA_SIZE);
      const buffer = gl.getIndexedParameter(gl.UNIFORM_BUFFER_BINDING, binding);
      const start = gl.getIndexedParameter(gl.UNIFORM_BUFFER_START, binding);
      const size = gl.getIndexedParameter(gl.UNIFORM_BUFFER_SIZE, binding);
      result.push({
        name, blockIndex: i, binding, dataBytes: dataSize,
        bufferId: bid(buffer), bufferBytes: readBufferSize(buffer),
        rangeStartBytes: start, rangeSizeBytes: size
      });
    }
    return result;
  }

  function recordDraw(kind, args) {
    if (!active) return;
    const program = gl.getParameter(gl.CURRENT_PROGRAM);
    if (!program || !isSkinned(program)) return;
    totalSkinnedDraws++;

    const vao = gl.getParameter(gl.VERTEX_ARRAY_BINDING);
    const elementBuffer = gl.getParameter(gl.ELEMENT_ARRAY_BUFFER_BINDING);
    const key = [pid(program), bid(vao), bid(elementBuffer), kind,
      args[0], args[1], args[2], args[3], args[4]].join(":");
    let entry = records.get(key);
    if (entry) {
      entry.calls++;
      entry.lastSeen = new Date().toISOString();
      return;
    }
    if (records.size >= MAX_RECORDS) return;

    const indexed = kind !== "drawArrays";
    const indexType = indexed ? enumName(args[2]) : null;
    const indexBytes = !indexed ? null :
      args[2] === gl.UNSIGNED_BYTE ? 1 :
      args[2] === gl.UNSIGNED_SHORT ? 2 :
      args[2] === gl.UNSIGNED_INT ? 4 : null;

    entry = {
      key, calls: 1, firstSeen: new Date().toISOString(), lastSeen: null,
      programId: pid(program), vaoId: bid(vao), drawKind: kind,
      mode: enumName(args[0]), count: args[1],
      indexType, indexBytes, indexOffset: indexed ? args[3] : null,
      indexBufferId: bid(elementBuffer),
      indexBufferBytes: indexed ? readBufferSize(elementBuffer) : null,
      instanceCount: kind === "drawElementsInstanced" ? args[4] : null,
      viewport: Array.from(gl.getParameter(gl.VIEWPORT)),
      attributes: inspectAttributes(program),
      uniformBlocks: inspectUniformBlocks(program)
    };
    records.set(key, entry);
    console.info("[GreenBoxDiag] captured skinned draw", entry);
  }

  gl.drawElements = function (...args) {
    try { recordDraw("drawElements", args); }
    catch (e) { console.warn("[GreenBoxDiag] inspection failed:", e); }
    return original.drawElements.apply(this, args);
  };
  gl.drawElementsInstanced = function (...args) {
    try { recordDraw("drawElementsInstanced", args); }
    catch (e) { console.warn("[GreenBoxDiag] inspection failed:", e); }
    return original.drawElementsInstanced.apply(this, args);
  };

  function report() {
    return JSON.stringify({
      tool: "green_boxes_diagnostics",
      version: 1,
      capturedAt: new Date().toISOString(),
      totalSkinnedDraws,
      uniqueDraws: records.size,
      records: Array.from(records.values())
    }, null, 2);
  }

  function stop() {
    if (!active) return;
    active = false;
    if (gl.drawElements !== original.drawElements) gl.drawElements = original.drawElements;
    if (gl.drawElementsInstanced !== original.drawElementsInstanced) {
      gl.drawElementsInstanced = original.drawElementsInstanced;
    }
    console.info("[GreenBoxDiag] stopped. Skinned draws observed:",
      totalSkinnedDraws, "unique layouts:", records.size);
  }

  window[KEY] = { stop, report };
  console.info("[GreenBoxDiag] observer-only mode. Move around so character meshes render, then run:\n" +
    "copy(window.__greenBoxDiagnostics.report())\n" +
    "Stop with window.__greenBoxDiagnostics.stop()");
})();
