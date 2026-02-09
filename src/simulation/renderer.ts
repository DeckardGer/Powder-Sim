import renderShaderSource from "./shaders/render.wgsl?raw";
import type { PowderSimulation } from "./simulation";

export class SimulationRenderer {
  private pipeline: GPURenderPipeline;
  private bindGroups: [GPUBindGroup, GPUBindGroup];
  private uniformBuffer: GPUBuffer;

  constructor(
    device: GPUDevice,
    simulation: PowderSimulation,
    format: GPUTextureFormat
  ) {

    const shaderModule = device.createShaderModule({
      code: renderShaderSource,
    });

    // Uniform buffer for render params (width, height)
    this.uniformBuffer = device.createBuffer({
      size: 8,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });

    const params = new Uint32Array([simulation.width, simulation.height]);
    device.queue.writeBuffer(this.uniformBuffer, 0, params);

    this.pipeline = device.createRenderPipeline({
      layout: "auto",
      vertex: {
        module: shaderModule,
        entryPoint: "vs_main",
      },
      fragment: {
        module: shaderModule,
        entryPoint: "fs_main",
        targets: [{ format }],
      },
      primitive: {
        topology: "triangle-list",
      },
    });

    const layout = this.pipeline.getBindGroupLayout(0);

    // Create bind groups for both ping-pong buffers
    this.bindGroups = [
      device.createBindGroup({
        layout,
        entries: [
          {
            binding: 0,
            resource: { buffer: simulation.getBuffer(0) },
          },
          { binding: 1, resource: { buffer: this.uniformBuffer } },
        ],
      }),
      device.createBindGroup({
        layout,
        entries: [
          {
            binding: 0,
            resource: { buffer: simulation.getBuffer(1) },
          },
          { binding: 1, resource: { buffer: this.uniformBuffer } },
        ],
      }),
    ];
  }

  render(encoder: GPUCommandEncoder, view: GPUTextureView, currentBufferIndex: number): void {
    const pass = encoder.beginRenderPass({
      colorAttachments: [
        {
          view,
          clearValue: { r: 0.04, g: 0.04, b: 0.05, a: 1.0 },
          loadOp: "clear",
          storeOp: "store",
        },
      ],
    });

    pass.setPipeline(this.pipeline);
    pass.setBindGroup(0, this.bindGroups[currentBufferIndex]);
    pass.draw(3); // Fullscreen triangle
    pass.end();
  }

  destroy(): void {
    this.uniformBuffer.destroy();
  }
}
