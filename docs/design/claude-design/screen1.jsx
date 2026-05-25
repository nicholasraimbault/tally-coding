// Tally Coding · Screen 1 — Mobile Kanban + ambient mini-dash
// BRUTAL TERMINAL skin · square corners · mono everywhere

function MiniTaskRow({ title, agents, progress }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 10, padding: '7px 0',
    }}>
      <div style={{ display: 'flex', gap: 4 }}>
        {agents.map((r, i) => <AgentAvatar key={i} role={r} size={18} surface={TC.sheet} pulse={i === 0} />)}
      </div>
      <div style={{
        flex: 1, color: TC.fg_dim, fontSize: 12, fontWeight: 500,
        whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        letterSpacing: 0, fontFamily: FONT,
      }}>{title}</div>
      <div style={{ width: 64, display: 'flex', alignItems: 'center', gap: 7 }}>
        <ProgressBar pct={progress} height={3} />
        <span style={{
          color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700,
          fontVariantNumeric: 'tabular-nums', minWidth: 24, textAlign: 'right',
          fontFamily: FONT,
        }}>{progress}%</span>
      </div>
    </div>
  );
}

function TallyBubble() {
  return (
    <div style={{ display: 'flex', gap: 9, alignItems: 'flex-end', paddingTop: 4 }}>
      <TallyAvatar size={28} badgeSurface={TC.sheet} />
      <div style={{
        position: 'relative',
        background: 'transparent',
        border: `1px solid ${TC.border}`,
        borderRadius: 0,
        padding: '9px 12px 10px',
        color: TC.fg_dim, fontSize: 12, lineHeight: 1.45,
        letterSpacing: 0, fontFamily: FONT,
        maxWidth: 280, textWrap: 'pretty',
      }}>
        Diagnosed the daily-deals bug.{' '}
        <span style={{ color: TC.fg, fontWeight: 700 }}>Coder is patching</span>
        {' '}— PR in ~5 min.
      </div>
    </div>
  );
}

function AmbientMiniDash() {
  return (
    <div style={{
      position: 'absolute', left: 0, right: 0, bottom: 0,
      background: TC.sheet,
      borderTop: `1px solid ${TC.border}`,
      borderRadius: 0,
      padding: '8px 16px 42px',
      zIndex: 15,
      display: 'flex', flexDirection: 'column', gap: 10,
    }}>
      {/* drag handle — sliver of softness allowed for affordance */}
      <div style={{ display: 'flex', justifyContent: 'center', paddingBottom: 2 }}>
        <div style={{ width: 36, height: 4, borderRadius: 999, background: TC.border }} />
      </div>

      {/* stat row */}
      <div style={{
        display: 'flex', alignItems: 'baseline', gap: 7, fontFamily: FONT,
      }}>
        <span style={{
          fontSize: 18, fontWeight: 700, color: TC.fg, letterSpacing: 0,
          fontVariantNumeric: 'tabular-nums', lineHeight: 1,
        }}>6</span>
        <span style={{
          fontSize: 10.5, color: TC.fg_xdim, fontWeight: 700,
          textTransform: 'uppercase', letterSpacing: 0.6,
        }}>open</span>
        <span style={{ color: TC.fg_dimmer, fontSize: 11, padding: '0 4px' }}>│</span>
        <span style={{
          fontSize: 18, fontWeight: 700, color: TC.fg, letterSpacing: 0,
          fontVariantNumeric: 'tabular-nums', lineHeight: 1,
        }}>3</span>
        <span style={{
          fontSize: 10.5, color: TC.fg_xdim, fontWeight: 700,
          textTransform: 'uppercase', letterSpacing: 0.6,
        }}>done today</span>
      </div>

      {/* task rows */}
      <div style={{
        display: 'flex', flexDirection: 'column',
        borderTop: `1px solid ${TC.border}`, marginTop: 2, paddingTop: 4,
      }}>
        <MiniTaskRow title="Fix daily-deals price formatting" agents={['architect','coder']} progress={60} />
        <div style={{ height: 1, background: TC.border }} />
        <MiniTaskRow title="Build email digest worker" agents={['coder']} progress={30} />
      </div>

      <TallyBubble />
    </div>
  );
}

function Screen1() {
  return (
    <div
      data-screen-label="01 Mobile · Kanban · ambient mini-dash"
      style={{
        width: '100%', height: '100%',
        background: TC.bg, color: TC.fg, fontFamily: FONT,
        display: 'flex', flexDirection: 'column',
        position: 'relative', overflow: 'hidden',
      }}>
      <TCGlobalStyles />
      <div style={{ height: 56 }} />
      <AppHeader />
      <KanbanScroll />
      <AmbientMiniDash />
    </div>
  );
}

window.Screen1 = Screen1;
