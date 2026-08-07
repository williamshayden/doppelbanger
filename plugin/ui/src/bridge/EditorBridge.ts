export type ParameterId = 0 | 1 | 2 | 3;

export interface EditorParameter {
  id: ParameterId;
  normalized: number;
  display: number;
}

export interface EditorState {
  parameters: EditorParameter[];
  bypass: boolean;
  build: string;
  dspReady: boolean;
  runtimeMode: "LOCAL";
  error?: string;
}

declare global {
  interface Window {
    IPlugSendMsg?: (message: string) => void;
    __doppelbangerReceive?: (message: string) => void;
  }
}

const parameterIds = new Set([0, 1, 2, 3]);
const initialState: EditorState = {
  parameters: [0, 1, 2, 3].map((id) => ({ id: id as ParameterId, normalized: 0.5, display: 0 })),
  bypass: false,
  build: "1.0.0",
  dspReady: true,
  runtimeMode: "LOCAL"
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, allowed: string[]): boolean {
  return Object.keys(value).every((key) => allowed.includes(key));
}

function isParameter(value: unknown): value is EditorParameter {
  return isRecord(value) &&
    hasOnlyKeys(value, ["id", "normalized", "display"]) &&
    typeof value.id === "number" && Number.isInteger(value.id) && parameterIds.has(value.id) &&
    typeof value.normalized === "number" && Number.isFinite(value.normalized) && value.normalized >= 0 && value.normalized <= 1 &&
    typeof value.display === "number" && Number.isFinite(value.display);
}

function clampNormalized(value: number): number {
  return Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;
}

export class EditorBridge {
  private readonly listeners = new Set<(state: EditorState) => void>();
  private state: EditorState = initialState;
  private receiver?: (message: string) => void;

  subscribe(listener: (state: EditorState) => void): () => void {
    this.listeners.add(listener);
    this.installReceiver();
    listener(this.state);
    this.ready();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0 && window.__doppelbangerReceive === this.receiver) {
        delete window.__doppelbangerReceive;
        this.receiver = undefined;
      }
    };
  }

  ready(): void {
    this.send("ui.ready", {});
  }

  beginParameter(id: ParameterId): void {
    this.send("parameter.begin_edit", { id });
  }

  setParameter(id: ParameterId, normalizedValue: number): void {
    this.send("parameter.set", { id, value: clampNormalized(normalizedValue) });
  }

  endParameter(id: ParameterId): void {
    this.send("parameter.end_edit", { id });
  }

  beginBypass(): void {
    this.send("bypass.begin_edit", {});
  }

  setBypass(value: boolean): void {
    this.send("bypass.set", { value: Boolean(value) });
  }

  endBypass(): void {
    this.send("bypass.end_edit", {});
  }

  private installReceiver(): void {
    if (this.receiver) {
      return;
    }
    this.receiver = (message: string) => this.receive(message);
    window.__doppelbangerReceive = this.receiver;
  }

  private send(type: string, payload: Record<string, unknown>): void {
    if (typeof window.IPlugSendMsg !== "function") {
      this.setError("DBUI_TRANSPORT_UNAVAILABLE");
      return;
    }
    window.IPlugSendMsg(JSON.stringify({ version: 1, type, payload }));
  }

  private receive(message: string): void {
    if (new TextEncoder().encode(message).length > 4096) {
      this.setError("DBUI_BRIDGE_MESSAGE");
      return;
    }
    try {
      const envelope: unknown = JSON.parse(message);
      if (!isRecord(envelope) || !hasOnlyKeys(envelope, ["version", "type", "request_id", "payload"]) ||
        envelope.version !== 1 || typeof envelope.type !== "string" || !isRecord(envelope.payload) ||
        (envelope.request_id !== undefined && (typeof envelope.request_id !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(envelope.request_id)))) {
        throw new Error("invalid envelope");
      }
      this.applyNativeEnvelope(envelope.type, envelope.payload);
    } catch {
      this.setError("DBUI_BRIDGE_MESSAGE");
    }
  }

  private applyNativeEnvelope(type: string, payload: Record<string, unknown>): void {
    if (type === "state.snapshot" &&
      hasOnlyKeys(payload, ["parameters", "bypass", "build", "dsp_ready", "runtime_mode"]) &&
      Array.isArray(payload.parameters) && payload.parameters.length === 4 && payload.parameters.every(isParameter) &&
      new Set(payload.parameters.map((parameter) => parameter.id)).size === 4 &&
      typeof payload.bypass === "boolean" && typeof payload.build === "string" &&
      typeof payload.dsp_ready === "boolean" && payload.runtime_mode === "LOCAL") {
      this.state = {
        parameters: [...payload.parameters].sort((left, right) => left.id - right.id) as EditorParameter[],
        bypass: payload.bypass,
        build: payload.build,
        dspReady: payload.dsp_ready,
        runtimeMode: "LOCAL"
      };
      this.notify();
      return;
    }
    if (type === "parameter.changed" && isParameter(payload)) {
      this.state = {
        ...this.state,
        error: undefined,
        parameters: this.state.parameters.map((parameter) => parameter.id === payload.id ? payload : parameter)
      };
      this.notify();
      return;
    }
    if (type === "bypass.changed" && hasOnlyKeys(payload, ["value"]) && typeof payload.value === "boolean") {
      this.state = { ...this.state, error: undefined, bypass: payload.value };
      this.notify();
      return;
    }
    if (type === "compatibility.error" && hasOnlyKeys(payload, ["code"]) && typeof payload.code === "string" && /^DBUI_[A-Z_]+$/.test(payload.code)) {
      this.setError(payload.code);
      return;
    }
    this.setError("DBUI_BRIDGE_MESSAGE");
  }

  private setError(error: string): void {
    this.state = { ...this.state, error };
    this.notify();
  }

  private notify(): void {
    this.listeners.forEach((listener) => listener(this.state));
  }
}
