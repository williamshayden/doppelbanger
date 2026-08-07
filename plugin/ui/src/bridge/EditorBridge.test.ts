import { afterEach, describe, expect, it, vi } from "vitest";
import { EditorBridge } from "./EditorBridge";

declare global {
  interface Window {
    IPlugSendMsg?: (message: string) => void;
    __doppelbangerReceive?: (message: string) => void;
  }
}

afterEach(() => {
  delete window.IPlugSendMsg;
  delete window.__doppelbangerReceive;
});

describe("EditorBridge", () => {
  it("sends ui.ready after subscription and uses version 1 for every UI command", () => {
    const sent: unknown[] = [];
    window.IPlugSendMsg = (message) => sent.push(JSON.parse(message));
    const bridge = new EditorBridge();
    const unsubscribe = bridge.subscribe(() => undefined);

    bridge.beginParameter(0);
    bridge.setParameter(0, 0.5);
    bridge.endParameter(0);
    bridge.beginBypass();
    bridge.setBypass(true);
    bridge.endBypass();

    expect(sent).toEqual([
      { version: 1, type: "ui.ready", payload: {} },
      { version: 1, type: "parameter.begin_edit", payload: { id: 0 } },
      { version: 1, type: "parameter.set", payload: { id: 0, value: 0.5 } },
      { version: 1, type: "parameter.end_edit", payload: { id: 0 } },
      { version: 1, type: "bypass.begin_edit", payload: {} },
      { version: 1, type: "bypass.set", payload: { value: true } },
      { version: 1, type: "bypass.end_edit", payload: {} }
    ]);
    unsubscribe();
  });

  it("clamps non-finite normalized values before transport", () => {
    const send = vi.fn();
    window.IPlugSendMsg = send;
    const bridge = new EditorBridge();
    const unsubscribe = bridge.subscribe(() => undefined);

    bridge.setParameter(1, Number.NaN);
    bridge.setParameter(1, -2);
    bridge.setParameter(1, 9);

    expect(send.mock.calls.slice(1).map(([message]) => JSON.parse(message))).toEqual([
      { version: 1, type: "parameter.set", payload: { id: 1, value: 0 } },
      { version: 1, type: "parameter.set", payload: { id: 1, value: 0 } },
      { version: 1, type: "parameter.set", payload: { id: 1, value: 1 } }
    ]);
    unsubscribe();
  });

  it("reports an unavailable injected transport visibly", () => {
    const seen: string[] = [];
    const bridge = new EditorBridge();
    const unsubscribe = bridge.subscribe((state) => seen.push(state.error ?? ""));

    expect(seen).toContain("DBUI_TRANSPORT_UNAVAILABLE");
    unsubscribe();
  });

  it("hydrates from a native snapshot and reports unknown native envelopes", () => {
    window.IPlugSendMsg = () => undefined;
    const bridge = new EditorBridge();
    const seen: string[] = [];
    const unsubscribe = bridge.subscribe((state) => seen.push(state.error ?? state.parameters[0].display.toString()));

    window.__doppelbangerReceive?.(JSON.stringify({
      version: 1,
      type: "state.snapshot",
      payload: {
        parameters: [
          { id: 0, normalized: 0.75, display: 6 },
          { id: 1, normalized: 0.5, display: 0 },
          { id: 2, normalized: 0.5, display: 0 },
          { id: 3, normalized: 0.5, display: 0 }
        ],
        bypass: false,
        build: "1.0.0",
        dsp_ready: true,
        runtime_mode: "LOCAL"
      }
    }));
    window.__doppelbangerReceive?.("{\"version\":1,\"type\":\"bad\",\"payload\":{}}");

    expect(seen).toContain("6");
    expect(seen).toContain("DBUI_BRIDGE_MESSAGE");
    unsubscribe();
  });

  it("removes the native callback after the last subscription and requests a fresh snapshot on recreation", () => {
    const sent: unknown[] = [];
    window.IPlugSendMsg = (message) => sent.push(JSON.parse(message));
    const first = new EditorBridge();
    const unsubscribe = first.subscribe(() => undefined);
    unsubscribe();

    expect(window.__doppelbangerReceive).toBeUndefined();

    const recreated = new EditorBridge();
    const stop = recreated.subscribe(() => undefined);
    expect(sent.filter((message) => (message as { type: string }).type === "ui.ready")).toHaveLength(2);
    stop();
  });
});
