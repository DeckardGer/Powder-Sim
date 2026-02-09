import { useState, useCallback, useEffect, useMemo } from "react";
import type { AppScreen, SimulationConfig, SimulationSettings, SimulationStats } from "@/types";
import { DEFAULT_SETTINGS } from "@/types";
import { useWebGPU } from "@/hooks/useWebGPU";
import { useSimulation } from "@/hooks/useSimulation";
import { GPUFallback } from "@/components/GPUFallback";
import { TitleScreen } from "@/components/TitleScreen";
import { SimulationCanvas } from "@/components/SimulationCanvas";
import { StatusBar } from "@/components/StatusBar";
import { Toolbar } from "@/components/Toolbar";

function App() {
  const gpu = useWebGPU();
  const [screen, setScreen] = useState<AppScreen>("title");
  const [settings, setSettings] = useState<SimulationSettings>(DEFAULT_SETTINGS);
  const [stats, setStats] = useState<SimulationStats>({
    fps: 0,
    particleCount: 0,
    frameCount: 0,
  });

  const simConfig = useMemo<SimulationConfig>(
    () => ({
      width: settings.gridSize,
      height: settings.gridSize,
      workgroupSize: 16,
    }),
    [settings.gridSize],
  );

  const {
    setSimulation,
    brushRef,
    setBrushSize,
    setBrushElement,
    clearSimulation,
    flushCells,
    pointerHandlers,
  } = useSimulation(settings.gridSize, settings.brushSize);

  // Force re-render when brush changes (brushRef is a ref, not state)
  const [brushState, setBrushState] = useState(brushRef.current);

  const handleBrushSizeChange = useCallback(
    (size: number) => {
      setBrushSize(size);
      setBrushState({ ...brushRef.current });
    },
    [setBrushSize, brushRef],
  );

  const handleBrushElementChange = useCallback(
    (element: number) => {
      setBrushElement(element);
      setBrushState({ ...brushRef.current });
    },
    [setBrushElement, brushRef],
  );

  const handleStatsUpdate = useCallback((newStats: SimulationStats) => {
    setStats(newStats);
  }, []);

  const goBack = useCallback(() => {
    setScreen("title");
  }, []);

  // Keyboard shortcuts
  useEffect(() => {
    if (screen !== "simulation") return;

    const handleKeyDown = (e: KeyboardEvent) => {
      switch (e.key) {
        case "Escape":
          goBack();
          break;
        case "+":
        case "=":
          handleBrushSizeChange(brushRef.current.size + 2);
          break;
        case "-":
        case "_":
          handleBrushSizeChange(brushRef.current.size - 2);
          break;
        case "c":
        case "C":
          clearSimulation();
          break;
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [screen, goBack, handleBrushSizeChange, clearSimulation, brushRef]);

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
    return (
      <TitleScreen
        settings={settings}
        onPlay={(s) => {
          setSettings(s);
          handleBrushSizeChange(s.brushSize);
          setScreen("simulation");
        }}
      />
    );
  }

  return (
    <div className="relative h-screen w-screen bg-background pb-8">
      <SimulationCanvas
        gpuContext={gpu.context}
        config={simConfig}
        onStatsUpdate={handleStatsUpdate}
        onSimulationReady={setSimulation}
        pointerHandlers={pointerHandlers}
        onFlushCells={flushCells}
      />
      <Toolbar
        brush={brushState}
        onBrushSizeChange={handleBrushSizeChange}
        onBrushElementChange={handleBrushElementChange}
        onClear={clearSimulation}
        onBack={goBack}
      />
      <StatusBar stats={stats} />
    </div>
  );
}

export default App;
