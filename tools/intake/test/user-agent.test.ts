// Requests to Discogs and Last.fm carry a User-Agent that names the tool and
// its version only: no URL, no account handle, nothing that identifies the
// person running it. fetch is stubbed; nothing here touches the network.

import { afterEach, expect, test } from "bun:test";
import { httpDiscogs, httpLastfm } from "../src/providers.ts";
import { CLI_VERSION } from "../src/types.ts";

const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

/** Replace fetch with a stub that records each request's User-Agent and answers with an empty result. */
function recordUserAgents(): string[] {
  const agents: string[] = [];
  globalThis.fetch = (async (_url: string | URL | Request, init?: RequestInit) => {
    agents.push(new Headers(init?.headers).get("User-Agent") ?? "");
    return new Response(JSON.stringify({ results: [] }), { status: 200, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
  return agents;
}

test("Discogs requests send only the tool name and version as User-Agent", async () => {
  const agents = recordUserAgents();
  await httpDiscogs("synthetic-token").searchRelease({ artist: "Example Artist", album: "Example Album" });
  expect(agents).toEqual([`jl-intake/${CLI_VERSION}`]);
});

test("Last.fm requests send the same User-Agent", async () => {
  const agents = recordUserAgents();
  await httpLastfm("synthetic-key")("Example Artist");
  expect(agents.length).toBeGreaterThan(0);
  for (const agent of agents) expect(agent).toBe(`jl-intake/${CLI_VERSION}`);
});
