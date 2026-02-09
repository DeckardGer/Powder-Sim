import type { SimulationStats } from "@/types";
import { DEFAULT_CONFIG } from "@/types";

interface StatusBarProps {
  stats: SimulationStats;
}

function fpsColor(fps: number): string {
  if (fps >= 55) return "text-green-400";
  if (fps >= 30) return "text-yellow-400";
  return "text-red-400";
}

export function StatusBar({ stats }: StatusBarProps) {
  return (
    <div className="fixed bottom-0 left-0 right-0 z-30 flex h-8 items-center justify-between border-t border-foreground/10 bg-background/90 px-4 backdrop-blur-sm">
      <div className="flex items-center gap-6">
        <span className="text-[10px] uppercase tracking-wider text-muted-foreground">
          FPS{" "}
          <span className={fpsColor(stats.fps)}>{stats.fps.toString().padStart(3, " ")}</span>
        </span>
        <span className="text-[10px] uppercase tracking-wider text-muted-foreground">
          PARTICLES{" "}
          <span className="text-foreground">{stats.particleCount}</span>
        </span>
        <span className="text-[10px] uppercase tracking-wider text-muted-foreground">
          FRAME{" "}
          <span className="text-foreground">{stats.frameCount}</span>
        </span>
      </div>
      <div className="text-[10px] uppercase tracking-wider text-muted-foreground/50">
        {DEFAULT_CONFIG.width}x{DEFAULT_CONFIG.height}
      </div>
    </div>
  );
}
