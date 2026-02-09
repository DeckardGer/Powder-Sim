interface GPUFallbackProps {
  error: string;
}

export function GPUFallback({ error }: GPUFallbackProps) {
  return (
    <div className="flex h-screen w-screen items-center justify-center bg-background p-8">
      <div className="max-w-lg border-2 border-foreground p-8">
        <h1 className="mb-4 text-2xl font-bold uppercase tracking-[0.2em]">
          GPU ERROR
        </h1>
        <div className="mb-6 border-t border-foreground/20 pt-4">
          <p className="mb-4 text-sm uppercase tracking-wider text-muted-foreground">
            WEBGPU IS NOT AVAILABLE
          </p>
          <p className="font-mono text-xs text-destructive">{error}</p>
        </div>
        <div className="border-t border-foreground/20 pt-4">
          <p className="text-xs uppercase tracking-wider text-muted-foreground">
            REQUIREMENTS
          </p>
          <ul className="mt-2 space-y-1 text-xs text-muted-foreground">
            <li>// CHROME 113+ OR EDGE 113+</li>
            <li>// FIREFOX NIGHTLY (FLAG ENABLED)</li>
            <li>// SAFARI 18+ (MACOS/IOS)</li>
            <li>// HARDWARE GPU REQUIRED</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
