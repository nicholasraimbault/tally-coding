// Tally Coding · Screen 3 — Channels sheet expanded
// Same frame · same Pronoic header · 5-col kanban behind (mostly hidden)
// Sheet has been swiped up; covers ~75% of viewport.

function ChannelRow({ name, snippet, time, needsAttention, escalations, isLast }) {
  const [hov, setHov] = React.useState(false);

  if (needsAttention) {
    return (
      <div
        onMouseEnter={() => setHov(true)}
        onMouseLeave={() => setHov(false)}
        style={{
          position: 'relative',
          background: hov ? 'rgba(245,158,11,0.08)' : 'rgba(245,158,11,0.05)',
          borderBottom: `1px solid rgba(245,158,11,0.20)`,
          cursor: 'pointer', fontFamily: FONT,
          transition: 'background 120ms ease',
        }}>
        {/* 3px left-edge accent */}
        <div style={{
          position: 'absolute', left: 0, top: 0, bottom: 0,
          width: 3, background: TC.amber,
          boxShadow: `0 0 12px rgba(245,158,11,0.5)`,
        }} />
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
          padding: '14px 16px 14px 19px', // 16 + 3 for accent
        }}>
          <span style={{
            color: TC.amber, fontSize: 14, fontWeight: 500, width: 16,
            display: 'inline-flex', justifyContent: 'center',
          }}>＃</span>
          <span style={{
            flex: 1, color: TC.th, fontSize: 15, fontWeight: 600,
            letterSpacing: -0.2,
          }}>{name}</span>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 6,
            color: TC.amber, fontSize: 12, fontWeight: 600,
            letterSpacing: -0.05,
          }}>
            <span style={{
              width: 5, height: 5, borderRadius: '50%', background: TC.amber,
              boxShadow: '0 0 6px rgba(245,158,11,0.6)',
            }} />
            {escalations === 1 ? '1 escalation' : `${escalations} escalations`}
          </div>
        </div>
      </div>
    );
  }

  return (
    <div
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        background: hov ? 'rgba(255,255,255,0.025)' : 'transparent',
        borderBottom: isLast ? 'none' : '1px solid rgba(255,255,255,0.04)',
        cursor: 'pointer', fontFamily: FONT,
        transition: 'background 120ms ease',
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '14px 16px',
      }}>
      <span style={{
        color: TC.tdd, fontSize: 14, fontWeight: 500, width: 16,
        display: 'inline-flex', justifyContent: 'center',
      }}>＃</span>
      <span style={{
        color: TC.th, fontSize: 15, fontWeight: 600, letterSpacing: -0.2,
        flexShrink: 0,
      }}>{name}</span>
      <span style={{
        flex: 1, minWidth: 0,
        color: TC.td, fontSize: 12, fontWeight: 400,
        whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        letterSpacing: -0.05,
      }}>
        <span style={{ color: TC.tdd }}>Last:</span> “{snippet}”
      </span>
      <span style={{
        color: TC.tdd, fontSize: 11, fontWeight: 500,
        fontVariantNumeric: 'tabular-nums', flexShrink: 0,
      }}>{time}</span>
    </div>
  );
}

function ChannelsSheet() {
  return (
    <div style={{
      position: 'absolute', left: 0, right: 0, bottom: 0,
      height: '76%',
      background: TC.sheet,
      borderTop: `1px solid ${TC.borderStr}`,
      borderRadius: '16px 16px 0 0',
      boxShadow: '0 -16px 48px rgba(0,0,0,0.6), 0 -2px 0 rgba(255,255,255,0.04)',
      zIndex: 15,
      display: 'flex', flexDirection: 'column',
      overflow: 'hidden',
      fontFamily: FONT,
    }}>
      {/* drag handle */}
      <div style={{
        display: 'flex', justifyContent: 'center',
        padding: '8px 0 6px',
        flexShrink: 0,
      }}>
        <div style={{
          width: 36, height: 4, borderRadius: 999,
          background: 'rgba(255,255,255,0.18)',
        }} />
      </div>

      {/* header */}
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        padding: '6px 16px 14px',
        flexShrink: 0,
      }}>
        <span style={{
          color: TC.th, fontSize: 14, fontWeight: 600, letterSpacing: -0.15,
        }}>Channels</span>
        <NewChannelBtn />
      </div>

      {/* divider */}
      <div style={{ height: 1, background: TC.border, marginBottom: 4 }} />

      {/* channel list */}
      <div style={{ flex: 1, overflowY: 'auto', overflowX: 'hidden' }} className="tc-scroll">
        <ChannelRow
          name="general"
          needsAttention
          escalations={1}
        />
        <ChannelRow
          name="health"
          snippet="p99 OK at 240ms"
          time="1h"
        />
        <ChannelRow
          name="planning"
          snippet="Q3 roadmap draft ready for review"
          time="4h"
        />
        <ChannelRow
          name="payments"
          snippet="Stripe webhooks ok"
          time="yesterday"
          isLast
        />
      </div>

      {/* bottom safe area for home indicator */}
      <div style={{ height: 34, flexShrink: 0 }} />
    </div>
  );
}

function NewChannelBtn() {
  const [hov, setHov] = React.useState(false);
  return (
    <button
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        display: 'inline-flex', alignItems: 'center', gap: 5,
        background: 'transparent', border: 'none', cursor: 'pointer',
        padding: '6px 4px',
        color: hov ? TC.tm : TC.td,
        fontSize: 12, fontWeight: 500, fontFamily: FONT,
        letterSpacing: -0.05,
        transition: 'color 120ms ease',
      }}>
      <svg width="11" height="11" viewBox="0 0 14 14" fill="none">
        <path d="M7 2.5v9M2.5 7h9" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
      </svg>
      New
    </button>
  );
}

function Screen3() {
  return (
    <div
      data-screen-label="03 Mobile · Channels sheet expanded"
      style={{
        width: '100%', height: '100%',
        background: TC.bg, color: TC.th, fontFamily: FONT,
        display: 'flex', flexDirection: 'column',
        position: 'relative', overflow: 'hidden',
      }}>
      <TCGlobalStyles />
      <div style={{ height: 56 }} />
      <AppHeader />
      <KanbanScroll escalatedTaskIdx={0} bottomPad={700} />
      {/* dim overlay over the kanban (sheet drops a heavier shadow over it) */}
      <div style={{
        position: 'absolute', left: 0, right: 0, top: 0, bottom: '76%',
        background: 'linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.25) 100%)',
        pointerEvents: 'none',
        zIndex: 10,
      }} />
      <ChannelsSheet />
    </div>
  );
}

window.Screen3 = Screen3;
