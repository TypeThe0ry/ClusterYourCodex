import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { secureControllerProxy } from "./dev/secure-controller-proxy.ts";

export default defineConfig({
  plugins: [react(), secureControllerProxy()],
  server: {
    port: 1420,
    strictPort: true,
  },
  preview: {
    port: 1420,
    strictPort: true,
  },
});
