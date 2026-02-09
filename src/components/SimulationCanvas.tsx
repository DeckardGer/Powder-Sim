import { useRef, useEffect, useCallback } from "react";
import { configureCanvas } from "@/simulation/gpu";
import { PowderSimulation } from "@/simulation/simulation";
import { SimulationRenderer } from "@/simulation/renderer";
import type { SimulationStats } from "@/types";
import { DEFAULT_CONFIG } from "@/types";
import type { GPUContext } from "@/simulation/gpu";

interface SimulationCanvasProps {
  gpuContext: GPUContext;
  onStatsUpdate?: (stats: SimulationStats) => void;
  onSimulationReady?: (simulation: PowderSimulation) => void;
  pointerHandlers?: {
    onPointerDown: (e: React.PointerEvent<HTMLCanvasElement>) => void;
    onPointerMove: (e: React.PointerEvent<HTMLCanvasElement>) => void;
    onPointerUp: (e: React.PointerEvent<HTMLCanvasElement>) => void;
    onPointerLeave: (e: React.PointerEvent<HTMLCanvasElement>) => void;
  };
}

export function SimulationCanvas({
  gpuContext,
  onStatsUpdate,
  onSimulationReady,
  pointerHandlers,
}: SimulationCanvasProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const simulationRef = useRef<PowderSimulation | null>(null);
  const rendererRef = useRef<SimulationRenderer | null>(null);
  const animFrameRef = useRef<number>(0);
  const fpsCounterRef = useRef({ frames: 0, lastTime: performance.now() });
  const simAccumulatorRef = useRef({ lastTime: 0, accumulator: 0 });

  // Fixed timestep: 60 simulation steps per second, max 4 catch-up steps
  const SIM_DT = 1000 / 60;
  const MAX_SIM_STEPS = 4;

  const gameLoop = useCallback(
    (canvasContext: GPUCanvasContext) => {
      const simulation = simulationRef.current;
      const renderer = rendererRef.current;
      if (!simulation || !renderer) return;

      const { device } = gpuContext;
      simAccumulatorRef.current.lastTime = performance.now();

      const loop = () => {
        const now = performance.now();
        const frameElapsed = now - simAccumulatorRef.current.lastTime;
        simAccumulatorRef.current.lastTime = now;

        // Skip frame if tab was backgrounded (avoids massive catch-up)
        const fpsElapsed = now - fpsCounterRef.current.lastTime;
        if (fpsElapsed > 2000) {
          fpsCounterRef.current.lastTime = now;
          fpsCounterRef.current.frames = 0;
          simAccumulatorRef.current.accumulator = 0;
          animFrameRef.current = requestAnimationFrame(loop);
          return;
        }

        // FPS tracking
        fpsCounterRef.current.frames++;
        if (fpsElapsed >= 1000) {
          const fps = Math.round(
            (fpsCounterRef.current.frames * 1000) / fpsElapsed,
          );
          fpsCounterRef.current.frames = 0;
          fpsCounterRef.current.lastTime = now;
          simulation.requestParticleCount();
          onStatsUpdate?.({
            fps,
            particleCount: simulation.particleCount,
            frameCount: simulation.frame,
          });
        }

        // Fixed-timestep accumulator: run simulation at constant rate
        simAccumulatorRef.current.accumulator += frameElapsed;
        let simSteps = 0;
        while (
          simAccumulatorRef.current.accumulator >= SIM_DT &&
          simSteps < MAX_SIM_STEPS
        ) {
          simAccumulatorRef.current.accumulator -= SIM_DT;
          simSteps++;
        }
        // Drain excess accumulator to prevent spiral-of-death
        if (simAccumulatorRef.current.accumulator > SIM_DT) {
          simAccumulatorRef.current.accumulator = 0;
        }

        // Batch all sim steps + render into one command encoder
        if (simSteps > 0) {
          const encoder = device.createCommandEncoder();
          for (let i = 0; i < simSteps; i++) {
            simulation.step(encoder);
          }

          const textureView = canvasContext.getCurrentTexture().createView();
          renderer.render(
            encoder,
            textureView,
            simulation.getCurrentBufferIndex(),
          );

          device.queue.submit([encoder.finish()]);
        }

        animFrameRef.current = requestAnimationFrame(loop);
      };

      animFrameRef.current = requestAnimationFrame(loop);
    },
    [gpuContext, onStatsUpdate],
  );

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const { device } = gpuContext;

    canvas.width = DEFAULT_CONFIG.width;
    canvas.height = DEFAULT_CONFIG.height;

    const canvasContext = configureCanvas(canvas, device);
    const format = navigator.gpu.getPreferredCanvasFormat();

    const simulation = new PowderSimulation(device);
    const renderer = new SimulationRenderer(device, simulation, format);

    simulationRef.current = simulation;
    rendererRef.current = renderer;

    onSimulationReady?.(simulation);
    gameLoop(canvasContext);

    return () => {
      if (animFrameRef.current) {
        cancelAnimationFrame(animFrameRef.current);
      }
      renderer.destroy();
      simulation.destroy();
      simulationRef.current = null;
      rendererRef.current = null;
    };
  }, [gpuContext, gameLoop, onSimulationReady]);

  return (
    <canvas
      ref={canvasRef}
      className="block h-full w-full"
      style={{ imageRendering: "pixelated", touchAction: "none" }}
      {...pointerHandlers}
    />
  );
}
