import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// base './' => relative asset paths, so the build serves correctly from App Service regardless
// of host path (public/server.mjs serves dist/). public/config.json is copied as-is to
// dist/config.json and then overwritten at deploy time with the real API URL (tenant-agnostic
// build).
export default defineConfig({
  base: './',
  plugins: [react()],
  build: {
    outDir: 'dist',
    sourcemap: false,
    // fluentui is one ~600 kB library chunk, cached for a year by server.mjs; splitting it
    // further buys nothing on a repeat visit.
    chunkSizeWarningLimit: 700,
    rolldownOptions: {
      output: {
        // Heavy vendor libraries get their own long-cacheable chunks, so an app-only change
        // doesn't invalidate them. Higher priority wins when a module matches several groups.
        // [\\/] matches the path separator on Windows too.
        codeSplitting: {
          groups: [
            { name: 'react', test: /[\\/]node_modules[\\/](react|react-dom|scheduler)[\\/]/, priority: 30 },
            { name: 'recharts', test: /[\\/]node_modules[\\/](recharts|d3-[^\\/]+|victory-vendor)[\\/]/, priority: 20 },
            { name: 'fluentui', test: /[\\/]node_modules[\\/](@fluentui|@griffel)[\\/]/, priority: 20 },
            { name: 'vendor', test: /[\\/]node_modules[\\/]/, priority: 10 },
          ],
        },
      },
    },
  },
})
