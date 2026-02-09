import { useState } from "react";
import type { AppScreen } from "@/types";

function App() {
  const [_screen, _setScreen] = useState<AppScreen>("title");

  return (
    <div className="h-screen w-screen bg-background text-foreground">
      <div className="flex h-full items-center justify-center">
        <p className="text-sm uppercase tracking-[0.3em] text-muted-foreground">
          INITIALIZING...
        </p>
      </div>
    </div>
  );
}

export default App;
