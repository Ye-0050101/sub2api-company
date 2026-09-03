<template>
  <div class="company-home" :class="{ 'hs-paused': motionPaused }" data-testid="company-home">
    <div class="hs-backdrop" aria-hidden="true"></div>
    <div class="hs-wrap">
      <header class="hs-header">
        <div class="hs-brand">
          <img v-if="siteLogo" :src="siteLogo" :alt="brandName" class="hs-logo" />
          <span v-else class="hs-monogram" aria-hidden="true">HS</span>
          <div class="hs-brand-name">{{ brandName }}<span class="hs-brand-sub">COMPANY WORKSPACE</span></div>
        </div>
        <nav class="hs-nav" :aria-label="t('home.company.navigation')">
          <a v-if="docUrl" class="hs-nav-guide" :href="docUrl" target="_blank" rel="noopener noreferrer">{{ t('home.company.guide') }}</a>
          <button v-else class="hs-nav-guide" type="button" @click="guideOpen = true">{{ t('home.company.guide') }}</button>
          <LocaleSwitcher />
          <button class="hs-icon-button hs-motion-toggle" type="button" :aria-label="motionLabel" :aria-pressed="motionPaused" :title="motionLabel" @click="motionPaused = !motionPaused">
            <Icon v-if="motionPaused" name="play" size="sm" />
            <span v-else class="hs-pause-symbol" aria-hidden="true"></span>
          </button>
          <button class="hs-icon-button" type="button" :aria-label="isDark ? t('home.switchToLight') : t('home.switchToDark')" @click="emit('toggle-theme')">
            <Icon :name="isDark ? 'sun' : 'moon'" size="sm" />
          </button>
          <router-link class="hs-nav-login" :to="destination">{{ actionLabel }}</router-link>
        </nav>
      </header>
      <main>
        <section class="hs-hero">
          <div class="hs-copy">
            <p class="hs-eyebrow">{{ t('home.company.eyebrow') }}</p>
            <h1>{{ t('home.company.headlineFirst') }}<br>{{ t('home.company.headlineSecond') }}<span class="hs-accent">{{ t('home.company.headlineAccent') }}</span></h1>
            <p class="hs-description">{{ description }}</p>
            <div class="hs-actions">
              <router-link class="hs-primary" :to="destination">{{ actionLabel }}<Icon name="arrowRight" size="sm" /></router-link>
              <a v-if="docUrl" class="hs-secondary" :href="docUrl" target="_blank" rel="noopener noreferrer">{{ t('home.company.viewGuide') }}<Icon name="externalLink" size="sm" /></a>
              <button v-else class="hs-secondary" type="button" @click="guideOpen = true">{{ t('home.company.viewGuide') }}<Icon name="externalLink" size="sm" /></button>
            </div>
            <div class="hs-private-note"><Icon name="users" size="sm" />{{ t('home.company.authorizedMembers') }}</div>
          </div>
          <div class="hs-scene" role="img" :aria-label="t('home.company.sceneDescription')">
            <div class="hs-ground"></div>
            <div class="hs-orbit"><div class="hs-orbit-spin"></div></div>
            <div class="hs-orbit hs-orbit-inner"><div class="hs-orbit-spin"></div></div>
            <div class="hs-stack"><div class="hs-layer hs-layer-bottom"></div><div class="hs-layer hs-layer-middle"></div><div class="hs-layer hs-layer-top"><Icon name="shield" size="xl" /></div></div>
            <div class="hs-label hs-label-left"><Icon name="userCircle" size="sm" /><div>{{ t('home.company.identity') }}<span class="hs-label-small">IDENTITY &amp; ACCESS</span></div></div>
            <div class="hs-label hs-label-right"><Icon name="server" size="sm" /><div>{{ t('home.company.routing') }}<span class="hs-label-small">MANAGED ROUTING</span></div></div>
            <div class="hs-scene-caption">{{ t('home.company.sceneCaption') }}</div>
          </div>
        </section>
        <section class="hs-features" :aria-label="t('home.company.featuresLabel')">
          <article v-for="feature in features" :key="feature.key" class="hs-feature">
            <div class="hs-feature-heading"><span class="hs-feature-icon"><Icon :name="feature.icon" size="sm" /></span><span class="hs-feature-number">{{ feature.index }}</span></div>
            <h2>{{ t(`home.company.${feature.key}Title`) }}</h2><p>{{ t(`home.company.${feature.key}Description`) }}</p>
          </article>
        </section>
      </main>
      <footer class="hs-footer">
        <p>{{ t('home.company.footer') }}</p>
        <CompanyVersionBadge :version="version" />
      </footer>
    </div>
    <BaseDialog :show="guideOpen" :title="t('home.company.guideTitle')" width="narrow" @close="guideOpen = false">
      <ol class="space-y-4 text-sm leading-relaxed text-gray-600 dark:text-dark-300">
        <li v-for="step in [1, 2, 3]" :key="step" class="flex items-start gap-3"><span class="font-mono text-primary-600 dark:text-primary-400">0{{ step }}</span><span>{{ t(`home.company.guideStep${step}`) }}</span></li>
      </ol>
      <template #footer><button type="button" class="btn btn-secondary" @click="guideOpen = false">{{ t('common.close') }}</button></template>
    </BaseDialog>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import BaseDialog from '@/components/common/BaseDialog.vue'
