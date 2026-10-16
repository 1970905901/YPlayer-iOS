<template>
  <div
    class="w-32 h-full flex-shrink-0 border-r border-gray-200 dark:border-gray-700 bg-light dark:bg-dark"
  >
    <div
      v-for="section in sections"
      :key="section.id"
      class="px-4 py-2.5 cursor-pointer text-sm transition-colors duration-200 border-l-2"
      :class="[
        currentSection === section.id
          ? 'text-primary dark:text-white bg-gray-50 dark:bg-dark-100 !border-primary font-medium'
          : 'text-gray-600 dark:text-gray-400 border-transparent hover:text-primary hover:dark:text-white hover:bg-gray-50 hover:dark:bg-dark-100 hover:border-gray-300'
      ]"
      @click="handleClick(section.id)"
    >
      {{ section.title }}
    </div>
  </div>
</template>

<script setup lang="ts">
defineOptions({
  name: 'SettingNav'
});

export interface NavSection {
  id: string;
  title: string;
}

interface Props {
  /** 导航项列表 */
  sections: NavSection[];
  /** 当前激活的分组 ID */
  currentSection: string;
}

defineProps<Props>();

const emit = defineEmits<{
  navigate: [sectionId: string];
}>();

const handleClick = (sectionId: string) => {
  emit('navigate', sectionId);
};
</script>
