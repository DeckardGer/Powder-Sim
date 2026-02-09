export const ElementType = {
  Empty: 0,
  Sand: 1,
  Water: 2,
  Stone: 3,
  Fire: 4,
  Steam: 5,
  Wood: 6,
  Glass: 7,
  Smoke: 8,
} as const;

export type ElementTypeValue = (typeof ElementType)[keyof typeof ElementType];

export interface SimulationConfig {
  width: number;
  height: number;
  workgroupSize: number;
}

export const DEFAULT_CONFIG: SimulationConfig = {
  width: 512,
  height: 512,
  workgroupSize: 16,
};

export interface BrushConfig {
  element: ElementTypeValue;
  size: number;
  minSize: number;
  maxSize: number;
}

export const DEFAULT_BRUSH: BrushConfig = {
  element: ElementType.Sand,
  size: 8,
  minSize: 1,
  maxSize: 32,
};

export type AppScreen = "title" | "simulation";

export interface SimulationStats {
  fps: number;
  particleCount: number;
  frameCount: number;
}
