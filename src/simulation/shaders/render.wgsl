// Fullscreen quad renderer: reads cell buffer, maps elements to colors
// Vertex shader generates a fullscreen triangle from vertex_index (no vertex buffer needed)

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
  // Fullscreen triangle trick: 3 vertices cover the entire screen
  var out: VertexOutput;
  let x = f32(i32(vertex_index) / 2) * 4.0 - 1.0;
  let y = f32(i32(vertex_index) % 2) * 4.0 - 1.0;
  out.position = vec4f(x, y, 0.0, 1.0);
  // UV: map to [0,1] range, flip Y so top of grid = top of screen
  out.uv = vec2f((x + 1.0) * 0.5, 1.0 - (y + 1.0) * 0.5);
  return out;
}

// Cell encoding: bits 0-7 = element type, bits 8-15 = color variation
const ELEMENT_MASK: u32 = 0xFFu;
const COLOR_SHIFT: u32 = 8u;
const COLOR_MASK: u32 = 0xFFu;

const EMPTY: u32 = 0u;
const SAND: u32 = 1u;
const WATER: u32 = 2u;
const STONE: u32 = 3u;

struct RenderParams {
  width: u32,
  height: u32,
}

@group(0) @binding(0) var<storage, read> cells: array<u32>;
@group(0) @binding(1) var<uniform> params: RenderParams;

fn sandColor(variation: f32) -> vec3f {
  // Warm sand palette with per-particle variation
  let base = vec3f(0.87, 0.72, 0.42);
  let dark = vec3f(0.72, 0.58, 0.32);
  let light = vec3f(0.95, 0.82, 0.52);
  let t = variation;
  if (t < 0.5) {
    return mix(dark, base, t * 2.0);
  }
  return mix(base, light, (t - 0.5) * 2.0);
}

fn waterColor(variation: f32) -> vec3f {
  let base = vec3f(0.2, 0.4, 0.85);
  let alt = vec3f(0.15, 0.35, 0.75);
  return mix(alt, base, variation);
}

fn stoneColor(variation: f32) -> vec3f {
  let base = vec3f(0.45, 0.45, 0.48);
  let alt = vec3f(0.38, 0.38, 0.42);
  return mix(alt, base, variation);
}

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let px = u32(uv.x * f32(params.width));
  let py = u32(uv.y * f32(params.height));

  // Clamp to grid bounds
  if (px >= params.width || py >= params.height) {
    return vec4f(0.04, 0.04, 0.05, 1.0);
  }

  let cell = cells[py * params.width + px];
  let element = cell & ELEMENT_MASK;
  let colorVar = f32((cell >> COLOR_SHIFT) & COLOR_MASK) / 255.0;

  var color: vec3f;

  switch(element) {
    case SAND: {
      color = sandColor(colorVar);
    }
    case WATER: {
      color = waterColor(colorVar);
    }
    case STONE: {
      color = stoneColor(colorVar);
    }
    default: {
      // Empty: near-black with subtle grid pattern
      let grid = f32((px + py) % 2u) * 0.008;
      color = vec3f(0.04 + grid, 0.04 + grid, 0.05 + grid);
    }
  }

  return vec4f(color, 1.0);
}
