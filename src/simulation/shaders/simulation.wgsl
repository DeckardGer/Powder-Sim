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
const WOOD: u32 = 6u;
const GLASS: u32 = 7u;
const SMOKE: u32 = 8u;
const OIL: u32 = 9u;

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

fn isImmovable(element: u32) -> bool {
  return element == STONE || element == WOOD || element == GLASS;
}

fn getDensity(element: u32) -> u32 {
  switch(element) {
    case FIRE:  { return 0u; }
    case SMOKE: { return 1u; }
    case STEAM: { return 1u; }
    case EMPTY: { return EMPTY_DENSITY; }
    case OIL:   { return 4u; }
    case WATER: { return 5u; }
    case WOOD:  { return 9u; }
    case SAND:  { return 10u; }
    case GLASS: { return 200u; }
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

// Age a single cell: decrement fire/steam/smoke lifetime, convert on expiry
fn ageCell(cell: u32, rng: u32) -> u32 {
  let element = getElement(cell);

  if (element == FIRE) {
    let lifetime = getLifetime(cell);
    if (lifetime == 0u) { return 0u; }
    // ~1.5% chance to age per pass (24 passes * 1.5% ~ 0.36 age/frame)
    let should_age = (rng & 63u) == 0u;
    if (should_age) {
      let new_lt = lifetime - 1u;
      if (new_lt == 0u) {
        // Fire dies: 50% chance → smoke, 50% → empty
        if (((rng >> 7u) & 1u) == 1u) {
          let smoke_cv = (rng >> 8u) & 0xFFu;
          return makeCell(SMOKE, smoke_cv, 60u + ((rng >> 16u) % 40u));
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

  if (element == SMOKE) {
    let lifetime = getLifetime(cell);
    if (lifetime == 0u) { return 0u; }
    // ~2% chance to age per pass (slightly faster than steam)
    let should_age = (rng & 63u) == 0u;
    if (should_age) {
      let new_lt = lifetime - 1u;
      if (new_lt == 0u) { return 0u; }
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

  // === ALCHEMY: fire + water → water extinguishes fire ===
  // Fire is killed on contact with water → becomes steam.
  // Water is consumed: 70% survives, 30% → steam.
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

      // Fire: extinguished → becomes steam (hiss effect).
      // Water: mostly survives, 30% → steam from heat.
      if (a_tl == FIRE) { tl = makeCell(STEAM, (rng_a >> 8u) & 0xFFu, 40u + rng_a % 40u); }
      else if (a_tl == WATER) { if ((rng_a % 100u) < 30u) { tl = makeCell(STEAM, (rng_a >> 8u) & 0xFFu, 60u + rng_a % 60u); } }

      if (a_tr == FIRE) { tr = makeCell(STEAM, (rng_b >> 8u) & 0xFFu, 40u + rng_b % 40u); }
      else if (a_tr == WATER) { if ((rng_b % 100u) < 30u) { tr = makeCell(STEAM, (rng_b >> 8u) & 0xFFu, 60u + rng_b % 60u); } }

      if (a_bl == FIRE) { bl = makeCell(STEAM, (rng_c >> 8u) & 0xFFu, 40u + rng_c % 40u); }
      else if (a_bl == WATER) { if ((rng_c % 100u) < 30u) { bl = makeCell(STEAM, (rng_c >> 8u) & 0xFFu, 60u + rng_c % 60u); } }

      if (a_br == FIRE) { br = makeCell(STEAM, (rng_d >> 8u) & 0xFFu, 40u + rng_d % 40u); }
      else if (a_br == WATER) { if ((rng_d % 100u) < 30u) { br = makeCell(STEAM, (rng_d >> 8u) & 0xFFu, 60u + rng_d % 60u); } }
    }
  }

  // === ALCHEMY: fire + wood → wood ignites + smoke ===
  // Wood in the same 2x2 block as fire catches fire (~0.2% per pass).
  // Fire is unaffected. Empty cells in the block emit smoke (combustion byproduct).
  {
    let w_tl = getElement(tl);
    let w_tr = getElement(tr);
    let w_bl = getElement(bl);
    let w_br = getElement(br);

    let has_fire_w = (w_tl == FIRE || w_tr == FIRE || w_bl == FIRE || w_br == FIRE);
    let has_wood = (w_tl == WOOD || w_tr == WOOD || w_bl == WOOD || w_br == WOOD);

    if (has_fire_w && has_wood) {
      let rng_w = hash(rng1 ^ 0xD00DF1AEu);
      if (w_tl == WOOD && (rng_w & 511u) == 0u) {
        tl = makeCell(FIRE, (rng_w >> 8u) & 0xFFu, 100u + rng_w % 60u);
      } else if (w_tl == EMPTY && (rng_w & 63u) == 0u) {
        tl = makeCell(SMOKE, (rng_w >> 8u) & 0xFFu, 40u + rng_w % 30u);
      }
      let rng_w2 = hash(rng_w ^ 0xB0A4D00Du);
      if (w_tr == WOOD && (rng_w2 & 511u) == 0u) {
        tr = makeCell(FIRE, (rng_w2 >> 8u) & 0xFFu, 100u + rng_w2 % 60u);
      } else if (w_tr == EMPTY && (rng_w2 & 63u) == 0u) {
        tr = makeCell(SMOKE, (rng_w2 >> 8u) & 0xFFu, 40u + rng_w2 % 30u);
      }
      let rng_w3 = hash(rng_w2 ^ 0x1A01B3AAu);
      if (w_bl == WOOD && (rng_w3 & 511u) == 0u) {
        bl = makeCell(FIRE, (rng_w3 >> 8u) & 0xFFu, 100u + rng_w3 % 60u);
      } else if (w_bl == EMPTY && (rng_w3 & 63u) == 0u) {
        bl = makeCell(SMOKE, (rng_w3 >> 8u) & 0xFFu, 40u + rng_w3 % 30u);
      }
      let rng_w4 = hash(rng_w3 ^ 0xF1A4BE44u);
      if (w_br == WOOD && (rng_w4 & 511u) == 0u) {
        br = makeCell(FIRE, (rng_w4 >> 8u) & 0xFFu, 100u + rng_w4 % 60u);
      } else if (w_br == EMPTY && (rng_w4 & 63u) == 0u) {
        br = makeCell(SMOKE, (rng_w4 >> 8u) & 0xFFu, 40u + rng_w4 % 30u);
      }
    }
  }

  // === ALCHEMY: fire + oil → oil ignites + smoke ===
  // Oil in the same 2x2 block as fire catches fire easily (~15% per pass).
  // Fire is unaffected. Empty cells in the block emit smoke (combustion byproduct).
  {
    let o_tl = getElement(tl);
    let o_tr = getElement(tr);
    let o_bl = getElement(bl);
    let o_br = getElement(br);

    let has_fire_o = (o_tl == FIRE || o_tr == FIRE || o_bl == FIRE || o_br == FIRE);
    let has_oil = (o_tl == OIL || o_tr == OIL || o_bl == OIL || o_br == OIL);

    if (has_fire_o && has_oil) {
      let rng_o = hash(rng1 ^ 0xF1AE0001u);
      if (o_tl == OIL && (rng_o % 100u) < 15u) {
        tl = makeCell(FIRE, (rng_o >> 8u) & 0xFFu, 80u + rng_o % 60u);
      } else if (o_tl == EMPTY && (rng_o & 31u) == 0u) {
        tl = makeCell(SMOKE, (rng_o >> 8u) & 0xFFu, 40u + rng_o % 30u);
      }
      let rng_o2 = hash(rng_o ^ 0xF1AE0002u);
      if (o_tr == OIL && (rng_o2 % 100u) < 15u) {
        tr = makeCell(FIRE, (rng_o2 >> 8u) & 0xFFu, 80u + rng_o2 % 60u);
      } else if (o_tr == EMPTY && (rng_o2 & 31u) == 0u) {
        tr = makeCell(SMOKE, (rng_o2 >> 8u) & 0xFFu, 40u + rng_o2 % 30u);
      }
      let rng_o3 = hash(rng_o2 ^ 0xF1AE0003u);
      if (o_bl == OIL && (rng_o3 % 100u) < 15u) {
        bl = makeCell(FIRE, (rng_o3 >> 8u) & 0xFFu, 80u + rng_o3 % 60u);
      } else if (o_bl == EMPTY && (rng_o3 & 31u) == 0u) {
        bl = makeCell(SMOKE, (rng_o3 >> 8u) & 0xFFu, 40u + rng_o3 % 30u);
      }
      let rng_o4 = hash(rng_o3 ^ 0xF1AE0004u);
      if (o_br == OIL && (rng_o4 % 100u) < 15u) {
        br = makeCell(FIRE, (rng_o4 >> 8u) & 0xFFu, 80u + rng_o4 % 60u);
      } else if (o_br == EMPTY && (rng_o4 & 31u) == 0u) {
        br = makeCell(SMOKE, (rng_o4 >> 8u) & 0xFFu, 40u + rng_o4 % 30u);
      }
    }
  }

  // === ALCHEMY: fire + sand → glass (melting) ===
  // Sustained fire melts sand into glass (~2% per pass). Fire loses lifetime.
  {
    let g_tl = getElement(tl);
    let g_tr = getElement(tr);
    let g_bl = getElement(bl);
    let g_br = getElement(br);

    let has_fire_g = (g_tl == FIRE || g_tr == FIRE || g_bl == FIRE || g_br == FIRE);
    let has_sand = (g_tl == SAND || g_tr == SAND || g_bl == SAND || g_br == SAND);

    if (has_fire_g && has_sand) {
      let rng_g = hash(rng1 ^ 0x6EA55000u);

      // Melt sand cells (~2% each)
      if (g_tl == SAND && (rng_g % 100u) < 2u) {
        tl = makeCell(GLASS, (rng_g >> 8u) & 0xFFu, 0u);
      }
      let rng_g2 = hash(rng_g ^ 0xAE1F0001u);
      if (g_tr == SAND && (rng_g2 % 100u) < 2u) {
        tr = makeCell(GLASS, (rng_g2 >> 8u) & 0xFFu, 0u);
      }
      let rng_g3 = hash(rng_g2 ^ 0xAE1F0002u);
      if (g_bl == SAND && (rng_g3 % 100u) < 2u) {
        bl = makeCell(GLASS, (rng_g3 >> 8u) & 0xFFu, 0u);
      }
      let rng_g4 = hash(rng_g3 ^ 0xAE1F0003u);
      if (g_br == SAND && (rng_g4 % 100u) < 2u) {
        br = makeCell(GLASS, (rng_g4 >> 8u) & 0xFFu, 0u);
      }

      // Fire loses lifetime from melting effort (7 per sand in block)
      let sand_count = u32(g_tl == SAND) + u32(g_tr == SAND)
                     + u32(g_bl == SAND) + u32(g_br == SAND);
      let melt_cost = sand_count * 7u;
      if (g_tl == FIRE) { let lt = getLifetime(tl); if (lt > melt_cost) { tl = setLifetime(tl, lt - melt_cost); } else { tl = 0u; } }
      if (g_tr == FIRE) { let lt = getLifetime(tr); if (lt > melt_cost) { tr = setLifetime(tr, lt - melt_cost); } else { tr = 0u; } }
      if (g_bl == FIRE) { let lt = getLifetime(bl); if (lt > melt_cost) { bl = setLifetime(bl, lt - melt_cost); } else { bl = 0u; } }
      if (g_br == FIRE) { let lt = getLifetime(br); if (lt > melt_cost) { br = setLifetime(br, lt - melt_cost); } else { br = 0u; } }
    }
  }

  // === STONE HEAT: accumulation, decay, and transfer ===
  // Stone uses bits 16-23 as heat level (0-255). Fire heats adjacent stone,
  // hot stone conducts heat and affects neighbors (ignites wood, melts sand, boils water).
  {
    let h_tl = getElement(tl);
    let h_tr = getElement(tr);
    let h_bl = getElement(bl);
    let h_br = getElement(br);

    let has_stone = (h_tl == STONE || h_tr == STONE || h_bl == STONE || h_br == STONE);

    if (has_stone) {
      let heat_rng = hash(rng1 ^ 0xBEA70001u);

      // --- Heat accumulation: fire heats adjacent stone by 2-4 per pass ---
      let fire_in_block = u32(h_tl == FIRE) + u32(h_tr == FIRE)
                        + u32(h_bl == FIRE) + u32(h_br == FIRE);
      let heat_gain = fire_in_block * (2u + (heat_rng & 1u)); // 2-3 per fire cell

      if (h_tl == STONE && fire_in_block > 0u) {
        let h = min(getLifetime(tl) + heat_gain, 255u);
        tl = setLifetime(tl, h);
      }
      if (h_tr == STONE && fire_in_block > 0u) {
        let h = min(getLifetime(tr) + heat_gain, 255u);
        tr = setLifetime(tr, h);
      }
      if (h_bl == STONE && fire_in_block > 0u) {
        let h = min(getLifetime(bl) + heat_gain, 255u);
        bl = setLifetime(bl, h);
      }
      if (h_br == STONE && fire_in_block > 0u) {
        let h = min(getLifetime(br) + heat_gain, 255u);
        br = setLifetime(br, h);
      }

      // --- Heat decay: ~1% chance per pass to cool by 1 ---
      let cool_rng = hash(heat_rng ^ 0xC001D000u);
      if (h_tl == STONE && getLifetime(tl) > 0u && (cool_rng & 127u) == 0u) {
        tl = setLifetime(tl, getLifetime(tl) - 1u);
      }
      let cool_rng2 = hash(cool_rng ^ 0xC001D001u);
      if (h_tr == STONE && getLifetime(tr) > 0u && (cool_rng2 & 127u) == 0u) {
        tr = setLifetime(tr, getLifetime(tr) - 1u);
      }
      let cool_rng3 = hash(cool_rng2 ^ 0xC001D002u);
      if (h_bl == STONE && getLifetime(bl) > 0u && (cool_rng3 & 127u) == 0u) {
        bl = setLifetime(bl, getLifetime(bl) - 1u);
      }
      let cool_rng4 = hash(cool_rng3 ^ 0xC001D003u);
      if (h_br == STONE && getLifetime(br) > 0u && (cool_rng4 & 127u) == 0u) {
        br = setLifetime(br, getLifetime(br) - 1u);
      }

      // --- Stone-to-stone heat conduction ---
      // Equalize heat between adjacent stone cells (1 unit toward average)
      if (h_tl == STONE && h_tr == STONE) {
        let ht1 = getLifetime(tl); let ht2 = getLifetime(tr);
        if (ht1 > ht2 + 1u) { tl = setLifetime(tl, ht1 - 1u); tr = setLifetime(tr, ht2 + 1u); }
        else if (ht2 > ht1 + 1u) { tr = setLifetime(tr, ht2 - 1u); tl = setLifetime(tl, ht1 + 1u); }
      }
      if (h_bl == STONE && h_br == STONE) {
        let ht1 = getLifetime(bl); let ht2 = getLifetime(br);
        if (ht1 > ht2 + 1u) { bl = setLifetime(bl, ht1 - 1u); br = setLifetime(br, ht2 + 1u); }
        else if (ht2 > ht1 + 1u) { br = setLifetime(br, ht2 - 1u); bl = setLifetime(bl, ht1 + 1u); }
      }
      if (h_tl == STONE && h_bl == STONE) {
        let ht1 = getLifetime(tl); let ht2 = getLifetime(bl);
        if (ht1 > ht2 + 1u) { tl = setLifetime(tl, ht1 - 1u); bl = setLifetime(bl, ht2 + 1u); }
        else if (ht2 > ht1 + 1u) { bl = setLifetime(bl, ht2 - 1u); tl = setLifetime(tl, ht1 + 1u); }
      }
      if (h_tr == STONE && h_br == STONE) {
        let ht1 = getLifetime(tr); let ht2 = getLifetime(br);
        if (ht1 > ht2 + 1u) { tr = setLifetime(tr, ht1 - 1u); br = setLifetime(br, ht2 + 1u); }
        else if (ht2 > ht1 + 1u) { br = setLifetime(br, ht2 - 1u); tr = setLifetime(tr, ht1 + 1u); }
      }

      // --- Hot stone effects on neighbors ---
      // Re-read elements (stone heat may not change types, but be safe)
      let hx_tl = getElement(tl);
      let hx_tr = getElement(tr);
      let hx_bl = getElement(bl);
      let hx_br = getElement(br);

      // Find max stone heat in the block
      var max_heat = 0u;
      if (hx_tl == STONE) { max_heat = max(max_heat, getLifetime(tl)); }
      if (hx_tr == STONE) { max_heat = max(max_heat, getLifetime(tr)); }
      if (hx_bl == STONE) { max_heat = max(max_heat, getLifetime(bl)); }
      if (hx_br == STONE) { max_heat = max(max_heat, getLifetime(br)); }

      let fx_rng = hash(heat_rng ^ 0xFE0A0B0Cu);

      // Hot stone (>150) ignites wood (~0.05% per pass)
      if (max_heat > 150u) {
        let fx_rng2 = hash(fx_rng ^ 0xA0B0C0D0u);
        if (hx_tl == WOOD && (fx_rng & 2047u) == 0u) {
          tl = makeCell(FIRE, (fx_rng >> 8u) & 0xFFu, 80u + fx_rng % 60u);
        }
        if (hx_tr == WOOD && (fx_rng2 & 2047u) == 0u) {
          tr = makeCell(FIRE, (fx_rng2 >> 8u) & 0xFFu, 80u + fx_rng2 % 60u);
        }
        let fx_rng3 = hash(fx_rng2 ^ 0xB0C0D0E0u);
        if (hx_bl == WOOD && (fx_rng3 & 2047u) == 0u) {
          bl = makeCell(FIRE, (fx_rng3 >> 8u) & 0xFFu, 80u + fx_rng3 % 60u);
        }
        let fx_rng4 = hash(fx_rng3 ^ 0xC0D0E0F0u);
        if (hx_br == WOOD && (fx_rng4 & 2047u) == 0u) {
          br = makeCell(FIRE, (fx_rng4 >> 8u) & 0xFFu, 80u + fx_rng4 % 60u);
        }
      }

      // Very hot stone (>200) melts sand (~0.5% per pass)
      if (max_heat > 200u) {
        let mx_rng = hash(fx_rng ^ 0xD0E0F000u);
        if (hx_tl == SAND && (mx_rng % 200u) == 0u) {
          tl = makeCell(GLASS, (mx_rng >> 8u) & 0xFFu, 0u);
        }
        let mx_rng2 = hash(mx_rng ^ 0xE0F00010u);
        if (hx_tr == SAND && (mx_rng2 % 200u) == 0u) {
          tr = makeCell(GLASS, (mx_rng2 >> 8u) & 0xFFu, 0u);
        }
        let mx_rng3 = hash(mx_rng2 ^ 0xF0001020u);
        if (hx_bl == SAND && (mx_rng3 % 200u) == 0u) {
          bl = makeCell(GLASS, (mx_rng3 >> 8u) & 0xFFu, 0u);
        }
        let mx_rng4 = hash(mx_rng3 ^ 0x00102030u);
        if (hx_br == SAND && (mx_rng4 % 200u) == 0u) {
          br = makeCell(GLASS, (mx_rng4 >> 8u) & 0xFFu, 0u);
        }
      }

      // Hot stone (>100) boils water (~1% per pass)
      if (max_heat > 100u) {
        let bx_rng = hash(fx_rng ^ 0x5011BEE0u);
        if (hx_tl == WATER && (bx_rng % 100u) < 1u) {
          tl = makeCell(STEAM, (bx_rng >> 8u) & 0xFFu, 120u + bx_rng % 80u);
        }
        let bx_rng2 = hash(bx_rng ^ 0xB011BEE1u);
        if (hx_tr == WATER && (bx_rng2 % 100u) < 1u) {
          tr = makeCell(STEAM, (bx_rng2 >> 8u) & 0xFFu, 120u + bx_rng2 % 80u);
        }
        let bx_rng3 = hash(bx_rng2 ^ 0xB011BEE2u);
        if (hx_bl == WATER && (bx_rng3 % 100u) < 1u) {
          bl = makeCell(STEAM, (bx_rng3 >> 8u) & 0xFFu, 120u + bx_rng3 % 80u);
        }
        let bx_rng4 = hash(bx_rng3 ^ 0xB011BEE3u);
        if (hx_br == WATER && (bx_rng4 % 100u) < 1u) {
          br = makeCell(STEAM, (bx_rng4 >> 8u) & 0xFFu, 120u + bx_rng4 % 80u);
        }
      }
    }
  }

  // Re-read elements after aging + alchemy + heat (types may have changed)
  let etl = getElement(tl);
  let etr = getElement(tr);
  let ebl = getElement(bl);
  let ebr = getElement(br);

  // === PHASE 1: GRAVITY ===
  if (params.lateral_only == 0u && should_move) {
    // Try to drop left column: TL falls to BL
    let can_drop_l = getDensity(etl) > getDensity(ebl) && !isImmovable(etl) && !isImmovable(ebl);
    // Try to drop right column: TR falls to BR
    let can_drop_r = getDensity(etr) > getDensity(ebr) && !isImmovable(etr) && !isImmovable(ebr);

    // Sand-water drag: gates ALL sand movement through water (vertical + diagonal).
    // Without this, sand bypasses vertical drag via the diagonal dispersion path.
    let sand_water_move = (rng1 % 100u) < 35u; // 35% chance to move through water
    let sw_l = (etl == SAND && ebl == WATER) || (etl == WATER && ebl == SAND);
    let sw_r = (etr == SAND && ebr == WATER) || (etr == WATER && ebr == SAND);

    // Gas rise drag: fire/steam/smoke rise slowly, not every pass.
    // Without this, gases teleport upward at full simulation speed.
    let gas_rng = (rng1 >> 6u) % 100u;
    let fire_l = (etl == FIRE && ebl == EMPTY) || (etl == EMPTY && ebl == FIRE);
    let fire_r = (etr == FIRE && ebr == EMPTY) || (etr == EMPTY && ebr == FIRE);
    let steam_l = (etl == STEAM && ebl == EMPTY) || (etl == EMPTY && ebl == STEAM);
    let steam_r = (etr == STEAM && ebr == EMPTY) || (etr == EMPTY && ebr == STEAM);
    let smoke_l = (etl == SMOKE && ebl == EMPTY) || (etl == EMPTY && ebl == SMOKE);
    let smoke_r = (etr == SMOKE && ebr == EMPTY) || (etr == EMPTY && ebr == SMOKE);
    let fire_can_move = gas_rng < 20u;  // 20% → ~2-3 rises/frame
    let steam_can_move = gas_rng < 35u; // 35% → ~4-5 rises/frame
    let smoke_can_move = gas_rng < 30u; // 30% → ~3-4 rises/frame
    let gas_ok_l = (!fire_l || fire_can_move) && (!steam_l || steam_can_move) && (!smoke_l || smoke_can_move);
    let gas_ok_r = (!fire_r || fire_can_move) && (!steam_r || steam_can_move) && (!smoke_r || smoke_can_move);

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
      let tl_slide_base = d_tl > d_br && d_tl > EMPTY_DENSITY && d_bl >= d_tl && !isImmovable(etl) && !isImmovable(ebr);
      let tr_slide_base = d_tr > d_bl && d_tr > EMPTY_DENSITY && d_br >= d_tr && !isImmovable(etr) && !isImmovable(ebl);
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

    // Oil lateral spread: same diving-beet rules as water.
    // Oil is a liquid, spreads laterally when the other row is occupied.
    {
      let ol_tl = getElement(tl);
      let ol_tr = getElement(tr);
      let ol_bl = getElement(bl);
      let ol_br = getElement(br);

      // Bottom row: one oil + one empty → swap if top row fully occupied
      if ((ol_bl == OIL && ol_br == EMPTY) || (ol_br == OIL && ol_bl == EMPTY)) {
        if (ol_tl != EMPTY && ol_tr != EMPTY) {
          let tmp = bl; bl = br; br = tmp;
        }
      }

      // Top row: one oil + one empty → swap if bottom row fully occupied
      if ((ol_tl == OIL && ol_tr == EMPTY) || (ol_tr == OIL && ol_tl == EMPTY)) {
        if (ol_bl != EMPTY && ol_br != EMPTY) {
          let tmp = tl; tl = tr; tr = tmp;
        }
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

    // Smoke lateral spread: similar to steam, loose dispersal.
    {
      let sk_tl = getElement(tl);
      let sk_tr = getElement(tr);
      let sk_bl = getElement(bl);
      let sk_br = getElement(br);
      let smoke_spread_rng = hash(rng0 ^ 0x540EEEE0u);
      let smoke_free_spread = (smoke_spread_rng & 7u) == 0u; // ~12.5%

      // Bottom row: one smoke + one empty
      if ((sk_bl == SMOKE && sk_br == EMPTY) || (sk_br == SMOKE && sk_bl == EMPTY)) {
        if ((sk_tl != EMPTY && sk_tr != EMPTY) || smoke_free_spread) {
          let tmp = bl; bl = br; br = tmp;
        }
      }

      // Top row: one smoke + one empty
      if ((sk_tl == SMOKE && sk_tr == EMPTY) || (sk_tr == SMOKE && sk_tl == EMPTY)) {
        if ((sk_bl != EMPTY && sk_br != EMPTY) || smoke_free_spread) {
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
