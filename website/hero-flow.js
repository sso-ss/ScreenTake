function createHeroFlow(canvas) {
  const graphics = canvas.getContext('webgl', { alpha: false, antialias: false, depth: false, powerPreference: 'low-power' });
  if (!graphics) return null;
  const vertexSource = `
    attribute vec2 position;
    void main() { gl_Position = vec4(position, 0.0, 1.0); }
  `;
  const fragmentSource = `
    precision mediump float;
    uniform vec2 resolution;
    uniform vec2 pointer;
    uniform float phase;
    uniform float strength;
    float hash(vec2 point) {
      return fract(sin(dot(point, vec2(127.1, 311.7))) * 43758.5453);
    }
    float noise(vec2 point) {
      vec2 cell = floor(point);
      vec2 blend = fract(point);
      blend = blend * blend * (3.0 - 2.0 * blend);
      return mix(mix(hash(cell), hash(cell + vec2(1.0, 0.0)), blend.x),
        mix(hash(cell + vec2(0.0, 1.0)), hash(cell + vec2(1.0, 1.0)), blend.x), blend.y);
    }
    float field(vec2 point) {
      float value = noise(point) * 0.57;
      point = mat2(1.6, -1.2, 1.2, 1.6) * point;
      value += noise(point + 8.3) * 0.28;
      value += noise(point * 2.0 + 3.8) * 0.15;
      return value;
    }
    void main() {
      vec2 uv = gl_FragCoord.xy / resolution;
      float aspect = resolution.x / resolution.y;
      vec2 point = vec2(uv.x * aspect, uv.y);
      vec2 distanceToMouse = point - vec2(pointer.x * aspect, 1.0 - pointer.y);
      float influence = exp(-dot(distanceToMouse, distanceToMouse) * 7.0) * strength;
      point += vec2(-distanceToMouse.y, distanceToMouse.x) * influence * 0.75;
      point += vec2(0.15, -0.1) * influence;
      vec2 drift = vec2(cos(phase), sin(phase)) * 0.65;
      vec2 warp = vec2(field(point * 2.1 + drift), field(point * 2.1 - drift + 5.2));
      float folds = field(point * vec2(2.8, 2.2) + warp * 2.3 + drift);
      float light = smoothstep(0.29, 0.73, folds);
      float ribbons = sin((point.x * 0.8 - point.y + warp.x * 0.65) * 11.0 + sin(phase) * 1.8);
      float shade = smoothstep(-0.65, 0.8, ribbons) * 0.23;
      vec3 plum = vec3(0.60, 0.48, 0.75);
      vec3 lilac = vec3(0.82, 0.72, 0.94);
      vec3 pearl = vec3(0.95, 0.89, 0.98);
      vec3 color = mix(plum, lilac, light);
      color = mix(color, pearl, smoothstep(0.42, 0.78, folds) * 0.85 + shade);
      float textLight = exp(-dot((uv - vec2(0.5, 0.77)) * vec2(1.7, 2.6), (uv - vec2(0.5, 0.77)) * vec2(1.7, 2.6)) * 3.0);
      color = mix(color, pearl, textLight * 0.48);
      color += (hash(gl_FragCoord.xy) - 0.5) * 0.009;
      gl_FragColor = vec4(color, 1.0);
    }
  `;
  const shaders = [];
  const compile = (type, source) => {
    const shader = graphics.createShader(type);
    shaders.push(shader);
    graphics.shaderSource(shader, source);
    graphics.compileShader(shader);
    return graphics.getShaderParameter(shader, graphics.COMPILE_STATUS) ? shader : null;
  };
  const vertex = compile(graphics.VERTEX_SHADER, vertexSource);
  const fragment = compile(graphics.FRAGMENT_SHADER, fragmentSource);
  if (!vertex || !fragment) {
    shaders.forEach(shader => graphics.deleteShader(shader));
    return null;
  }
  const program = graphics.createProgram();
  graphics.attachShader(program, vertex);
  graphics.attachShader(program, fragment);
  graphics.linkProgram(program);
  shaders.forEach(shader => graphics.deleteShader(shader));
  if (!graphics.getProgramParameter(program, graphics.LINK_STATUS)) {
    graphics.deleteProgram(program);
    return null;
  }
  graphics.useProgram(program);
  const buffer = graphics.createBuffer();
  graphics.bindBuffer(graphics.ARRAY_BUFFER, buffer);
  graphics.bufferData(graphics.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), graphics.STATIC_DRAW);
  const position = graphics.getAttribLocation(program, 'position');
  graphics.enableVertexAttribArray(position);
  graphics.vertexAttribPointer(position, 2, graphics.FLOAT, false, 0, 0);
  const uniforms = Object.fromEntries(['resolution', 'pointer', 'phase', 'strength'].map(name => [name, graphics.getUniformLocation(program, name)]));
  const state = { phase: 0, x: .5, y: .3, strength: 0 };
  const draw = () => {
    graphics.uniform2f(uniforms.resolution, canvas.width, canvas.height);
    graphics.uniform2f(uniforms.pointer, state.x, state.y);
    graphics.uniform1f(uniforms.phase, state.phase);
    graphics.uniform1f(uniforms.strength, state.strength);
    graphics.drawArrays(graphics.TRIANGLES, 0, 6);
  };
  const resize = () => {
    const bounds = canvas.getBoundingClientRect();
    const resolutionScale = Math.min(1, 1200 / Math.max(bounds.width, bounds.height));
    canvas.width = Math.max(1, Math.round(bounds.width * resolutionScale));
    canvas.height = Math.max(1, Math.round(bounds.height * resolutionScale));
    graphics.viewport(0, 0, canvas.width, canvas.height);
    draw();
  };
  const resizeObserver = new ResizeObserver(resize);
  resizeObserver.observe(canvas);
  resize();
  canvas.classList.add('is-ready');
  return {
    state,
    draw,
    dispose() {
      resizeObserver.disconnect();
      graphics.deleteBuffer(buffer);
      graphics.deleteProgram(program);
      canvas.classList.remove('is-ready');
    }
  };
}
