# Powder-Sim Architecture

## Overview

GPU-accelerated falling sand simulation using WebGPU compute shaders and Margolus neighborhood block cellular automata.

## Pipeline

```
User Input (pointer events) → CPU staging → GPU Compute (4 Margolus passes/frame) → GPU Render (fullscreen quad) → Canvas
```

## Cell Encoding

Each cell is a `Uint32`:
- Bits 0-7: Element type (supports 256 types)
- Bits 8-15: Color variation (per-particle visual diversity)
- Bits 16-31: Reserved for metadata (future: temperature, lifetime)

## Margolus Neighborhood

The Margolus CA divides the grid into non-overlapping 2x2 blocks. Each frame runs 4 compute passes with different block offsets:

1. Offset (0,0) — aligned blocks
2. Offset (1,0) — shifted right by 1
3. Offset (0,1) — shifted down by 1
4. Offset (1,1) — shifted diagonally

This Z-pattern ensures every cell participates in multiple block contexts per frame, eliminating directional bias.

### Why Margolus?

Standard cellular automata on GPUs have race conditions: multiple threads may read/write the same cell. Margolus blocks are non-overlapping within each pass, so each thread owns its 2x2 block exclusively. No atomics or synchronization needed.

## Ping-Pong Buffers

Two storage buffers alternate as source and destination:
- Pass N reads from buffer A, writes to buffer B
- Pass N+1 reads from buffer B, writes to buffer A

This avoids read-write hazards within a single pass.

## Density-Based Physics

Each element has a density value. Within a 2x2 block, denser elements swap downward with lighter ones:
- EMPTY: 0 (void)
- WATER: 5 (medium, flows)
- SAND: 10 (heavy, falls)
- STONE: 255 (immovable)

This naturally handles sand sinking through water, etc.

## Element System

To add a new element:
1. Add constant to `simulation.wgsl` and type to `src/types/index.ts`
2. Add density value in `getDensity()` function
3. Add color mapping in `render.wgsl`
4. Add interaction rules if any (e.g., Water + Fire → Steam)
5. Add UI entry in `Toolbar.tsx`

No structural changes needed — the architecture supports up to 256 element types.
