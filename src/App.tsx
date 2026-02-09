import { useState, useCallback } from "react";
import type { AppScreen, SimulationStats } from "@/types";
import { useWebGPU } from "@/hooks/useWebGPU";
import { useSimulation } from "@/hooks/useSimulation";
import { GPUFallback } from "@/components/GPUFallback";
import { TitleScreen } from "@/components/TitleScreen";
import { SimulationCanvas } from "@/components/SimulationCanvas";

function App() {
  const gpu = useWebGPU();
  const [screen, setScreen] = useState<AppScreen>("title");
  const [_stats, setStats] = useState<SimulationStats>({
    fps: 0,
    particleCount: 0,
    frameCount: 0,
  });

  const { setSimulation, pointerHandlers } = useSimulation();

  const handleStatsUpdate = useCallback((stats: SimulationStats) => {
    setStats(stats);
  }, []);

  if (gpu.status === "loading") {
    return (
      <div className="flex h-screen w-screen items-center justify-center bg-background">
        <p className="text-sm uppercase tracking-[0.3em] text-muted-foreground">
          INITIALIZING GPU...
        </p>
      </div>
    );
  }

  if (gpu.status === "error") {
    return <GPUFallback error={gpu.error} />;
  }

  if (screen === "title") {
    return <TitleScreen onPlay={() => setScreen("simulation")} />;
  }

  return (
    <div className="relative h-screen w-screen bg-background">
      <SimulationCanvas
        gpuContext={gpu.context}
        onStatsUpdate={handleStatsUpdate}
        onSimulationReady={setSimulation}
        pointerHandlers={pointerHandlers}
      />
    </div>
  );
}

export default App;
