import { useEffect, useState } from "react";
import { EditorBridge, type EditorState } from "./bridge/EditorBridge";
import { DbKnob } from "./components/DbKnob";
import { ResponseCurve } from "./components/ResponseCurve";
import "./editor.css";

const defaultBridge = new EditorBridge();
const initialState: EditorState = {
  parameters: [0, 1, 2, 3].map((id) => ({ id: id as 0 | 1 | 2 | 3, normalized: 0.5, display: 0 })),
  bypass: false,
  build: "1.0.0",
  dspReady: true,
  runtimeMode: "LOCAL"
};
const labels = ["LOW", "MID", "HIGH", "OUTPUT"] as const;

export function App({ bridge = defaultBridge }: { bridge?: EditorBridge }) {
  const [state, setState] = useState<EditorState>(initialState);
  useEffect(() => bridge.subscribe(setState), [bridge]);

  const setBypass = () => {
    bridge.beginBypass();
    bridge.setBypass(!state.bypass);
    bridge.endBypass();
  };

  return (
    <main className="editor-shell">
      <header className="editor-header">
        <div>
          <h1>DOPPELBANGER</h1>
          <p>GOBLIN CITY RECORDS</p>
        </div>
        <button className="bypass" role="switch" aria-checked={state.bypass} aria-label="BYPASS" onClick={setBypass}>
          <span>BYPASS</span><i aria-hidden="true" />
        </button>
      </header>
      <section className="curve-panel" aria-label="EQ response">
        <ResponseCurve low={state.parameters[0].display} mid={state.parameters[1].display} high={state.parameters[2].display} />
        <div className="curve-labels"><span>20</span><span>100</span><span>1K</span><span>10K</span><span>20K</span></div>
      </section>
      <section className="knob-row" aria-label="Doppelbanger controls">
        {state.parameters.map((parameter, index) => (
          <DbKnob
            key={parameter.id}
            id={parameter.id}
            label={labels[index]}
            normalized={parameter.normalized}
            display={parameter.display}
            onBegin={() => bridge.beginParameter(parameter.id)}
            onSet={(value) => bridge.setParameter(parameter.id, value)}
            onEnd={() => bridge.endParameter(parameter.id)}
          />
        ))}
      </section>
      {state.error && <output className="bridge-error">{state.error}</output>}
      <footer className="editor-footer">
        <span>{state.dspReady ? "DSP READY" : "DSP UNAVAILABLE"}</span>
        <span>BRIDGE v1</span>
        <span>BUILD {state.build}</span>
        <span>{state.runtimeMode}</span>
      </footer>
    </main>
  );
}
