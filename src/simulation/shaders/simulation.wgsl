// Margolus neighborhood block cellular automata compute shader
// Each thread handles one 2x2 block.
// 4 passes per frame with alternating offsets eliminate directional bias.

// Cell encoding: bits 0-7 = element type, bits 8-15 = color variation, bits 16-31 = metadata
const ELEMENT_MASK: u32 = 0xFFu;
const COLOR_SHIFT: u32 = 8u;
const COLOR_MASK: u32 = 0xFF00u;

// Element types
const EMPTY: u32 = 0u;
const SAND: u32 = 1u;
const WATER: u32 = 2u;
const STONE: u32 = 3u;

struct Params {
  width: u32,
  height: u32,
  offset_x: u32,
  offset_y: u32,
  frame: u32,
}

@group(0) @binding(0) var<storage, read> input: array<u32>;
@group(0) @binding(1) var<storage, read_write> output: array<u32>;
@group(0) @binding(2) var<uniform> params: Params;

fn getElement(cell: u32) -> u32 {
  return cell & ELEMENT_MASK;
}

fn getDensity(element: u32) -> u32 {
  switch(element) {
    case EMPTY: { return 0u; }
    case WATER: { return 5u; }
    case SAND:  { return 10u; }
    case STONE: { return 255u; }
    default:    { return 0u; }
  }
}

fn isMovable(element: u32) -> bool {
  return element != EMPTY && element != STONE;
}

// Hash-based RNG using frame counter and block position
fn hash(seed: u32) -> u32 {
  var x = seed;
  x ^= x >> 16u;
  x *= 0x45d9f3bu;
  x ^= x >> 16u;
  x *= 0x45d9f3bu;
  x ^= x >> 16u;
  return x;
}

fn idx(x: u32, y: u32) -> u32 {
  return y * params.width + x;
}

override WORKGROUP_SIZE: u32 = 16u;

@compute @workgroup_size(WORKGROUP_SIZE, WORKGROUP_SIZE)
fn main(@builtin(global_invocation_id) gid: vec3u) {
  // Each thread handles one 2x2 Margolus block
  // Block top-left corner position with offset
  let bx = gid.x * 2u + params.offset_x;
  let by = gid.y * 2u + params.offset_y;

  // Bounds check: all 4 cells of the 2x2 block must be in grid
  if (bx + 1u >= params.width || by + 1u >= params.height) {
    // For edge blocks, just copy through
    if (bx < params.width && by < params.height) {
      output[idx(bx, by)] = input[idx(bx, by)];
    }
    if (bx + 1u < params.width && by < params.height) {
      output[idx(bx + 1u, by)] = input[idx(bx + 1u, by)];
    }
    if (bx < params.width && by + 1u < params.height) {
      output[idx(bx, by + 1u)] = input[idx(bx, by + 1u)];
    }
    if (bx + 1u < params.width && by + 1u < params.height) {
      output[idx(bx + 1u, by + 1u)] = input[idx(bx + 1u, by + 1u)];
    }
    return;
  }

  // Read the 2x2 block: TL=top-left, TR=top-right, BL=bottom-left, BR=bottom-right
  // Grid layout: y increases downward (row 0 = top)
  var tl = input[idx(bx, by)];
  var tr = input[idx(bx + 1u, by)];
  var bl = input[idx(bx, by + 1u)];
  var br = input[idx(bx + 1u, by + 1u)];

  let etl = getElement(tl);
  let etr = getElement(tr);
  let ebl = getElement(bl);
  let ebr = getElement(br);

  let dtl = getDensity(etl);
  let dtr = getDensity(etr);
  let dbl = getDensity(ebl);
  let dbr = getDensity(ebr);

  // Per-block random using position + frame
  let rng_seed = hash(bx + by * params.width + params.frame * 31337u);
  let rand_bit = rng_seed & 1u; // 0 or 1, for left/right bias

  // === GRAVITY RULES ===
  // Dense particles above lighter ones → swap down

  // Rule 1: Both top cells fall straight down if denser than bottom
  if (dtl > dbl && dtr > dbr) {
    // Both columns: swap top with bottom
    let tmp_l = tl; tl = bl; bl = tmp_l;
    let tmp_r = tr; tr = br; br = tmp_r;
  }
  // Rule 2: Left column falls
  else if (dtl > dbl) {
    let tmp = tl; tl = bl; bl = tmp;
    // Right side: try diagonal if possible
    if (dtr > dbl) {
      // TR wants to fall, BL is now lighter (was swapped) — skip complex
    }
  }
  // Rule 3: Right column falls
  else if (dtr > dbr) {
    let tmp = tr; tr = br; br = tmp;
  }
  // Rule 4: Diagonal slide — particle on top can't fall straight, slides diagonally
  else if (dtl > 0u && dbl >= dtl && dbr < dtl) {
    // TL is heavy, BL blocks it, BR is lighter → slide TL to BR
    if (rand_bit == 0u || etr != EMPTY) {
      let tmp = tl; tl = br; br = tmp;
    }
  }
  else if (dtr > 0u && dbr >= dtr && dbl < dtr) {
    // TR is heavy, BR blocks it, BL is lighter → slide TR to BL
    if (rand_bit == 1u || etl != EMPTY) {
      let tmp = tr; tr = bl; bl = tmp;
    }
  }
  // Rule 5: Cross-diagonal slides with random bias
  else if (dtl > 0u && dbl >= dtl && getElement(tl) != STONE) {
    // TL is stuck, try to spread sideways
    if (etr == EMPTY && rand_bit == 0u) {
      let tmp = tl; tl = tr; tr = tmp;
    }
  }
  else if (dtr > 0u && dbr >= dtr && getElement(tr) != STONE) {
    if (etl == EMPTY && rand_bit == 1u) {
      let tmp = tr; tr = tl; tl = tmp;
    }
  }

  // Write the (possibly modified) block back
  output[idx(bx, by)] = tl;
  output[idx(bx + 1u, by)] = tr;
  output[idx(bx, by + 1u)] = bl;
  output[idx(bx + 1u, by + 1u)] = br;
}
