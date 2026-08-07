import { act, fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { App } from "./App";
import { EditorBridge } from "./bridge/EditorBridge";

function bridgeWithTransport() {
  window.IPlugSendMsg = vi.fn();
  return new EditorBridge();
}

describe("App", () => {
  it("renders the approved copy, four labelled controls, bypass, and the response curve", () => {
    const bridge = bridgeWithTransport();
    render(<App bridge={bridge} />);

    expect(screen.getByText("DOPPELBANGER")).toBeInTheDocument();
    expect(screen.getByText("GOBLIN CITY RECORDS")).toBeInTheDocument();
    expect(screen.getByRole("switch", { name: "BYPASS" })).toBeInTheDocument();
    expect(screen.getAllByRole("slider")).toHaveLength(4);
    expect(screen.getByTestId("response-curve")).toBeInTheDocument();
    expect(screen.getByText("DSP READY")).toBeInTheDocument();
    expect(screen.getByText("BRIDGE v1")).toBeInTheDocument();
    expect(screen.getByText("BUILD 1.0.0")).toBeInTheDocument();
    expect(screen.getByText("LOCAL")).toBeInTheDocument();
  });

  it("hydrates controls from native state, mirrors host updates, and changes the response curve", () => {
    const bridge = bridgeWithTransport();
    render(<App bridge={bridge} />);
    const before = screen.getByTestId("response-curve").getAttribute("points");
    act(() => window.__doppelbangerReceive?.(JSON.stringify({
      version: 1, type: "state.snapshot", payload: {
        parameters: [
          { id: 0, normalized: 0.75, display: 6 },
          { id: 1, normalized: 0.25, display: -6 },
          { id: 2, normalized: 0.5, display: 0 },
          { id: 3, normalized: 0.5, display: 0 }
        ],
        bypass: true, build: "1.0.0", dsp_ready: true, runtime_mode: "LOCAL"
      }
    })));

    expect(screen.getByRole("slider", { name: "LOW" })).toHaveAttribute("aria-valuetext", "+6.00 dB");
    expect(screen.getByRole("switch", { name: "BYPASS" })).toHaveAttribute("aria-checked", "true");
    expect(screen.getByTestId("response-curve")).not.toHaveAttribute("points", before ?? "");
  });

  it("sends bypass gestures and displays bridge compatibility errors", () => {
    const bridge = bridgeWithTransport();
    render(<App bridge={bridge} />);
    fireEvent.click(screen.getByRole("switch", { name: "BYPASS" }));
    act(() => window.__doppelbangerReceive?.("{\"version\":1,\"type\":\"invalid\",\"payload\":{}}"));

    expect(window.IPlugSendMsg).toHaveBeenCalledWith(JSON.stringify({ version: 1, type: "bypass.begin_edit", payload: {} }));
    expect(window.IPlugSendMsg).toHaveBeenCalledWith(JSON.stringify({ version: 1, type: "bypass.set", payload: { value: true } }));
    expect(window.IPlugSendMsg).toHaveBeenCalledWith(JSON.stringify({ version: 1, type: "bypass.end_edit", payload: {} }));
    expect(screen.getByText("DBUI_BRIDGE_MESSAGE")).toBeInTheDocument();
  });
});
