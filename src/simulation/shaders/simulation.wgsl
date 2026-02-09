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

// Hash-based RNG — returns a pseudo-random u32
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
  let bx = gid.x * 2u + params.offset_x;
  let by = gid.y * 2u + params.offset_y;

  // Bounds check: all 4 cells of the 2x2 block must be in grid
  if (bx + 1u >= params.width || by + 1u >= params.height) {
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
  var tl = input[idx(bx, by)];
  var tr = input[idx(bx + 1u, by)];
  var bl = input[idx(bx, by + 1u)];
  var br = input[idx(bx + 1u, by + 1u)];

  // Multiple independent random values from different seeds
  let rng0 = hash(bx * 1973u + by * 9277u + params.frame * 26699u);
  let rng1 = hash(rng0 ^ 0xDEADBEEFu);
  let rand_bit = rng0 & 1u;

  // Probabilistic movement: ~75% chance a block processes gravity.
  // This breaks lockstep wavefronts and creates natural velocity variation.
  // Use bits 4-5 of rng1 so it's independent from rand_bit.
  let move_chance = (rng1 >> 4u) & 3u; // 0-3, skip on 0 = 25% skip rate
  let should_move = move_chance != 0u;

  let etl = getElement(tl);
  let etr = getElement(tr);
  let ebl = getElement(bl);
  let ebr = getElement(br);

  if (should_move) {
    // Try to drop left column: TL falls to BL
    let can_drop_l = getDensity(etl) > getDensity(ebl) && etl != STONE;
    // Try to drop right column: TR falls to BR
    let can_drop_r = getDensity(etr) > getDensity(ebr) && etr != STONE;

    if (can_drop_l && can_drop_r) {
      let tmp = tl; tl = bl; bl = tmp;
      let tmp2 = tr; tr = br; br = tmp2;
    } else if (can_drop_l) {
      let tmp = tl; tl = bl; bl = tmp;
    } else if (can_drop_r) {
      let tmp = tr; tr = br; br = tmp;
    } else {
      // Try diagonal slides
      let d_tl = getDensity(etl);
      let d_tr = getDensity(etr);
      let d_bl = getDensity(ebl);
      let d_br = getDensity(ebr);

      // Diagonal slides: sand always, water only when the adjacent path is
      // clear (prevents scatter in streams) and with ~25% probability.
      let tl_slide_base = d_tl > d_br && d_tl > 0u && d_bl >= d_tl && etl != STONE;
      let tr_slide_base = d_tr > d_bl && d_tr > 0u && d_br >= d_tr && etr != STONE;
      let water_diag = ((rng1 >> 8u) & 3u) == 0u;
      let tl_slide = tl_slide_base && (etl != WATER || (d_tr < d_tl && water_diag));
      let tr_slide = tr_slide_base && (etr != WATER || (d_tl < d_tr && water_diag));

      if (tl_slide && tr_slide) {
        if (rand_bit == 0u) {
          let tmp = tl; tl = br; br = tmp;
        } else {
          let tmp = tr; tr = bl; bl = tmp;
        }
      } else if (tl_slide) {
        let tmp = tl; tl = br; br = tmp;
      } else if (tr_slide) {
        let tmp = tr; tr = bl; bl = tmp;
      }
    }
  }

  // Phase 2: Water lateral spread (based on diving-beet/falling-turnip rules)
  // Runs every pass (not gated by should_move) for fast pool leveling.
  // A row may spread only when the OTHER row is fully occupied — this
  // naturally prevents narrow falling columns from widening mid-air
  // while allowing pool edges to level quickly.
  {
    let w_tl = getElement(tl);
    let w_tr = getElement(tr);
    let w_bl = getElement(bl);
    let w_br = getElement(br);

    // Bottom row: one water + one empty → swap if top row fully occupied
    if ((w_bl == WATER && w_br == EMPTY) || (w_br == WATER && w_bl == EMPTY)) {
      if (w_tl != EMPTY && w_tr != EMPTY) {
        let tmp = bl; bl = br; br = tmp;
      }
    }

    // Top row: one water + one empty → swap if bottom row fully occupied
    if ((w_tl == WATER && w_tr == EMPTY) || (w_tr == WATER && w_tl == EMPTY)) {
      if (w_bl != EMPTY && w_br != EMPTY) {
        let tmp = tl; tl = tr; tr = tmp;
      }
    }
  }

  output[idx(bx, by)] = tl;
  output[idx(bx + 1u, by)] = tr;
  output[idx(bx, by + 1u)] = bl;
  output[idx(bx + 1u, by + 1u)] = br;
}
