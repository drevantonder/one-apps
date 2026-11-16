// Fake AI providers for AI Usage's test: Claude's, Codex's and OpenCode Go's usage endpoints on one port of this
// machine, each answering by the token it's sent, as the real ones answer by account. `/seen` says how many reads
// each path has had. It prints its port once it's listening.
const now = Date.now()
const hours = (n) => new Date(now + n * 3_600_000).toISOString()
const MARKER = process.env.MARKER

const claude = {
  [`${MARKER}-claude-1`]: {
    five_hour: { utilization: 62, resets_at: hours(2.5) },
    seven_day: { utilization: 35, resets_at: hours(80) },
    seven_day_opus: { utilization: 88, resets_at: hours(80) },
    seven_day_sonnet: { utilization: 20, resets_at: hours(80) },
    extra_usage: { used_credits: 4, monthly_limit: 50 },
  },
  [`${MARKER}-claude-2`]: {
    five_hour: { utilization: 100, resets_at: hours(1) },
    seven_day: { utilization: 71, resets_at: hours(30) },
  },
}
const responses = {
  "/api/oauth/usage": (token) => claude[token],
  "/backend-api/wham/usage": (token) =>
    token === `${MARKER}-codex` && {
      plan_type: "plus",
      rate_limit: {
        primary_window: { used_percent: 10, reset_at: Math.round(now / 1000) + 4 * 3600 },
        secondary_window: { used_percent: 81, reset_at: Math.round(now / 1000) + 5 * 86400 },
      },
    },
  "/zen/go/v1/usage": (token) =>
    token === `${MARKER}-opencode` && {
      usage: {
        rolling: { percent: 5, resetsAt: hours(3) },
        weekly: { percent: 40, resetsAt: hours(100) },
        monthly: { percent: 12, resetsAt: hours(400) },
      },
    },
}
const seen = {}

const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  fetch(request) {
    const { pathname } = new URL(request.url)
    if (pathname === "/seen") return Response.json(seen)
    const response = responses[pathname]
    if (!response) return new Response("not here", { status: 404 })
    seen[pathname] = (seen[pathname] || 0) + 1
    const token = (request.headers.get("authorization") || "").replace(/^Bearer /, "")
    const body = response(token)
    return body ? Response.json(body) : new Response("who are you?", { status: 401 })
  },
})
console.log(server.port)
