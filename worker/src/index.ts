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
	// Identifier for the game this Worker manages. Used as the Hetzner VM name
	// (must be unique within your Hetzner project — pick e.g. "enshrouded",
	// "valheim", "palworld" if running multiple Workers).
	GAME_NAME: string;
	// UDP port the game listens on for player connections — shown in connect
	// info. Enshrouded 15637, Valheim 2456, Palworld 8211.
	GAME_PORT: string;
}

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
	const data = await hetzner(env, `/servers?name=${env.GAME_NAME}`);
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

/**
 * Resolve which Hetzner snapshot to boot from.
 *
 * If HETZNER_SNAPSHOT_ID is set to a numeric ID, use it verbatim (back-compat
 * with deployments that pinned to a specific snapshot).
 *
 * Otherwise — including when set to "auto" or left empty — list the project's
 * snapshots and pick the most recent one whose description starts with
 * `<GAME_NAME>-` (matching the convention from SETUP.md: `enshrouded-v1`,
 * `valheim-v1`, etc.).
 *
 * The auto-discovery path means a new snapshot bake doesn't require redeploying
 * the Worker — the next /start just picks up the latest one.
 */
async function resolveSnapshotId(env: Env): Promise<number> {
	const explicit = env.HETZNER_SNAPSHOT_ID?.trim();
	if (explicit && explicit !== 'auto' && /^\d+$/.test(explicit)) {
		return parseInt(explicit, 10);
	}

	const data = await hetzner(env, '/images?type=snapshot&per_page=50');
	const prefix = `${env.GAME_NAME}-`;
	const matching = (data?.images ?? [])
		.filter((img: any) => typeof img.description === 'string' && img.description.startsWith(prefix))
		.sort((a: any, b: any) => Date.parse(b.created) - Date.parse(a.created));

	if (matching.length === 0) {
		throw new Error(
			`No snapshot found whose description starts with '${prefix}'. ` +
			`Bake a snapshot for ${env.GAME_NAME} (the bake step in SETUP.md does this) ` +
			`or set HETZNER_SNAPSHOT_ID to a specific snapshot ID.`
		);
	}

	return matching[0].id;
}

async function startServerAsync(env: Env, appId: string, token: string): Promise<void> {
	try {
		const existing = await findServer(env);
		if (existing) {
			await patchInteractionMessage(appId, token,
				`Already running at \`${existing.public_net.ipv4.ip}:${env.GAME_PORT}\``);
			return;
		}

		const snapshotId = await resolveSnapshotId(env);

		const body = {
			name: env.GAME_NAME,
			server_type: env.HETZNER_SERVER_TYPE,
			image: snapshotId,
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

		await patchInteractionMessage(appId, token, `🟡 Provisioning ${env.GAME_NAME} server at \`${ip}\`…`);

		let ready = false;
		for (let i = 0; i < 24; i++) {
			await sleep(5000);
			const data = await hetzner(env, `/servers/${serverId}`);
			if (data?.server?.status === 'running') { ready = true; break; }
		}

		if (!ready) {
			await patchInteractionMessage(appId, token,
				`⚠️ Server still provisioning at \`${ip}\` — taking longer than usual. Use the status command to check.`);
			return;
		}

		await patchInteractionMessage(appId, token, `🟡 VM up at \`${ip}\`, ${env.GAME_NAME} booting…`);
		await sleep(35000);

		await patchInteractionMessage(appId, token,
			`🟢 ${env.GAME_NAME} server is live! Connect to \`${ip}:${env.GAME_PORT}\``);
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
	if (!s) return `⚪ No ${env.GAME_NAME} server running.`;
	return `🟢 ${env.GAME_NAME} running at \`${s.public_net.ipv4.ip}:${env.GAME_PORT}\` (${s.status})`;
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
