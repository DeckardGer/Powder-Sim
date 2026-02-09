import type { SimulationConfig } from "@/types";
import { DEFAULT_CONFIG } from "@/types";
import simulationShaderSource from "./shaders/simulation.wgsl?raw";
import conditionalWriteShaderSource from "./shaders/conditional_write.wgsl?raw";

const MARGOLUS_OFFSETS: [number, number][] = [
  [0, 0],
  [1, 0],
  [0, 1],
  [1, 1],
];

const GRAVITY_PASSES = 12;
const LATERAL_PASSES = 12;
const PASSES_PER_FRAME = GRAVITY_PASSES + LATERAL_PASSES;

export class PowderSimulation {
  private device: GPUDevice;
  private config: SimulationConfig;
  private pipeline: GPUComputePipeline;

  private buffers: [GPUBuffer, GPUBuffer];
  private uniformBuffers: GPUBuffer[];
  private passBindGroups: [GPUBindGroup, GPUBindGroup][];

  // GPU readback for particle counting
  private stagingBuffer: GPUBuffer;
  private cachedParticleCount = 0;
  private readbackPending = false;

  // Conditional write (brush → GPU, only overwrites empty cells)
  private pendingWriteBuffer: GPUBuffer;
  private conditionalWritePipeline: GPUComputePipeline;
  private conditionalWriteBindGroup: GPUBindGroup;
  private hasPendingWrites = false;

  private frameCount = 0;
  private cellCount: number;

  constructor(device: GPUDevice, config: SimulationConfig = DEFAULT_CONFIG) {
    this.device = device;
    this.config = config;
    this.cellCount = config.width * config.height;

    const bufferSize = this.cellCount * 4;

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

    // Staging buffer for async GPU readback (particle counting)
    this.stagingBuffer = device.createBuffer({
      size: bufferSize,
      usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST,
    });

    // Pending write buffer for conditional brush writes
    this.pendingWriteBuffer = device.createBuffer({
      size: bufferSize,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.uniformBuffers = [];
    for (let i = 0; i < PASSES_PER_FRAME; i++) {
      this.uniformBuffers.push(
        device.createBuffer({
          size: 32,
          usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
        }),
      );
    }

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

    const bindGroupLayout = this.pipeline.getBindGroupLayout(0);

    this.passBindGroups = [];
    for (let pass = 0; pass < PASSES_PER_FRAME; pass++) {
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

    // Conditional write pipeline (applies brush to empty cells only)
    const conditionalWriteModule = device.createShaderModule({
      code: conditionalWriteShaderSource,
    });
    this.conditionalWritePipeline = device.createComputePipeline({
      layout: "auto",
      compute: {
        module: conditionalWriteModule,
        entryPoint: "main",
      },
    });
    this.conditionalWriteBindGroup = device.createBindGroup({
      layout: this.conditionalWritePipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.buffers[0] } },
        { binding: 1, resource: { buffer: this.pendingWriteBuffer } },
      ],
    });

    this.clear();
  }

  private hashU32(x: number): number {
    x = ((x >>> 0) ^ ((x >>> 0) >> 16)) * 0x45d9f3b;
    x = ((x >>> 0) ^ ((x >>> 0) >> 16)) * 0x45d9f3b;
    return x >>> 0;
  }

