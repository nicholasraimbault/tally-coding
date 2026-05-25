// Tally Coding · Screen 3 — Channels sheet expanded (RICH variant)
// BRUTAL TERMINAL skin · square corners · mono uppercase labels

// ─── small author avatars (solid color blocks, square, monogram) ─────────

function TallyAvatarSm({ size = 14, surface = TC.sheet }) {
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
      <div
        className="tc-blink"
        style={{
          position: 'absolute', right: -1, bottom: -1,
          width: cur, height: cur,
          background: TC.green,
          border: `1px solid ${surface}`,
        }}
      />
    </div>
  );
}

function YouAvatarSm({ size = 14 }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: 0,
      background: TC.green,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      color: TC.bg, fontWeight: 700, fontSize: Math.max(8, size * 0.62),
      letterSpacing: 0, lineHeight: 1, fontFamily: FONT, flexShrink: 0,
    }}>Y</div>
  );
}

// ─── inline snippet ─────────────────────────────────────────────────────

function ChannelSnippet({ author, snippet }) {
  const avatar = author === 'tally'
    ? <TallyAvatarSm size={14} />
    : <YouAvatarSm size={14} />;
  const name = author === 'tally' ? 'Tally' : 'You';

  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 6,
      minWidth: 0, fontFamily: FONT,
    }}>
      {avatar}
      <span style={{
        color: TC.fg, fontSize: 11.5, fontWeight: 700,
        letterSpacing: 0, flexShrink: 0,
      }}>{name}</span>
      <span style={{ color: TC.fg_dimmer, fontSize: 11.5, flexShrink: 0 }}>:</span>
      <span style={{
        flex: 1, minWidth: 0,
        color: TC.fg_dim, fontSize: 11.5, fontWeight: 400,
        letterSpacing: 0,
        whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
      }}>{snippet}</span>
    </div>
  );
}

// ─── calm row (2 lines) ─────────────────────────────────────────────────

function CalmChannelRow({ name, topic, time, author, snippet, isLast }) {
  const [hov, setHov] = React.useState(false);
  return (
    <div
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        background: hov ? 'rgba(192,202,245,0.04)' : 'transparent',
        borderBottom: isLast ? 'none' : `1px solid ${TC.border}`,
        cursor: 'pointer', fontFamily: FONT,
        transition: 'background 120ms ease',
        padding: '12px 16px',
        display: 'flex', flexDirection: 'column', gap: 5,
      }}>
      {/* line 1 — name · topic + time */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{
          color: TC.fg_xdim, fontSize: 13, fontWeight: 500, width: 14,
          display: 'inline-flex', justifyContent: 'center', lineHeight: 1,
        }}>＃</span>
        <span style={{
          color: TC.fg, fontSize: 14, fontWeight: 700,
          letterSpacing: 0, flexShrink: 0, lineHeight: 1.1,
        }}>{name}</span>
        <span style={{ color: TC.fg_dimmer, fontSize: 11, flexShrink: 0 }}>│</span>
        <span style={{
          flex: 1, minWidth: 0,
          color: TC.fg_xdim, fontSize: 10.5, fontWeight: 500,
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
          letterSpacing: 0.4, textTransform: 'uppercase',
        }}>{topic}</span>
        <span style={{
          color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700,
          fontVariantNumeric: 'tabular-nums', flexShrink: 0,
        }}>{time}</span>
      </div>

      {/* line 2 — snippet with author avatar */}
      <div style={{ paddingLeft: 22 }}>
        <ChannelSnippet author={author} snippet={snippet} />
      </div>
    </div>
  );
}

// ─── needs-attention card (3 lines) ─────────────────────────────────────

