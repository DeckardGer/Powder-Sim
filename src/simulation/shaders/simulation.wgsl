// Margolus neighborhood block cellular automata compute shader
// Each thread handles one 2x2 block.
// 4 passes per frame with alternating offsets eliminate directional bias.

// Cell encoding: bits 0-7 = element type, bits 8-15 = color variation, bits 16-23 = lifetime (fire/steam)
const ELEMENT_MASK: u32 = 0xFFu;
const LIFETIME_SHIFT: u32 = 16u;
const LIFETIME_MASK: u32 = 0xFFu;

// Element types
const EMPTY: u32 = 0u;
const SAND: u32 = 1u;
const WATER: u32 = 2u;
const STONE: u32 = 3u;
const FIRE: u32 = 4u;
const STEAM: u32 = 5u;

// Density: fire/steam < empty so they rise via existing gravity logic.
// The key insight from diving-beet/falling-turnip: gases lighter than empty
// means the pairwise density swap naturally pushes them upward.
const EMPTY_DENSITY: u32 = 2u;

struct Params {
  width: u32,
  height: u32,
  offset_x: u32,
  offset_y: u32,
  frame: u32,
  lateral_only: u32,
}

@group(0) @binding(0) var<storage, read> input: array<u32>;
@group(0) @binding(1) var<storage, read_write> output: array<u32>;
@group(0) @binding(2) var<uniform> params: Params;

fn getElement(cell: u32) -> u32 {
  return cell & ELEMENT_MASK;
}

fn getLifetime(cell: u32) -> u32 {
  return (cell >> LIFETIME_SHIFT) & LIFETIME_MASK;
}

fn getDensity(element: u32) -> u32 {
  switch(element) {
    case FIRE:  { return 0u; }
    case STEAM: { return 1u; }
    case EMPTY: { return EMPTY_DENSITY; }
    case WATER: { return 5u; }
    case SAND:  { return 10u; }
    case STONE: { return 255u; }
    default:    { return EMPTY_DENSITY; }
  }
}

fn makeCell(element: u32, color_var: u32, lifetime: u32) -> u32 {
  return (element & ELEMENT_MASK)
       | ((color_var & 0xFFu) << 8u)
       | ((lifetime & LIFETIME_MASK) << LIFETIME_SHIFT);
}

fn setLifetime(cell: u32, lifetime: u32) -> u32 {
  return (cell & 0xFF00FFFFu) | ((lifetime & LIFETIME_MASK) << LIFETIME_SHIFT);
}

