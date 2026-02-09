/// <reference types="vite/client" />

declare module "*.wgsl?raw" {
  const value: string;
  export default value;
}
