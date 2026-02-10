import { ElementType } from "@/types";
import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";

interface CommandMenuProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onElementSelect: (element: number) => void;
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
  { type: ElementType.Oil, label: "OIL", color: "bg-amber-950" },
  { type: ElementType.Lava, label: "LAVA", color: "bg-red-700" },
  { type: ElementType.Acid, label: "ACID", color: "bg-green-500" },
  { type: ElementType.Gunpowder, label: "GUNPOWDER", color: "bg-zinc-600" },
  { type: ElementType.Bomb, label: "BOMB", color: "bg-red-950" },
  { type: ElementType.Plant, label: "PLANT", color: "bg-green-700" },
  { type: ElementType.Ice, label: "ICE", color: "bg-cyan-300" },
  { type: ElementType.Empty, label: "ERASER", color: "bg-zinc-900" },
] as const;

export function CommandMenu({
  open,
  onOpenChange,
  onElementSelect,
  onClear,
  onBack,
}: CommandMenuProps) {
  const select = (fn: () => void) => {
    onOpenChange(false);
    fn();
  };

  return (
    <CommandDialog
      open={open}
      onOpenChange={onOpenChange}
      title="Command Menu"
      description="Select an element or action"
    >
      <CommandInput
        placeholder="Search elements..."
        className="text-[11px] uppercase tracking-wider"
      />
      <CommandList>
        <CommandEmpty className="text-[11px] uppercase tracking-wider">
          No results found.
        </CommandEmpty>
        <CommandGroup
          heading="ELEMENTS"
          className="[&_[cmdk-group-heading]]:text-[10px] [&_[cmdk-group-heading]]:uppercase [&_[cmdk-group-heading]]:tracking-wider"
        >
          {ELEMENTS.map(({ type, label, color }) => (
            <CommandItem
              key={type}
              value={label}
              onSelect={() => select(() => onElementSelect(type))}
              className="text-[11px] uppercase tracking-wider"
            >
              <span className={`inline-block h-2.5 w-2.5 shrink-0 ${color}`} />
              {label}
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandGroup
          heading="ACTIONS"
          className="[&_[cmdk-group-heading]]:text-[10px] [&_[cmdk-group-heading]]:uppercase [&_[cmdk-group-heading]]:tracking-wider"
        >
          <CommandItem
            value="Clear canvas"
            onSelect={() => select(onClear)}
            className="text-[11px] uppercase tracking-wider"
          >
            CLEAR
          </CommandItem>
          <CommandItem
            value="Back to title"
            onSelect={() => select(onBack)}
            className="text-[11px] uppercase tracking-wider"
          >
            BACK
          </CommandItem>
        </CommandGroup>
      </CommandList>
    </CommandDialog>
  );
}
