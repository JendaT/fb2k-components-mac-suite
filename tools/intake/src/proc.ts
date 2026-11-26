// External tool runs with a hard time limit, in their own process group: the
// unpack tools (src/archive.ts) and the beets shim (src/providers.ts).

/** Signals that end intake while a tool runs; the tool's group goes first. */
const STOP_SIGNALS = ["SIGTERM", "SIGINT", "SIGHUP"] as const;

/** How long a signalled intake waits for the killed tool before it cleans up and ends anyway. */
const STOP_GRACE_MS = 5000;

/** setTimeout's longest delay: a longer one would fire at once. */
const MAX_TIMER_MS = 2 ** 31 - 1;

export interface ToolRun {
  code: number;
  /** The tool's stdout with `captureStdout`, else "". */
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

export interface ToolOptions {
  /** Collect stdout, read while the tool runs as stderr is. Without it stdout is discarded. */
  captureStdout?: boolean;
  /** The tool's environment; default: intake's own. */
  env?: Record<string, string | undefined>;
  /** Runs on a stop signal, before intake re-raises it (see runTool). */
  cleanup?: () => void;
}

/**
 * Read a pipe to its end in the background: a tool that fills a pipe nobody
 * reads blocks forever.
 */
function collect(stream: ReadableStream<Uint8Array>) {
  const chunks: Uint8Array[] = [];
  const reader = stream.getReader();
  const done = (async () => {
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) return;
        chunks.push(value);
      }
    } catch {
      // cancelled after a kill
    }
  })();
  return {
    done,
    cancel: () => void reader.cancel().catch(() => {}),
    text: () => Buffer.concat(chunks).toString(),
  };
}

/**
 * Run a tool (stdin ignored, stderr collected, stdout collected with
 * `captureStdout`, else discarded) in its own process group, so a kill
 * reaches every process of it: Homebrew's `7z` is a shell wrapper that runs
 * p7zip as a child, and killing only the wrapper would leave p7zip writing.
 * The group is SIGKILLed when the run exceeds `timeoutMs` (capped at
 * setTimeout's limit, about 24.8 days), and the result is then `timedOut`,
 * with whatever output came before the kill.
 *
 * While the tool runs, SIGTERM, SIGINT and SIGHUP are caught: the group is
 * killed, `cleanup` (if given) runs once the tool has exited (or after
 * STOP_GRACE_MS, for a tool stuck in the kernel), and intake re-raises the
 * signal to end as it would have without the handler. A tool in its own
 * group would not get a terminal's SIGINT or SIGHUP, and nothing forwards a
 * SIGTERM sent to intake (foobar2000 sends one at its time cap), so without
 * the handlers the tool would outlive intake. The handlers exist only during
 * the run. SIGKILL cannot be caught: a tool running then outlives intake
 * (archive: the partial dir it leaves is removed by the next scan).
 *
 * Throws when the tool cannot be started (Bun.spawn, e.g. no such file).
 */
export async function runTool(argv: string[], timeoutMs: number, opts: ToolOptions = {}): Promise<ToolRun> {
  const proc = Bun.spawn(argv, {
    stdin: "ignore",
    stdout: opts.captureStdout ? "pipe" : "ignore",
    stderr: "pipe",
    detached: true,
    ...(opts.env && { env: opts.env }),
  });
  const killGroup = () => {
    try {
      process.kill(-proc.pid, "SIGKILL");
    } catch {
      // already gone
    }
  };
  const stderr = collect(proc.stderr);
  const stdout = opts.captureStdout && proc.stdout instanceof ReadableStream ? collect(proc.stdout) : null;

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    killGroup();
  }, Math.min(timeoutMs, MAX_TIMER_MS));

  let signal: NodeJS.Signals | null = null;
  let stopped = false;
  const removeHandlers = () => {
    for (const s of STOP_SIGNALS) process.off(s, onSignal);
  };
  const stop = (s: NodeJS.Signals) => {
    if (stopped) return;
    stopped = true;
    try {
      opts.cleanup?.();
    } catch {
      // best effort (archive: the next scan removes a leftover partial dir)
    }
    removeHandlers();
    process.kill(process.pid, s);
  };
  function onSignal(s: NodeJS.Signals) {
    if (signal !== null) return;
    signal = s;
    clearTimeout(timer);
    killGroup();
    setTimeout(() => stop(s), STOP_GRACE_MS);
  }
  for (const s of STOP_SIGNALS) process.on(s, onSignal);

  try {
    const code = await proc.exited;
    if (signal !== null) {
      stop(signal);
      await new Promise(() => {}); // the re-raised signal ends the process
    }
    if (timedOut) {
      stderr.cancel();
      stdout?.cancel();
    } else {
      await Promise.all([stderr.done, stdout?.done]);
    }
    return { code, stdout: stdout?.text() ?? "", stderr: stderr.text(), timedOut };
  } finally {
    clearTimeout(timer);
    removeHandlers();
  }
}
