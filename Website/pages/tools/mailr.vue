<script setup lang="ts">
// Drop into the slyy.ai Nuxt site as pages/tools/mailr.vue → https://slyy.ai/tools/mailr
const version = '0.1.1'
const tag = `mailr-v${version}`
const dmg = `https://github.com/mySlyy/releases/releases/download/${tag}/slyy-mailr-${version}-mac-universal.dmg`
const notes = `https://github.com/mySlyy/releases/releases/tag/${tag}`

useSeoMeta({
  title: 'Slyy Mailr – mail, calendar and video calls on your own servers',
  description: 'Native Mac and iPhone app for your own IMAP/SMTP mail, CalDAV calendar and Jitsi video calls. A simple Outlook replacement.',
  ogTitle: 'Slyy Mailr',
})

const features = [
  { title: 'Mail on your servers', text: 'IMAP and SMTP with TLS or STARTTLS, push via IDLE, folders, search, drafts that save themselves, attachments. Remote images stay blocked until you allow them.' },
  { title: 'Calendar that talks to Outlook', text: 'CalDAV with day, week and month views, repeating events that keep their time across daylight saving, and invitations that Outlook, Google and Apple accept.' },
  { title: 'One click to a video call', text: 'Every meeting can carry a private Jitsi room on vid.rocket.re-cloud.io. Join from the invite, the calendar or the reminder.' },
  { title: 'Set up in a minute', text: 'Enter email and password; Slyy Mailr finds your mail, calendar and video servers. Your password stays in the Keychain.' },
]
</script>

<template>
  <main class="mailr">
    <section class="hero">
      <p class="eyebrow">Slyy tools</p>
      <h1>Slyy Mailr</h1>
      <p class="lead">Mail, calendar and video calls on your own servers. A simple, native replacement for Outlook on Mac and iPhone.</p>
      <div class="actions">
        <a class="primary" :href="dmg">Download for Mac</a>
        <a class="secondary" :href="notes">Release notes · v{{ version }}</a>
      </div>
      <p class="fine">macOS 14 or newer · Apple Silicon and Intel · iPhone and iPad via TestFlight (coming)</p>
    </section>

    <section class="features" aria-label="Features">
      <article v-for="f in features" :key="f.title">
        <h2>{{ f.title }}</h2>
        <p>{{ f.text }}</p>
      </article>
    </section>

    <section class="install">
      <h2>Install</h2>
      <ol>
        <li>Open the DMG and drag Slyy Mailr to Applications.</li>
        <li>This preview is not notarized yet: on first start, right-click the app and choose Open.</li>
        <li>Sign in with your <code>@slyy.ai</code> address. Servers: <code>imap.slyy.ai</code>, <code>smtp.slyy.ai</code>, <code>dav.slyy.ai</code>.</li>
      </ol>
    </section>
  </main>
</template>

<style scoped>
.mailr { max-width: 1080px; margin: 0 auto; padding: 72px 24px 96px; font-family: 'Hanken Grotesk', system-ui, sans-serif; color: #0a0a0a; }
.eyebrow { font-family: 'Martian Mono', monospace; font-size: 12px; letter-spacing: 0.06em; text-transform: uppercase; color: #2b3bff; margin: 0 0 12px; }
h1 { font-size: clamp(40px, 7vw, 72px); letter-spacing: -0.03em; margin: 0; }
.lead { font-size: 20px; line-height: 1.5; max-width: 640px; color: #3d3d3d; margin: 16px 0 28px; }
.actions { display: flex; flex-wrap: wrap; gap: 12px; }
.actions a { height: 48px; padding: 0 20px; display: inline-flex; align-items: center; font-weight: 600; text-decoration: none; }
.primary { background: #2b3bff; color: #fff; }
.primary:hover { background: #1f2ed0; }
.secondary { border: 1px solid #a3a3a3; color: #0a0a0a; }
.fine { font-size: 13px; color: #5c5c5c; margin-top: 14px; }
.features { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 1px; background: #e2e2e2; border: 1px solid #e2e2e2; margin: 64px 0; }
.features article { background: #fff; padding: 24px; }
.features h2 { font-size: 18px; margin: 0 0 8px; }
.features p { margin: 0; line-height: 1.55; color: #3d3d3d; }
.install h2 { font-size: 24px; margin: 0 0 12px; }
.install ol { line-height: 1.7; padding-left: 20px; }
code { font-family: 'Martian Mono', monospace; font-size: 13px; background: #f4f4f2; padding: 1px 5px; }
</style>
