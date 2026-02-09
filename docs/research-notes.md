# Research Notes

## Powder Simulation Techniques

### Cellular Automata Approaches

1. **Standard CA**: Each cell checks neighbors and updates. Simple but has GPU race conditions — multiple threads may read/write same cell simultaneously.

2. **Margolus Neighborhood**: Grid divided into non-overlapping 2x2 blocks. Each block is processed independently. Multiple offset passes per frame cover all cell relationships. Chosen for this project — best GPU parallelism without atomics.

3. **Chunk-based**: Grid divided into larger chunks processed sequentially. Good for CPU, poor GPU utilization.

### Key Findings

- **Power-of-2 grid sizes** (512, 1024) align well with GPU workgroup sizes and prevent wasted threads at boundaries.

- **16x16 workgroups** are optimal for most GPUs. Larger workgroups waste registers on simple compute shaders.

- **Hash-based RNG** (multiply-shift) is faster than proper PRNGs on GPU and provides sufficient randomness for visual simulation. No need for Mersenne Twister quality.

- **Single command encoder** for compute + render eliminates CPU round-trips. Compute and render are recorded into one command buffer and submitted atomically.

- **Fullscreen triangle** (3 vertices, no vertex buffer) is more efficient than a fullscreen quad (4 vertices + index buffer). The triangle overshoots the viewport and gets clipped by the GPU for free.

### Density-Based vs Rule-Based

Rule-based systems (explicit "if sand above water, swap") become combinatorially explosive with many elements. Density-based systems ("heavier sinks, lighter rises") scale linearly — each new element just needs a density value.

### Color Variation

Per-particle color stored in bits 8-15 gives 256 shades per element type. This creates natural-looking material variety without additional simulation cost.
