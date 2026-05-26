// Tally Coding · Screen 5 — Long-term channel chat (#general) + escalation
// BRUTAL TERMINAL skin · square corners · mono uppercase chrome

// ─── small avatars ──────────────────────────────────────────────────────

function TallyAvatarSm({ size = 16, surface = TC.bg }) {
  const cur = Math.max(4, Math.round(size * 0.28));
  return (
    <div style={{ width: size, height: size, position: 'relative', flexShrink: 0 }}>
      <div style={{
        width: size, height: size, borderRadius: 0,
        background: TC.green,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: TC.bg, fontWeight: 700, fontSize: Math.max(8, size * 0.62),
        letterSpacing: 0, lineHeight: 1, fontFamily: FONT,
      }}>T</div>
      <div className="tc-blink" style={{
        position: 'absolute', right: -1, bottom: -1,
        width: cur, height: cur,
        background: TC.green,
        border: `1px solid ${surface}`,
      }} />
    </div>
  );
}

function YouAvatar({ size = 28 }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: 0,
      background: TC.green,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      color: TC.bg, fontWeight: 700, fontSize: size * 0.52,
      letterSpacing: 0, lineHeight: 1, fontFamily: FONT, flexShrink: 0,
    }}>Y</div>
  );
}

// ─── channel header ─────────────────────────────────────────────────────

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
          display: 'flex', alignItems: 'center', gap: 4,
        }}>
          <span style={{ color: TC.fg_xdim, fontWeight: 500 }}>＃</span>
          general
        </div>
        <div style={{
          color: TC.fg_xdim, fontSize: 10.5, letterSpacing: 0.5,
          textTransform: 'uppercase', fontWeight: 500,
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>service health &amp; alerts</div>
      </div>

      <button style={{
        width: 36, height: 36, borderRadius: 0,
        background: 'transparent', border: 'none', cursor: 'pointer',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        flexShrink: 0,
      }}>
        <svg width="18" height="4" viewBox="0 0 18 4" fill="none">
          <rect x="0" y="0" width="4" height="4" fill={TC.fg_xdim}/>
          <rect x="7" y="0" width="4" height="4" fill={TC.fg_xdim}/>
          <rect x="14" y="0" width="4" height="4" fill={TC.fg_xdim}/>
        </svg>
      </button>
    </div>
  );
}

// ─── message blocks ─────────────────────────────────────────────────────

function TallyMessage({ time, body }) {
  return (
    <div style={{
      display: 'flex', gap: 10, alignItems: 'flex-start',
      padding: '12px 16px 2px', fontFamily: FONT,
    }}>
      <div style={{ width: 28, flexShrink: 0 }}>
        <TallyAvatar size={28} badgeSurface={TC.bg} />
      </div>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 5 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{ color: TC.fg, fontSize: 12.5, fontWeight: 700, letterSpacing: 0 }}>Tally</span>
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

function UserMessage({ time, body }) {
  return (
    <div style={{
      display: 'flex', gap: 10, alignItems: 'flex-start',
      padding: '12px 16px 2px', fontFamily: FONT,
    }}>
      <div style={{ width: 28, flexShrink: 0 }}>
        <YouAvatar size={28} />
      </div>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 4 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{ color: TC.fg, fontSize: 12.5, fontWeight: 700, letterSpacing: 0 }}>You</span>
          <span style={{
            color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700,
            fontVariantNumeric: 'tabular-nums', letterSpacing: 0.3,
            textTransform: 'uppercase',
          }}>{time}</span>
        </div>
        <div style={{
          color: TC.fg_dim, fontSize: 13, lineHeight: 1.45,
          letterSpacing: 0, textWrap: 'pretty',
        }}>{body}</div>
      </div>
    </div>
  );
}

// ─── escalation card ────────────────────────────────────────────────────

function QuickReplyPrimary({ label }) {
  const [hov, setHov] = React.useState(false);
  return (
    <button
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        flex: 1, height: 36, borderRadius: 0,
        background: TC.green,
        border: 'none', cursor: 'pointer',
        color: TC.bg, fontWeight: 700, fontSize: 11.5, letterSpacing: 0.8,
        textTransform: 'uppercase', fontFamily: FONT,
        filter: hov ? 'brightness(1.15)' : 'none',
        transition: 'filter 100ms ease',
      }}
    >{label}</button>
  );
}

function QuickReplyOutline({ label }) {
  const [hov, setHov] = React.useState(false);
  return (
    <button
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        flex: 1, height: 36, borderRadius: 0,
        background: hov ? 'rgba(192,202,245,0.05)' : 'transparent',
        border: `1px solid ${hov ? TC.borderStr : TC.border}`,
        cursor: 'pointer',
        color: TC.fg, fontWeight: 700, fontSize: 11.5, letterSpacing: 0.8,
        textTransform: 'uppercase', fontFamily: FONT,
        transition: 'background 120ms ease, border-color 120ms ease',
      }}
    >{label}</button>
  );
}