import CompanyVersionBadge from '@/components/common/CompanyVersionBadge.vue'
import LocaleSwitcher from '@/components/common/LocaleSwitcher.vue'
import Icon from '@/components/icons/Icon.vue'

const props = defineProps<{
  siteName: string
  siteLogo: string
  siteSubtitle: string
  docUrl: string
  version: string
  isAuthenticated: boolean
  dashboardPath: string
  isDark: boolean
}>()
const emit = defineEmits<{ (event: 'toggle-theme'): void }>()
const { t } = useI18n()
const guideOpen = ref(false)
const motionPaused = ref(false)
const motionLabel = computed(() => t(motionPaused.value ? 'home.company.playMotion' : 'home.company.pauseMotion'))
const destination = computed(() => props.isAuthenticated ? props.dashboardPath : '/login')
const actionLabel = computed(() => t(props.isAuthenticated ? 'home.goToDashboard' : 'home.company.employeeLogin'))
// Honor saved administrator branding; only replace upstream default placeholders.
const brandName = computed(() => props.siteName && props.siteName !== 'Sub2API' ? props.siteName : t('home.company.siteName'))
const defaultSubtitles = ['', 'AI API Gateway Platform', 'Subscription to API Conversion Platform']
const description = computed(() => defaultSubtitles.includes(props.siteSubtitle) ? t('home.company.description') : props.siteSubtitle)
const features = [
  { key: 'access', icon: 'key', index: '01 / ACCESS' },
  { key: 'control', icon: 'shield', index: '02 / CONTROL' },
  { key: 'visibility', icon: 'clipboard', index: '03 / VISIBILITY' }
] as const
</script>

