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
  private uniformBuffer: GPUBuffer;

  // Pre-created bind groups for both ping-pong directions
  private bindGroups: [GPUBindGroup, GPUBindGroup][];

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

    // Uniform buffer for params struct (5 x u32 = 20 bytes, padded to 32)
    this.uniformBuffer = device.createBuffer({
      size: 32,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });

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

    // Pre-create bind groups for both ping-pong directions
    // For each direction, we need bind groups for each Margolus offset
    const bindGroupLayout = this.pipeline.getBindGroupLayout(0);

    this.bindGroups = [
      // Direction 0: buffer[0] → buffer[1]
      this.createBindGroupPair(bindGroupLayout, 0, 1),
      // Direction 1: buffer[1] → buffer[0]
      this.createBindGroupPair(bindGroupLayout, 1, 0),
    ];

    // Initialize buffers to zero (empty cells)
    const zeros = new Uint32Array(this.cellCount);
    device.queue.writeBuffer(this.buffers[0], 0, zeros);
    device.queue.writeBuffer(this.buffers[1], 0, zeros);
  }

  private createBindGroupPair(
    layout: GPUBindGroupLayout,
    srcIdx: number,
    dstIdx: number
  ): [GPUBindGroup, GPUBindGroup] {
    // We only need one bind group per direction since the uniform buffer
    // is shared and updated per-pass
    const bg = this.device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: this.buffers[srcIdx] } },
        { binding: 1, resource: { buffer: this.buffers[dstIdx] } },
        { binding: 2, resource: { buffer: this.uniformBuffer } },
      ],
    });
    return [bg, bg]; // Same bind group reused (uniform is updated via writeBuffer)
  }

  /** Run 4 Margolus passes within a single command encoder */
  step(encoder: GPUCommandEncoder): void {
    const workgroupsX = Math.ceil(
      this.config.width / 2 / this.config.workgroupSize
    );
    const workgroupsY = Math.ceil(
      this.config.height / 2 / this.config.workgroupSize
    );

    for (let i = 0; i < 4; i++) {
      const [ox, oy] = MARGOLUS_OFFSETS[i];
      const direction = (this.frameCount * 4 + i) % 2;

      // Update uniform buffer with current pass params
      const params = new Uint32Array([
        this.config.width,
        this.config.height,
        ox,
        oy,
        this.frameCount * 4 + i,
      ]);
      this.device.queue.writeBuffer(this.uniformBuffer, 0, params);

      const pass = encoder.beginComputePass();
      pass.setPipeline(this.pipeline);
      pass.setBindGroup(0, this.bindGroups[direction][0]);
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
    this.uniformBuffer.destroy();
  }
}