function OpenTaskLink() {
  const [hov, setHov] = React.useState(false);
  return (
    <button
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        display: 'inline-flex', alignItems: 'center', gap: 6,
        background: 'transparent', border: 'none', padding: '6px 0',
        cursor: 'pointer', whiteSpace: 'nowrap',
        color: hov ? TC.fg : TC.fg_xdim,
        fontWeight: 700, fontSize: 10.5, letterSpacing: 0.6,
        textTransform: 'uppercase', fontFamily: FONT,
        transition: 'color 120ms ease',
        alignSelf: 'flex-start',
      }}>
      <svg width="11" height="11" viewBox="0 0 14 14" fill="none">
        <rect x="1.5" y="2" width="11" height="8" stroke="currentColor" strokeWidth="1.3" fill="none"/>
        <path d="M4 10.5l-1 2 3-2" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="miter" fill="none"/>
      </svg>
      Open task channel
    </button>
  );
}

function EscalationCardMessage({ time, taskName, question, options }) {
  return (
    <div style={{
      display: 'flex', gap: 10, alignItems: 'flex-start',
      padding: '12px 16px 2px', fontFamily: FONT,
    }}>
      <div style={{ width: 28, flexShrink: 0 }}>
        <TallyAvatar size={28} badgeSurface={TC.bg} />
      </div>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 5 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{ color: TC.fg, fontSize: 12.5, fontWeight: 700, letterSpacing: 0 }}>Tally</span>
          <span style={{
            color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700,
            fontVariantNumeric: 'tabular-nums', letterSpacing: 0.3,
            textTransform: 'uppercase',
          }}>{time}</span>
        </div>

        {/* the escalation CARD — coral wash, 1px coral border, square */}
        <div style={{
          alignSelf: 'flex-start',
          maxWidth: 320,
          background: 'rgba(247,118,142,0.05)',
          border: `1px solid ${TC.red}`,
          borderRadius: 0,
          padding: '12px 14px',
          display: 'flex', flexDirection: 'column', gap: 10,
        }}>
          {/* header row */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 7, flex: 1, minWidth: 0 }}>
              <TallyAvatarSm size={16} surface="#26171c" />
              <span style={{
                color: TC.red, fontSize: 11, fontWeight: 700,
                letterSpacing: 0.6, textTransform: 'uppercase',
              }}>Tally needs you</span>
            </div>
            <div style={{
              display: 'inline-flex', alignItems: 'center', gap: 5,
              color: TC.fg_dim, fontSize: 11, fontWeight: 500,
              letterSpacing: 0, flexShrink: 0, whiteSpace: 'nowrap',
            }}>
              <svg width="11" height="11" viewBox="0 0 14 14" fill="none">
                <rect x="2" y="2" width="10" height="10" stroke={TC.red} strokeWidth="1.3"/>
                <path d="M4.5 5.5h5M4.5 7.5h5M4.5 9.5h3" stroke={TC.red} strokeWidth="1.1" strokeLinecap="square"/>
              </svg>
              <span style={{ whiteSpace: 'nowrap' }}>{taskName}</span>
            </div>
          </div>

          {/* question */}
          <div style={{
            color: TC.fg_dim, fontSize: 13, lineHeight: 1.45,
            letterSpacing: 0, textWrap: 'pretty',
          }}>{question}</div>

          {/* quick replies */}
          <div style={{ display: 'flex', gap: 8 }}>
            {options.map((opt, i) =>
              i === 0
                ? <QuickReplyPrimary key={i} label={opt} />
                : <QuickReplyOutline key={i} label={opt} />
            )}
          </div>

          <OpenTaskLink />
        </div>
      </div>
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
            fontFamily: FONT, fontSize: 16, fontWeight: 700,
            color: active ? TC.bg : TC.fg_xdim,
          }}>▶</button>
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
        padding: '6px 0 10px',
      }}>
      <TallyMessage
        time="1h"
        body="Started the daily-deals price formatting task — Architect is breaking it down."
      />
      <UserMessage
        time="55m"
        body="Thanks. Let me know when there’s a decision to make."
      />
      <TallyMessage
        time="20m"
        body="Coder is on the parse step. Found a null-value edge in legacy rows — adding a guard."
      />
      <EscalationCardMessage
        time="2m"
        taskName="Fix daily-deals"
        question={
          <span>
            Coder hit a rounding edge case. Should the daily-deals export round to{' '}
            <span style={{ color: TC.fg, fontWeight: 700 }}>2 decimals</span> or keep{' '}
            <span style={{ color: TC.fg, fontWeight: 700 }}>4</span>?
          </span>
        }
        options={['2 decimals', 'Keep 4']}
      />
    </div>
  );
}

function Screen5() {
  return (
    <div
      data-screen-label="05 Mobile · #general channel with escalation"
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

window.Screen5 = Screen5;
