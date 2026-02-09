import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import type { SimulationSettings } from "@/types";
import { DEFAULT_SETTINGS } from "@/types";

interface TitleScreenProps {
  settings?: SimulationSettings;
  onPlay: (settings: SimulationSettings) => void;
}

const GRID_SIZES = [256, 512, 1024] as const;
const BRUSH_MIN = 2;
const BRUSH_MAX = 32;
const BRUSH_STEP = 2;

export function TitleScreen({ settings: initialSettings, onPlay }: TitleScreenProps) {
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [aboutOpen, setAboutOpen] = useState(false);
  const [gridSize, setGridSize] = useState(initialSettings?.gridSize ?? DEFAULT_SETTINGS.gridSize);
  const [brushSize, setBrushSize] = useState(initialSettings?.brushSize ?? DEFAULT_SETTINGS.brushSize);

  return (
    <div className="relative flex h-screen w-screen flex-col items-center justify-center bg-background">
      {/* Scanline overlay */}
      <div
        className="pointer-events-none absolute inset-0 z-10"
        style={{
          background:
            "repeating-linear-gradient(0deg, transparent, transparent 2px, rgba(0,0,0,0.08) 2px, rgba(0,0,0,0.08) 4px)",
        }}
      />

      <div className="relative z-20 flex flex-col items-center gap-12">
        {/* Title */}
        <div className="text-center">
          <h1 className="text-6xl font-bold uppercase tracking-[0.5em] text-foreground md:text-8xl">
            POWDER
          </h1>
          <div className="mt-2 h-px w-full bg-foreground/20" />
          <p className="mt-3 text-xs uppercase tracking-[0.4em] text-muted-foreground">
            FALLING SAND SIMULATION
          </p>
        </div>

        {/* Menu */}
        <div className="flex flex-col gap-3">
          <Button
            variant="outline"
            className="h-12 w-64 border-2 border-foreground text-sm uppercase tracking-[0.3em] transition-none hover:bg-foreground hover:text-background"
            onClick={() => onPlay({ gridSize, brushSize })}
          >
            PLAY
          </Button>
          <Button
            variant="outline"
            className="h-12 w-64 border-2 border-foreground/40 text-sm uppercase tracking-[0.3em] text-muted-foreground transition-none hover:border-foreground hover:bg-foreground hover:text-background"
            onClick={() => setSettingsOpen(true)}
          >
            SETTINGS
          </Button>
          <Button
            variant="outline"
            className="h-12 w-64 border-2 border-foreground/40 text-sm uppercase tracking-[0.3em] text-muted-foreground transition-none hover:border-foreground hover:bg-foreground hover:text-background"
            onClick={() => setAboutOpen(true)}
          >
            ABOUT
          </Button>
        </div>

        {/* Version */}
        <p className="text-[10px] uppercase tracking-[0.3em] text-muted-foreground/50">
          V0.1.0 // WEBGPU
        </p>
      </div>

      {/* Settings Dialog */}
      <Dialog open={settingsOpen} onOpenChange={setSettingsOpen}>
        <DialogContent className="border-2 border-foreground bg-background">
          <DialogHeader>
            <DialogTitle className="text-lg uppercase tracking-[0.2em]">
              SETTINGS
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-5 pt-2">
            {/* Grid Size selector */}
            <div className="space-y-2 border-b border-foreground/10 pb-4">
              <span className="text-xs uppercase tracking-wider text-muted-foreground">
                GRID SIZE
              </span>
              <div className="flex gap-2">
                {GRID_SIZES.map((size) => (
                  <Button
                    key={size}
                    variant="outline"
                    className={`h-8 flex-1 border-2 text-xs uppercase tracking-wider transition-none ${
                      gridSize === size
                        ? "border-foreground bg-foreground text-background"
                        : "border-foreground/40 text-muted-foreground hover:border-foreground hover:bg-foreground hover:text-background"
                    }`}
                    onClick={() => setGridSize(size)}
                  >
                    {size}
                  </Button>
                ))}
              </div>
            </div>

            {/* Brush Size selector */}
            <div className="space-y-2 border-b border-foreground/10 pb-4">
              <span className="text-xs uppercase tracking-wider text-muted-foreground">
                DEFAULT BRUSH SIZE
              </span>
              <div className="flex items-center gap-3">
                <Button
                  variant="outline"
                  className="h-8 w-8 border-2 border-foreground/40 text-xs transition-none hover:border-foreground hover:bg-foreground hover:text-background"
                  onClick={() => setBrushSize(Math.max(BRUSH_MIN, brushSize - BRUSH_STEP))}
                >
                  −
                </Button>
                <span className="w-8 text-center text-sm tabular-nums">
                  {brushSize}
                </span>
                <Button
                  variant="outline"
                  className="h-8 w-8 border-2 border-foreground/40 text-xs transition-none hover:border-foreground hover:bg-foreground hover:text-background"
                  onClick={() => setBrushSize(Math.min(BRUSH_MAX, brushSize + BRUSH_STEP))}
                >
                  +
                </Button>
              </div>
            </div>

            {/* Read-only info */}
            <div className="flex items-center justify-between border-b border-foreground/10 pb-3">
              <span className="text-xs uppercase tracking-wider text-muted-foreground">
                RENDERER
              </span>
              <span className="text-xs">WEBGPU COMPUTE</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-xs uppercase tracking-wider text-muted-foreground">
                ALGORITHM
              </span>
              <span className="text-xs">MARGOLUS CA</span>
            </div>
          </div>
        </DialogContent>
      </Dialog>

      {/* About Dialog */}
      <Dialog open={aboutOpen} onOpenChange={setAboutOpen}>
        <DialogContent className="border-2 border-foreground bg-background">
          <DialogHeader>
            <DialogTitle className="text-lg uppercase tracking-[0.2em]">
              ABOUT
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-3 pt-2 text-xs text-muted-foreground">
            <p>
              GPU-ACCELERATED FALLING SAND SIMULATION USING WEBGPU COMPUTE
              SHADERS AND MARGOLUS NEIGHBORHOOD BLOCK CELLULAR AUTOMATA.
            </p>
            <div className="border-t border-foreground/10 pt-3">
              <p className="uppercase tracking-wider">CONTROLS</p>
              <ul className="mt-2 space-y-1">
                <li>// CLICK + DRAG TO DRAW</li>
                <li>// +/- TO CHANGE BRUSH SIZE</li>
                <li>// C TO CLEAR</li>
                <li>// ESC TO RETURN TO MENU</li>
              </ul>
            </div>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
