import { Button } from "@/components/ui/button";
import type { BrushConfig } from "@/types";
import { ElementType } from "@/types";

interface ToolbarProps {
  brush: BrushConfig;
  onBrushSizeChange: (size: number) => void;
  onBrushElementChange: (element: number) => void;
  onClear: () => void;
  onBack: () => void;
}

const ELEMENTS = [
  { type: ElementType.Sand, label: "SAND", color: "bg-yellow-600" },
  { type: ElementType.Water, label: "WATER", color: "bg-blue-500" },
  { type: ElementType.Stone, label: "STONE", color: "bg-zinc-500" },
  { type: ElementType.Wood, label: "WOOD", color: "bg-amber-800" },
  { type: ElementType.Fire, label: "FIRE", color: "bg-orange-500" },
  { type: ElementType.Steam, label: "STEAM", color: "bg-slate-400" },
  { type: ElementType.Glass, label: "GLASS", color: "bg-cyan-200" },
  { type: ElementType.Empty, label: "ERASE", color: "bg-zinc-900" },
] as const;

export function Toolbar({
  brush,
  onBrushSizeChange,
  onBrushElementChange,
  onClear,
  onBack,
}: ToolbarProps) {
  return (
    <div className="fixed left-3 top-3 z-30 flex flex-col gap-2">
      {/* Element selector */}
      <div className="border border-foreground/20 bg-background/90 p-2 backdrop-blur-sm">
        <p className="mb-2 text-[10px] uppercase tracking-wider text-muted-foreground">
          ELEMENT
        </p>
        <div className="flex flex-col gap-1">
          {ELEMENTS.map(({ type, label, color }) => (
            <button
              key={type}
              className={`flex items-center gap-2 px-2 py-1 text-left text-[11px] uppercase tracking-wider transition-none ${
                brush.element === type
                  ? "bg-foreground/10 text-foreground"
                  : "text-muted-foreground hover:text-foreground"
              }`}
              onClick={() => onBrushElementChange(type)}
            >
              <span className={`inline-block h-2.5 w-2.5 ${color}`} />
              {label}
            </button>
          ))}
        </div>
      </div>

      {/* Brush size */}
      <div className="border border-foreground/20 bg-background/90 p-2 backdrop-blur-sm">
        <p className="mb-2 text-[10px] uppercase tracking-wider text-muted-foreground">
          BRUSH
        </p>
        <div className="flex items-center gap-2">
          <Button
            variant="outline"
            size="sm"
            className="h-6 w-6 border-foreground/30 p-0 text-xs transition-none"
            onClick={() => onBrushSizeChange(brush.size - 2)}
          >
            -
          </Button>
          <span className="w-6 text-center text-[11px]">{brush.size}</span>
          <Button
            variant="outline"
            size="sm"
            className="h-6 w-6 border-foreground/30 p-0 text-xs transition-none"
            onClick={() => onBrushSizeChange(brush.size + 2)}
          >
            +
          </Button>
        </div>
      </div>

      {/* Actions */}
      <div className="flex flex-col gap-1">
        <Button
          variant="outline"
          size="sm"
          className="h-7 border-foreground/20 text-[10px] uppercase tracking-wider transition-none"
          onClick={onClear}
        >
          CLEAR
        </Button>
        <Button
          variant="outline"
          size="sm"
          className="h-7 border-foreground/20 text-[10px] uppercase tracking-wider transition-none"
          onClick={onBack}
        >
          ESC BACK
        </Button>
      </div>
    </div>
  );
}