function NeedsAttentionRow({ name, count, taskTitle }) {
  const [hov, setHov] = React.useState(false);
  return (
    <div
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        position: 'relative',
        background: hov ? 'rgba(247,118,142,0.08)' : 'rgba(247,118,142,0.05)',
        borderBottom: `1px solid ${TC.amberLine}`,
        cursor: 'pointer', fontFamily: FONT,
        transition: 'background 120ms ease',
      }}>
      {/* 3px coral left-edge accent — no glow */}
      <div style={{
        position: 'absolute', left: 0, top: 0, bottom: 0,
        width: 3, background: TC.red,
      }} />

      <div style={{
        padding: '14px 16px 14px 19px',
        display: 'flex', flexDirection: 'column', gap: 7,
      }}>
        {/* line 1 — header */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{
            color: TC.red, fontSize: 13, fontWeight: 500, width: 14,
            display: 'inline-flex', justifyContent: 'center', lineHeight: 1,
          }}>＃</span>
          <span style={{
            flex: 1, color: TC.fg, fontSize: 14, fontWeight: 700,
            letterSpacing: 0, lineHeight: 1.1,
          }}>{name}</span>
          <div style={{
            display: 'inline-flex', alignItems: 'center', gap: 5,
            padding: '2px 7px', borderRadius: 0,
            background: 'transparent',
            border: `1px solid ${TC.red}`,
            color: TC.red, fontSize: 10, fontWeight: 700,
            letterSpacing: 0.6, fontVariantNumeric: 'tabular-nums',
            flexShrink: 0, textTransform: 'uppercase',
          }}>
            <span style={{ width: 5, height: 5, background: TC.red }} />
            {count === 1 ? '1 escalation' : `${count} escalations`}
          </div>
          <svg width="11" height="11" viewBox="0 0 12 12" fill="none">
            <path d="M4 2l4 4-4 4" stroke={TC.red} strokeWidth="1.8"
                  strokeLinecap="square" strokeLinejoin="miter"/>
          </svg>
        </div>

        {/* line 2 — Tally narrator inline */}
        <div style={{
          paddingLeft: 22,
          display: 'flex', alignItems: 'center', gap: 7,
        }}>
          <TallyAvatarSm size={16} surface="#26171c" />
          <span style={{
            color: TC.red, fontSize: 11, fontWeight: 700,
            letterSpacing: 0.6, textTransform: 'uppercase', flex: 1,
          }}>Tally needs you</span>
          <span style={{
            color: 'rgba(247,118,142,0.75)', fontSize: 10.5, fontWeight: 700,
            fontVariantNumeric: 'tabular-nums',
            textTransform: 'uppercase', letterSpacing: 0.4,
          }}>2m ago</span>
        </div>

        {/* line 3 — task context */}
        <div style={{
          paddingLeft: 22,
          display: 'flex', alignItems: 'center', gap: 6,
          minWidth: 0,
        }}>
          {/* task icon in coral — square outline */}
          <svg width="11" height="11" viewBox="0 0 14 14" fill="none" style={{ flexShrink: 0 }}>
            <rect x="2" y="2" width="10" height="10" stroke={TC.red} strokeWidth="1.4"/>
            <path d="M4.5 5.5h5M4.5 7.5h5M4.5 9.5h3" stroke={TC.red} strokeWidth="1.2" strokeLinecap="square"/>
          </svg>
          <span style={{
            color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700, flexShrink: 0,
            letterSpacing: 0.5, textTransform: 'uppercase',
          }}>About:</span>
          <span style={{
            flex: 1, minWidth: 0,
            color: TC.fg_dim, fontSize: 11.5, fontWeight: 500,
            letterSpacing: 0,
            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
          }}>{taskTitle}</span>
        </div>
      </div>
    </div>
  );
}

// ─── header ─────────────────────────────────────────────────────────────

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
        color: hov ? TC.fg : TC.fg_xdim,
        fontSize: 10.5, fontWeight: 700, fontFamily: FONT,
        letterSpacing: 0.6, textTransform: 'uppercase',
        transition: 'color 120ms ease',
      }}>
      <span style={{ fontSize: 12, lineHeight: 1 }}>+</span>
      New
    </button>
  );
}

// ─── sheet ──────────────────────────────────────────────────────────────

function ChannelsSheet() {
  return (
    <div style={{
      position: 'absolute', left: 0, right: 0, bottom: 0,
      height: '76%',
      background: TC.sheet,
      borderTop: `1px solid ${TC.borderStr}`,
      borderRadius: 0,
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
          background: TC.border,
        }} />
      </div>

      {/* header */}
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        padding: '6px 16px 12px',
        flexShrink: 0,
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{
            color: TC.fg, fontSize: 11, fontWeight: 700, letterSpacing: 1,
            textTransform: 'uppercase',
          }}>Channels</span>
          <span style={{
            color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700,
            padding: '1px 6px', borderRadius: 0,
            border: `1px solid ${TC.border}`,
            fontVariantNumeric: 'tabular-nums',
          }}>4</span>
        </div>
        <NewChannelBtn />
      </div>

      {/* activity strip */}
      <div style={{
        textAlign: 'center',
        padding: '4px 16px 10px',
        color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700,
        letterSpacing: 0.8, textTransform: 'uppercase',
        borderBottom: `1px solid ${TC.border}`,
        flexShrink: 0,
      }}>
        Today · 8 messages · <span style={{ color: TC.red }}>1 needs you</span>
      </div>

      {/* channel list */}
      <div style={{ flex: 1, overflowY: 'auto', overflowX: 'hidden' }} className="tc-scroll">
        <NeedsAttentionRow
          name="general"
          count={1}
          taskTitle="Fix daily-deals price formatting"
        />
        <CalmChannelRow
          name="health"
          topic="service health & alerts"
          time="12m"
          author="tally"
          snippet="p99 OK at 240ms — service healthy"
        />
        <CalmChannelRow
          name="planning"
          topic="roadmap & decisions"
          time="1h"
          author="you"
          snippet="Q3 roadmap draft ready for review"
        />
        <CalmChannelRow
          name="payments"
          topic="Stripe & webhooks"
          time="yesterday"
          author="tally"
          snippet="Stripe webhooks approved — running smoothly"
          isLast
        />
      </div>

      {/* safe area */}
      <div style={{ height: 34, flexShrink: 0 }} />
    </div>
  );
}

function Screen3() {
  return (
    <div
      data-screen-label="03 Mobile · Channels sheet expanded"
      style={{
        width: '100%', height: '100%',
        background: TC.bg, color: TC.fg, fontFamily: FONT,
        display: 'flex', flexDirection: 'column',
        position: 'relative', overflow: 'hidden',
      }}>
      <TCGlobalStyles />
      <div style={{ height: 56 }} />
      <AppHeader />
      <KanbanScroll escalatedTaskIdx={0} bottomPad={700} />
      {/* dim overlay over the kanban — flat (no gradient) */}
      <div style={{
        position: 'absolute', left: 0, right: 0, top: 0, bottom: '76%',
        background: 'rgba(0,0,0,0.35)',
        pointerEvents: 'none',
        zIndex: 10,
      }} />
      <ChannelsSheet />
    </div>
  );
}

window.Screen3 = Screen3;
