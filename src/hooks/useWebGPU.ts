import { useState, useEffect, useRef } from "react";
import { initWebGPU, type GPUContext } from "@/simulation/gpu";

export type GPUState =
  | { status: "loading" }
  | { status: "ready"; context: GPUContext }
  | { status: "error"; error: string };

export function useWebGPU(): GPUState {
  const [state, setState] = useState<GPUState>({ status: "loading" });
  const initialized = useRef(false);

  useEffect(() => {
    if (initialized.current) return;
    initialized.current = true;

    initWebGPU()
      .then((context) => {
        setState({ status: "ready", context });
      })
      .catch((err: unknown) => {
        const message =
          err instanceof Error ? err.message : "Unknown GPU error";
        setState({ status: "error", error: message });
      });
  }, []);

  return state;
}
