// Tally Coding · Screen 2 — Escalation takeover (mobile mini-dash)
// BRUTAL TERMINAL skin · square corners · mono uppercase buttons

function QuickReplyPrimary({ label }) {
  const [hov, setHov] = React.useState(false);
  return (
    <button
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        flex: 1, height: 40, borderRadius: 0,
        background: TC.green,
        border: 'none', cursor: 'pointer',
        color: TC.bg, fontWeight: 700, fontSize: 12, letterSpacing: 0.8,
        textTransform: 'uppercase',
        fontFamily: FONT,
        filter: hov ? 'brightness(1.15)' : 'none',
        transition: 'filter 100ms ease, transform 80ms ease',
      }}
      onMouseDown={e => e.currentTarget.style.transform = 'scale(0.98)'}
      onMouseUp={e => e.currentTarget.style.transform = 'scale(1)'}
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
        flex: 1, height: 40, borderRadius: 0,
        background: hov ? 'rgba(192,202,245,0.05)' : 'transparent',
        border: `1px solid ${hov ? TC.borderStr : TC.border}`,
        cursor: 'pointer',
        color: TC.fg, fontWeight: 700, fontSize: 12, letterSpacing: 0.8,
        textTransform: 'uppercase',
        fontFamily: FONT,
        transition: 'background 120ms ease, border-color 120ms ease',
      }}
    >{label}</button>
  );
}

function GhostBtn({ children, align = 'left' }) {
  const [hov, setHov] = React.useState(false);
  return (
    <button
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        background: 'transparent', border: 'none', padding: '6px 0',
        cursor: 'pointer',
        color: hov ? TC.fg : TC.fg_xdim,
        fontWeight: 700, fontSize: 11, letterSpacing: 0.6,
        textTransform: 'uppercase', fontFamily: FONT,
        display: 'flex', alignItems: 'center', gap: 6,
        textAlign: align,
        transition: 'color 120ms ease',
      }}
    >{children}</button>
  );
}

function EscalationSheet() {
  return (
    <div style={{
      position: 'absolute', left: 0, right: 0, bottom: 0,
      background: TC.sheet,
      borderTop: `1px solid ${TC.amberLine}`,
      borderRadius: 0,
      padding: 0,
      zIndex: 15,
      overflow: 'hidden',
      fontFamily: FONT,
    }}>
      {/* coral wash */}
      <div style={{
        position: 'absolute', inset: 0,
        background: TC.amberWash,
        pointerEvents: 'none',
      }} />

      <div style={{
        position: 'relative',
        padding: '8px 16px 42px',
        display: 'flex', flexDirection: 'column', gap: 14,
      }}>
        {/* drag handle */}
        <div style={{ display: 'flex', justifyContent: 'center', paddingBottom: 2 }}>
          <div style={{ width: 36, height: 4, borderRadius: 999, background: TC.border }} />
        </div>

        {/* header row */}
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10 }}>
          <TallyAvatar size={28} badgeSurface={TC.sheet} />
          <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
              <span style={{
                display: 'inline-flex', alignItems: 'center', gap: 4,
                color: TC.fg, fontWeight: 700, fontSize: 13, letterSpacing: 0,
              }}>
                <span style={{ color: TC.fg_xdim, fontWeight: 500 }}>＃</span>
                general
              </span>
              <span style={{ color: TC.fg_dimmer, fontSize: 11 }}>│</span>
              <span style={{
                color: TC.red, fontWeight: 700, fontSize: 11,
                textTransform: 'uppercase', letterSpacing: 0.6,
              }}>needs you</span>
            </div>
            <div style={{
              color: TC.fg_xdim, fontSize: 11, letterSpacing: 0,
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}>
              about: <span style={{ color: TC.fg_dim }}>Fix daily-deals price formatting</span>
            </div>
          </div>
          {/* queue badge */}
          <div style={{
            display: 'inline-flex', alignItems: 'center',
            padding: '3px 7px', borderRadius: 0,
            background: 'transparent',
            color: TC.red, fontSize: 10.5, fontWeight: 700,
            letterSpacing: 0.4, fontVariantNumeric: 'tabular-nums',
            border: `1px solid ${TC.red}`,
            flexShrink: 0, textTransform: 'uppercase',
          }}>1/2</div>
        </div>

        {/* question */}
        <div style={{
          color: TC.fg_dim, fontSize: 13, fontWeight: 400,
          lineHeight: 1.45, letterSpacing: 0,
          textWrap: 'pretty',
        }}>
          Coder hit a rounding edge case. Should the daily-deals export round to{' '}
          <span style={{ color: TC.fg, fontWeight: 700 }}>2 decimals</span>
          {' '}or keep{' '}
          <span style={{ color: TC.fg, fontWeight: 700 }}>4</span>?
        </div>

        {/* quick replies */}
        <div style={{ display: 'flex', gap: 8 }}>
          <QuickReplyPrimary label="2 decimals" />
          <QuickReplyOutline label="Keep 4" />
        </div>

        {/* bottom row */}
        <div style={{
          display: 'flex', justifyContent: 'space-between', alignItems: 'center',
          marginTop: -2,
        }}>
          <GhostBtn>
            <svg width="11" height="11" viewBox="0 0 14 14" fill="none">
              <rect x="1.5" y="2" width="11" height="8" stroke="currentColor" strokeWidth="1.3" fill="none"/>
              <path d="M4 10.5l-1 2 3-2" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="miter" fill="none"/>
            </svg>
            Open #general
          </GhostBtn>
          <GhostBtn>
            Skip
            <svg width="11" height="11" viewBox="0 0 24 24" fill="none">
              <path d="M5 12h14M13 5l7 7-7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="square" strokeLinejoin="miter"/>
            </svg>
          </GhostBtn>
        </div>
      </div>
    </div>
  );
}

function Screen2() {
  return (
    <div
      data-screen-label="02 Mobile · Mini-dash escalation takeover"
      style={{
        width: '100%', height: '100%',
        background: TC.bg, color: TC.fg, fontFamily: FONT,
        display: 'flex', flexDirection: 'column',
        position: 'relative', overflow: 'hidden',
      }}>
      <TCGlobalStyles />
      <div style={{ height: 56 }} />
      <AppHeader />
      <KanbanScroll escalatedTaskIdx={0} bottomPad={320} />
      <EscalationSheet />
    </div>
  );
}

window.Screen2 = Screen2;
