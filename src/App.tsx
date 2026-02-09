import { useState } from "react";
import type { AppScreen } from "@/types";
import { useWebGPU } from "@/hooks/useWebGPU";
import { GPUFallback } from "@/components/GPUFallback";

function App() {
  const gpu = useWebGPU();
  const [_screen, _setScreen] = useState<AppScreen>("title");

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

  return (
    <div className="h-screen w-screen bg-background text-foreground">
      <div className="flex h-full items-center justify-center">
        <p className="text-sm uppercase tracking-[0.3em] text-muted-foreground">
          GPU READY
        </p>
      </div>
    </div>
  );
}

export default App;
