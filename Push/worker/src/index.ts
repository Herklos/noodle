import { Container, getContainer } from '@cloudflare/containers'

export interface Env {
  PUSH_CONTAINER: DurableObjectNamespace<PushContainer>
  // Rate limits per client address at Cloudflare's edge ([[ratelimits]] in wrangler.toml).
  REGISTER_LIMITER: RateLimit
  RING_LIMITER: RateLimit
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

// What a limited client gets back: the same bodies the server answers its own 429s with.
const LIMITED: Record<string, { limiter: (env: Env) => RateLimit; body: object }> = {
  'POST /v1/register': { limiter: (env) => env.REGISTER_LIMITER, body: { error: 'rateLimited' } },
  'POST /v1/ring': { limiter: (env) => env.RING_LIMITER, body: { outcome: 'rateLimited', reason: 'addressLimit' } },
}

// The key an address is limited under: an IPv4 address as it is, an IPv6 address by its /64 (one
// subscriber's allocation, inside which addresses are free to change), and IPv4-mapped IPv6 as IPv4.
// The server groups addresses the same way (PushService.clientAddress).
function clientKey(address: string): string {
  const text = address.trim()
  const bytes = ipv4(text)
  if (bytes) return bytes.join('.')
  const groups = ipv6(text)
  if (!groups) return text.slice(0, 64)
  if (groups.slice(0, 5).every((group) => group === 0) && groups[5] === 0xffff) {
    return [groups[6] >> 8, groups[6] & 0xff, groups[7] >> 8, groups[7] & 0xff].join('.')
  }
  return `${groups.slice(0, 4).map((group) => group.toString(16)).join(':')}::/64`
}

function ipv4(text: string): number[] | undefined {
  const parts = text.split('.')
  if (parts.length !== 4 || !parts.every((part) => /^[0-9]{1,3}$/.test(part) && Number(part) <= 255)) return undefined
  return parts.map(Number)
}

function ipv6(address: string): number[] | undefined {
  const text = address.split('%')[0]
  if (!text.includes(':')) return undefined
  const groups = (part: string): number[] | undefined => {
    if (part === '') return []
    const pieces = part.split(':')
    const result: number[] = []
    for (const [index, piece] of pieces.entries()) {
      if (index === pieces.length - 1 && piece.includes('.')) {
        const bytes = ipv4(piece)
        if (!bytes) return undefined
        result.push((bytes[0] << 8) | bytes[1], (bytes[2] << 8) | bytes[3])
      } else {
        if (!/^[0-9a-fA-F]{1,4}$/.test(piece)) return undefined
        result.push(parseInt(piece, 16))
      }
    }
    return result
  }
  const gap = text.indexOf('::')
  if (gap < 0) {
    const all = groups(text)
    return all?.length === 8 ? all : undefined
  }
  const rest = text.slice(gap + 2)
  const left = groups(text.slice(0, gap))
  const right = rest.includes('::') ? undefined : groups(rest)
  if (!left || !right || left.length + right.length > 7) return undefined
  return [...left, ...new Array<number>(8 - left.length - right.length).fill(0), ...right]
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    const route = `${request.method} ${url.pathname}`
    if (!ROUTES.has(route)) {
      return new Response('Not found', { status: 404 })
    }
    const address = request.headers.get('CF-Connecting-IP') ?? 'unknown'
    // Abuse is turned away here, before the container parses anything or checks a signature. The edge
    // limit is per Cloudflare location and approximate; the server applies the exact one again.
    const limited = LIMITED[route]
    if (limited) {
      const { success } = await limited.limiter(env).limit({ key: clientKey(address) })
      if (!success) return Response.json(limited.body, { status: 429 })
    }
    // The caller's address, for the server's per-address limits. Set here, so clients cannot.
    const headers = new Headers(request.headers)
    headers.set('X-Noodle-Client-IP', address)
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