// Age a single cell: decrement fire/steam lifetime, convert on expiry
fn ageCell(cell: u32, rng: u32) -> u32 {
  let element = getElement(cell);

  if (element == FIRE) {
    let lifetime = getLifetime(cell);
    if (lifetime == 0u) { return 0u; }
    // ~3% chance to age per pass (24 passes * 3% ~ 0.7 age/frame)
    let should_age = (rng & 31u) == 0u;
    if (should_age) {
      let new_lt = lifetime - 1u;
      if (new_lt == 0u) {
        // Fire dies: 50% chance → steam (smoke effect), 50% → empty
        if (((rng >> 5u) & 1u) == 1u) {
          let steam_cv = (rng >> 8u) & 0xFFu;
          return makeCell(STEAM, steam_cv, 80u + ((rng >> 16u) % 60u));
        }
        return 0u;
      }
      return setLifetime(cell, new_lt);
    }
    return cell;
  }

  if (element == STEAM) {
    let lifetime = getLifetime(cell);
    if (lifetime == 0u) {
      // Condensed: become water
      let water_cv = (rng >> 8u) & 0xFFu;
      return makeCell(WATER, water_cv, 0u);
    }
    // ~1.5% chance to age per pass
    let should_age = (rng & 63u) == 0u;
    if (should_age) {
      let new_lt = lifetime - 1u;
      if (new_lt == 0u) {
        let water_cv = (rng >> 8u) & 0xFFu;
        return makeCell(WATER, water_cv, 0u);
      }
      return setLifetime(cell, new_lt);
    }
    return cell;
  }

  return cell;
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

  // When offset is 1, the first row/column (x=0 or y=0) isn't part of any
  // 2x2 block and would never be written to output, losing particles through
  // the ping-pong. Each edge thread copies these orphaned cells through.
  if (params.offset_x == 1u && gid.x == 0u) {
    let ey = gid.y * 2u;
    if (ey < params.height) { output[idx(0u, ey)] = input[idx(0u, ey)]; }
    if (ey + 1u < params.height) { output[idx(0u, ey + 1u)] = input[idx(0u, ey + 1u)]; }
  }
  if (params.offset_y == 1u && gid.y == 0u) {
    let ex = gid.x * 2u;
    if (ex < params.width) { output[idx(ex, 0u)] = input[idx(ex, 0u)]; }
    if (ex + 1u < params.width) { output[idx(ex + 1u, 0u)] = input[idx(ex + 1u, 0u)]; }
  }

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

  // === AGING: fire/steam lifetime decay ===
  {
    let rng_age_tl = hash(rng1 ^ 0x11111111u);
    let rng_age_tr = hash(rng1 ^ 0x22222222u);
    let rng_age_bl = hash(rng1 ^ 0x33333333u);
    let rng_age_br = hash(rng1 ^ 0x44444444u);
    tl = ageCell(tl, rng_age_tl);
    tr = ageCell(tr, rng_age_tr);
    bl = ageCell(bl, rng_age_bl);
    br = ageCell(br, rng_age_br);
  }

  // === ALCHEMY: fire + water → violent steam explosion ===
  // Fire SURVIVES the reaction (loses lifetime) so it burns through water
  // over multiple passes. Water is either evaporated (→empty) or becomes steam.
  // Empty cells in the blast become short-lived burst steam.
  {
    let a_tl = getElement(tl);
    let a_tr = getElement(tr);
    let a_bl = getElement(bl);
    let a_br = getElement(br);

    let has_fire = (a_tl == FIRE || a_tr == FIRE || a_bl == FIRE || a_br == FIRE);
    let has_water = (a_tl == WATER || a_tr == WATER || a_bl == WATER || a_br == WATER);

    if (has_fire && has_water) {
      let rng_a = hash(rng1 ^ 0xFEEDFACEu);
      let rng_b = hash(rng_a ^ 0xABCD1234u);
      let rng_c = hash(rng_b ^ 0x5678EF01u);
      let rng_d = hash(rng_c ^ 0x9ABC2345u);

      // Count water to scale lifetime cost
      let water_count = u32(a_tl == WATER) + u32(a_tr == WATER)
                      + u32(a_bl == WATER) + u32(a_br == WATER);
      let lt_cost = 8u + water_count * 4u; // 12-24 lifetime lost per reaction

      // Fire: survives but loses lifetime. Dies if depleted.
      // Water: 60% evaporated (→empty), 40% → steam.
      // Empty: → short-lived burst steam (splash).
      if (a_tl == FIRE) { let lt = getLifetime(tl); if (lt > lt_cost) { tl = setLifetime(tl, lt - lt_cost); } else { tl = 0u; } }
      else if (a_tl == WATER) { if ((rng_a % 100u) < 60u) { tl = 0u; } else { tl = makeCell(STEAM, (rng_a >> 8u) & 0xFFu, 120u + rng_a % 80u); } }
      else if (a_tl == EMPTY) { tl = makeCell(STEAM, (rng_a >> 8u) & 0xFFu, 15u + rng_a % 20u); }

      if (a_tr == FIRE) { let lt = getLifetime(tr); if (lt > lt_cost) { tr = setLifetime(tr, lt - lt_cost); } else { tr = 0u; } }
      else if (a_tr == WATER) { if ((rng_b % 100u) < 60u) { tr = 0u; } else { tr = makeCell(STEAM, (rng_b >> 8u) & 0xFFu, 120u + rng_b % 80u); } }
      else if (a_tr == EMPTY) { tr = makeCell(STEAM, (rng_b >> 8u) & 0xFFu, 15u + rng_b % 20u); }

      if (a_bl == FIRE) { let lt = getLifetime(bl); if (lt > lt_cost) { bl = setLifetime(bl, lt - lt_cost); } else { bl = 0u; } }
      else if (a_bl == WATER) { if ((rng_c % 100u) < 60u) { bl = 0u; } else { bl = makeCell(STEAM, (rng_c >> 8u) & 0xFFu, 120u + rng_c % 80u); } }
      else if (a_bl == EMPTY) { bl = makeCell(STEAM, (rng_c >> 8u) & 0xFFu, 15u + rng_c % 20u); }

      if (a_br == FIRE) { let lt = getLifetime(br); if (lt > lt_cost) { br = setLifetime(br, lt - lt_cost); } else { br = 0u; } }
      else if (a_br == WATER) { if ((rng_d % 100u) < 60u) { br = 0u; } else { br = makeCell(STEAM, (rng_d >> 8u) & 0xFFu, 120u + rng_d % 80u); } }
      else if (a_br == EMPTY) { br = makeCell(STEAM, (rng_d >> 8u) & 0xFFu, 15u + rng_d % 20u); }
    }
  }

  // Re-read elements after aging + alchemy (types may have changed)
  let etl = getElement(tl);
  let etr = getElement(tr);
  let ebl = getElement(bl);
  let ebr = getElement(br);

  // === PHASE 1: GRAVITY ===
  if (params.lateral_only == 0u && should_move) {
    // Try to drop left column: TL falls to BL
    let can_drop_l = getDensity(etl) > getDensity(ebl) && etl != STONE;
    // Try to drop right column: TR falls to BR
    let can_drop_r = getDensity(etr) > getDensity(ebr) && etr != STONE;

    // Sand-water drag: gates ALL sand movement through water (vertical + diagonal).
    // Without this, sand bypasses vertical drag via the diagonal dispersion path.
    let sand_water_move = (rng1 % 100u) < 35u; // 35% chance to move through water
    let sw_l = (etl == SAND && ebl == WATER) || (etl == WATER && ebl == SAND);
    let sw_r = (etr == SAND && ebr == WATER) || (etr == WATER && ebr == SAND);

    // Gas rise drag: fire/steam rise slowly, not every pass.
    // Without this, gases teleport upward at full simulation speed.
    let gas_rng = (rng1 >> 6u) % 100u;
    let fire_l = (etl == FIRE && ebl == EMPTY) || (etl == EMPTY && ebl == FIRE);
    let fire_r = (etr == FIRE && ebr == EMPTY) || (etr == EMPTY && ebr == FIRE);
    let steam_l = (etl == STEAM && ebl == EMPTY) || (etl == EMPTY && ebl == STEAM);
    let steam_r = (etr == STEAM && ebr == EMPTY) || (etr == EMPTY && ebr == STEAM);
    let fire_can_move = gas_rng < 20u;  // 20% → ~2-3 rises/frame
    let steam_can_move = gas_rng < 35u; // 35% → ~4-5 rises/frame
    let gas_ok_l = (!fire_l || fire_can_move) && (!steam_l || steam_can_move);
    let gas_ok_r = (!fire_r || fire_can_move) && (!steam_r || steam_can_move);

    let drop_l = can_drop_l && (!sw_l || sand_water_move) && gas_ok_l;
    let drop_r = can_drop_r && (!sw_r || sand_water_move) && gas_ok_r;

    if (drop_l && drop_r) {
      let tmp = tl; tl = bl; bl = tmp;
      let tmp2 = tr; tr = br; br = tmp2;
    } else if (drop_l) {
      let tmp = tl; tl = bl; bl = tmp;
    } else if (drop_r) {
      let tmp = tr; tr = br; br = tmp;
    } else {
      // Try diagonal slides (only for falling elements: density > EMPTY_DENSITY)
      let d_tl = getDensity(etl);
      let d_tr = getDensity(etr);
      let d_bl = getDensity(ebl);
      let d_br = getDensity(ebr);

      // Diagonal slides: sand always, water only when the adjacent path is
      // clear (prevents scatter in streams) and with ~25% probability.
      let tl_slide_base = d_tl > d_br && d_tl > EMPTY_DENSITY && d_bl >= d_tl && etl != STONE;
      let tr_slide_base = d_tr > d_bl && d_tr > EMPTY_DENSITY && d_br >= d_tr && etr != STONE;
      let water_diag = ((rng1 >> 8u) & 3u) == 0u;

      // Sand disperses through water even when not resting on something.
      // This fires when drag allowed movement and the vertical drop was
      // skipped, letting sand fan out sideways as it sinks through water.
      let sand_disp = ((rng1 >> 12u) & 1u) == 0u; // 50%
      let tl_water_disp = etl == SAND && ebr == WATER && d_tl > d_br && sand_disp && sand_water_move;
      let tr_water_disp = etr == SAND && ebl == WATER && d_tr > d_bl && sand_disp && sand_water_move;

      // Gate standard diagonal slides into water by the same drag
      let tl_sand_water = etl == SAND && ebr == WATER;
      let tr_sand_water = etr == SAND && ebl == WATER;
      let tl_slide_raw = (tl_slide_base && (etl != WATER || (d_tr < d_tl && water_diag))) || tl_water_disp;
      let tr_slide_raw = (tr_slide_base && (etr != WATER || (d_tl < d_tr && water_diag))) || tr_water_disp;
      let tl_slide = tl_slide_raw && (!tl_sand_water || sand_water_move);
      let tr_slide = tr_slide_raw && (!tr_sand_water || sand_water_move);

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

  // === PHASE 2: LATERAL SPREAD ===
  // Water lateral spread (based on diving-beet/falling-turnip rules)
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

    // Steam lateral spread: looser than water — steam disperses freely.
    // Against a surface (other row occupied): always spread.
    // Free-floating: ~12% chance to spread anyway, breaking hard walls.
    {
      let st_tl = getElement(tl);
      let st_tr = getElement(tr);
      let st_bl = getElement(bl);
      let st_br = getElement(br);
      let steam_spread_rng = hash(rng0 ^ 0x57EA4444u);
      let steam_free_spread = (steam_spread_rng & 7u) == 0u; // ~12.5%

      // Bottom row: one steam + one empty
      if ((st_bl == STEAM && st_br == EMPTY) || (st_br == STEAM && st_bl == EMPTY)) {
        if ((st_tl != EMPTY && st_tr != EMPTY) || steam_free_spread) {
          let tmp = bl; bl = br; br = tmp;
        }
      }

      // Top row: one steam + one empty
      if ((st_tl == STEAM && st_tr == EMPTY) || (st_tr == STEAM && st_tl == EMPTY)) {
        if ((st_bl != EMPTY && st_br != EMPTY) || steam_free_spread) {
          let tmp = tl; tl = tr; tr = tmp;
        }
      }
    }

    // Underwater sand smoothing: submerged sand spreads laterally, reducing
    // sharp peaks into gentle curves (lower angle of repose in water).
    // Only fires when sand is at the pile surface (water directly above it).
    {
      let s_tl = getElement(tl);
      let s_tr = getElement(tr);
      let s_bl = getElement(bl);
      let s_br = getElement(br);
      let smooth_rng = hash(rng0 ^ 0x12345678u);
      let should_smooth = (smooth_rng & 31u) == 0u; // ~3% per pass
      if (should_smooth) {
        if (s_bl == SAND && s_br == WATER && s_tl == WATER) {
          let tmp = bl; bl = br; br = tmp;
        } else if (s_br == SAND && s_bl == WATER && s_tr == WATER) {
          let tmp = bl; bl = br; br = tmp;
        }
      }
    }

    // Erosion: flowing water lifts adjacent sand upward.
    // When water sits next to sand in the bottom row and there's space above,
    // the sand particle gets dislodged upward into the water stream.
    let erosion_rng = hash(rng0 ^ 0xCAFEBABEu);
    let erode = (erosion_rng & 511u) == 0u; // ~0.2% per pass
    if (erode) {
      let e2_tl = getElement(tl);
      let e2_tr = getElement(tr);
      let e2_bl = getElement(bl);
      let e2_br = getElement(br);
      if (e2_bl == WATER && e2_br == SAND && (e2_tr == EMPTY || e2_tr == WATER)) {
        let tmp = br; br = tr; tr = tmp;
      } else if (e2_br == WATER && e2_bl == SAND && (e2_tl == EMPTY || e2_tl == WATER)) {
        let tmp = bl; bl = tl; tl = tmp;
      }
    }
  }

  output[idx(bx, by)] = tl;
  output[idx(bx + 1u, by)] = tr;
  output[idx(bx, by + 1u)] = bl;
  output[idx(bx + 1u, by + 1u)] = br;
}
