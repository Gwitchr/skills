// nazgul for Oh My Pi, installed by nazgul's install.sh as ~/.omp/agent/hooks/post/nazgul.ts.
// omp loads every file in that folder as an extension in every session. check.sh exits at once in a
// repo that is not enrolled, so outside enrolled repos this hook does nothing.
//
// agent_end cannot block, so this hook starts check.sh detached. check.sh pushes a report built from
// git and the agent's last message, then polls the session's thread in the background. A reply goes
// to an inbox file under <git common dir>/nazgul/inbox/. The first line is `nazgul-deliver: show`
// or `nazgul-deliver: inject`. show is notified and not added to the agent's context. inject (only
// when auto_continue is on and the reply passed the author check) is shown and added to the context
// while the session is idle, at session start, or at the next prompt. Anything else is show.
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

// nazgul's scripts folder, an absolute path filled in by install.sh.
const SCRIPTS = "__NAZGUL_SH__";

type Message = { role?: string; content?: unknown };

function lastAssistantText(messages: unknown[]): string {
	for (let i = messages.length - 1; i >= 0; i--) {
		const m = messages[i] as Message;
		if (m?.role !== "assistant") continue;
		if (typeof m.content === "string") return m.content;
		if (Array.isArray(m.content)) {
			return m.content
				.filter((c: { type?: string }) => c?.type === "text")
				.map((c: { text?: string }) => c.text ?? "")
				.join("\n");
		}
	}
	return "";
}

export default function nazgul(pi: ExtensionAPI): void {
	let root: string | undefined;
	let common: string | undefined;

	const locate = async (ctx: ExtensionContext): Promise<boolean> => {
		if (root && common) return true;
		try {
			const top = await pi.exec("git", ["rev-parse", "--show-toplevel"], { cwd: ctx.cwd, timeout: 5000 });
			const dir = await pi.exec("git", ["rev-parse", "--git-common-dir"], { cwd: ctx.cwd, timeout: 5000 });
			if (top.code !== 0 || dir.code !== 0) return false;
			root = top.stdout.trim();
			common = path.resolve(ctx.cwd, dir.stdout.trim());
			return true;
		} catch {
			return false; // not a git repo: nazgul stays off
		}
	};

	const inboxPath = (ctx: ExtensionContext): string | undefined => {
		if (!common) return undefined;
		const id = (ctx.sessionManager.getSessionId() || "omp").replace(/[^A-Za-z0-9_-]/g, "-").slice(0, 80);
		return path.join(common, "nazgul", "inbox", `${id}.md`);
	};

	// Claims the inbox by rename first, so a write from check.sh is never lost between read and delete.
	const takeInbox = (ctx: ExtensionContext): string | undefined => {
		const inbox = inboxPath(ctx);
		if (!inbox) return undefined;
		const claimed = `${inbox}.${process.pid}.reading`;
		try {
			fs.renameSync(inbox, claimed);
		} catch {
			return undefined;
		}
		try {
			return fs.readFileSync(claimed, "utf8").trim() || undefined;
		} finally {
			fs.rmSync(claimed, { force: true });
		}
	};

	const surface = (ctx: ExtensionContext): void => {
		const raw = takeInbox(ctx);
		if (!raw) return;
		const nl = raw.indexOf("\n");
		const first = nl === -1 ? raw : raw.slice(0, nl);
		let mode: "show" | "inject" = "show";
		let text = raw;
		if (first === "nazgul-deliver: inject") {
			mode = "inject";
			text = raw.slice(nl + 1).trim();
		} else if (first === "nazgul-deliver: show") {
			text = raw.slice(nl + 1).trim();
		}
		if (!text) return;
		ctx.ui.notify(text, "info");
		if (mode === "inject") pi.sendMessage({ customType: "nazgul", content: text, display: true });
	};

	pi.on("agent_end", async (event, ctx) => {
		if (event.willContinue || ctx.agent.kind !== "main") return;
		if (!(await locate(ctx)) || !root) return;
		const script = path.join(SCRIPTS, "check.sh");
		const inbox = inboxPath(ctx);
		if (!inbox || !fs.existsSync(script)) return;
		const payload = path.join(os.tmpdir(), `nazgul-omp-${process.pid}-${Date.now()}.json`);
		try {
			fs.writeFileSync(
				payload,
				JSON.stringify({
					session_id: ctx.sessionManager.getSessionId(),
					cwd: ctx.cwd,
					last_assistant_message: lastAssistantText(event.messages ?? []),
				}),
				{ mode: 0o600 },
			);
			Bun.spawn({
				cmd: ["bash", script, "--agent", "omp", "--background", "--payload", payload, "--inbox", inbox],
				cwd: ctx.cwd,
				detached: true,
				stdin: "ignore",
				stdout: "ignore",
				stderr: "ignore",
			}).unref();
		} catch {
			fs.rmSync(payload, { force: true });
		}
	});

	pi.on("session_start", async (_event, ctx) => {
		if (ctx.agent.kind !== "main" || !(await locate(ctx))) return;
		surface(ctx);
		ctx.setInterval(() => {
			if (ctx.isIdle()) surface(ctx);
		}, 15_000);
	});

	pi.on("input", async (_event, ctx) => {
		if (await locate(ctx)) surface(ctx);
	});
}
