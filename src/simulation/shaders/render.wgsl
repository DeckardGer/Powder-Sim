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

// Cell encoding: bits 0-7 = element type, bits 8-15 = color variation, bits 16-23 = lifetime
const ELEMENT_MASK: u32 = 0xFFu;
const COLOR_SHIFT: u32 = 8u;
const COLOR_MASK: u32 = 0xFFu;
const LIFETIME_SHIFT: u32 = 16u;
const LIFETIME_MASK: u32 = 0xFFu;

const EMPTY: u32 = 0u;
const SAND: u32 = 1u;
const WATER: u32 = 2u;
const STONE: u32 = 3u;
const FIRE: u32 = 4u;
const STEAM: u32 = 5u;
const WOOD: u32 = 6u;
const GLASS: u32 = 7u;
const SMOKE: u32 = 8u;

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

fn stoneColor(variation: f32, heat: f32) -> vec3f {
  let base = vec3f(0.45, 0.45, 0.48);
  let alt = vec3f(0.38, 0.38, 0.42);
  let cold = mix(alt, base, variation);

  // Heat gradient: cold gray → warm → orange → red-hot → white-hot
  let t = clamp(heat / 255.0, 0.0, 1.0);
  if (t < 0.12) {
    // Below threshold: normal stone
    return cold;
  }
  let ht = clamp((t - 0.12) / 0.88, 0.0, 1.0); // remap to 0-1
  let warm = vec3f(0.55, 0.35, 0.25);
  let orange = vec3f(0.9, 0.45, 0.1);
  let red_hot = vec3f(1.0, 0.25, 0.05);
  let white_hot = vec3f(1.0, 0.85, 0.6);
  var glow: vec3f;
  if (ht < 0.3) {
    glow = mix(warm, orange, ht / 0.3);
  } else if (ht < 0.65) {
    glow = mix(orange, red_hot, (ht - 0.3) / 0.35);
  } else {
    glow = mix(red_hot, white_hot, (ht - 0.65) / 0.35);
  }
  return mix(cold, glow, clamp(ht * 1.2, 0.0, 1.0));
}

fn fireColor(variation: f32, lifetime: f32) -> vec3f {
  // Normalize lifetime: spawns at ~60-120, so /120 gives 0→1 range
  let t = clamp(lifetime / 120.0, 0.0, 1.0);
  // Dark red → orange → yellow → white-hot
  let dark_red = vec3f(0.5, 0.05, 0.0);
  let orange = vec3f(1.0, 0.45, 0.0);
  let yellow = vec3f(1.0, 0.85, 0.15);
  let white_hot = vec3f(1.0, 0.97, 0.7);
  var color: vec3f;
  if (t < 0.2) {
    color = mix(dark_red, orange, t * 5.0);
  } else if (t < 0.55) {
    color = mix(orange, yellow, (t - 0.2) / 0.35);
  } else {
    color = mix(yellow, white_hot, (t - 0.55) / 0.45);
  }
  // Flicker from color variation
  let flicker = (variation - 0.5) * 0.25;
  color += vec3f(flicker, flicker * 0.4, 0.0);
  return clamp(color, vec3f(0.0), vec3f(1.0));
}

fn woodColor(variation: f32) -> vec3f {
  let base = vec3f(0.4, 0.26, 0.13);
  let dark = vec3f(0.28, 0.17, 0.08);
  let light = vec3f(0.52, 0.35, 0.18);
  let t = variation;
  if (t < 0.5) {
    return mix(dark, base, t * 2.0);
  }
  return mix(base, light, (t - 0.5) * 2.0);
}

fn smokeColor(variation: f32, lifetime: f32) -> vec3f {
  // Normalize: spawns at ~60-100, so /80 gives ~0.75-1.25 (clamped)
  let t = clamp(lifetime / 80.0, 0.0, 1.0);
  // Fresh smoke is dark gray, aging smoke fades to near-background
  let fresh = vec3f(0.35, 0.33, 0.32);
  let faded = vec3f(0.08, 0.08, 0.09);
  let base = mix(faded, fresh, t);
  // Per-particle variation for wispy look
  let vary = (variation - 0.5) * 0.1;
  return clamp(base + vec3f(vary, vary, vary), vec3f(0.0), vec3f(1.0));
}

fn glassColor(variation: f32) -> vec3f {
  let base = vec3f(0.7, 0.85, 0.88);
  let alt = vec3f(0.6, 0.78, 0.82);
  let color = mix(alt, base, variation);
  // Subtle sparkle on some particles
  let sparkle = step(0.92, variation) * 0.15;
  return clamp(color + vec3f(sparkle), vec3f(0.0), vec3f(1.0));
}

fn steamColor(variation: f32, lifetime: f32) -> vec3f {
  // Normalize: spawns at ~150-250, so /200 gives ~0.75-1.25 (clamped)
  let t = clamp(lifetime / 200.0, 0.0, 1.0);
  // Fresh steam is bright white, aging steam fades toward background
  let fresh = vec3f(0.82, 0.84, 0.88);
  let faded = vec3f(0.2, 0.21, 0.24);
  let base = mix(faded, fresh, t);
  // Per-particle variation for wispy look
  let vary = (variation - 0.5) * 0.18;
  return clamp(base + vec3f(vary, vary, vary * 1.1), vec3f(0.0), vec3f(1.0));
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
  let lifetime = f32((cell >> LIFETIME_SHIFT) & LIFETIME_MASK);

  var color: vec3f;

  switch(element) {
    case SAND: {
      color = sandColor(colorVar);
    }
    case WATER: {
      color = waterColor(colorVar);
    }
    case STONE: {
      color = stoneColor(colorVar, lifetime);
    }
    case FIRE: {
      color = fireColor(colorVar, lifetime);
    }
    case STEAM: {
      color = steamColor(colorVar, lifetime);
    }
    case WOOD: {
      color = woodColor(colorVar);
    }
    case GLASS: {
      color = glassColor(colorVar);
    }
    case SMOKE: {
      color = smokeColor(colorVar, lifetime);
    }
    default: {
      // Empty: near-black with subtle grid pattern
      let grid = f32((px + py) % 2u) * 0.008;
      color = vec3f(0.04 + grid, 0.04 + grid, 0.05 + grid);
    }
  }

  return vec4f(color, 1.0);
}
