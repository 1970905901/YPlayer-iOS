import vue from '@vitejs/plugin-vue';
import { resolve } from 'path';
import AutoImport from 'unplugin-auto-import/vite';
import { NaiveUiResolver } from 'unplugin-vue-components/resolvers';
import Components from 'unplugin-vue-components/vite';
import { defineConfig } from 'vite';
import viteCompression from 'vite-plugin-compression';
import VueDevTools from 'vite-plugin-vue-devtools';

export default defineConfig(({ mode }) => ({
  base: './',
  // 项目src
  root: resolve('src/renderer'),
  resolve: {
    alias: {
      '@': resolve('src/renderer'),
      '@renderer': resolve('src/renderer'),
      '@i18n': resolve('src/i18n')
    }
  },
  plugins: [
    vue(),
    viteCompression(),
    mode !== 'production' ? VueDevTools() : undefined,
    AutoImport({
      imports: [
        'vue',
        {
          'naive-ui': ['useDialog', 'useMessage', 'useNotification', 'useLoadingBar']
        }
      ]
    }),
    Components({
      resolvers: [NaiveUiResolver()]
    })
  ].filter(Boolean),
  publicDir: resolve('resources'),
  build: {
    outDir: resolve('dist'),
    emptyOutDir: true,
    // 构建目标支持 iOS 14.0 / Safari 14
    target: ['es2020', 'safari14', 'ios14']
  },
  server: {
    host: '0.0.0.0',
    proxy: {}
  }
}));
