import { useRef } from "react";

export interface DbKnobProps {
  id: 0 | 1 | 2 | 3;
  label: string;
  normalized: number;
  display: number;
  onBegin: () => void;
  onSet: (value: number) => void;
  onEnd: () => void;
}

export function formatDb(value: number): string {
  return (value >= 0 ? "+" : "") + value.toFixed(2) + " dB";
}

export function DbKnob({ label, normalized, display, onBegin, onSet, onEnd }: DbKnobProps) {
  const active = useRef(false);
  const adjustmentKeys = ["ArrowDown", "ArrowLeft", "ArrowRight", "ArrowUp", "Home", "End", "PageDown", "PageUp"];
  const begin = () => {
    if (!active.current) {
      active.current = true;
      onBegin();
    }
  };
  const end = () => {
    if (active.current) {
      active.current = false;
      onEnd();
    }
  };
  const angle = -135 + normalized * 270;

  return (
    <label className="db-knob">
      <span className="db-knob__face" aria-hidden="true">
        <svg viewBox="0 0 136 136" focusable="false">
          <circle cx="68" cy="68" r="59" />
          <circle className="db-knob__arc" cx="68" cy="68" r="52" />
          <line className="db-knob__marker" x1="68" y1="68" x2="68" y2="24" transform={"rotate(" + angle + " 68 68)"} />
          <circle className="db-knob__hub" cx="68" cy="68" r="7" />
        </svg>
      </span>
      <span className="db-knob__label">{label}</span>
      <input
        aria-label={label}
        aria-valuemax={1}
        aria-valuemin={0}
        aria-valuetext={formatDb(display)}
        max="1"
        min="0"
        onBlur={end}
        onChange={(event) => onSet(Number(event.currentTarget.value))}
        onKeyDown={(event) => {
          if (adjustmentKeys.includes(event.key)) {
            begin();
          }
        }}
        onKeyUp={(event) => {
          if (adjustmentKeys.includes(event.key)) {
            end();
          }
        }}
        onPointerCancel={end}
        onPointerDown={begin}
        onPointerUp={end}
        step="0.001"
        type="range"
        value={normalized}
      />
      <span className="db-knob__value">{formatDb(display)}</span>
    </label>
  );
}
