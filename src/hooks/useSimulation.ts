import { useRef, useCallback, useEffect } from "react";
import type { PowderSimulation } from "@/simulation/simulation";
import type { BrushConfig } from "@/types";
import { DEFAULT_BRUSH, DEFAULT_CONFIG, ElementType } from "@/types";

interface PendingCell {
  x: number;
  y: number;
  value: number;
}

export function useSimulation() {
  const simulationRef = useRef<PowderSimulation | null>(null);
  const brushRef = useRef<BrushConfig>({ ...DEFAULT_BRUSH });
  const lastPosRef = useRef<{ x: number; y: number } | null>(null);
  const isDrawingRef = useRef(false);
  const pendingCellsRef = useRef<Map<number, PendingCell>>(new Map());
  const holdIntervalRef = useRef<number>(0);

  const setSimulation = useCallback((sim: PowderSimulation | null) => {
    simulationRef.current = sim;
  }, []);

  const setBrushSize = useCallback((size: number) => {
    const clamped = Math.max(
      DEFAULT_BRUSH.minSize,
      Math.min(DEFAULT_BRUSH.maxSize, size),
    );
    brushRef.current = { ...brushRef.current, size: clamped };
  }, []);

  const setBrushElement = useCallback((element: number) => {
    brushRef.current = {
      ...brushRef.current,
      element: element as BrushConfig["element"],
    };
  }, []);

  /** Convert canvas pixel coordinates to grid coordinates */
  const canvasToGrid = useCallback(
    (
      canvasX: number,
      canvasY: number,
      canvas: HTMLCanvasElement,
    ): { x: number; y: number } => {
      const rect = canvas.getBoundingClientRect();
      const scaleX = DEFAULT_CONFIG.width / rect.width;
      const scaleY = DEFAULT_CONFIG.height / rect.height;
      return {
        x: Math.floor((canvasX - rect.left) * scaleX),
        y: Math.floor((canvasY - rect.top) * scaleY),
      };
    },
    [],
  );

  /** Paint a circular brush stamp at (cx, cy) */
  const stamp = useCallback((cx: number, cy: number) => {
    const brush = brushRef.current;
    const r = brush.size;
    const rSq = r * r;

    for (let dy = -r; dy <= r; dy++) {
      for (let dx = -r; dx <= r; dx++) {
        if (dx * dx + dy * dy > rSq) continue;
        const x = cx + dx;
        const y = cy + dy;
        if (
          x < 0 ||
          x >= DEFAULT_CONFIG.width ||
          y < 0 ||
          y >= DEFAULT_CONFIG.height
        )
          continue;

        const colorVar = Math.floor(Math.random() * 256);
        let value: number;
        if (brush.element === ElementType.Empty) {
          value = 0;
        } else if (brush.element === ElementType.Fire) {
          const lifetime = 60 + Math.floor(Math.random() * 60); // 60-119
          value = brush.element | (colorVar << 8) | (lifetime << 16);
        } else if (brush.element === ElementType.Steam) {
          const lifetime = 150 + Math.floor(Math.random() * 100); // 150-249
          value = brush.element | (colorVar << 8) | (lifetime << 16);
        } else {
          value = brush.element | (colorVar << 8);
        }

        const key = y * DEFAULT_CONFIG.width + x;
        pendingCellsRef.current.set(key, { x, y, value });
      }
    }
  }, []);

  /** Bresenham line interpolation between two points */
  const bresenhamLine = useCallback(
    (x0: number, y0: number, x1: number, y1: number) => {
      let dx = Math.abs(x1 - x0);
      let dy = -Math.abs(y1 - y0);
      const sx = x0 < x1 ? 1 : -1;
      const sy = y0 < y1 ? 1 : -1;
      let err = dx + dy;
      let cx = x0;
      let cy = y0;

      while (true) {
        stamp(cx, cy);
        if (cx === x1 && cy === y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
          err += dy;
          cx += sx;
        }
        if (e2 <= dx) {
          err += dx;
          cy += sy;
        }
      }
    },
    [stamp],
  );

  /** Flush pending cells to the simulation */
  const flushCells = useCallback(() => {
    const sim = simulationRef.current;
    if (!sim || pendingCellsRef.current.size === 0) return;

    const cells = Array.from(pendingCellsRef.current.values());
    sim.writeCells(cells);
    pendingCellsRef.current.clear();
  }, []);

  /** Start continuous stamp interval while holding mouse */
  const startHoldInterval = useCallback(() => {
    stopHoldInterval();
    holdIntervalRef.current = window.setInterval(() => {
      const pos = lastPosRef.current;
      if (!isDrawingRef.current || !pos) return;
      stamp(pos.x, pos.y);
    }, 1000 / 30); // 30 stamps per second while holding
  }, [stamp]);

  const stopHoldInterval = useCallback(() => {
    if (holdIntervalRef.current) {
      clearInterval(holdIntervalRef.current);
      holdIntervalRef.current = 0;
    }
  }, []);

  // Clean up interval on unmount
  useEffect(() => {
    return () => stopHoldInterval();
  }, [stopHoldInterval]);

  const onPointerDown = useCallback(
    (e: React.PointerEvent<HTMLCanvasElement>) => {
      const canvas = e.currentTarget;
      canvas.setPointerCapture(e.pointerId);
      isDrawingRef.current = true;
      const pos = canvasToGrid(e.clientX, e.clientY, canvas);
      lastPosRef.current = pos;
      stamp(pos.x, pos.y);
      startHoldInterval();
    },
    [canvasToGrid, stamp, startHoldInterval],
  );

  const onPointerMove = useCallback(
    (e: React.PointerEvent<HTMLCanvasElement>) => {
      if (!isDrawingRef.current) return;
      const canvas = e.currentTarget;
      const pos = canvasToGrid(e.clientX, e.clientY, canvas);
      const last = lastPosRef.current;

      if (last) {
        bresenhamLine(last.x, last.y, pos.x, pos.y);
      } else {
        stamp(pos.x, pos.y);
      }

      lastPosRef.current = pos;
    },
    [canvasToGrid, bresenhamLine, stamp],
  );

  const onPointerUp = useCallback(() => {
    isDrawingRef.current = false;
    lastPosRef.current = null;
    stopHoldInterval();
  }, [stopHoldInterval]);

  const clearSimulation = useCallback(() => {
    simulationRef.current?.clear();
  }, []);

  return {
    setSimulation,
    brushRef,
    setBrushSize,
    setBrushElement,
    clearSimulation,
    flushCells,
    pointerHandlers: {
      onPointerDown,
      onPointerMove,
      onPointerUp,
      onPointerLeave: onPointerUp,
    },
  };
}
