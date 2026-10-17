<template>
  <div class="border-b border-gray-100 dark:border-gray-800 bg-white dark:bg-black z-10">
    <n-scrollbar ref="scrollbarRef" x-scrollable>
      <div
        class="flex items-center py-4 page-padding"
        style="white-space: nowrap"
        @wheel.prevent="handleWheel"
      >
        <button
          v-for="(category, index) in categories"
          :key="getItemKey(category, index)"
          type="button"
          class="category-btn py-1.5 px-4 mr-3 inline-flex items-center justify-center rounded-full cursor-pointer select-none text-sm font-medium border-0 outline-none active:scale-95"
          :class="[
            animationClass,
            index === 0 ? 'ml-0.5' : '',
            isActive(category)
              ? 'is-active bg-primary text-white shadow-lg shadow-primary/25 scale-105'
              : 'bg-gray-100 dark:bg-neutral-800 text-neutral-600 dark:text-neutral-400'
          ]"
          :style="getAnimationDelay(index)"
          @click="handleClickCategory(category)"
        >
          {{ getItemLabel(category) }}
        </button>
      </div>
    </n-scrollbar>
  </div>
</template>

<script setup lang="ts">
import { NScrollbar } from 'naive-ui';
import { computed, ref, watch } from 'vue';

import { setAnimationDelay } from '@/utils';

type Category = string | number | { [key: string]: any };

type CategorySelectorProps = {
  categories: Category[];
  modelValue: any;
  labelKey?: string;
  valueKey?: string;
  animationClass?: string;
};

const props = withDefaults(defineProps<CategorySelectorProps>(), {
  labelKey: 'label',
  valueKey: 'value',
  animationClass: 'animate__bounceIn'
});

const emit = defineEmits<{
  'update:modelValue': [value: any];
  change: [value: any];
}>();

const scrollbarRef = ref();

// 内部乐观状态：点击时立即响应主题色，无需等待路由异步队列
const selectedValue = ref(props.modelValue);

watch(
  () => props.modelValue,
  (val) => {
    selectedValue.value = val;
  }
);

const getItemKey = (item: Category, index: number): string | number => {
  if (typeof item === 'object' && item !== null) {
    return item[props.valueKey] ?? item[props.labelKey] ?? index;
  }
  return item;
};

const getItemLabel = (item: Category): string => {
  if (typeof item === 'object' && item !== null) {
    return item[props.labelKey] ?? String(item);
  }
  return String(item);
};

const getItemValue = (item: Category): any => {
  if (typeof item === 'object' && item !== null) {
    return item[props.valueKey] ?? item;
  }
  return item;
};

const isActive = (item: Category): boolean => {
  const itemValue = getItemValue(item);
  return itemValue === selectedValue.value;
};

const getAnimationDelay = computed(() => {
  return (index: number) => setAnimationDelay(index, 30);
});

const handleClickCategory = (item: Category) => {
  const value = getItemValue(item);
  if (value === selectedValue.value) return;

  // 1. 同步立即更新选定状态，消除主题色切换延迟
  selectedValue.value = value;

  // 2. 向上派发双向绑定与变更事件
  emit('update:modelValue', value);
  emit('change', value);
};

const handleWheel = (e: WheelEvent) => {
  const scrollbar = scrollbarRef.value;
  if (scrollbar) {
    const delta = e.deltaY || e.detail;
    scrollbar.scrollBy({ left: delta });
  }
};

defineExpose({
  scrollbarRef
});
</script>

<style scoped lang="scss">
.category-btn {
  -webkit-tap-highlight-color: transparent;
  touch-action: manipulation;
  transition:
    transform 0.15s cubic-bezier(0.4, 0, 0.2, 1),
    background-color 0.12s ease,
    color 0.12s ease,
    box-shadow 0.15s ease;

  // 仅在真实支持鼠标 hover 的桌面设备上启用 hover 样式，彻底杜绝 iOS/移动端需要点两下才能触发 click 的 bug
  @media (hover: hover) and (pointer: fine) {
    &:not(.is-active):hover {
      @apply bg-gray-200 dark:bg-neutral-700 text-neutral-900 dark:text-white;
    }
  }
}
</style>
