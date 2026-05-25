// Tally Coding · Screen 4 — Task channel chat view
// BRUTAL TERMINAL skin · square corners · mono uppercase chrome

// ─── header ─────────────────────────────────────────────────────────────

function ChannelHeader() {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 10,
      padding: '10px 12px 12px 8px',
      borderBottom: `1px solid ${TC.border}`,
      fontFamily: FONT,
    }}>
      <button style={{
        width: 36, height: 36, borderRadius: 0,
        background: 'transparent', border: 'none', cursor: 'pointer',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        flexShrink: 0,
      }}>
        <svg width="18" height="18" viewBox="0 0 18 18" fill="none">
          <path d="M11 3.5L5.5 9L11 14.5" stroke={TC.fg_xdim} strokeWidth="2"
                strokeLinecap="square" strokeLinejoin="miter"/>
        </svg>
      </button>

      <div style={{
        flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2,
      }}>
        <div style={{
          color: TC.fg, fontSize: 14, fontWeight: 700,
          letterSpacing: 0, lineHeight: 1.25,
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>Fix daily-deals price formatting</div>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 5,
          color: TC.fg_dimmer, fontSize: 10.5, fontFamily: MONO, letterSpacing: 0,
        }}>
          <svg width="9" height="9" viewBox="0 0 16 16" fill="none">
            <rect x="3" y="2" width="2" height="2" fill={TC.fg_dimmer}/>
            <rect x="3" y="12" width="2" height="2" fill={TC.fg_dimmer}/>
            <rect x="11" y="7" width="2" height="2" fill={TC.fg_dimmer}/>
            <path d="M4 4v8M5 11h2c2 0 3-1 3-3" stroke={TC.fg_dimmer} strokeWidth="1.2" fill="none"/>
          </svg>
          feat/daily-deals-fmt
        </div>
      </div>

      <div style={{
        display: 'inline-flex', alignItems: 'center', gap: 5,
        padding: '4px 8px', borderRadius: 0,
        background: 'transparent',
        border: `1px solid ${TC.red}`,
        color: TC.red, fontSize: 10, fontWeight: 700,
        letterSpacing: 0.6, textTransform: 'uppercase',
        flexShrink: 0,
      }}>
        <span style={{
          width: 5, height: 5, background: TC.red,
        }} className="tc-blink" />
        Paused · needs you
      </div>
    </div>
  );
}

// ─── message blocks ─────────────────────────────────────────────────────

const NAME_FOR = {
  architect: 'Architect',
  coder: 'Coder',
  reader: 'Reader',
  tester: 'Tester',
};

function AgentMessage({ role, time, body, consecutive }) {
  return (
    <div style={{
      display: 'flex', gap: 10, alignItems: 'flex-start',
      padding: consecutive ? '2px 16px 0' : '10px 16px 0',
      fontFamily: FONT,
    }}>
      <div style={{ width: 28, flexShrink: 0 }}>
        {!consecutive && <AgentAvatar role={role} size={28} surface={TC.bg} pulse={false} />}
      </div>

      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 4 }}>
        {!consecutive && (
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
            <span style={{
              color: TC.fg, fontSize: 12.5, fontWeight: 700, letterSpacing: 0,
            }}>{NAME_FOR[role]}</span>
            <span style={{
              color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700,
              fontVariantNumeric: 'tabular-nums', letterSpacing: 0.3,
              textTransform: 'uppercase',
            }}>{time}</span>
          </div>
        )}
        <div style={{
          color: TC.fg_dim, fontSize: 13, lineHeight: 1.45,
          letterSpacing: 0, textWrap: 'pretty',
        }}>{body}</div>
      </div>
    </div>
  );
}

function TallyMessage({ time, body }) {
  return (
    <div style={{
      display: 'flex', gap: 10, alignItems: 'flex-start',
      padding: '12px 16px 2px',
      fontFamily: FONT,
    }}>
      <div style={{ width: 28, flexShrink: 0 }}>
        <TallyAvatar size={28} badgeSurface={TC.bg} />
      </div>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 5 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{
            color: TC.fg, fontSize: 12.5, fontWeight: 700, letterSpacing: 0,
          }}>Tally</span>
          <span style={{
            color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700,
            fontVariantNumeric: 'tabular-nums', letterSpacing: 0.3,
            textTransform: 'uppercase',
          }}>{time}</span>
        </div>
        <div style={{
          alignSelf: 'flex-start',
          background: 'transparent',
          border: `1px solid ${TC.border}`,
          borderRadius: 0,
          padding: '9px 12px 10px',
          color: TC.fg_dim, fontSize: 13, lineHeight: 1.45,
          letterSpacing: 0, textWrap: 'pretty',
          maxWidth: 320,
        }}>{body}</div>
      </div>
    </div>
  );
}

