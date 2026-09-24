// Edge Function — compteur des liens de téléchargement.
//
// `/mac`, `/linux` et `/ios` y arrivent par les `rewrites` de vercel.json
// (`?p=mac|linux|ios`) : on incrémente un compteur, puis 302 vers le vrai
// fichier (GitHub Releases) ou la fiche App Store. Même modèle que
// souffleuse.app (website/api/download.js).
//
// Aucune IP, aucun cookie, rien de stocké sur la personne : des compteurs
// agrégés, dans l'Upstash de Souffleuse sous le préfixe `corr:`. Le
// User-Agent n'est lu que pour ne pas compter les robots qui suivent les liens.

export const config = { runtime: 'edge' }

const TARGETS = {
    mac: 'https://github.com/menufactory43/correspondance-releases/releases/download/mac-latest/Correspondance.dmg',
    linux: 'https://github.com/menufactory43/correspondance-releases/releases/download/linux-latest/Correspondance-linux-x86_64.tar.gz',
    ios: 'https://apps.apple.com/app/correspondance-une-inbox/id6807945434',
}

// Un store lent ou cassé ne doit jamais retarder un téléchargement.
const KV_TIMEOUT_MS = 800
const BOT_RE = /bot|crawl|spider|slurp|facebookexternalhit|preview|curl|wget|python|headless/i

async function bump(platform) {
    const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL
    const token = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN
    if (!url || !token) return

    const day = new Date().toISOString().slice(0, 10)
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), KV_TIMEOUT_MS)
    try {
        await fetch(`${url}/pipeline`, {
            method: 'POST',
            headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
            body: JSON.stringify([
                ['INCR', `corr:dl:${platform}`],
                ['INCR', `corr:dl:${day}:${platform}`],
            ]),
            signal: ctrl.signal,
        })
    } catch {
        // Le téléchargement prime.
    } finally {
        clearTimeout(timer)
    }
}

export default async function handler(request) {
    const platform = new URL(request.url).searchParams.get('p')
    const target = TARGETS[platform]
    if (!target) return new Response('Not found', { status: 404 })

    const ua = request.headers.get('user-agent') || ''
    if (request.method === 'GET' && ua && !BOT_RE.test(ua)) await bump(platform)

    return new Response(null, {
        status: 302,
        headers: { Location: target, 'Cache-Control': 'no-store' },
    })
}
