# Powder-Sim

A WebGPU-accelerated falling sand simulator built with React and TypeScript. Uses Margolus neighborhood cellular automata running entirely on the GPU via compute shaders.

**Live demo:** https://powder-simulation.vercel.app/

## Features

- **GPU compute simulation** — 24 Margolus CA passes per frame on a 512x512 grid
- **Density-based physics** — sand, water, and stone interact through density comparisons
- **Sand-water interactions** — drag, diagonal dispersion, underwater smoothing, and erosion
- **Ping-pong double buffering** — two storage buffers alternate to avoid read-write hazards
- **Circular brush** — hold-to-draw at 30Hz with Bresenham line interpolation
- **Conditional writes** — GPU-side shader prevents overwriting existing particles
- **Async particle counting** — staging buffer readback without blocking the render loop

## Stack

- Vite 7 + React 19 + TypeScript 5.9
- Tailwind CSS v4 + shadcn/ui
- WebGPU compute shaders (WGSL)
- JetBrains Mono font

## Getting Started

```bash
pnpm install
pnpm dev
```

Requires a browser with WebGPU support (Chrome 113+, Edge 113+, Safari 18+, Firefox Nightly).

## Scripts

| Command | Description |
| --- | --- |
| `pnpm dev` | Start dev server |
| `pnpm build` | Type-check and build for production |
| `pnpm preview` | Preview production build |
| `pnpm lint` | Run ESLint |

## Architecture

```
User Input (Pointer Events)
  -> canvasToGrid() + Bresenham stamp (CPU)
  -> Pending cells written to GPU buffer
  -> Conditional write compute pass (only writes to empty cells)
  -> 12 gravity passes + 12 lateral passes (Margolus CA)
  -> Fullscreen triangle render pass (cell -> color)
  -> Canvas
```

### Key Files

| File | Purpose |
| --- | --- |
| `src/simulation/simulation.ts` | PowderSimulation class — buffers, compute passes, readback |
| `src/simulation/renderer.ts` | SimulationRenderer — fullscreen triangle render pipeline |
| `src/simulation/gpu.ts` | WebGPU adapter/device initialization |
| `src/simulation/shaders/simulation.wgsl` | Margolus CA compute shader |
| `src/simulation/shaders/render.wgsl` | Cell-to-color fragment shader |
| `src/simulation/shaders/conditional_write.wgsl` | Brush write pipeline |
| `src/hooks/useSimulation.ts` | Brush input, Bresenham drawing, hold-to-draw |
| `src/hooks/useWebGPU.ts` | GPU state management hook |
| `src/types/index.ts` | Element types, configs, interfaces |

### Simulation Engine

The simulation uses a **Margolus neighborhood** cellular automaton. The grid is divided into non-overlapping 2x2 blocks, and each GPU thread processes one block. Four possible block offsets are shuffled per sweep to eliminate directional bias.

**Cell encoding** (32-bit `u32`):
- Bits 0-7: element type (Empty=0, Sand=1, Water=2, Stone=3)
- Bits 8-15: per-particle color variation
- Bits 16-31: reserved

**Physics phases per frame:**
1. **Gravity** (12 passes) — vertical drops by density, diagonal slides, sand-water drag
2. **Lateral** (24 passes) — water leveling, underwater sand smoothing, erosion

## Controls

| Input | Action |
| --- | --- |
| Click / drag | Draw with selected element |
| Hold | Continuous stamping at 30Hz |
| `+` / `-` | Increase / decrease brush size |
| `C` | Clear the grid |
| `ESC` | Return to title screen |

## Browser Support

WebGPU is required. The app shows a fallback screen if WebGPU is unavailable.

| Browser | Minimum Version |
| --- | --- |
| Chrome | 113+ |
| Edge | 113+ |
| Safari | 18+ |
| Firefox | Nightly (behind flag) |
