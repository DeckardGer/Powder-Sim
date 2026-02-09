// Margolus neighborhood block cellular automata compute shader
// Each thread handles one 2x2 block.
// 4 passes per frame with alternating offsets eliminate directional bias.

// Cell encoding: bits 0-7 = element type, bits 8-15 = color variation, bits 16-31 = metadata
const ELEMENT_MASK: u32 = 0xFFu;

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
  let bx = gid.x * 2u + params.offset_x;
  let by = gid.y * 2u + params.offset_y;

  // Bounds check: all 4 cells of the 2x2 block must be in grid
  if (bx + 1u >= params.width || by + 1u >= params.height) {
    // For edge cells, copy through unchanged
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

  // Read the 2x2 block
  // Layout:  tl(bx,by)   tr(bx+1,by)
  //          bl(bx,by+1) br(bx+1,by+1)
  // y increases downward, so bl/br are BELOW tl/tr
  var tl = input[idx(bx, by)];
  var tr = input[idx(bx + 1u, by)];
  var bl = input[idx(bx, by + 1u)];
  var br = input[idx(bx + 1u, by + 1u)];

  // Per-block random
  let rng = hash(bx * 1973u + by * 9277u + params.frame * 26699u);
  let rand_bit = rng & 1u;

  // --- Apply gravity and movement rules ---
  // Strategy: check each possible swap independently.
  // Priority: straight down > diagonal down > lateral spread

  let etl = getElement(tl);
  let etr = getElement(tr);
  let ebl = getElement(bl);
  let ebr = getElement(br);

  // Try to drop left column: TL falls to BL
  let can_drop_l = getDensity(etl) > getDensity(ebl) && etl != STONE;
  // Try to drop right column: TR falls to BR
  let can_drop_r = getDensity(etr) > getDensity(ebr) && etr != STONE;

  if (can_drop_l && can_drop_r) {
    // Both columns fall
    let tmp = tl; tl = bl; bl = tmp;
    let tmp2 = tr; tr = br; br = tmp2;
  } else if (can_drop_l && !can_drop_r) {
    // Only left falls straight down
    let tmp = tl; tl = bl; bl = tmp;
  } else if (can_drop_r && !can_drop_l) {
    // Only right falls straight down
    let tmp = tr; tr = br; br = tmp;
  } else {
    // Neither can fall straight — try diagonal slides
    // Re-read elements (they haven't changed since no swap above)
    let d_tl = getDensity(etl);
    let d_tr = getDensity(etr);
    let d_bl = getDensity(ebl);
    let d_br = getDensity(ebr);

    // TL wants to fall but BL blocks — slide to BR if lighter
    let tl_slide_right = d_tl > d_br && d_tl > 0u && d_bl >= d_tl && etl != STONE;
    // TR wants to fall but BR blocks — slide to BL if lighter
    let tr_slide_left = d_tr > d_bl && d_tr > 0u && d_br >= d_tr && etr != STONE;

    if (tl_slide_right && tr_slide_left) {
      // Both want to slide diagonally — pick one randomly
      if (rand_bit == 0u) {
        let tmp = tl; tl = br; br = tmp;
      } else {
        let tmp = tr; tr = bl; bl = tmp;
      }
    } else if (tl_slide_right) {
      let tmp = tl; tl = br; br = tmp;
    } else if (tr_slide_left) {
      let tmp = tr; tr = bl; bl = tmp;
    } else {
      // No vertical movement possible — try lateral spread (for water)
      // Water spreads sideways randomly
      if (etl == WATER && etr == EMPTY && rand_bit == 0u) {
        let tmp = tl; tl = tr; tr = tmp;
      } else if (etr == WATER && etl == EMPTY && rand_bit == 1u) {
        let tmp = tr; tr = tl; tl = tmp;
      } else if (ebl == WATER && ebr == EMPTY && rand_bit == 0u) {
        let tmp = bl; bl = br; br = tmp;
      } else if (ebr == WATER && ebl == EMPTY && rand_bit == 1u) {
        let tmp = br; br = bl; bl = tmp;
      }
    }
  }

  // Write the block back
  output[idx(bx, by)] = tl;
  output[idx(bx + 1u, by)] = tr;
  output[idx(bx, by + 1u)] = bl;
  output[idx(bx + 1u, by + 1u)] = br;
}
