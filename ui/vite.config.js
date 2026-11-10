import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// For local development run a pod on :8100 (scripts/run-local.sh) and `npm run dev`.
const api = 'http://localhost:8100'

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/broadcast': api,
      '/members': api,
      '/identity': api,
      '/ws': { target: api, ws: true },
    },
  },
})
