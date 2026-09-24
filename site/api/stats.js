// Edge Function — lecture des compteurs de téléchargement (agrégés, publics).
// `?day=YYYY-MM-DD` ajoute les compteurs du jour. Le pied de page ne lit que
// `mac` ; les autres servent à suivre.

export const config = { runtime: 'edge' }

const PLATFORMS = ['mac', 'ios', 'linux']
const KV_TIMEOUT_MS = 800

export default async function handler(request) {
    const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL
    const token =
        process.env.KV_REST_API_READ_ONLY_TOKEN ||
        process.env.KV_REST_API_TOKEN ||
        process.env.UPSTASH_REDIS_REST_READ_ONLY_TOKEN ||
        process.env.UPSTASH_REDIS_REST_TOKEN

    const day = new URL(request.url).searchParams.get('day')
    const dayValid = day && /^\d{4}-\d{2}-\d{2}$/.test(day)
    const keys = PLATFORMS.map((p) => `corr:dl:${p}`)
    if (dayValid) keys.push(...PLATFORMS.map((p) => `corr:dl:${day}:${p}`))

    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), KV_TIMEOUT_MS)
    try {
        if (!url || !token) throw new Error('KV non configuré')
        const res = await fetch(`${url}/mget/${keys.map(encodeURIComponent).join('/')}`, {
            headers: { Authorization: `Bearer ${token}` },
            signal: ctrl.signal,
        })
        const vals = ((await res.json()).result ?? []).map((v) => parseInt(v ?? 0, 10) || 0)
        const payload = Object.fromEntries(PLATFORMS.map((p, i) => [p, vals[i]]))
        payload.total = PLATFORMS.reduce((s, _, i) => s + vals[i], 0)
        if (dayValid) payload.day = { date: day, ...Object.fromEntries(PLATFORMS.map((p, i) => [p, vals[3 + i]])) }
        return Response.json(payload, { headers: { 'Cache-Control': 'public, max-age=60' } })
    } catch {
        return Response.json({ error: 'kv_unavailable' }, { status: 503, headers: { 'Cache-Control': 'no-store' } })
    } finally {
        clearTimeout(timer)
    }
}
