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
  Oil: 9,
  Lava: 10,
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
  minSize: 2,
  maxSize: 32,
};

export interface SimulationSettings {
  gridSize: number;
  brushSize: number;
}

export const DEFAULT_SETTINGS: SimulationSettings = {
  gridSize: 512,
  brushSize: 8,
};

export type AppScreen = "title" | "simulation";

export interface SimulationStats {
  fps: number;
  particleCount: number;
  frameCount: number;
}