<style scoped>
.company-home {
  --hs-bg: #f6f9f8; --hs-surface: #ffffff; --hs-ink: #132b32; --hs-muted: #586f74;
  --hs-line: #dce6e4; --hs-teal: #007e75; --hs-tint: #e7f5ef; --hs-button: #153a3e;
  --hs-button-text: #ffffff; --hs-grid: #153a3e04; --hs-glow: #aae6d887; --hs-glow-secondary: #d8e9f279;
  --hs-shadow: #235a5a13; --hs-orbit: #82aaa778; --hs-orbit-inner: #a4c4bf80;
  --hs-layer-border: #c7e5df; --hs-bottom-a: #d4eee5; --hs-bottom-b: #b5d9d3;
  --hs-middle-a: #ecf9f3; --hs-middle-b: #c9e8e2; --hs-top-a: #ffffff; --hs-top-b: #ecf7f3; --hs-sheen: #ffffffd0;
  color: var(--hs-ink); background: var(--hs-bg); font-family: Inter, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
  position: relative; isolation: isolate; overflow: clip; min-height: 100vh; min-width: 0;
}
:global(.dark .company-home) {
  --hs-bg: #101c20; --hs-surface: #17272d; --hs-ink: #eaf6f5; --hs-muted: #a4bbbf;
  --hs-line: #2a4248; --hs-teal: #5ae2ca; --hs-tint: #173c37; --hs-button: #8ee7d8;
  --hs-button-text: #0e2829; --hs-grid: #ffffff03; --hs-glow: #1c756d5c; --hs-glow-secondary: #2145513d;
  --hs-shadow: #00000027; --hs-orbit: #66b5a934; --hs-orbit-inner: #79c8ba25;
  --hs-layer-border: #47766f; --hs-bottom-a: #284b43; --hs-bottom-b: #1c3c40;
  --hs-middle-a: #42675c; --hs-middle-b: #254e50; --hs-top-a: #254d49; --hs-top-b: #193d3b; --hs-sheen: #91ffdb1f;
}
.company-home * { box-sizing: border-box; }
.company-home button, .company-home a { -webkit-tap-highlight-color: transparent; }
.company-home button:focus-visible, .company-home a:focus-visible { outline: 2px solid var(--hs-teal); outline-offset: 4px; }
.hs-backdrop { position: absolute; inset: 0; z-index: -1; pointer-events: none; overflow: hidden; background-image: linear-gradient(var(--hs-grid) 1px, transparent 1px), linear-gradient(90deg, var(--hs-grid) 1px, transparent 1px); background-size: 54px 54px; }
.hs-backdrop::before, .hs-backdrop::after { content: ''; position: absolute; border-radius: 50%; }
.hs-backdrop::before { top: 0; right: -90px; width: 650px; height: 640px; background: radial-gradient(ellipse, var(--hs-glow), transparent 66%); animation: hs-atmosphere 14s ease-in-out infinite alternate; }
.hs-backdrop::after { top: 360px; left: -100px; width: 400px; height: 380px; background: radial-gradient(ellipse, var(--hs-glow-secondary), transparent 66%); animation: hs-atmosphere 17s ease-in-out infinite alternate-reverse; }
.hs-wrap { max-width: 1240px; margin: auto; padding: 0 48px; }
.hs-header { min-height: 88px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--hs-line); gap: 20px; }
.hs-brand { display: flex; align-items: center; gap: 12px; min-width: 0; }
.hs-monogram { width: 38px; height: 38px; flex-shrink: 0; background: var(--hs-button); color: var(--hs-button-text); border-radius: 12px; display: grid; place-items: center; font-size: 15px; font-weight: 600; letter-spacing: -1px; }
.hs-logo { width: 38px; height: 38px; object-fit: contain; flex-shrink: 0; }
.hs-brand-name { font-size: 17px; font-weight: 600; letter-spacing: .2px; overflow-wrap: anywhere; }
.hs-brand-sub { display: block; color: var(--hs-muted); font-size: 10px; letter-spacing: 1.8px; margin-top: 3px; }
.hs-nav { display: flex; align-items: center; justify-content: flex-end; flex-wrap: wrap; gap: 14px; flex-shrink: 0; }
.hs-nav-guide { color: var(--hs-muted); background: transparent; border: 0; padding: 9px 0; font-size: 12px; }
.hs-nav-guide:hover { color: var(--hs-teal); }
.hs-icon-button { display: flex; align-items: center; justify-content: center; width: 34px; height: 34px; border: 1px solid var(--hs-line); background: var(--hs-surface); border-radius: 50%; color: var(--hs-muted); }
.hs-pause-symbol { width: 9px; height: 12px; border-left: 2px solid currentColor; border-right: 2px solid currentColor; }
.hs-nav-login { font-size: 12px; border: 1px solid var(--hs-line); border-radius: 8px; background: var(--hs-surface); padding: 9px 16px; color: var(--hs-ink); }
.hs-hero { display: grid; grid-template-columns: 1.06fr 1fr; align-items: center; gap: 12px; min-height: 550px; padding: 54px 0 44px; }
.hs-copy { position: relative; z-index: 2; min-width: 0; }
.hs-eyebrow { display: flex; align-items: center; gap: 8px; color: var(--hs-teal); font-size: 11px; letter-spacing: 1.4px; margin: 0 0 22px; animation: hs-enter .8s .05s both; }
.hs-eyebrow::before { content: ''; width: 19px; height: 2px; background: var(--hs-teal); flex-shrink: 0; }
h1 { font-size: clamp(36px, 4.6vw, 64px); font-weight: 600; line-height: 1.25; letter-spacing: -2px; margin: 0 0 24px; animation: hs-enter .85s .15s both; overflow-wrap: anywhere; }
.hs-accent { display: inline-block; color: var(--hs-teal); position: relative; }
.hs-accent::after { content: ''; position: absolute; bottom: -6px; left: 0; right: 0; height: 2px; background: linear-gradient(90deg, var(--hs-teal), transparent); transform-origin: left; animation: hs-underline 1.1s .7s both; }
.hs-description { max-width: 390px; color: var(--hs-muted); font-size: 14px; line-height: 1.9; margin: 0 0 29px; white-space: pre-line; overflow-wrap: anywhere; animation: hs-enter .85s .25s both; }
.hs-actions { display: flex; align-items: center; flex-wrap: wrap; gap: 20px; animation: hs-enter .85s .35s both; }
.hs-primary { display: inline-flex; gap: 24px; align-items: center; background: var(--hs-button); color: var(--hs-button-text); border: 0; border-radius: 10px; padding: 16px 23px; font-size: 14px; box-shadow: 0 7px 20px var(--hs-shadow); transition: transform .22s, box-shadow .22s; }
.hs-primary svg { transition: transform .25s; }
.hs-primary:hover { transform: translateY(-3px); box-shadow: 0 12px 26px var(--hs-shadow); }
.hs-primary:hover svg { transform: translateX(4px); }
.hs-secondary { display: flex; gap: 5px; align-items: center; border: 0; background: transparent; color: var(--hs-muted); padding: 12px 0; font-size: 12px; }
.hs-private-note { display: flex; align-items: center; gap: 7px; font-size: 11px; color: var(--hs-muted); margin-top: 23px; animation: hs-enter .85s .45s both; }
.hs-scene { height: 390px; position: relative; perspective: 900px; overflow: clip; animation: hs-enter 1.1s .2s both; }
.hs-ground { position: absolute; width: 270px; height: 105px; border-radius: 50%; top: 253px; left: 50%; transform: translateX(-50%); background: radial-gradient(ellipse, var(--hs-shadow), transparent 68%); filter: blur(17px); animation: hs-shadow 7s ease-in-out infinite; }
.hs-orbit { position: absolute; left: 50%; top: 51%; border: 1px solid var(--hs-orbit); border-radius: 50%; width: 360px; height: 360px; transform: translate(-50%, -50%) rotateX(61deg) rotateZ(-23deg); }
.hs-orbit-inner { width: 300px; height: 300px; transform: translate(-50%, -50%) rotateX(61deg) rotateZ(14deg); border-style: dashed; border-color: var(--hs-orbit-inner); }
.hs-orbit-spin { position: absolute; inset: -1px; border-radius: 50%; animation: hs-orbit 16s linear infinite; }
.hs-orbit-spin::before { content: ''; position: absolute; width: 8px; height: 8px; top: 50%; left: -4px; border-radius: 50%; background: var(--hs-teal); box-shadow: 0 0 14px var(--hs-teal); }
.hs-orbit-inner .hs-orbit-spin { animation-duration: 23s; animation-direction: reverse; }
.hs-orbit-inner .hs-orbit-spin::before { width: 5px; height: 5px; opacity: .6; }
.hs-stack { position: absolute; left: 50%; top: 46%; width: 215px; height: 215px; transform: translate(-50%, -50%); animation: hs-float 7s ease-in-out infinite; }
.hs-layer { position: absolute; inset: 0; border-radius: 35px; transform: rotateX(51deg) rotateZ(-35deg); border: 1px solid var(--hs-layer-border); box-shadow: 0 18px 35px var(--hs-shadow); }
.hs-layer-bottom { top: 50px; bottom: -50px; background: linear-gradient(135deg, var(--hs-bottom-a), var(--hs-bottom-b)); opacity: .85; }
.hs-layer-middle { top: 25px; bottom: -25px; background: linear-gradient(135deg, var(--hs-middle-a), var(--hs-middle-b)); opacity: .92; }
.hs-layer-top { background: linear-gradient(140deg, var(--hs-top-a), var(--hs-top-b)); overflow: hidden; display: grid; place-items: center; }
.hs-layer-top::after { content: ''; position: absolute; inset: -100%; background: linear-gradient(115deg, transparent 41%, var(--hs-sheen) 50%, transparent 58%); animation: hs-sheen 7s ease-in-out infinite; }
.hs-layer-top svg { width: 72px; height: 72px; color: var(--hs-teal); stroke-width: 1.15; }
.hs-label { position: absolute; display: flex; align-items: center; gap: 9px; padding: 12px 14px; border: 1px solid var(--hs-line); border-radius: 11px; background: var(--hs-surface); box-shadow: 0 8px 24px var(--hs-shadow); font-size: 11px; z-index: 3; }
.hs-label svg { color: var(--hs-teal); flex-shrink: 0; }
.hs-label-left { top: 49px; left: 3px; animation: hs-label-float 8s ease-in-out infinite; }
.hs-label-right { top: 240px; right: 1px; animation: hs-label-float 8s -3s ease-in-out infinite; }
.hs-label-small { font-size: 9px; letter-spacing: 1px; color: var(--hs-muted); display: block; margin-top: 2px; }
.hs-scene-caption { position: absolute; bottom: 13px; left: 0; right: 0; text-align: center; color: var(--hs-muted); font-size: 10px; letter-spacing: 3px; }
.hs-features { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); border-top: 1px solid var(--hs-line); border-bottom: 1px solid var(--hs-line); padding: 30px 0; margin: 0 0 30px; animation: hs-enter .9s .5s both; }
.hs-feature { padding: 0 23px; position: relative; transition: transform .25s; }
.hs-feature:first-child { padding-left: 0; }
.hs-feature:last-child { padding-right: 0; }
.hs-feature + .hs-feature { border-left: 1px solid var(--hs-line); }
.hs-feature:hover { transform: translateY(-4px); }
.hs-feature-heading { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
.hs-feature-icon { width: 32px; height: 32px; display: grid; place-items: center; background: var(--hs-tint); border-radius: 9px; color: var(--hs-teal); }
.hs-feature-number { font-size: 10px; color: var(--hs-muted); letter-spacing: 1px; opacity: .65; }
.hs-feature h2 { font-size: 15px; font-weight: 500; line-height: 1.5; margin: 0 0 7px; }
.hs-feature p { font-size: 12px; line-height: 1.85; color: var(--hs-muted); margin: 0; white-space: pre-line; }
.hs-footer { display: flex; justify-content: space-between; flex-wrap: wrap; gap: 18px; align-items: center; padding: 0 0 30px; font-size: 11px; color: var(--hs-muted); line-height: 1.8; }
.hs-footer p { margin: 0; }
.hs-paused *, .hs-paused *::before, .hs-paused *::after { animation-play-state: paused !important; }
@keyframes hs-enter { from { opacity: 0; transform: translateY(15px); } to { opacity: 1; transform: translateY(0); } }
@keyframes hs-underline { from { transform: scaleX(0); } to { transform: scaleX(1); } }
@keyframes hs-atmosphere { from { transform: translate(-15px, -10px) scale(.92); } to { transform: translate(45px, 40px) scale(1.12); } }
@keyframes hs-orbit { to { transform: rotate(360deg); } }
@keyframes hs-float { 0%, 100% { transform: translate(-50%, -50%) translateY(0); } 50% { transform: translate(-50%, -50%) translateY(-13px); } }
@keyframes hs-shadow { 0%, 100% { opacity: .8; scale: 1; } 50% { opacity: .5; scale: .86; } }
@keyframes hs-label-float { 0%, 100% { transform: translateY(0); } 50% { transform: translateY(-7px); } }
@keyframes hs-sheen { 0%, 20% { transform: translateX(-45%); } 65%, 100% { transform: translateX(45%); } }
@media (max-width: 900px) {
  .hs-wrap { padding: 0 32px; } .hs-nav { gap: 9px; } .hs-nav-guide { display: none; }
  .hs-hero { min-height: 440px; gap: 5px; } h1 { font-size: 44px; }
  .hs-description { font-size: 13px; max-width: 290px; } .hs-scene { height: 340px; }
  .hs-stack { width: 155px; height: 155px; } .hs-orbit { width: 270px; height: 270px; }
  .hs-orbit-inner { width: 220px; height: 220px; } .hs-label { padding: 10px; font-size: 10px; }
  .hs-label-left { top: 46px; } .hs-label-right { top: 220px; } .hs-ground { top: 220px; width: 220px; }
  .hs-actions { gap: 13px; } .hs-primary { padding: 14px 18px; gap: 15px; } .hs-feature { padding: 0 17px; }
}
@media (max-width: 680px) {
  .hs-wrap { padding: 0 24px; } .hs-header { min-height: 80px; flex-wrap: wrap; padding: 14px 0; gap: 12px; }
  .hs-brand-name { font-size: 14px; } .hs-brand-sub { font-size: 8px; letter-spacing: 1.3px; }
  .hs-nav { flex-shrink: 1; gap: 10px; } .hs-nav-login { display: none; }
  .hs-monogram, .hs-logo { width: 33px; height: 33px; font-size: 13px; border-radius: 10px; }
  .hs-hero { grid-template-columns: 1fr; gap: 8px; padding-top: 36px; padding-bottom: 17px; }
  h1 { font-size: clamp(36px, 9vw, 46px); line-height: 1.25; letter-spacing: -1.5px; }
  .hs-eyebrow { margin-bottom: 20px; font-size: 10px; }
  .hs-description { font-size: 13px; max-width: 340px; margin-bottom: 22px; }
  .hs-scene { height: 310px; max-width: 370px; width: 100%; margin: 0 auto; }
  .hs-stack { width: 166px; height: 166px; } .hs-orbit { width: 284px; height: 284px; }
  .hs-orbit-inner { width: 238px; height: 238px; } .hs-label-left { top: 35px; }
  .hs-label-right { top: 198px; } .hs-ground { top: 195px; } .hs-scene-caption { bottom: 4px; }
  .hs-features { grid-template-columns: 1fr; padding: 6px 0; margin-bottom: 23px; }
  .hs-feature, .hs-feature:first-child, .hs-feature:last-child { padding: 22px 0; }
  .hs-feature + .hs-feature { border-left: 0; border-top: 1px solid var(--hs-line); }
  .hs-feature-heading { float: left; margin: 2px 15px 0 0; } .hs-feature-number { display: none; }
  .hs-feature h2 { font-size: 14px; } .hs-feature p { margin-left: 47px; font-size: 12px; }
  .hs-footer { padding-bottom: 23px; }
}
@media (pointer: coarse) { .hs-icon-button { width: 44px; height: 44px; } }
@media (prefers-reduced-motion: reduce) {
  .company-home *, .company-home *::before, .company-home *::after { animation: none !important; transition: none !important; }
  .hs-motion-toggle { display: none; }
}
</style>
