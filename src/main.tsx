import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource/jetbrains-mono/400.css";
import "@fontsource/jetbrains-mono/700.css";
import "./index.css";
import App from "./App";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { Analytics } from "@vercel/analytics/react";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
    <Analytics />
  </StrictMode>,
);
