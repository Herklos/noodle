import { Container, getContainer } from '@cloudflare/containers'

export interface Env {
  PUSH_CONTAINER: DurableObjectNamespace<PushContainer>
  // Secrets, set by the deploy workflow from the push-production environment.
  APNS_KEY_P8: string
  APNS_KEY_ID: string
  PUSH_SEAL_KEY: string
  // Plain vars from wrangler.toml.
  APNS_TEAM_ID: string
  APNS_TOPIC: string
}

// Push keeps its rate limits and recent call IDs in memory, so every request goes to one instance.
const INSTANCE = 'push'

export class PushContainer extends Container<Env> {
  // The port NoodlePush listens on.
  defaultPort = 8080

  // Longer than the cron's 5 minutes, so the pings keep the instance and its APNs key warm.
  sleepAfter = '15m'

  // The server reads its configuration from the environment (PushConfiguration in PushCore).
  // A field, not a getter: the base constructor sets this.env before field initializers run.
  envVars: Record<string, string> = {
    APNS_KEY_P8: this.env.APNS_KEY_P8,
    APNS_KEY_ID: this.env.APNS_KEY_ID,
    PUSH_SEAL_KEY: this.env.PUSH_SEAL_KEY,
    APNS_TEAM_ID: this.env.APNS_TEAM_ID,
    APNS_TOPIC: this.env.APNS_TOPIC,
    PORT: '8080',
  }
}

const ROUTES = new Set(['GET /healthz', 'POST /v1/register', 'POST /v1/ring'])

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    if (!ROUTES.has(`${request.method} ${url.pathname}`)) {
      return new Response('Not found', { status: 404 })
    }
    // The caller's address, for the per-address limit on /v1/register. Set here, so clients cannot.
    const headers = new Headers(request.headers)
    headers.set('X-Noodle-Client-IP', request.headers.get('CF-Connecting-IP') ?? 'unknown')
    const forwarded = new Request(request, { headers })
    return getContainer(env.PUSH_CONTAINER, INSTANCE).fetch(forwarded)
  },

  // The cron trigger: wakes or keeps the instance, so a ring does not wait for a cold start.
  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(
      getContainer(env.PUSH_CONTAINER, INSTANCE)
        .fetch(new Request('https://push.usenoodle.app/healthz'))
        .then((response) => {
          if (!response.ok) console.error(`Warm-up ping answered ${response.status}`)
        }),
    )
  },
} satisfies ExportedHandler<Env>
