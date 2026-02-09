# CLAUDE.md

## Project Overview

WebGPU falling sand simulator. Margolus neighborhood cellular automata running on GPU compute shaders, React frontend.

## Commands

- `pnpm dev` — start dev server
- `pnpm build` — type-check (`tsc -b`) then bundle (`vite build`)
- `pnpm lint` — ESLint
- `npx tsc --noEmit` — type-check only (fast, use after edits)
- `npx prettier --write "src/**/*.{ts,tsx,css}"` — format

## Code Conventions

- **No enums** — `erasableSyntaxOnly` is enabled. Use `as const` objects instead.
- **No unused locals** — `noUnusedLocals` is strict. Remove unused vars immediately or the build fails.
- **Path alias** — `@/*` maps to `./src/*` (configured in tsconfig + vite.config).
- **WGSL imports** — use `?raw` suffix: `import shader from "./foo.wgsl?raw"`. Type declared in `src/vite-env.d.ts`.
- **Tailwind v4** — uses `@tailwindcss/vite` plugin, no postcss.config. Theme in `src/index.css`.
- **shadcn/ui** — `new-york` style, components in `src/components/ui/`. Config in `components.json`.
- **Dark-only theme** — all colors in `:root` CSS vars (OKLCH). Zero border-radius everywhere.

## Architecture

### Simulation Pipeline (per frame)

```
writeBuffer (uniforms x24) -> commandEncoder -> conditional write pass -> 24 compute passes -> 1 render pass -> submit
```

- Single command encoder for all compute + render (zero CPU round-trips)
- Ping-pong: passes alternate buf[0]->buf[1] and buf[1]->buf[0]
- 24 passes = always even, so result always in buf[0]
- First 12 passes: full simulation (gravity + lateral spread)
- Last 12 passes: lateral_only=1 (water spread + smoothing + erosion, gravity skipped)

### Key Files

- `src/simulation/simulation.ts` — PowderSimulation class (buffers, passes, readback, conditional writes)
- `src/simulation/renderer.ts` — SimulationRenderer (fullscreen triangle render)
- `src/simulation/gpu.ts` — adapter/device init, canvas config
- `src/simulation/shaders/simulation.wgsl` — Margolus CA compute shader (main physics)
- `src/simulation/shaders/render.wgsl` — cell-to-color fragment shader
- `src/simulation/shaders/conditional_write.wgsl` — GPU-side brush write (only writes to empty cells)
- `src/hooks/useWebGPU.ts` — GPU state hook (loading/error/ready)
- `src/hooks/useSimulation.ts` — brush input, Bresenham, hold-to-draw interval
- `src/types/index.ts` — ElementType (as const), SimulationConfig, BrushConfig, AppScreen

### Cell Encoding (u32)

- Bits 0-7: element type (Empty=0, Sand=1, Water=2, Stone=3, Fire=4, Steam=5, Wood=6, Glass=7, Smoke=8, Oil=9, Lava=10)
- Bits 8-15: per-particle color variation
- Bits 16-23: lifetime (fire/steam/smoke) or heat level (stone/lava)
- Bits 24-31: reserved

### Elements & Density

Fire=0, Smoke=1, Steam=1, Empty=2, Oil=4, Water=5, Lava=7, Wood=9, Sand=10, Glass=200, Stone=255. Denser elements sink via pairwise density comparison in 2x2 Margolus blocks. Wood, Glass, and Stone are immovable solids. Lava is a viscous movable liquid (50% gravity drag, 30% lateral spread).

## Critical Bugs (don't regress)

1. **Per-pass uniform buffers** — `queue.writeBuffer` is immediate CPU-side. A single shared uniform buffer gets overwritten by the last pass before GPU executes. Each of the 24 passes MUST have its own uniform buffer + bind group.

2. **Banding lines** — fixed Margolus offset order + deterministic movement = visible horizontal lines. Fix: shuffle pass order per frame + 25% probabilistic skip per block.

3. **CPU particle tracking drifts** — a Set tracking write positions drifts because the GPU moves particles. Use GPU readback (staging buffer + mapAsync) instead.

4. **Edge particle loss** — when Margolus offset is 1, cells at x=0 or y=0 aren't part of any 2x2 block and never get written to output. Fix: edge threads explicitly copy orphaned cells through.

5. **Conditional write pending flag** — bit 31 of the pending write buffer marks "write pending". The shader strips it before applying. Value 0 with bit 31 set = eraser (always overwrites). Value != 0 with bit 31 = particle (only writes to empty cells).

## Simulation Physics

### Phase 1: Gravity (first 12 passes, gated by `lateral_only == 0` and `should_move`)

- **Vertical drop**: per-column density comparison, swap if top is heavier
- **Sand-liquid drag**: `sand_liquid_move` (35% chance) gates ALL sand movement through water/oil/lava (vertical + diagonal)
- **Diagonal slide**: sand always eligible; water only with adjacent-clear check + 25% probability
- **Sand dispersion in water**: sand can slide diagonally into water even without resting on something (50% when drag allows)

### Phase 2: Lateral (all 24 passes, not gated by `should_move`)

- **Water lateral spread**: diving-beet/falling-turnip rules. Row swaps water+empty if other row is fully occupied.
- **Underwater sand smoothing**: submerged sand (water above) slides laterally at ~3%/pass. Flattens peaks into curves.
- **Water erosion**: flowing water lifts adjacent sand upward at ~0.2%/pass.

### Alchemy (runs between aging and gravity)

- **Fire + Water**: fire survives (loses 12-24 lifetime), water 60% evaporates / 40% → steam, empty → burst steam
- **Fire + Wood**: wood ignites at ~15%/pass → becomes fire (lifetime 80-139). Fire unaffected. Chain reaction.
- **Fire + Sand → Glass**: sand melts at ~2%/pass. Fire loses 7 lifetime per sand in block.
- **Lava + Water**: water evaporates ~50%/pass → steam. Lava loses 3-4 heat per water cell/pass. Gravity sinks lava through water (no instant solidification). Lava solidifies to stone when heat reaches 0.
- **Lava + Sand → Glass**: ~4%/pass. Lava loses 3 heat per sand in block.
- **Lava + Wood**: wood ignites at ~8%/pass → fire. Much faster than fire+wood.
- **Lava + Oil**: oil ignites at ~20%/pass → fire.
- **Lava cooling**: ~0.6%/pass passive heat decay. Spawns at heat 180-239, solidifies to stone at 0 (~23 sec).
- **Stone heat**: fire/lava adds 2-3 heat/pass. Decays ~0.8%/pass. Conducts between adjacent stone (1 unit/pass).
  - heat > 100: boils water → steam (1%/pass)
  - heat > 150: ignites wood → fire (0.05%/pass)
  - heat > 200: melts sand → glass (0.5%/pass)

## WebGPU References

- [WebGPU spec](https://www.w3.org/TR/webgpu/)
- [WGSL spec](https://www.w3.org/TR/WGSL/)
- [WebGPU best practices](https://toji.dev/webgpu-best-practices/)
- [Margolus neighborhood (Wikipedia)](https://en.wikipedia.org/wiki/Block_cellular_automaton)
- [Diving Beet (Margolus CA reference)](https://github.com/Athas/diving-beet)
- [Falling Turnip (Margolus CA reference)](https://github.com/tranma/falling-turnip)
