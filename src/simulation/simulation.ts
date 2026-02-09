import type { SimulationConfig } from "@/types";
import { DEFAULT_CONFIG } from "@/types";
import simulationShaderSource from "./shaders/simulation.wgsl?raw";

// Margolus offsets: 4 passes to cover all 2x2 block positions
const MARGOLUS_OFFSETS: [number, number][] = [
  [0, 0],
  [1, 0],
  [0, 1],
  [1, 1],
];

export class PowderSimulation {
  private device: GPUDevice;
  private config: SimulationConfig;
  private pipeline: GPUComputePipeline;

  // Ping-pong storage buffers
  private buffers: [GPUBuffer, GPUBuffer];

  // 4 uniform buffers — one per Margolus offset pass
  private uniformBuffers: GPUBuffer[];

  // Bind groups: [passIndex][direction] — 4 passes × 2 ping-pong directions
  private passBindGroups: [GPUBindGroup, GPUBindGroup][];

  private frameCount = 0;
  private cellCount: number;

  constructor(device: GPUDevice, config: SimulationConfig = DEFAULT_CONFIG) {
    this.device = device;
    this.config = config;
    this.cellCount = config.width * config.height;

    const bufferSize = this.cellCount * 4; // Uint32 per cell

    // Create ping-pong storage buffers
    this.buffers = [
      device.createBuffer({
        size: bufferSize,
        usage:
          GPUBufferUsage.STORAGE |
          GPUBufferUsage.COPY_DST |
          GPUBufferUsage.COPY_SRC,
      }),
      device.createBuffer({
        size: bufferSize,
        usage:
          GPUBufferUsage.STORAGE |
          GPUBufferUsage.COPY_DST |
          GPUBufferUsage.COPY_SRC,
      }),
    ];

    // Create 4 uniform buffers (one per Margolus pass)
    // Each holds: width, height, offset_x, offset_y, frame (5 × u32 = 20 bytes, padded to 32)
    this.uniformBuffers = [];
    for (let i = 0; i < 4; i++) {
      this.uniformBuffers.push(
        device.createBuffer({
          size: 32,
          usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
        })
      );
    }

    // Create compute pipeline
    const shaderModule = device.createShaderModule({
      code: simulationShaderSource,
    });

    this.pipeline = device.createComputePipeline({
      layout: "auto",
      compute: {
        module: shaderModule,
        entryPoint: "main",
        constants: {
          WORKGROUP_SIZE: config.workgroupSize,
        },
      },
    });

    // Create bind groups: for each of 4 passes, create 2 (one per ping-pong direction)
    const bindGroupLayout = this.pipeline.getBindGroupLayout(0);

    this.passBindGroups = [];
    for (let pass = 0; pass < 4; pass++) {
      const bg0to1 = device.createBindGroup({
        layout: bindGroupLayout,
        entries: [
          { binding: 0, resource: { buffer: this.buffers[0] } },
          { binding: 1, resource: { buffer: this.buffers[1] } },
          { binding: 2, resource: { buffer: this.uniformBuffers[pass] } },
        ],
      });
      const bg1to0 = device.createBindGroup({
        layout: bindGroupLayout,
        entries: [
          { binding: 0, resource: { buffer: this.buffers[1] } },
          { binding: 1, resource: { buffer: this.buffers[0] } },
          { binding: 2, resource: { buffer: this.uniformBuffers[pass] } },
        ],
      });
      this.passBindGroups.push([bg0to1, bg1to0]);
    }

    // Initialize buffers to zero (empty cells)
    const zeros = new Uint32Array(this.cellCount);
    device.queue.writeBuffer(this.buffers[0], 0, zeros);
    device.queue.writeBuffer(this.buffers[1], 0, zeros);
  }

  /** Run 4 Margolus passes within a single command encoder */
  step(encoder: GPUCommandEncoder): void {
    const workgroupsX = Math.ceil(
      this.config.width / 2 / this.config.workgroupSize
    );
    const workgroupsY = Math.ceil(
      this.config.height / 2 / this.config.workgroupSize
    );

    // Write all 4 uniform buffers BEFORE recording compute passes.
    // Each has its own fixed offset but the frame counter varies.
    for (let i = 0; i < 4; i++) {
      const [ox, oy] = MARGOLUS_OFFSETS[i];
      const params = new Uint32Array([
        this.config.width,
        this.config.height,
        ox,
        oy,
        this.frameCount * 4 + i,
      ]);
      this.device.queue.writeBuffer(this.uniformBuffers[i], 0, params);
    }

    // Record 4 compute passes — each reads its own uniform buffer via its bind group
    for (let i = 0; i < 4; i++) {
      // Ping-pong direction: pass 0 reads buf0→buf1, pass 1 reads buf1→buf0, etc.
      const direction = (this.frameCount * 4 + i) % 2;

      const pass = encoder.beginComputePass();
      pass.setPipeline(this.pipeline);
      pass.setBindGroup(0, this.passBindGroups[i][direction]);
      pass.dispatchWorkgroups(workgroupsX, workgroupsY);
      pass.end();
    }

    this.frameCount++;
  }

  /** Write cells from CPU to GPU (for brush input) */
  writeCells(cells: { x: number; y: number; value: number }[]): void {
    if (cells.length === 0) return;

    for (let i = 0; i < cells.length; i++) {
      const { x, y, value } = cells[i];
      if (x < 0 || x >= this.config.width || y < 0 || y >= this.config.height)
        continue;
      const offset = (y * this.config.width + x) * 4;
      // Write directly to both buffers to ensure the cell appears
      const cellData = new Uint32Array([value]);
      this.device.queue.writeBuffer(this.buffers[0], offset, cellData);
      this.device.queue.writeBuffer(this.buffers[1], offset, cellData);
    }
  }

  /** Clear all cells */
  clear(): void {
    const zeros = new Uint32Array(this.cellCount);
    this.device.queue.writeBuffer(this.buffers[0], 0, zeros);
    this.device.queue.writeBuffer(this.buffers[1], 0, zeros);
    this.frameCount = 0;
  }

  /** Get the current read buffer index (for rendering) */
  getCurrentBufferIndex(): number {
    // 4 passes per frame, always even total, result always in buf[0]
    return (this.frameCount * 4) % 2;
  }

  /** Get a specific ping-pong buffer by index */
  getBuffer(index: number): GPUBuffer {
    return this.buffers[index];
  }

  get width(): number {
    return this.config.width;
  }

  get height(): number {
    return this.config.height;
  }

  get frame(): number {
    return this.frameCount;
  }

  destroy(): void {
    this.buffers[0].destroy();
    this.buffers[1].destroy();
    for (const ub of this.uniformBuffers) {
      ub.destroy();
    }
  }
}
