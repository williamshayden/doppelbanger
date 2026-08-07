import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { DbKnob } from "./DbKnob";

describe("DbKnob", () => {
  it("exposes an accessible native slider with a signed two-decimal dB value", () => {
    render(<DbKnob id={0} label="LOW" normalized={0.75} display={6} onBegin={vi.fn()} onSet={vi.fn()} onEnd={vi.fn()} />);
    const slider = screen.getByRole("slider", { name: "LOW" });

    expect(slider).toHaveAttribute("aria-valuemin", "0");
    expect(slider).toHaveAttribute("aria-valuemax", "1");
    expect(slider).toHaveAttribute("aria-valuetext", "+6.00 dB");
    expect(screen.getByText("+6.00 dB")).toBeInTheDocument();
  });

  it("orders pointer and keyboard editing gestures and ends on cancellation or blur", () => {
    const calls: string[] = [];
    render(<DbKnob id={2} label="HIGH" normalized={0.5} display={0}
      onBegin={() => calls.push("begin")}
      onSet={(value) => calls.push("set:" + value)}
      onEnd={() => calls.push("end")} />);
    const slider = screen.getByRole("slider", { name: "HIGH" });

    fireEvent.pointerDown(slider);
    fireEvent.change(slider, { target: { value: "0.7" } });
    fireEvent.pointerUp(slider);
    fireEvent.keyDown(slider, { key: "ArrowUp" });
    fireEvent.change(slider, { target: { value: "0.8" } });
    fireEvent.keyUp(slider, { key: "ArrowUp" });
    fireEvent.pointerDown(slider);
    fireEvent.pointerCancel(slider);
    fireEvent.pointerDown(slider);
    fireEvent.blur(slider);

    expect(calls).toEqual(["begin", "set:0.7", "end", "begin", "set:0.8", "end", "begin", "end", "begin", "end"]);
  });
});
