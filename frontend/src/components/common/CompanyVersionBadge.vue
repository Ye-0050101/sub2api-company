<template>
  <button
    type="button"
    class="company-version-trigger"
    :aria-label="`${label}: ${t('version.companyBuildDetails')}`"
    @click="showDetails = true"
  >{{ label }}</button>
  <BaseDialog
    :show="showDetails"
    :title="label"
    width="narrow"
    @close="showDetails = false"
  >
    <div class="space-y-4 text-sm text-gray-700 dark:text-dark-200">
      <p class="font-medium">{{ t('version.companyManagedBuild') }}</p>
      <dl class="space-y-3">
        <div>
          <dt class="text-xs text-gray-500 dark:text-dark-400">{{ t('version.companyUpstreamVersion') }}</dt>
          <dd class="mt-1">v{{ upstreamReleaseVersion }}</dd>
        </div>
        <div>
          <dt class="text-xs text-gray-500 dark:text-dark-400">{{ t('version.companyBuildDetails') }}</dt>
          <dd class="mt-1 select-text break-all font-mono text-xs">{{ version }}</dd>
        </div>
      </dl>
      <p class="text-xs leading-relaxed text-gray-500 dark:text-dark-400">{{ t('version.companyManagedHint') }}</p>
      <button type="button" class="btn btn-secondary text-xs" @click="copyToClipboard(companyVersionDetails(version))">
        <Icon :name="copied ? 'check' : 'copy'" size="sm" />
        {{ copied ? t('common.copied') : t('version.companyCopyVersion') }}
      </button>
    </div>
  </BaseDialog>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import BaseDialog from '@/components/common/BaseDialog.vue'
import Icon from '@/components/icons/Icon.vue'
import { useClipboard } from '@/composables/useClipboard'
import { companyVersionDetails, companyVersionLabel, upstreamReleaseVersion } from '@/utils/companyBuild'

const props = defineProps<{ version: string }>()
const { t } = useI18n()
const showDetails = ref(false)
const label = computed(() => companyVersionLabel(props.version))
const { copied, copyToClipboard } = useClipboard()
</script>

<style scoped>
.company-version-trigger {
  max-width: 100%;
  padding: 4px 8px;
  border-radius: 7px;
  background: #f3f4f6;
  color: #4b5563;
  font-size: 12px;
  line-height: 1.5;
  overflow-wrap: anywhere;
  text-align: left;
}
.company-version-trigger:hover { background: #e5e7eb; }
.company-version-trigger:focus-visible { outline: 2px solid #0d9488; outline-offset: 3px; }
:global(.dark .company-version-trigger) { background: #1f2937; color: #cbd5e1; }
:global(.dark .company-version-trigger:hover) { background: #374151; }
</style>