  step(encoder: GPUCommandEncoder): void {
    // Apply pending brush writes to buf0 before simulation
    if (this.hasPendingWrites) {
      const writePass = encoder.beginComputePass();
      writePass.setPipeline(this.conditionalWritePipeline);
      writePass.setBindGroup(0, this.conditionalWriteBindGroup);
      writePass.dispatchWorkgroups(Math.ceil(this.cellCount / 256));
      writePass.end();
      this.hasPendingWrites = false;
    }

    const workgroupsX = Math.ceil(
      this.config.width / 2 / this.config.workgroupSize,
    );
    const workgroupsY = Math.ceil(
      this.config.height / 2 / this.config.workgroupSize,
    );

    const passOffsets: number[] = [];
    const sweepCount = PASSES_PER_FRAME / 4;
    for (let sweep = 0; sweep < sweepCount; sweep++) {
      const order = [0, 1, 2, 3];
      let seed = this.hashU32(this.frameCount * 2 + sweep);
      for (let i = 3; i > 0; i--) {
        seed = this.hashU32(seed + i);
        const j = seed % (i + 1);
        const tmp = order[i];
        order[i] = order[j];
        order[j] = tmp;
      }
      passOffsets.push(...order);
    }

    for (let i = 0; i < PASSES_PER_FRAME; i++) {
      const [ox, oy] = MARGOLUS_OFFSETS[passOffsets[i]];
      const lateralOnly = i >= GRAVITY_PASSES ? 1 : 0;
      const params = new Uint32Array([
        this.config.width,
        this.config.height,
        ox,
        oy,
        this.frameCount * PASSES_PER_FRAME + i,
        lateralOnly,
      ]);
      this.device.queue.writeBuffer(this.uniformBuffers[i], 0, params);
    }

    for (let i = 0; i < PASSES_PER_FRAME; i++) {
      const direction = (this.frameCount * PASSES_PER_FRAME + i) % 2;

      const pass = encoder.beginComputePass();
      pass.setPipeline(this.pipeline);
      pass.setBindGroup(0, this.passBindGroups[i][direction]);
      pass.dispatchWorkgroups(workgroupsX, workgroupsY);
      pass.end();
    }

    this.frameCount++;
  }

  /** Initiate async GPU readback to count particles. Call ~once per second. */
  requestParticleCount(): void {
    if (this.readbackPending) return;
    this.readbackPending = true;

    const currentBuf = this.buffers[this.getCurrentBufferIndex()];
    const encoder = this.device.createCommandEncoder();
    encoder.copyBufferToBuffer(
      currentBuf,
      0,
      this.stagingBuffer,
      0,
      this.cellCount * 4,
    );
    this.device.queue.submit([encoder.finish()]);

    this.stagingBuffer
      .mapAsync(GPUMapMode.READ)
      .then(() => {
        const data = new Uint32Array(this.stagingBuffer.getMappedRange());
        let count = 0;
        for (let i = 0; i < data.length; i++) {
          if ((data[i] & 0xff) !== 0) count++;
        }
        this.cachedParticleCount = count;
        this.stagingBuffer.unmap();
        this.readbackPending = false;
      })
      .catch(() => {
        this.readbackPending = false;
      });
  }

  writeCells(cells: { x: number; y: number; value: number }[]): void {
    if (cells.length === 0) return;

    // Find bounding box to minimize the write region
    let minY = this.config.height;
    let maxY = 0;
    for (let i = 0; i < cells.length; i++) {
      const { x, y } = cells[i];
      if (x < 0 || x >= this.config.width || y < 0 || y >= this.config.height)
        continue;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    if (minY > maxY) return;

    // Build a contiguous typed array spanning the affected rows
    const rowSpan = maxY - minY + 1;
    const sliceLen = rowSpan * this.config.width;
    const slice = new Uint32Array(sliceLen);

    for (let i = 0; i < cells.length; i++) {
      const { x, y, value } = cells[i];
      if (x < 0 || x >= this.config.width || y < 0 || y >= this.config.height)
        continue;
      // Bit 31 = "write pending" flag; shader strips it before applying
      slice[(y - minY) * this.config.width + x] = value | 0x80000000;
    }

    const byteOffset = minY * this.config.width * 4;
    this.device.queue.writeBuffer(
      this.pendingWriteBuffer,
      byteOffset,
      slice,
    );
    this.hasPendingWrites = true;
  }

  clear(): void {
    const zeros = new Uint32Array(this.cellCount);
    this.device.queue.writeBuffer(this.buffers[0], 0, zeros);
    this.device.queue.writeBuffer(this.buffers[1], 0, zeros);
    this.device.queue.writeBuffer(this.pendingWriteBuffer, 0, zeros);
    this.hasPendingWrites = false;
    this.cachedParticleCount = 0;
    this.frameCount = 0;
  }

  get particleCount(): number {
    return this.cachedParticleCount;
  }

  getCurrentBufferIndex(): number {
    return (this.frameCount * PASSES_PER_FRAME) % 2;
  }

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
    this.stagingBuffer.destroy();
    this.pendingWriteBuffer.destroy();
    for (const ub of this.uniformBuffers) {
      ub.destroy();
    }
  }
}
