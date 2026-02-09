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
const LAVA: u32 = 10u;
const ACID: u32 = 11u;
const GUNPOWDER: u32 = 12u;
const BOMB: u32 = 13u;

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
  return element == STONE || element == WOOD || element == GLASS || element == BOMB;
}

fn getDensity(element: u32) -> u32 {
  switch(element) {
    case FIRE:  { return 0u; }
    case SMOKE: { return 1u; }
    case STEAM: { return 1u; }
    case EMPTY: { return EMPTY_DENSITY; }
    case OIL:   { return 4u; }
    case WATER: { return 5u; }
    case ACID:  { return 6u; }
    case LAVA:  { return 7u; }
    case WOOD:  { return 9u; }
    case SAND:      { return 10u; }
    case GUNPOWDER: { return 10u; }
    case GLASS: { return 200u; }
    case BOMB:  { return 255u; }
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

  if (element == LAVA) {
    let heat = getLifetime(cell);
    if (heat == 0u) {
      // Cooled completely: solidify into stone
      let stone_cv = (rng >> 8u) & 0xFFu;
      return makeCell(STONE, stone_cv, 0u);
    }
    // ~0.6% chance to cool per pass (24 passes * 0.6% ~ 14% per frame)
    // At heat ~200, takes ~1400 frames (~23 sec) to fully solidify
    let should_cool = (rng % 166u) == 0u;
    if (should_cool) {
      return setLifetime(cell, heat - 1u);
    }
    return cell;
  }

  if (element == ACID) {
    let potency = getLifetime(cell);
    if (potency == 0u) { return 0u; } // spent acid → empty
    // ~0.8% passive potency decay per pass
    let should_decay = (rng & 127u) == 0u;
    if (should_decay) {
      let new_p = potency - 1u;
      if (new_p == 0u) { return 0u; }
      return setLifetime(cell, new_p);
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
      // Water: mostly survives, 30% consumed (60% of consumed → steam, 40% → empty).
      let steam_coin_a = hash(rng_a ^ 0x5EA40001u);
      if (a_tl == FIRE) { tl = makeCell(STEAM, (rng_a >> 8u) & 0xFFu, 40u + rng_a % 40u); }
      else if (a_tl == WATER) { if ((rng_a % 100u) < 30u) { if ((steam_coin_a % 100u) < 60u) { tl = makeCell(STEAM, (rng_a >> 8u) & 0xFFu, 60u + rng_a % 60u); } else { tl = 0u; } } }

      let steam_coin_b = hash(rng_b ^ 0x5EA40002u);
      if (a_tr == FIRE) { tr = makeCell(STEAM, (rng_b >> 8u) & 0xFFu, 40u + rng_b % 40u); }
      else if (a_tr == WATER) { if ((rng_b % 100u) < 30u) { if ((steam_coin_b % 100u) < 60u) { tr = makeCell(STEAM, (rng_b >> 8u) & 0xFFu, 60u + rng_b % 60u); } else { tr = 0u; } } }

      let steam_coin_c = hash(rng_c ^ 0x5EA40003u);
      if (a_bl == FIRE) { bl = makeCell(STEAM, (rng_c >> 8u) & 0xFFu, 40u + rng_c % 40u); }
      else if (a_bl == WATER) { if ((rng_c % 100u) < 30u) { if ((steam_coin_c % 100u) < 60u) { bl = makeCell(STEAM, (rng_c >> 8u) & 0xFFu, 60u + rng_c % 60u); } else { bl = 0u; } } }

      let steam_coin_d = hash(rng_d ^ 0x5EA40004u);
      if (a_br == FIRE) { br = makeCell(STEAM, (rng_d >> 8u) & 0xFFu, 40u + rng_d % 40u); }
      else if (a_br == WATER) { if ((rng_d % 100u) < 30u) { if ((steam_coin_d % 100u) < 60u) { br = makeCell(STEAM, (rng_d >> 8u) & 0xFFu, 60u + rng_d % 60u); } else { br = 0u; } } }
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

  // === ALCHEMY: fire/blast fire + bomb → instant detonation ===
  // Bomb in the same 2x2 block as fire detonates instantly (100%/pass).
  // All cells in the block become blast fire (lt 250) or smoke.
  {
    let bm_tl = getElement(tl);
    let bm_tr = getElement(tr);
    let bm_bl = getElement(bl);
    let bm_br = getElement(br);

    let has_fire_bm = (bm_tl == FIRE || bm_tr == FIRE || bm_bl == FIRE || bm_br == FIRE);
    let has_bomb = (bm_tl == BOMB || bm_tr == BOMB || bm_bl == BOMB || bm_br == BOMB);

    if (has_fire_bm && has_bomb) {
      let bm_rng = hash(rng1 ^ 0xb00b0001u);
      // Convert every cell in block to blast fire or smoke
      if (bm_tl == BOMB || bm_tl == FIRE) {
        tl = makeCell(FIRE, (bm_rng >> 8u) & 0xFFu, 250u);
      } else if (bm_tl == EMPTY) {
        tl = makeCell(SMOKE, (bm_rng >> 8u) & 0xFFu, 60u + bm_rng % 40u);
      } else if (!isImmovable(bm_tl)) {
        tl = makeCell(FIRE, (bm_rng >> 8u) & 0xFFu, 240u);
      }
      let bm_rng2 = hash(bm_rng ^ 0xb00b0002u);
      if (bm_tr == BOMB || bm_tr == FIRE) {
        tr = makeCell(FIRE, (bm_rng2 >> 8u) & 0xFFu, 250u);
      } else if (bm_tr == EMPTY) {
        tr = makeCell(SMOKE, (bm_rng2 >> 8u) & 0xFFu, 60u + bm_rng2 % 40u);
      } else if (!isImmovable(bm_tr)) {
        tr = makeCell(FIRE, (bm_rng2 >> 8u) & 0xFFu, 240u);
      }
      let bm_rng3 = hash(bm_rng2 ^ 0xb00b0003u);
      if (bm_bl == BOMB || bm_bl == FIRE) {
        bl = makeCell(FIRE, (bm_rng3 >> 8u) & 0xFFu, 250u);
      } else if (bm_bl == EMPTY) {
        bl = makeCell(SMOKE, (bm_rng3 >> 8u) & 0xFFu, 60u + bm_rng3 % 40u);
      } else if (!isImmovable(bm_bl)) {
        bl = makeCell(FIRE, (bm_rng3 >> 8u) & 0xFFu, 240u);
      }
      let bm_rng4 = hash(bm_rng3 ^ 0xb00b0004u);
      if (bm_br == BOMB || bm_br == FIRE) {
        br = makeCell(FIRE, (bm_rng4 >> 8u) & 0xFFu, 250u);
      } else if (bm_br == EMPTY) {
        br = makeCell(SMOKE, (bm_rng4 >> 8u) & 0xFFu, 60u + bm_rng4 % 40u);
      } else if (!isImmovable(bm_br)) {
        br = makeCell(FIRE, (bm_rng4 >> 8u) & 0xFFu, 240u);
      }
    }
  }

  // === ALCHEMY: blast fire propagation (lt > 200) ===
  // High-lifetime fire from bomb detonation aggressively converts neighbors.
  // Each hop reduces lifetime by 8-12, creating natural radius decay.
  // Stone and glass survive; everything else is consumed.
  {
    let bf_tl = getElement(tl);
    let bf_tr = getElement(tr);
    let bf_bl = getElement(bl);
    let bf_br = getElement(br);

    // Find max blast fire lifetime in the block
    var max_blast_lt = 0u;
    if (bf_tl == FIRE && getLifetime(tl) > 200u) { max_blast_lt = max(max_blast_lt, getLifetime(tl)); }
    if (bf_tr == FIRE && getLifetime(tr) > 200u) { max_blast_lt = max(max_blast_lt, getLifetime(tr)); }
    if (bf_bl == FIRE && getLifetime(bl) > 200u) { max_blast_lt = max(max_blast_lt, getLifetime(bl)); }
    if (bf_br == FIRE && getLifetime(br) > 200u) { max_blast_lt = max(max_blast_lt, getLifetime(br)); }

    if (max_blast_lt > 200u) {
      let bf_rng = hash(rng1 ^ 0xb1a50001u);
      let bf_rng2 = hash(bf_rng ^ 0xb1a50002u);
      let bf_rng3 = hash(bf_rng2 ^ 0xb1a50003u);
      let bf_rng4 = hash(bf_rng3 ^ 0xb1a50004u);

      // Convert each non-blast-fire cell
      if (bf_tl != FIRE || getLifetime(tl) <= 200u) {
        let decay = 8u + (bf_rng % 5u); // 8-12
        let new_lt = max_blast_lt - min(decay, max_blast_lt);
        if (bf_tl == BOMB) { tl = makeCell(FIRE, (bf_rng >> 8u) & 0xFFu, 250u); }
        else if (bf_tl == GUNPOWDER) { let amp_lt = min(max_blast_lt - min(5u + (bf_rng % 4u), max_blast_lt), 255u); tl = makeCell(FIRE, (bf_rng >> 8u) & 0xFFu, amp_lt); }
        else if (bf_tl == WATER) { tl = makeCell(STEAM, (bf_rng >> 8u) & 0xFFu, 80u + bf_rng % 60u); }
        else if (bf_tl == ACID) { tl = makeCell(SMOKE, (bf_rng >> 8u) & 0xFFu, 40u + bf_rng % 30u); }
        else if (bf_tl == STONE) { let h = min(getLifetime(tl) + 10u, 255u); tl = setLifetime(tl, h); }
        else if (bf_tl == GLASS || bf_tl == LAVA) { /* survives */ }
        else if (bf_tl == SMOKE || bf_tl == STEAM) { /* already gaseous */ }
        else if (bf_tl != FIRE) { tl = makeCell(FIRE, (bf_rng >> 8u) & 0xFFu, new_lt); }
      }

      if (bf_tr != FIRE || getLifetime(tr) <= 200u) {
        let decay = 8u + (bf_rng2 % 5u);
        let new_lt = max_blast_lt - min(decay, max_blast_lt);
        if (bf_tr == BOMB) { tr = makeCell(FIRE, (bf_rng2 >> 8u) & 0xFFu, 250u); }
        else if (bf_tr == GUNPOWDER) { let amp_lt = min(max_blast_lt - min(5u + (bf_rng2 % 4u), max_blast_lt), 255u); tr = makeCell(FIRE, (bf_rng2 >> 8u) & 0xFFu, amp_lt); }
        else if (bf_tr == WATER) { tr = makeCell(STEAM, (bf_rng2 >> 8u) & 0xFFu, 80u + bf_rng2 % 60u); }
        else if (bf_tr == ACID) { tr = makeCell(SMOKE, (bf_rng2 >> 8u) & 0xFFu, 40u + bf_rng2 % 30u); }
        else if (bf_tr == STONE) { let h = min(getLifetime(tr) + 10u, 255u); tr = setLifetime(tr, h); }
        else if (bf_tr == GLASS || bf_tr == LAVA) { /* survives */ }
        else if (bf_tr == SMOKE || bf_tr == STEAM) { /* already gaseous */ }
        else if (bf_tr != FIRE) { tr = makeCell(FIRE, (bf_rng2 >> 8u) & 0xFFu, new_lt); }
      }

      if (bf_bl != FIRE || getLifetime(bl) <= 200u) {
        let decay = 8u + (bf_rng3 % 5u);
        let new_lt = max_blast_lt - min(decay, max_blast_lt);
        if (bf_bl == BOMB) { bl = makeCell(FIRE, (bf_rng3 >> 8u) & 0xFFu, 250u); }
        else if (bf_bl == GUNPOWDER) { let amp_lt = min(max_blast_lt - min(5u + (bf_rng3 % 4u), max_blast_lt), 255u); bl = makeCell(FIRE, (bf_rng3 >> 8u) & 0xFFu, amp_lt); }
        else if (bf_bl == WATER) { bl = makeCell(STEAM, (bf_rng3 >> 8u) & 0xFFu, 80u + bf_rng3 % 60u); }
        else if (bf_bl == ACID) { bl = makeCell(SMOKE, (bf_rng3 >> 8u) & 0xFFu, 40u + bf_rng3 % 30u); }
        else if (bf_bl == STONE) { let h = min(getLifetime(bl) + 10u, 255u); bl = setLifetime(bl, h); }
        else if (bf_bl == GLASS || bf_bl == LAVA) { /* survives */ }
        else if (bf_bl == SMOKE || bf_bl == STEAM) { /* already gaseous */ }
        else if (bf_bl != FIRE) { bl = makeCell(FIRE, (bf_rng3 >> 8u) & 0xFFu, new_lt); }
      }

      if (bf_br != FIRE || getLifetime(br) <= 200u) {
        let decay = 8u + (bf_rng4 % 5u);
        let new_lt = max_blast_lt - min(decay, max_blast_lt);
        if (bf_br == BOMB) { br = makeCell(FIRE, (bf_rng4 >> 8u) & 0xFFu, 250u); }
        else if (bf_br == GUNPOWDER) { let amp_lt = min(max_blast_lt - min(5u + (bf_rng4 % 4u), max_blast_lt), 255u); br = makeCell(FIRE, (bf_rng4 >> 8u) & 0xFFu, amp_lt); }
        else if (bf_br == WATER) { br = makeCell(STEAM, (bf_rng4 >> 8u) & 0xFFu, 80u + bf_rng4 % 60u); }
        else if (bf_br == ACID) { br = makeCell(SMOKE, (bf_rng4 >> 8u) & 0xFFu, 40u + bf_rng4 % 30u); }
        else if (bf_br == STONE) { let h = min(getLifetime(br) + 10u, 255u); br = setLifetime(br, h); }
        else if (bf_br == GLASS || bf_br == LAVA) { /* survives */ }
        else if (bf_br == SMOKE || bf_br == STEAM) { /* already gaseous */ }
        else if (bf_br != FIRE) { br = makeCell(FIRE, (bf_rng4 >> 8u) & 0xFFu, new_lt); }
      }
    }
  }

  // === ALCHEMY: fire + gunpowder → explosive chain reaction ===
  // Gunpowder in the same 2x2 block as fire detonates (~50%/pass).
  // With 24 passes/frame this is nearly instant chain reaction.
  // Resulting fire has high lifetime (120-179) for dramatic long-burning effect.
  {
    let gp_tl = getElement(tl);
    let gp_tr = getElement(tr);
    let gp_bl = getElement(bl);
    let gp_br = getElement(br);

    let has_fire_gp = (gp_tl == FIRE || gp_tr == FIRE || gp_bl == FIRE || gp_br == FIRE);
    let has_gunpowder = (gp_tl == GUNPOWDER || gp_tr == GUNPOWDER || gp_bl == GUNPOWDER || gp_br == GUNPOWDER);

    if (has_fire_gp && has_gunpowder) {
      let gp_rng = hash(rng1 ^ 0xba0000dau);
      if (gp_tl == GUNPOWDER && (gp_rng % 100u) < 50u) {
        tl = makeCell(FIRE, (gp_rng >> 8u) & 0xFFu, 120u + gp_rng % 60u);
      } else if (gp_tl == EMPTY && (gp_rng % 100u) < 10u) {
        tl = makeCell(SMOKE, (gp_rng >> 8u) & 0xFFu, 40u + gp_rng % 30u);
      }
      let gp_rng2 = hash(gp_rng ^ 0xba0000dbu);
      if (gp_tr == GUNPOWDER && (gp_rng2 % 100u) < 50u) {
        tr = makeCell(FIRE, (gp_rng2 >> 8u) & 0xFFu, 120u + gp_rng2 % 60u);
      } else if (gp_tr == EMPTY && (gp_rng2 % 100u) < 10u) {
        tr = makeCell(SMOKE, (gp_rng2 >> 8u) & 0xFFu, 40u + gp_rng2 % 30u);
      }
      let gp_rng3 = hash(gp_rng2 ^ 0xba0000dcu);
      if (gp_bl == GUNPOWDER && (gp_rng3 % 100u) < 50u) {
        bl = makeCell(FIRE, (gp_rng3 >> 8u) & 0xFFu, 120u + gp_rng3 % 60u);
      } else if (gp_bl == EMPTY && (gp_rng3 % 100u) < 10u) {
        bl = makeCell(SMOKE, (gp_rng3 >> 8u) & 0xFFu, 40u + gp_rng3 % 30u);
      }
      let gp_rng4 = hash(gp_rng3 ^ 0xba0000ddu);
      if (gp_br == GUNPOWDER && (gp_rng4 % 100u) < 50u) {
        br = makeCell(FIRE, (gp_rng4 >> 8u) & 0xFFu, 120u + gp_rng4 % 60u);
      } else if (gp_br == EMPTY && (gp_rng4 % 100u) < 10u) {
        br = makeCell(SMOKE, (gp_rng4 >> 8u) & 0xFFu, 40u + gp_rng4 % 30u);
      }
    }
  }

  // === ALCHEMY: lava interactions ===
  // Lava is a hot liquid that cools over time. On contact:
  // - Water: rapid cooling (lava loses heat, water → steam). Lava sinks through
  //   water via gravity while cooling, solidifying naturally when heat reaches 0.
  // - Sand: melts into glass (~4%/pass, faster than fire)
  // - Wood: ignites into fire (~8%/pass, much faster than fire+wood)
  // - Oil: ignites into fire (~20%/pass)
  {
    let lv_tl = getElement(tl);
    let lv_tr = getElement(tr);
    let lv_bl = getElement(bl);
    let lv_br = getElement(br);

    let has_lava = (lv_tl == LAVA || lv_tr == LAVA || lv_bl == LAVA || lv_br == LAVA);

    if (has_lava) {
      let lv_rng = hash(rng1 ^ 0x1a0a0001u);

      // --- Lava + Water: rapid cooling + steam ---
      // Water evaporates (~50%/pass), lava loses 3-5 heat per water cell.
      // Gravity handles sinking (density 7 > 5), no instant solidification.
      let has_water_lv = (lv_tl == WATER || lv_tr == WATER || lv_bl == WATER || lv_br == WATER);
      if (has_water_lv) {
        let water_ct = u32(lv_tl == WATER) + u32(lv_tr == WATER) + u32(lv_bl == WATER) + u32(lv_br == WATER);
        let cool_amt = water_ct * (3u + (lv_rng & 1u)); // 3-4 heat per water cell

        // Cool lava cells
        if (lv_tl == LAVA) { let h = getLifetime(tl); if (h > cool_amt) { tl = setLifetime(tl, h - cool_amt); } else { tl = setLifetime(tl, 0u); } }
        if (lv_tr == LAVA) { let h = getLifetime(tr); if (h > cool_amt) { tr = setLifetime(tr, h - cool_amt); } else { tr = setLifetime(tr, 0u); } }
        if (lv_bl == LAVA) { let h = getLifetime(bl); if (h > cool_amt) { bl = setLifetime(bl, h - cool_amt); } else { bl = setLifetime(bl, 0u); } }
        if (lv_br == LAVA) { let h = getLifetime(br); if (h > cool_amt) { br = setLifetime(br, h - cool_amt); } else { br = setLifetime(br, 0u); } }

        // Evaporate water (~50%/pass, 60% of consumed → steam, 40% → empty)
        let lv_rw = hash(lv_rng ^ 0xface0001u);
        let lv_sc1 = hash(lv_rw ^ 0x5EA40001u);
        if (lv_tl == WATER && (lv_rw % 100u) < 50u) { if ((lv_sc1 % 100u) < 60u) { tl = makeCell(STEAM, (lv_rw >> 8u) & 0xFFu, 80u + lv_rw % 60u); } else { tl = 0u; } }
        let lv_rw2 = hash(lv_rw ^ 0xface0002u);
        let lv_sc2 = hash(lv_rw2 ^ 0x5EA40002u);
        if (lv_tr == WATER && (lv_rw2 % 100u) < 50u) { if ((lv_sc2 % 100u) < 60u) { tr = makeCell(STEAM, (lv_rw2 >> 8u) & 0xFFu, 80u + lv_rw2 % 60u); } else { tr = 0u; } }
        let lv_rw3 = hash(lv_rw2 ^ 0xface0003u);
        let lv_sc3 = hash(lv_rw3 ^ 0x5EA40003u);
        if (lv_bl == WATER && (lv_rw3 % 100u) < 50u) { if ((lv_sc3 % 100u) < 60u) { bl = makeCell(STEAM, (lv_rw3 >> 8u) & 0xFFu, 80u + lv_rw3 % 60u); } else { bl = 0u; } }
        let lv_rw4 = hash(lv_rw3 ^ 0xface0004u);
        let lv_sc4 = hash(lv_rw4 ^ 0x5EA40004u);
        if (lv_br == WATER && (lv_rw4 % 100u) < 50u) { if ((lv_sc4 % 100u) < 60u) { br = makeCell(STEAM, (lv_rw4 >> 8u) & 0xFFu, 80u + lv_rw4 % 60u); } else { br = 0u; } }
      }

      // Re-read after water interaction (types may have changed)
      let lv2_tl = getElement(tl);
      let lv2_tr = getElement(tr);
      let lv2_bl = getElement(bl);
      let lv2_br = getElement(br);
      let has_lava2 = (lv2_tl == LAVA || lv2_tr == LAVA || lv2_bl == LAVA || lv2_br == LAVA);

      if (has_lava2) {
        // --- Lava + Sand: melts sand into glass (~4%/pass) ---
        let has_sand_lv = (lv2_tl == SAND || lv2_tr == SAND || lv2_bl == SAND || lv2_br == SAND);
        if (has_sand_lv) {
          let ls_rng = hash(lv_rng ^ 0xea550001u);
          if (lv2_tl == SAND && (ls_rng % 100u) < 4u) { tl = makeCell(GLASS, (ls_rng >> 8u) & 0xFFu, 0u); }
          let ls_rng2 = hash(ls_rng ^ 0xea550002u);
          if (lv2_tr == SAND && (ls_rng2 % 100u) < 4u) { tr = makeCell(GLASS, (ls_rng2 >> 8u) & 0xFFu, 0u); }
          let ls_rng3 = hash(ls_rng2 ^ 0xea550003u);
          if (lv2_bl == SAND && (ls_rng3 % 100u) < 4u) { bl = makeCell(GLASS, (ls_rng3 >> 8u) & 0xFFu, 0u); }
          let ls_rng4 = hash(ls_rng3 ^ 0xea550004u);
          if (lv2_br == SAND && (ls_rng4 % 100u) < 4u) { br = makeCell(GLASS, (ls_rng4 >> 8u) & 0xFFu, 0u); }

          // Lava loses heat from melting effort (3 per sand in block)
          let sand_ct = u32(lv2_tl == SAND) + u32(lv2_tr == SAND) + u32(lv2_bl == SAND) + u32(lv2_br == SAND);
          let lava_melt_cost = sand_ct * 3u;
          if (lv2_tl == LAVA) { let lt = getLifetime(tl); if (lt > lava_melt_cost) { tl = setLifetime(tl, lt - lava_melt_cost); } else { tl = setLifetime(tl, 0u); } }
          if (lv2_tr == LAVA) { let lt = getLifetime(tr); if (lt > lava_melt_cost) { tr = setLifetime(tr, lt - lava_melt_cost); } else { tr = setLifetime(tr, 0u); } }
          if (lv2_bl == LAVA) { let lt = getLifetime(bl); if (lt > lava_melt_cost) { bl = setLifetime(bl, lt - lava_melt_cost); } else { bl = setLifetime(bl, 0u); } }
          if (lv2_br == LAVA) { let lt = getLifetime(br); if (lt > lava_melt_cost) { br = setLifetime(br, lt - lava_melt_cost); } else { br = setLifetime(br, 0u); } }
        }

        // --- Lava + Wood: ignites wood (~8%/pass) ---
        let has_wood_lv = (lv2_tl == WOOD || lv2_tr == WOOD || lv2_bl == WOOD || lv2_br == WOOD);
        if (has_wood_lv) {
          let lw_rng = hash(lv_rng ^ 0xd00d0001u);
          if (lv2_tl == WOOD && (lw_rng % 100u) < 8u) { tl = makeCell(FIRE, (lw_rng >> 8u) & 0xFFu, 80u + lw_rng % 60u); }
          let lw_rng2 = hash(lw_rng ^ 0xd00d0002u);
          if (lv2_tr == WOOD && (lw_rng2 % 100u) < 8u) { tr = makeCell(FIRE, (lw_rng2 >> 8u) & 0xFFu, 80u + lw_rng2 % 60u); }
          let lw_rng3 = hash(lw_rng2 ^ 0xd00d0003u);
          if (lv2_bl == WOOD && (lw_rng3 % 100u) < 8u) { bl = makeCell(FIRE, (lw_rng3 >> 8u) & 0xFFu, 80u + lw_rng3 % 60u); }
          let lw_rng4 = hash(lw_rng3 ^ 0xd00d0004u);
          if (lv2_br == WOOD && (lw_rng4 % 100u) < 8u) { br = makeCell(FIRE, (lw_rng4 >> 8u) & 0xFFu, 80u + lw_rng4 % 60u); }
        }

        // --- Lava + Oil: ignites oil (~20%/pass) ---
        let has_oil_lv = (lv2_tl == OIL || lv2_tr == OIL || lv2_bl == OIL || lv2_br == OIL);
        if (has_oil_lv) {
          let lo_rng = hash(lv_rng ^ 0xbead0001u);
          if (lv2_tl == OIL && (lo_rng % 100u) < 20u) { tl = makeCell(FIRE, (lo_rng >> 8u) & 0xFFu, 80u + lo_rng % 60u); }
          let lo_rng2 = hash(lo_rng ^ 0xbead0002u);
          if (lv2_tr == OIL && (lo_rng2 % 100u) < 20u) { tr = makeCell(FIRE, (lo_rng2 >> 8u) & 0xFFu, 80u + lo_rng2 % 60u); }
          let lo_rng3 = hash(lo_rng2 ^ 0xbead0003u);
          if (lv2_bl == OIL && (lo_rng3 % 100u) < 20u) { bl = makeCell(FIRE, (lo_rng3 >> 8u) & 0xFFu, 80u + lo_rng3 % 60u); }
          let lo_rng4 = hash(lo_rng3 ^ 0xbead0004u);
          if (lv2_br == OIL && (lo_rng4 % 100u) < 20u) { br = makeCell(FIRE, (lo_rng4 >> 8u) & 0xFFu, 80u + lo_rng4 % 60u); }
        }

        // --- Lava + Gunpowder: ignites gunpowder (~30%/pass) ---
        let has_gp_lv = (lv2_tl == GUNPOWDER || lv2_tr == GUNPOWDER || lv2_bl == GUNPOWDER || lv2_br == GUNPOWDER);
        if (has_gp_lv) {
          let lgp_rng = hash(lv_rng ^ 0xbead0005u);
          if (lv2_tl == GUNPOWDER && (lgp_rng % 100u) < 30u) { tl = makeCell(FIRE, (lgp_rng >> 8u) & 0xFFu, 120u + lgp_rng % 60u); }
          let lgp_rng2 = hash(lgp_rng ^ 0xbead0006u);
          if (lv2_tr == GUNPOWDER && (lgp_rng2 % 100u) < 30u) { tr = makeCell(FIRE, (lgp_rng2 >> 8u) & 0xFFu, 120u + lgp_rng2 % 60u); }
          let lgp_rng3 = hash(lgp_rng2 ^ 0xbead0007u);
          if (lv2_bl == GUNPOWDER && (lgp_rng3 % 100u) < 30u) { bl = makeCell(FIRE, (lgp_rng3 >> 8u) & 0xFFu, 120u + lgp_rng3 % 60u); }
          let lgp_rng4 = hash(lgp_rng3 ^ 0xbead0008u);
          if (lv2_br == GUNPOWDER && (lgp_rng4 % 100u) < 30u) { br = makeCell(FIRE, (lgp_rng4 >> 8u) & 0xFFu, 120u + lgp_rng4 % 60u); }
        }

        // --- Lava + Bomb: instant detonation → blast fire ---
        let has_bomb_lv = (lv2_tl == BOMB || lv2_tr == BOMB || lv2_bl == BOMB || lv2_br == BOMB);
        if (has_bomb_lv) {
          let lbm_rng = hash(lv_rng ^ 0xb00b1a0au);
          if (lv2_tl == BOMB) { tl = makeCell(FIRE, (lbm_rng >> 8u) & 0xFFu, 250u); }
          let lbm_rng2 = hash(lbm_rng ^ 0xb00b1a0bu);
          if (lv2_tr == BOMB) { tr = makeCell(FIRE, (lbm_rng2 >> 8u) & 0xFFu, 250u); }
          let lbm_rng3 = hash(lbm_rng2 ^ 0xb00b1a0cu);
          if (lv2_bl == BOMB) { bl = makeCell(FIRE, (lbm_rng3 >> 8u) & 0xFFu, 250u); }
          let lbm_rng4 = hash(lbm_rng3 ^ 0xb00b1a0du);
          if (lv2_br == BOMB) { br = makeCell(FIRE, (lbm_rng4 >> 8u) & 0xFFu, 250u); }
        }
      }
    }
  }

  // === ALCHEMY: acid dissolves materials ===
  // Acid corrodes sand, stone, wood, glass, oil on contact. Loses potency per reaction.
  // Water dilutes acid. Fire/lava evaporate acid into smoke.
  {
    let ac_tl = getElement(tl);
    let ac_tr = getElement(tr);
    let ac_bl = getElement(bl);
    let ac_br = getElement(br);

    let has_acid = (ac_tl == ACID || ac_tr == ACID || ac_bl == ACID || ac_br == ACID);

    if (has_acid) {
      let ac_rng = hash(rng1 ^ 0xac1d0001u);

      // --- Acid + Fire: acid evaporates (~10%/pass) → smoke ---
      let has_fire_ac = (ac_tl == FIRE || ac_tr == FIRE || ac_bl == FIRE || ac_br == FIRE);
      if (has_fire_ac) {
        let af_rng = hash(ac_rng ^ 0xaf1e0001u);
        if (ac_tl == ACID && (af_rng % 100u) < 10u) { tl = makeCell(SMOKE, (af_rng >> 8u) & 0xFFu, 40u + af_rng % 30u); }
        let af_rng2 = hash(af_rng ^ 0xaf1e0002u);
        if (ac_tr == ACID && (af_rng2 % 100u) < 10u) { tr = makeCell(SMOKE, (af_rng2 >> 8u) & 0xFFu, 40u + af_rng2 % 30u); }
        let af_rng3 = hash(af_rng2 ^ 0xaf1e0003u);
        if (ac_bl == ACID && (af_rng3 % 100u) < 10u) { bl = makeCell(SMOKE, (af_rng3 >> 8u) & 0xFFu, 40u + af_rng3 % 30u); }
        let af_rng4 = hash(af_rng3 ^ 0xaf1e0004u);
        if (ac_br == ACID && (af_rng4 % 100u) < 10u) { br = makeCell(SMOKE, (af_rng4 >> 8u) & 0xFFu, 40u + af_rng4 % 30u); }
      }

      // --- Acid + Lava: acid evaporates (~15%/pass) → smoke ---
      let has_lava_ac = (ac_tl == LAVA || ac_tr == LAVA || ac_bl == LAVA || ac_br == LAVA);
      if (has_lava_ac) {
        let al_rng = hash(ac_rng ^ 0xa1a00001u);
        if (ac_tl == ACID && (al_rng % 100u) < 15u) { tl = makeCell(SMOKE, (al_rng >> 8u) & 0xFFu, 40u + al_rng % 30u); }
        let al_rng2 = hash(al_rng ^ 0xa1a00002u);
        if (ac_tr == ACID && (al_rng2 % 100u) < 15u) { tr = makeCell(SMOKE, (al_rng2 >> 8u) & 0xFFu, 40u + al_rng2 % 30u); }
        let al_rng3 = hash(al_rng2 ^ 0xa1a00003u);
        if (ac_bl == ACID && (al_rng3 % 100u) < 15u) { bl = makeCell(SMOKE, (al_rng3 >> 8u) & 0xFFu, 40u + al_rng3 % 30u); }
        let al_rng4 = hash(al_rng3 ^ 0xa1a00004u);
        if (ac_br == ACID && (al_rng4 % 100u) < 15u) { br = makeCell(SMOKE, (al_rng4 >> 8u) & 0xFFu, 40u + al_rng4 % 30u); }
      }

      // Re-read after fire/lava evaporation (acid cells may have become smoke)
      let ac2_tl = getElement(tl);
      let ac2_tr = getElement(tr);
      let ac2_bl = getElement(bl);
      let ac2_br = getElement(br);
      let has_acid2 = (ac2_tl == ACID || ac2_tr == ACID || ac2_bl == ACID || ac2_br == ACID);

      if (has_acid2) {
        // --- Acid + Water: acid dissolves water (~4%/pass) → steam, acid loses 1 potency ---
        let has_water_ac = (ac2_tl == WATER || ac2_tr == WATER || ac2_bl == WATER || ac2_br == WATER);
        if (has_water_ac) {
          let aw_rng = hash(ac_rng ^ 0xaeed0001u);
          let aw_sc1 = hash(aw_rng ^ 0x5EA40001u);
          if (ac2_tl == WATER && (aw_rng % 100u) < 4u) { if ((aw_sc1 % 100u) < 60u) { tl = makeCell(STEAM, (aw_rng >> 8u) & 0xFFu, 60u + aw_rng % 40u); } else { tl = 0u; } }
          let aw_rng2 = hash(aw_rng ^ 0xaeed0002u);
          let aw_sc2 = hash(aw_rng2 ^ 0x5EA40002u);
          if (ac2_tr == WATER && (aw_rng2 % 100u) < 4u) { if ((aw_sc2 % 100u) < 60u) { tr = makeCell(STEAM, (aw_rng2 >> 8u) & 0xFFu, 60u + aw_rng2 % 40u); } else { tr = 0u; } }
          let aw_rng3 = hash(aw_rng2 ^ 0xaeed0003u);
          let aw_sc3 = hash(aw_rng3 ^ 0x5EA40003u);
          if (ac2_bl == WATER && (aw_rng3 % 100u) < 4u) { if ((aw_sc3 % 100u) < 60u) { bl = makeCell(STEAM, (aw_rng3 >> 8u) & 0xFFu, 60u + aw_rng3 % 40u); } else { bl = 0u; } }
          let aw_rng4 = hash(aw_rng3 ^ 0xaeed0004u);
          let aw_sc4 = hash(aw_rng4 ^ 0x5EA40004u);
          if (ac2_br == WATER && (aw_rng4 % 100u) < 4u) { if ((aw_sc4 % 100u) < 60u) { br = makeCell(STEAM, (aw_rng4 >> 8u) & 0xFFu, 60u + aw_rng4 % 40u); } else { br = 0u; } }
          // Acid loses potency from water contact (1 per water cell, ~3%/pass)
          let aw_cost_rng = hash(aw_rng4 ^ 0xaeed0005u);
          if ((aw_cost_rng % 100u) < 3u) {
            if (ac2_tl == ACID) { let p = getLifetime(tl); if (p > 1u) { tl = setLifetime(tl, p - 1u); } else { tl = 0u; } }
            if (ac2_tr == ACID) { let p = getLifetime(tr); if (p > 1u) { tr = setLifetime(tr, p - 1u); } else { tr = 0u; } }
            if (ac2_bl == ACID) { let p = getLifetime(bl); if (p > 1u) { bl = setLifetime(bl, p - 1u); } else { bl = 0u; } }
            if (ac2_br == ACID) { let p = getLifetime(br); if (p > 1u) { br = setLifetime(br, p - 1u); } else { br = 0u; } }
          }
        }

        // --- Acid dissolves solids/liquids: sand, stone, wood, glass, oil ---
        // Each dissolved cell → empty + chance of smoke. Acid loses potency.
        let ad_rng = hash(ac_rng ^ 0xd150001u);

        // Helper: count acid cells for potency cost distribution
        let acid_count = u32(ac2_tl == ACID) + u32(ac2_tr == ACID) + u32(ac2_bl == ACID) + u32(ac2_br == ACID);

        // Process each non-acid cell: check if acid dissolves it
        var dissolved = 0u; // track total potency cost this block
        var cost_per: u32;

        // --- Dissolve TL ---
        let d_rng1 = hash(ad_rng ^ 0xd1550001u);
        if (ac2_tl == SAND && (d_rng1 % 100u) < 5u) { tl = makeCell(SMOKE, (d_rng1 >> 8u) & 0xFFu, 30u + d_rng1 % 20u); dissolved += 3u; }
        else if (ac2_tl == STONE && (d_rng1 % 100u) < 2u) { tl = makeCell(SMOKE, (d_rng1 >> 8u) & 0xFFu, 30u + d_rng1 % 20u); dissolved += 5u; }
        else if (ac2_tl == WOOD && (d_rng1 % 100u) < 8u) { tl = makeCell(SMOKE, (d_rng1 >> 8u) & 0xFFu, 30u + d_rng1 % 20u); dissolved += 2u; }
        else if (ac2_tl == GLASS && (d_rng1 % 100u) < 1u) { tl = makeCell(SMOKE, (d_rng1 >> 8u) & 0xFFu, 30u + d_rng1 % 20u); dissolved += 8u; }
        else if (ac2_tl == OIL && (d_rng1 % 100u) < 10u) { tl = makeCell(SMOKE, (d_rng1 >> 8u) & 0xFFu, 30u + d_rng1 % 20u); dissolved += 2u; }
        else if (ac2_tl == GUNPOWDER && (d_rng1 % 100u) < 5u) { tl = makeCell(SMOKE, (d_rng1 >> 8u) & 0xFFu, 30u + d_rng1 % 20u); dissolved += 3u; }
        else if (ac2_tl == BOMB && (d_rng1 % 100u) < 3u) { tl = makeCell(SMOKE, (d_rng1 >> 8u) & 0xFFu, 30u + d_rng1 % 20u); dissolved += 5u; }

        // --- Dissolve TR ---
        let d_rng2 = hash(ad_rng ^ 0xd1550002u);
        if (ac2_tr == SAND && (d_rng2 % 100u) < 5u) { tr = makeCell(SMOKE, (d_rng2 >> 8u) & 0xFFu, 30u + d_rng2 % 20u); dissolved += 3u; }
        else if (ac2_tr == STONE && (d_rng2 % 100u) < 2u) { tr = makeCell(SMOKE, (d_rng2 >> 8u) & 0xFFu, 30u + d_rng2 % 20u); dissolved += 5u; }
        else if (ac2_tr == WOOD && (d_rng2 % 100u) < 8u) { tr = makeCell(SMOKE, (d_rng2 >> 8u) & 0xFFu, 30u + d_rng2 % 20u); dissolved += 2u; }
        else if (ac2_tr == GLASS && (d_rng2 % 100u) < 1u) { tr = makeCell(SMOKE, (d_rng2 >> 8u) & 0xFFu, 30u + d_rng2 % 20u); dissolved += 8u; }
        else if (ac2_tr == OIL && (d_rng2 % 100u) < 10u) { tr = makeCell(SMOKE, (d_rng2 >> 8u) & 0xFFu, 30u + d_rng2 % 20u); dissolved += 2u; }
        else if (ac2_tr == GUNPOWDER && (d_rng2 % 100u) < 5u) { tr = makeCell(SMOKE, (d_rng2 >> 8u) & 0xFFu, 30u + d_rng2 % 20u); dissolved += 3u; }
        else if (ac2_tr == BOMB && (d_rng2 % 100u) < 3u) { tr = makeCell(SMOKE, (d_rng2 >> 8u) & 0xFFu, 30u + d_rng2 % 20u); dissolved += 5u; }

        // --- Dissolve BL ---
        let d_rng3 = hash(ad_rng ^ 0xd1550003u);
        if (ac2_bl == SAND && (d_rng3 % 100u) < 5u) { bl = makeCell(SMOKE, (d_rng3 >> 8u) & 0xFFu, 30u + d_rng3 % 20u); dissolved += 3u; }
        else if (ac2_bl == STONE && (d_rng3 % 100u) < 2u) { bl = makeCell(SMOKE, (d_rng3 >> 8u) & 0xFFu, 30u + d_rng3 % 20u); dissolved += 5u; }
        else if (ac2_bl == WOOD && (d_rng3 % 100u) < 8u) { bl = makeCell(SMOKE, (d_rng3 >> 8u) & 0xFFu, 30u + d_rng3 % 20u); dissolved += 2u; }
        else if (ac2_bl == GLASS && (d_rng3 % 100u) < 1u) { bl = makeCell(SMOKE, (d_rng3 >> 8u) & 0xFFu, 30u + d_rng3 % 20u); dissolved += 8u; }
        else if (ac2_bl == OIL && (d_rng3 % 100u) < 10u) { bl = makeCell(SMOKE, (d_rng3 >> 8u) & 0xFFu, 30u + d_rng3 % 20u); dissolved += 2u; }
        else if (ac2_bl == GUNPOWDER && (d_rng3 % 100u) < 5u) { bl = makeCell(SMOKE, (d_rng3 >> 8u) & 0xFFu, 30u + d_rng3 % 20u); dissolved += 3u; }
        else if (ac2_bl == BOMB && (d_rng3 % 100u) < 3u) { bl = makeCell(SMOKE, (d_rng3 >> 8u) & 0xFFu, 30u + d_rng3 % 20u); dissolved += 5u; }

        // --- Dissolve BR ---
        let d_rng4 = hash(ad_rng ^ 0xd1550004u);
        if (ac2_br == SAND && (d_rng4 % 100u) < 5u) { br = makeCell(SMOKE, (d_rng4 >> 8u) & 0xFFu, 30u + d_rng4 % 20u); dissolved += 3u; }
        else if (ac2_br == STONE && (d_rng4 % 100u) < 2u) { br = makeCell(SMOKE, (d_rng4 >> 8u) & 0xFFu, 30u + d_rng4 % 20u); dissolved += 5u; }
        else if (ac2_br == WOOD && (d_rng4 % 100u) < 8u) { br = makeCell(SMOKE, (d_rng4 >> 8u) & 0xFFu, 30u + d_rng4 % 20u); dissolved += 2u; }
        else if (ac2_br == GLASS && (d_rng4 % 100u) < 1u) { br = makeCell(SMOKE, (d_rng4 >> 8u) & 0xFFu, 30u + d_rng4 % 20u); dissolved += 8u; }
        else if (ac2_br == OIL && (d_rng4 % 100u) < 10u) { br = makeCell(SMOKE, (d_rng4 >> 8u) & 0xFFu, 30u + d_rng4 % 20u); dissolved += 2u; }
        else if (ac2_br == GUNPOWDER && (d_rng4 % 100u) < 5u) { br = makeCell(SMOKE, (d_rng4 >> 8u) & 0xFFu, 30u + d_rng4 % 20u); dissolved += 3u; }
        else if (ac2_br == BOMB && (d_rng4 % 100u) < 3u) { br = makeCell(SMOKE, (d_rng4 >> 8u) & 0xFFu, 30u + d_rng4 % 20u); dissolved += 5u; }

        // Deduct potency from acid cells (split cost across acid cells in block)
        if (dissolved > 0u && acid_count > 0u) {
          cost_per = dissolved / acid_count;
          if (cost_per == 0u) { cost_per = 1u; }
          if (ac2_tl == ACID) { let p = getLifetime(tl); if (p > cost_per) { tl = setLifetime(tl, p - cost_per); } else { tl = 0u; } }
          if (ac2_tr == ACID) { let p = getLifetime(tr); if (p > cost_per) { tr = setLifetime(tr, p - cost_per); } else { tr = 0u; } }
          if (ac2_bl == ACID) { let p = getLifetime(bl); if (p > cost_per) { bl = setLifetime(bl, p - cost_per); } else { bl = 0u; } }
          if (ac2_br == ACID) { let p = getLifetime(br); if (p > cost_per) { br = setLifetime(br, p - cost_per); } else { br = 0u; } }
        }
      }
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

      // --- Heat accumulation: fire/lava heats adjacent stone ---
      let fire_in_block = u32(h_tl == FIRE) + u32(h_tr == FIRE)
                        + u32(h_bl == FIRE) + u32(h_br == FIRE);
      let lava_in_block = u32(h_tl == LAVA) + u32(h_tr == LAVA)
                        + u32(h_bl == LAVA) + u32(h_br == LAVA);
      let heat_gain = fire_in_block * (2u + (heat_rng & 1u))   // fire: 2-3 per cell
                    + lava_in_block * (2u + (heat_rng & 1u));   // lava: 2-3 per cell (persistent, not hotter)

      if (h_tl == STONE && (fire_in_block > 0u || lava_in_block > 0u)) {
        let h = min(getLifetime(tl) + heat_gain, 255u);
        tl = setLifetime(tl, h);
      }
      if (h_tr == STONE && (fire_in_block > 0u || lava_in_block > 0u)) {
        let h = min(getLifetime(tr) + heat_gain, 255u);
        tr = setLifetime(tr, h);
      }
      if (h_bl == STONE && (fire_in_block > 0u || lava_in_block > 0u)) {
        let h = min(getLifetime(bl) + heat_gain, 255u);
        bl = setLifetime(bl, h);
      }
      if (h_br == STONE && (fire_in_block > 0u || lava_in_block > 0u)) {
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

        // Hot stone (>150) ignites gunpowder (~1% per pass, 20x faster than wood)
        let gp_hrng = hash(fx_rng4 ^ 0xba0dba0du);
        if (hx_tl == GUNPOWDER && (gp_hrng % 100u) < 1u) {
          tl = makeCell(FIRE, (gp_hrng >> 8u) & 0xFFu, 120u + gp_hrng % 60u);
        }
        let gp_hrng2 = hash(gp_hrng ^ 0xba0dba0eu);
        if (hx_tr == GUNPOWDER && (gp_hrng2 % 100u) < 1u) {
          tr = makeCell(FIRE, (gp_hrng2 >> 8u) & 0xFFu, 120u + gp_hrng2 % 60u);
        }
        let gp_hrng3 = hash(gp_hrng2 ^ 0xba0dba0fu);
        if (hx_bl == GUNPOWDER && (gp_hrng3 % 100u) < 1u) {
          bl = makeCell(FIRE, (gp_hrng3 >> 8u) & 0xFFu, 120u + gp_hrng3 % 60u);
        }
        let gp_hrng4 = hash(gp_hrng3 ^ 0xba0dba00u);
        if (hx_br == GUNPOWDER && (gp_hrng4 % 100u) < 1u) {
          br = makeCell(FIRE, (gp_hrng4 >> 8u) & 0xFFu, 120u + gp_hrng4 % 60u);
        }

        // Hot stone (>150) detonates bomb → blast fire (lt 250)
        let bm_hrng = hash(gp_hrng4 ^ 0xb00bba0du);
        if (hx_tl == BOMB && (bm_hrng % 100u) < 2u) {
          tl = makeCell(FIRE, (bm_hrng >> 8u) & 0xFFu, 250u);
        }
        let bm_hrng2 = hash(bm_hrng ^ 0xb00bba0eu);
        if (hx_tr == BOMB && (bm_hrng2 % 100u) < 2u) {
          tr = makeCell(FIRE, (bm_hrng2 >> 8u) & 0xFFu, 250u);
        }
        let bm_hrng3 = hash(bm_hrng2 ^ 0xb00bba0fu);
        if (hx_bl == BOMB && (bm_hrng3 % 100u) < 2u) {
          bl = makeCell(FIRE, (bm_hrng3 >> 8u) & 0xFFu, 250u);
        }
        let bm_hrng4 = hash(bm_hrng3 ^ 0xb00bba00u);
        if (hx_br == BOMB && (bm_hrng4 % 100u) < 2u) {
          br = makeCell(FIRE, (bm_hrng4 >> 8u) & 0xFFu, 250u);
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

      // Hot stone (>100) boils water (~1% per pass, 60% → steam, 40% → empty)
      if (max_heat > 100u) {
        let bx_rng = hash(fx_rng ^ 0x5011BEE0u);
        let bx_sc1 = hash(bx_rng ^ 0x5EA40001u);
        if (hx_tl == WATER && (bx_rng % 100u) < 1u) {
          if ((bx_sc1 % 100u) < 60u) { tl = makeCell(STEAM, (bx_rng >> 8u) & 0xFFu, 120u + bx_rng % 80u); } else { tl = 0u; }
        }
        let bx_rng2 = hash(bx_rng ^ 0xB011BEE1u);
        let bx_sc2 = hash(bx_rng2 ^ 0x5EA40002u);
        if (hx_tr == WATER && (bx_rng2 % 100u) < 1u) {
          if ((bx_sc2 % 100u) < 60u) { tr = makeCell(STEAM, (bx_rng2 >> 8u) & 0xFFu, 120u + bx_rng2 % 80u); } else { tr = 0u; }
        }
        let bx_rng3 = hash(bx_rng2 ^ 0xB011BEE2u);
        let bx_sc3 = hash(bx_rng3 ^ 0x5EA40003u);
        if (hx_bl == WATER && (bx_rng3 % 100u) < 1u) {
          if ((bx_sc3 % 100u) < 60u) { bl = makeCell(STEAM, (bx_rng3 >> 8u) & 0xFFu, 120u + bx_rng3 % 80u); } else { bl = 0u; }
        }
        let bx_rng4 = hash(bx_rng3 ^ 0xB011BEE3u);
        let bx_sc4 = hash(bx_rng4 ^ 0x5EA40004u);
        if (hx_br == WATER && (bx_rng4 % 100u) < 1u) {
          if ((bx_sc4 % 100u) < 60u) { br = makeCell(STEAM, (bx_rng4 >> 8u) & 0xFFu, 120u + bx_rng4 % 80u); } else { br = 0u; }
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

    // Sand-liquid drag: gates ALL sand movement through water/oil/lava (vertical + diagonal).
    // Without this, sand bypasses vertical drag via the diagonal dispersion path.
    let sand_liquid_move = (rng1 % 100u) < 35u; // 35% chance to move through liquid
    let sw_l = (etl == SAND && (ebl == WATER || ebl == OIL || ebl == LAVA || ebl == ACID)) || ((etl == WATER || etl == OIL || etl == LAVA || etl == ACID) && ebl == SAND);
    let sw_r = (etr == SAND && (ebr == WATER || ebr == OIL || ebr == LAVA || ebr == ACID)) || ((etr == WATER || etr == OIL || etr == LAVA || etr == ACID) && ebr == SAND);

    // Lava viscosity drag: lava moves at ~50% speed (sluggish liquid)
    let lava_move = (rng1 % 100u) < 50u;
    let lava_l = etl == LAVA || ebl == LAVA;
    let lava_r = etr == LAVA || ebr == LAVA;

    // Gas rise drag: fire/steam/smoke rise slowly, not every pass.
    // Without this, gases teleport upward at full simulation speed.
    let gas_rng = (rng1 >> 6u) % 100u;
    let fire_l = (etl == FIRE && ebl == EMPTY) || (etl == EMPTY && ebl == FIRE);
    let fire_r = (etr == FIRE && ebr == EMPTY) || (etr == EMPTY && ebr == FIRE);
    let steam_l = (etl == STEAM && ebl == EMPTY) || (etl == EMPTY && ebl == STEAM);
    let steam_r = (etr == STEAM && ebr == EMPTY) || (etr == EMPTY && ebr == STEAM);
    let smoke_l = (etl == SMOKE && ebl == EMPTY) || (etl == EMPTY && ebl == SMOKE);
    let smoke_r = (etr == SMOKE && ebr == EMPTY) || (etr == EMPTY && ebr == SMOKE);
    // Young fire (freshly spawned, lifetime > 90 out of 60-119) drifts down
    // briefly before rising. Block rise and sometimes push downward.
    let young_fire_rng_l = hash(rng1 ^ 0xF12E0001u);
    let young_fire_rng_r = hash(rng1 ^ 0xF12E0002u);
    let fire_lt_l = max(getLifetime(tl) * u32(etl == FIRE), getLifetime(bl) * u32(ebl == FIRE));
    let fire_lt_r = max(getLifetime(tr) * u32(etr == FIRE), getLifetime(br) * u32(ebr == FIRE));
    let young_l = fire_l && fire_lt_l > 100u;
    let young_r = fire_r && fire_lt_r > 100u;
    // Young fire: 20% sink, 40% stall, 40% rise. Mature fire: normal 20% rise.
    let yf_chance_l = young_fire_rng_l % 100u;
    let yf_chance_r = young_fire_rng_r % 100u;
    var fire_can_move_l = gas_rng < 20u;
    var fire_can_move_r = gas_rng < 20u;
    var fire_sink_l = false;
    var fire_sink_r = false;
    if (young_l) { fire_can_move_l = yf_chance_l >= 60u; fire_sink_l = yf_chance_l < 20u; }
    if (young_r) { fire_can_move_r = yf_chance_r >= 60u; fire_sink_r = yf_chance_r < 20u; }
    let steam_can_move = gas_rng < 35u; // 35% → ~4-5 rises/frame
    let smoke_can_move = gas_rng < 30u; // 30% → ~3-4 rises/frame
    let gas_ok_l = (!fire_l || fire_can_move_l) && (!steam_l || steam_can_move) && (!smoke_l || smoke_can_move);
    let gas_ok_r = (!fire_r || fire_can_move_r) && (!steam_r || steam_can_move) && (!smoke_r || smoke_can_move);

    let drop_l = can_drop_l && (!sw_l || sand_liquid_move) && gas_ok_l && (!lava_l || lava_move);
    let drop_r = can_drop_r && (!sw_r || sand_liquid_move) && gas_ok_r && (!lava_r || lava_move);

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
      let tl_liquid_disp = etl == SAND && (ebr == WATER || ebr == OIL || ebr == LAVA || ebr == ACID) && d_tl > d_br && sand_disp && sand_liquid_move;
      let tr_liquid_disp = etr == SAND && (ebl == WATER || ebl == OIL || ebl == LAVA || ebl == ACID) && d_tr > d_bl && sand_disp && sand_liquid_move;

      // Gate standard diagonal slides into liquid by the same drag
      let tl_sand_liquid = etl == SAND && (ebr == WATER || ebr == OIL || ebr == LAVA || ebr == ACID);
      let tr_sand_liquid = etr == SAND && (ebl == WATER || ebl == OIL || ebl == LAVA || ebl == ACID);
      let tl_slide_raw = (tl_slide_base && (etl != WATER || (d_tr < d_tl && water_diag))) || tl_liquid_disp;
      let tr_slide_raw = (tr_slide_base && (etr != WATER || (d_tl < d_tr && water_diag))) || tr_liquid_disp;
      let tl_lava_slide = etl == LAVA;
      let tr_lava_slide = etr == LAVA;
      let tl_slide = tl_slide_raw && (!tl_sand_liquid || sand_liquid_move) && (!tl_lava_slide || lava_move);
      let tr_slide = tr_slide_raw && (!tr_sand_liquid || sand_liquid_move) && (!tr_lava_slide || lava_move);

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

    // Young fire sinking: push freshly spawned fire downward briefly.
    // Only when fire is on top and empty is below (fire hasn't risen yet).
    if (fire_sink_l && getElement(tl) == FIRE && getElement(bl) == EMPTY) {
      let tmp = tl; tl = bl; bl = tmp;
    }
    if (fire_sink_r && getElement(tr) == FIRE && getElement(br) == EMPTY) {
      let tmp = tr; tr = br; br = tmp;
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

    // Bottom row: water + empty → swap if top row fully occupied
    if ((w_bl == WATER && w_br == EMPTY) || (w_br == WATER && w_bl == EMPTY)) {
      if (w_tl != EMPTY && w_tr != EMPTY) {
        let tmp = bl; bl = br; br = tmp;
      }
    }

    // Top row: water + empty → swap if bottom row fully occupied
    if ((w_tl == WATER && w_tr == EMPTY) || (w_tr == WATER && w_tl == EMPTY)) {
      if (w_bl != EMPTY && w_br != EMPTY) {
        let tmp = tl; tl = tr; tr = tmp;
      }
    }

    // Water displaces oil laterally at ~12.5%/pass — fast enough to level
    // visibly but slow enough to not spray like a sprinkler on contact.
    {
      let wo_tl = getElement(tl);
      let wo_tr = getElement(tr);
      let wo_bl = getElement(bl);
      let wo_br = getElement(br);
      let wo_rng = hash(rng0 ^ 0xA01DF1CEu);
      let wo_spread = (wo_rng % 100u) < 40u; // ~40%

      if (wo_spread) {
        if ((wo_bl == WATER && wo_br == OIL) || (wo_br == WATER && wo_bl == OIL)) {
          if (wo_tl != EMPTY && wo_tr != EMPTY) {
            let tmp = bl; bl = br; br = tmp;
          }
        }
        if ((wo_tl == WATER && wo_tr == OIL) || (wo_tr == WATER && wo_tl == OIL)) {
          if (wo_bl != EMPTY && wo_br != EMPTY) {
            let tmp = tl; tl = tr; tr = tmp;
          }
        }
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

    // Lava lateral spread: viscous liquid, gated at ~30% for sluggish flow.
    {
      let la_tl = getElement(tl);
      let la_tr = getElement(tr);
      let la_bl = getElement(bl);
      let la_br = getElement(br);
      let lava_spread_rng = hash(rng0 ^ 0x1a0a0001u);
      let lava_spread = (lava_spread_rng % 100u) < 30u; // ~30%

      if (lava_spread) {
        // Bottom row: one lava + one empty → swap if top row fully occupied
        if ((la_bl == LAVA && la_br == EMPTY) || (la_br == LAVA && la_bl == EMPTY)) {
          if (la_tl != EMPTY && la_tr != EMPTY) {
            let tmp = bl; bl = br; br = tmp;
          }
        }

        // Top row: one lava + one empty → swap if bottom row fully occupied
        if ((la_tl == LAVA && la_tr == EMPTY) || (la_tr == LAVA && la_tl == EMPTY)) {
          if (la_bl != EMPTY && la_br != EMPTY) {
            let tmp = tl; tl = tr; tr = tmp;
          }
        }
      }
    }

    // Acid lateral spread: same diving-beet rules as water (no viscosity drag).
    {
      let ad_tl = getElement(tl);
      let ad_tr = getElement(tr);
      let ad_bl = getElement(bl);
      let ad_br = getElement(br);

      // Bottom row: one acid + one empty → swap if top row fully occupied
      if ((ad_bl == ACID && ad_br == EMPTY) || (ad_br == ACID && ad_bl == EMPTY)) {
        if (ad_tl != EMPTY && ad_tr != EMPTY) {
          let tmp = bl; bl = br; br = tmp;
        }
      }

      // Top row: one acid + one empty → swap if bottom row fully occupied
      if ((ad_tl == ACID && ad_tr == EMPTY) || (ad_tr == ACID && ad_tl == EMPTY)) {
        if (ad_bl != EMPTY && ad_br != EMPTY) {
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

    // Fire lateral spread: chaotic flicker. Higher free spread than steam/smoke
    // to give fire a dancing, turbulent look rather than a straight column.
    {
      let fi_tl = getElement(tl);
      let fi_tr = getElement(tr);
      let fi_bl = getElement(bl);
      let fi_br = getElement(br);
      let fire_spread_rng = hash(rng0 ^ 0xf12eeeeeu);
      let fire_free_spread = (fire_spread_rng % 100u) < 3u; // ~3%

      // Bottom row: one fire + one empty
      if ((fi_bl == FIRE && fi_br == EMPTY) || (fi_br == FIRE && fi_bl == EMPTY)) {
        if ((fi_tl != EMPTY && fi_tr != EMPTY) || fire_free_spread) {
          let tmp = bl; bl = br; br = tmp;
        }
      }

      // Top row: one fire + one empty
      if ((fi_tl == FIRE && fi_tr == EMPTY) || (fi_tr == FIRE && fi_tl == EMPTY)) {
        if ((fi_bl != EMPTY && fi_br != EMPTY) || fire_free_spread) {
          let tmp = tl; tl = tr; tr = tmp;
        }
      }
    }

    // Submerged sand smoothing: sand under liquid (water/oil) spreads laterally,
    // reducing sharp peaks into gentle curves (lower angle of repose in liquid).
    // Only fires when sand is at the pile surface (liquid directly above it).
    {
      let s_tl = getElement(tl);
      let s_tr = getElement(tr);
      let s_bl = getElement(bl);
      let s_br = getElement(br);
      let smooth_rng = hash(rng0 ^ 0x12345678u);
      let should_smooth = (smooth_rng & 31u) == 0u; // ~3% per pass
      if (should_smooth) {
        let s_tl_liq = s_tl == WATER || s_tl == OIL || s_tl == LAVA || s_tl == ACID;
        let s_tr_liq = s_tr == WATER || s_tr == OIL || s_tr == LAVA || s_tr == ACID;
        let s_bl_liq = s_bl == WATER || s_bl == OIL || s_bl == LAVA || s_bl == ACID;
        let s_br_liq = s_br == WATER || s_br == OIL || s_br == LAVA || s_br == ACID;
        if (s_bl == SAND && s_br_liq && s_tl_liq) {
          let tmp = bl; bl = br; br = tmp;
        } else if (s_br == SAND && s_bl_liq && s_tr_liq) {
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
