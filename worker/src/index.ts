import nacl from 'tweetnacl';

interface Env {
	HETZNER_TOKEN: string;
	HETZNER_SNAPSHOT_ID: string;
	HETZNER_VOLUME_ID: string;
	HETZNER_FIREWALL_ID: string;
	HETZNER_SSH_KEY: string;
	HETZNER_LOCATION: string;
	HETZNER_SERVER_TYPE: string;
	DISCORD_PUBLIC_KEY: string;
	WATCHDOG_SECRET: string;
}

const SERVER_NAME = 'enshrouded';
const GAME_PORT = 15637;

async function hetzner(env: Env, path: string, init?: RequestInit): Promise<any> {
	const r = await fetch(`https://api.hetzner.cloud/v1${path}`, {
		...init,
		headers: {
			'Authorization': `Bearer ${env.HETZNER_TOKEN}`,
			'Content-Type': 'application/json',
			...(init?.headers ?? {}),
		},
	});
	if (!r.ok) throw new Error(`Hetzner ${r.status}: ${await r.text()}`);
	if (r.status === 204) return null;
	return r.json();
}

async function findServer(env: Env) {
	const data = await hetzner(env, `/servers?name=${SERVER_NAME}`);
	return data?.servers?.[0] ?? null;
}

function sleep(ms: number): Promise<void> {
	return new Promise(r => setTimeout(r, ms));
}

async function patchInteractionMessage(appId: string, token: string, content: string): Promise<void> {
	await fetch(`https://discord.com/api/v10/webhooks/${appId}/${token}/messages/@original`, {
		method: 'PATCH',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ content }),
	});
}

async function startServerAsync(env: Env, appId: string, token: string): Promise<void> {
	try {
		const existing = await findServer(env);
		if (existing) {
			await patchInteractionMessage(appId, token,
				`Already running at \`${existing.public_net.ipv4.ip}:${GAME_PORT}\``);
			return;
		}

		const body = {
			name: SERVER_NAME,
			server_type: env.HETZNER_SERVER_TYPE,
			image: parseInt(env.HETZNER_SNAPSHOT_ID, 10),
			location: env.HETZNER_LOCATION,
			ssh_keys: [env.HETZNER_SSH_KEY],
			volumes: [parseInt(env.HETZNER_VOLUME_ID, 10)],
			firewalls: [{ firewall: parseInt(env.HETZNER_FIREWALL_ID, 10) }],
			start_after_create: true,
		};
		const created = await hetzner(env, '/servers', {
			method: 'POST',
			body: JSON.stringify(body),
		});
		const ip = created.server.public_net.ipv4.ip;
		const serverId = created.server.id;

		await patchInteractionMessage(appId, token, `🟡 Provisioning server at \`${ip}\`…`);

		let ready = false;
		for (let i = 0; i < 24; i++) {
			await sleep(5000);
			const data = await hetzner(env, `/servers/${serverId}`);
			if (data?.server?.status === 'running') { ready = true; break; }
		}

		if (!ready) {
			await patchInteractionMessage(appId, token,
				`⚠️ Server still provisioning at \`${ip}\` — taking longer than usual. Try \`/enshrouded status\`.`);
			return;
		}

		await patchInteractionMessage(appId, token, `🟡 VM up at \`${ip}\`, game booting…`);
		await sleep(35000);

		await patchInteractionMessage(appId, token,
			`🟢 Server is live! Connect to \`${ip}:${GAME_PORT}\``);
	} catch (e: any) {
		await patchInteractionMessage(appId, token, `❌ ${e.message}`);
	}
}

async function stopServer(env: Env, ctx: ExecutionContext): Promise<string> {
	const s = await findServer(env);
	if (!s) return 'No server running.';

	// Graceful ACPI shutdown — triggers systemd stop, which runs `docker compose down`
	await hetzner(env, `/servers/${s.id}/actions/shutdown`, { method: 'POST' });

	// After we respond to Discord, poll until server is off, then delete
	ctx.waitUntil((async () => {
		for (let i = 0; i < 30; i++) {       // up to 3 minutes
			await new Promise(r => setTimeout(r, 6000));
			const data = await hetzner(env, `/servers/${s.id}`);
			if (data?.server?.status === 'off') break;
		}
		await hetzner(env, `/servers/${s.id}`, { method: 'DELETE' });
	})());

	return '🟡 Graceful shutdown initiated. Saves are flushing — server will be deleted in ~2 minutes.';
}

async function statusServer(env: Env): Promise<string> {
	const s = await findServer(env);
	if (!s) return '⚪ No server running.';
	return `🟢 Running at \`${s.public_net.ipv4.ip}:${GAME_PORT}\` (${s.status})`;
}

function hexToBytes(hex: string): Uint8Array {
	const out = new Uint8Array(hex.length / 2);
	for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
	return out;
}

function verifyDiscord(body: string, sig: string, ts: string, pubKey: string): boolean {
	const msg = new TextEncoder().encode(ts + body);
	return nacl.sign.detached.verify(msg, hexToBytes(sig), hexToBytes(pubKey));
}

export default {
	async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const url = new URL(req.url);

		if (url.pathname === '/api/cleanup' && req.method === 'POST') {
			if (req.headers.get('Authorization') !== `Bearer ${env.WATCHDOG_SECRET}`) {
				return new Response('unauthorized', { status: 401 });
			}
			await stopServer(env, ctx);
			return new Response('ok');
		}

		if (url.pathname === '/discord' && req.method === 'POST') {
			const sig = req.headers.get('X-Signature-Ed25519');
			const ts = req.headers.get('X-Signature-Timestamp');
			const raw = await req.text();
			if (!sig || !ts || !verifyDiscord(raw, sig, ts, env.DISCORD_PUBLIC_KEY)) {
				return new Response('bad signature', { status: 401 });
			}
			const interaction = JSON.parse(raw);
			if (interaction.type === 1) return Response.json({ type: 1 });

			if (interaction.type === 2) {
				const sub = interaction.data?.options?.[0]?.name ?? '';

				if (sub === 'start') {
					ctx.waitUntil(startServerAsync(env, interaction.application_id, interaction.token));
					return Response.json({ type: 5 });
				}

				let content = 'Unknown command';
				try {
					if (sub === 'stop') content = await stopServer(env, ctx);
					if (sub === 'status') content = await statusServer(env);
				} catch (e: any) {
					content = `❌ ${e.message}`;
				}
				return Response.json({ type: 4, data: { content } });
			}
		}

		return new Response('not found', { status: 404 });
	},
};
