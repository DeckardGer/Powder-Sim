# Progress

## Browser Compatibility

| Browser | Version | WebGPU Support | Status |
|---------|---------|---------------|--------|
| Chrome | 113+ | Full | Primary target |
| Edge | 113+ | Full | Supported |
| Safari | 18+ | Full | Supported |
| Firefox | Nightly | Behind flag | Experimental |

## Performance Notes

- **Target**: 60 FPS at 512x512 grid
- **GPU workload**: 4 compute passes + 1 render pass per frame
- **Buffer size**: 512 * 512 * 4 = 1 MB per ping-pong buffer (2 MB total)
- **Workgroups**: (512/2/16) * (512/2/16) = 16 * 16 = 256 workgroups per pass

## Milestone Tracking

- [x] M1: Project Setup — Vite + React + TypeScript + Tailwind + shadcn
- [x] M2: WebGPU Foundation — adapter init, hook, fallback
- [x] M3: Simulation Engine — Margolus CA compute shader
- [x] M4: Render Pipeline — fullscreen quad shader, renderer, canvas
- [x] M5: User Input — Bresenham brush, pointer capture
- [x] M6: Title Screen — brutalist design, navigation
- [x] M7: UI Polish — status bar, toolbar, keyboard shortcuts
- [x] M8: Testing & Optimization — error boundary, edge cases, docs

## Known Limitations

- Particle count tracking not yet implemented (requires GPU readback or atomic counter)
- Water/Stone elements defined but physics rules are Sand-focused in MVP
- No save/load functionality
- No mobile-optimized touch controls beyond basic pointer events
