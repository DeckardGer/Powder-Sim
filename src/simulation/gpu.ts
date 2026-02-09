export interface GPUContext {
  adapter: GPUAdapter;
  device: GPUDevice;
}

export async function initWebGPU(): Promise<GPUContext> {
  if (!navigator.gpu) {
    throw new Error("WebGPU is not supported in this browser.");
  }

  const adapter = await navigator.gpu.requestAdapter({
    powerPreference: "high-performance",
  });

  if (!adapter) {
    throw new Error("Failed to get GPU adapter.");
  }

  const device = await adapter.requestDevice({
    requiredFeatures: [],
    requiredLimits: {
      maxStorageBufferBindingSize: adapter.limits.maxStorageBufferBindingSize,
      maxBufferSize: adapter.limits.maxBufferSize,
    },
  });

  device.lost.then((info) => {
    console.error(`WebGPU device lost: ${info.message}`);
    if (info.reason !== "destroyed") {
      throw new Error(`GPU device lost: ${info.message}`);
    }
  });

  return { adapter, device };
}

export function configureCanvas(
  canvas: HTMLCanvasElement,
  device: GPUDevice
): GPUCanvasContext {
  const context = canvas.getContext("webgpu");
  if (!context) {
    throw new Error("Failed to get WebGPU canvas context.");
  }

  context.configure({
    device,
    format: navigator.gpu.getPreferredCanvasFormat(),
    alphaMode: "opaque",
  });

  return context;
}
