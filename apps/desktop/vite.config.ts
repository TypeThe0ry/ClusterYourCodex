import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { secureControllerProxy } from "./dev/secure-controller-proxy.ts";

export default defineConfig({
  plugins: [react(), secureControllerProxy()],
  server: {
    port: 1420,
    strictPort: true,
    watch: {
      // Tauri compiles native binaries below this directory while Vite is
      // running. Watching those transient, executable files on Windows races
      // the linker/antivirus file handles and can terminate dev startup with
      // EBUSY before the desktop window is created.
      ignored: ["**/src-tauri/target/**"],
    },
  },
  preview: {
    port: 1420,
    strictPort: true,
  },
});
