/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_CONTROLLER_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
