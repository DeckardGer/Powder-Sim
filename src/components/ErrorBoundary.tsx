import { Component } from "react";
import type { ReactNode, ErrorInfo } from "react";

interface ErrorBoundaryProps {
  children: ReactNode;
}

interface ErrorBoundaryState {
  hasError: boolean;
  error: Error | null;
}

export class ErrorBoundary extends Component<
  ErrorBoundaryProps,
  ErrorBoundaryState
> {
  constructor(props: ErrorBoundaryProps) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("Powder-Sim crashed:", error, info.componentStack);
  }

  render() {
    if (this.state.hasError) {
      return (
        <div className="flex h-screen w-screen items-center justify-center bg-[#0a0a0b] p-8 font-mono text-white">
          <div className="max-w-lg border-2 border-white p-8">
            <h1 className="mb-4 text-2xl font-bold uppercase tracking-[0.2em]">
              FATAL ERROR
            </h1>
            <div className="mb-6 border-t border-white/20 pt-4">
              <p className="mb-4 text-sm uppercase tracking-wider text-zinc-400">
                THE SIMULATION HAS CRASHED
              </p>
              <p className="text-xs text-red-400">
                {this.state.error?.message ?? "Unknown error"}
              </p>
            </div>
            <button
              className="border border-white px-4 py-2 text-xs uppercase tracking-wider transition-none hover:bg-white hover:text-black"
              onClick={() => window.location.reload()}
            >
              RELOAD
            </button>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}