function StateChangeNote({ text }) {
  return (
    <div style={{
      display: 'flex', justifyContent: 'center',
      padding: '14px 16px 4px',
      fontFamily: FONT,
    }}>
      <span style={{
        color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700,
        letterSpacing: 0.8, textTransform: 'uppercase',
      }}>— {text} —</span>
    </div>
  );
}

// ─── composer ───────────────────────────────────────────────────────────

function Composer() {
  const [val, setVal] = React.useState('');
  const active = val.trim().length > 0;
  return (
    <div style={{
      borderTop: `1px solid ${TC.border}`,
      background: TC.bg,
      padding: '8px 16px 42px',
      fontFamily: FONT, flexShrink: 0,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <div style={{
          flex: 1, position: 'relative',
          background: 'rgba(192,202,245,0.04)',
          border: `1px solid ${TC.border}`,
          borderRadius: 0, height: 40,
          display: 'flex', alignItems: 'center',
        }}>
          {/* terminal prompt glyph */}
          <span style={{
            paddingLeft: 12, color: TC.green, fontSize: 13,
            fontWeight: 700, fontFamily: FONT,
          }}>›</span>
          <input
            type="text"
            value={val}
            onChange={e => setVal(e.target.value)}
            placeholder="send a message…"
            style={{
              flex: 1, width: '100%', height: '100%',
              background: 'transparent', border: 'none', outline: 'none',
              padding: '0 12px',
              color: TC.fg, fontSize: 13, fontFamily: FONT,
              letterSpacing: 0,
            }}
          />
        </div>

        <button
          disabled={!active}
          style={{
            width: 40, height: 40, borderRadius: 0,
            background: active ? TC.green : 'transparent',
            border: `1px solid ${active ? TC.green : TC.border}`,
            cursor: active ? 'pointer' : 'default',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            flexShrink: 0,
            transition: 'background 120ms ease, border-color 120ms ease',
            fontFamily: FONT,
            fontSize: 16, fontWeight: 700,
            color: active ? TC.bg : TC.fg_xdim,
            letterSpacing: 0,
          }}>
          ▶
        </button>
      </div>
    </div>
  );
}

// ─── stream ─────────────────────────────────────────────────────────────

function MessageStream() {
  const ref = React.useRef(null);
  React.useEffect(() => {
    if (ref.current) ref.current.scrollTop = ref.current.scrollHeight;
  }, []);
  return (
    <div
      ref={ref}
      className="tc-scroll"
      style={{
        flex: 1, overflowY: 'auto', overflowX: 'hidden',
        padding: '8px 0 10px',
      }}>
      <AgentMessage
        role="architect"
        time="5m"
        body="Broke this into 3 subtasks: parse → normalize → format. Dispatched parse to Coder."
      />
      <AgentMessage
        role="coder"
        time="4m"
        body="Parsing the daily-deals JSON. Spotted legacy rows where amount is null — adding a guard."
      />
      <AgentMessage
        role="coder"
        time="3m"
        consecutive
        body="Null guard in. 12/15 test cases pass. Stuck on the rounding edge case for cents."
      />
      <TallyMessage
        time="2m"
        body="Posted the rounding question to #general — pausing here until you decide."
      />
      <StateChangeNote text="Coder is waiting on you" />
    </div>
  );
}

function Screen4() {
  return (
    <div
      data-screen-label="04 Mobile · Task channel chat"
      style={{
        width: '100%', height: '100%',
        background: TC.bg, color: TC.fg, fontFamily: FONT,
        display: 'flex', flexDirection: 'column',
        position: 'relative', overflow: 'hidden',
      }}>
      <TCGlobalStyles />
      <div style={{ height: 56 }} />
      <ChannelHeader />
      <MessageStream />
      <Composer />
    </div>
  );
}

window.Screen4 = Screen4;
