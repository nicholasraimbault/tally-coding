// Tally Coding · Screen 6 — Desktop ambient (kanban + sidebar)
// BRUTAL TERMINAL skin · square corners · mono uppercase chrome

const SIDEBAR_W = 240;
const DESK_COL_W = 220;
const DESK_COL_GAP = 14;

// ─── workspace row ──────────────────────────────────────────────────────

function WorkspaceRow() {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 10,
      padding: '14px 14px',
      borderBottom: `1px solid ${TC.border}`,
      fontFamily: FONT, flexShrink: 0,
    }}>
      <div style={{
        width: 24, height: 24, borderRadius: 0,
        background: TC.green,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: TC.bg, fontSize: 13, fontWeight: 700, flexShrink: 0,
        fontFamily: FONT, lineHeight: 1,
      }}>P</div>
      <span style={{
        flex: 1, color: TC.fg, fontSize: 14, fontWeight: 700,
        letterSpacing: 0,
      }}>pronoic</span>
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
        <path d="M2 3.5l3 3 3-3" stroke={TC.fg_xdim} strokeWidth="1.6" strokeLinecap="square" strokeLinejoin="miter"/>
      </svg>
      <button style={{
        marginLeft: 4, width: 26, height: 26, borderRadius: 0,
        background: 'transparent', border: 'none', cursor: 'pointer',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
          <circle cx="10.5" cy="10.5" r="6.5" stroke={TC.fg_xdim} strokeWidth="1.8"/>
          <path d="M20 20l-4.5-4.5" stroke={TC.fg_xdim} strokeWidth="1.8" strokeLinecap="square"/>
        </svg>
      </button>
    </div>
  );
}

// ─── section label ──────────────────────────────────────────────────────

function SidebarSectionLabel({ label, count }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 6,
      padding: '14px 14px 6px',
      fontFamily: FONT,
    }}>
      <span style={{
        color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700,
        textTransform: 'uppercase', letterSpacing: 1,
      }}>{label}</span>
      {count != null && (
        <span style={{
          color: TC.fg_xdim, fontSize: 10.5, fontWeight: 700,
          padding: '1px 6px', borderRadius: 0,
          border: `1px solid ${TC.border}`,
          fontVariantNumeric: 'tabular-nums',
        }}>{count}</span>
      )}
      <div style={{ flex: 1 }} />
      <button style={{
        width: 22, height: 22, borderRadius: 0,
        background: 'transparent', border: 'none', cursor: 'pointer',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: TC.fg_xdim, fontFamily: FONT, fontSize: 14, fontWeight: 700,
        lineHeight: 1,
      }}>+</button>
    </div>
  );
}

// ─── channel rows ───────────────────────────────────────────────────────

function SidebarChannel({ name, needsAttention, count }) {
  const [hov, setHov] = React.useState(false);

  if (needsAttention) {
    return (
      <div
        onMouseEnter={() => setHov(true)}
        onMouseLeave={() => setHov(false)}
        style={{
          position: 'relative',
          background: hov ? 'rgba(247,118,142,0.08)' : 'rgba(247,118,142,0.05)',
          cursor: 'pointer', fontFamily: FONT,
          transition: 'background 120ms ease',
        }}>
        {/* 3px coral left accent — no glow */}
        <div style={{
          position: 'absolute', left: 0, top: 0, bottom: 0,
          width: 3, background: TC.red,
        }} />
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8,
          padding: '7px 14px 7px 17px',
        }}>
          <span style={{
            color: TC.red, fontSize: 13, width: 14,
            display: 'inline-flex', justifyContent: 'center', lineHeight: 1,
          }}>＃</span>
          <span style={{
            flex: 1, color: TC.fg, fontSize: 13, fontWeight: 700,
            letterSpacing: 0,
          }}>{name}</span>
          <span style={{
            display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
            minWidth: 18, height: 18, padding: '0 5px', borderRadius: 0,
            background: 'transparent',
            border: `1px solid ${TC.red}`,
            color: TC.red, fontSize: 10, fontWeight: 700,
            fontVariantNumeric: 'tabular-nums',
          }}>{count}</span>
          <svg width="10" height="10" viewBox="0 0 12 12" fill="none">
            <path d="M4 2l4 4-4 4" stroke={TC.red} strokeWidth="1.8"
                  strokeLinecap="square" strokeLinejoin="miter"/>
          </svg>
        </div>
      </div>
    );
  }

  return (
    <div
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        background: hov ? 'rgba(192,202,245,0.04)' : 'transparent',
        cursor: 'pointer', fontFamily: FONT,
        transition: 'background 120ms ease',
        display: 'flex', alignItems: 'center', gap: 8,
        padding: '7px 14px',
      }}>
      <span style={{
        color: TC.fg_xdim, fontSize: 13, width: 14,
        display: 'inline-flex', justifyContent: 'center', lineHeight: 1,
      }}>＃</span>
      <span style={{
        flex: 1, color: hov ? TC.fg : TC.fg_dim, fontSize: 13, fontWeight: 700,
        letterSpacing: 0,
        transition: 'color 120ms ease',
      }}>{name}</span>
    </div>
  );
}

// ─── sidebar mini-dash (no drag handle, square) ─────────────────────────

function SidebarMiniRow({ title, agents, progress }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 7, padding: '6px 0',
    }}>
      <div style={{ display: 'flex', gap: 3, flexShrink: 0 }}>
        {agents.map((r, i) => <AgentAvatar key={i} role={r} size={16} surface={TC.sheet} pulse={i === 0} />)}
      </div>
      <div style={{
        flex: 1, color: TC.fg_dim, fontSize: 11.5, fontWeight: 500,
        whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        letterSpacing: 0, fontFamily: FONT,
        minWidth: 0,
      }}>{title}</div>
      <div style={{ width: 42, flexShrink: 0 }}>
        <ProgressBar pct={progress} height={3} />
      </div>
      <span style={{
        color: TC.fg_xdim, fontSize: 10, fontWeight: 700,
        fontVariantNumeric: 'tabular-nums', minWidth: 22, textAlign: 'right',
        fontFamily: FONT, flexShrink: 0,
      }}>{progress}%</span>
    </div>
  );
}

function SidebarTallyBubble() {
  return (
    <div style={{ display: 'flex', gap: 8, alignItems: 'flex-end', paddingTop: 6 }}>
      <TallyAvatar size={22} badgeSurface={TC.sheet} />
      <div style={{
        background: 'transparent',
        border: `1px solid ${TC.border}`,
        borderRadius: 0,
        padding: '8px 10px 9px',
        color: TC.fg_dim, fontSize: 11.5, lineHeight: 1.45,
        letterSpacing: 0, fontFamily: FONT,
        textWrap: 'pretty',
        maxWidth: 178,
      }}>
        Diagnosed the daily-deals bug.{' '}
        <span style={{ color: TC.fg, fontWeight: 700 }}>Coder is patching</span>
        {' '}— PR in ~5 min.
      </div>
    </div>
  );
}

function SidebarMiniDash() {
  return (
    <div style={{
      flexShrink: 0,
      background: TC.sheet,
      borderTop: `1px solid ${TC.border}`,
      padding: '12px 14px 14px',
      display: 'flex', flexDirection: 'column', gap: 8,
      fontFamily: FONT,
    }}>
      {/* stat row */}
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 7 }}>
        <span style={{
          fontSize: 16, fontWeight: 700, color: TC.fg, letterSpacing: 0,
          fontVariantNumeric: 'tabular-nums', lineHeight: 1,
        }}>6</span>
        <span style={{
          fontSize: 10, color: TC.fg_xdim, fontWeight: 700,
          textTransform: 'uppercase', letterSpacing: 0.6,
        }}>open</span>
        <span style={{ color: TC.fg_dimmer, fontSize: 11, padding: '0 3px' }}>│</span>
        <span style={{
          fontSize: 16, fontWeight: 700, color: TC.fg, letterSpacing: 0,
          fontVariantNumeric: 'tabular-nums', lineHeight: 1,
        }}>3</span>
        <span style={{
          fontSize: 10, color: TC.fg_xdim, fontWeight: 700,
          textTransform: 'uppercase', letterSpacing: 0.6,
        }}>done today</span>
      </div>

      {/* per-task rows */}
      <div style={{
        borderTop: `1px solid ${TC.border}`, marginTop: 2, paddingTop: 2,
      }}>
        <SidebarMiniRow title="Fix daily-deals price…" agents={['architect','coder']} progress={60} />
        <div style={{ height: 1, background: TC.border }} />
        <SidebarMiniRow title="Build email digest worker" agents={['coder']} progress={30} />
      </div>

      <SidebarTallyBubble />
    </div>
  );
}

// ─── sidebar shell ──────────────────────────────────────────────────────

function Sidebar() {
  return (
    <div style={{
      width: SIDEBAR_W, height: '100%',
      background: TC.bg,
      borderRight: `1px solid ${TC.border}`,
      display: 'flex', flexDirection: 'column',
      flexShrink: 0,
    }}>
      <WorkspaceRow />
      <div style={{ flex: 1, overflowY: 'auto', overflowX: 'hidden' }} className="tc-scroll">
        <SidebarSectionLabel label="Channels" count={4} />
        <div style={{ display: 'flex', flexDirection: 'column' }}>
          <SidebarChannel name="general" needsAttention count={1} />
          <SidebarChannel name="health" />
          <SidebarChannel name="planning" />
          <SidebarChannel name="payments" />
        </div>
      </div>
      <SidebarMiniDash />
    </div>
  );
}

// ─── desktop kanban ─────────────────────────────────────────────────────

function DesktopKanban({ escalatedTaskIdx = null }) {
  const Col = ({ children }) => (
    <div style={{
      width: DESK_COL_W, flexShrink: 0,
      display: 'flex', flexDirection: 'column',
    }}>{children}</div>
  );
  const Stack = ({ children }) => (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>{children}</div>
  );

  return (
    <div style={{
      flex: 1, height: '100%',
      background: TC.bg, color: TC.fg,
      overflowY: 'auto', overflowX: 'hidden',
      fontFamily: FONT,
    }} className="tc-scroll">
      <div style={{
        padding: '20px 20px 28px',
        display: 'flex', gap: DESK_COL_GAP,
        minWidth: 'max-content',
      }}>
        <Col>
          <ColumnHeader icon={<ColIcon kind="todo" />} name="to do" count="2" dim />
          <Stack>
            <TodoCard branch="idea/refunds-csv" title="Add refunds CSV export to admin" queued />
            <TodoCard branch="idea/cart-abandon" title="Cart-abandonment email sequence" queued />
            <NewTaskRow />
          </Stack>
        </Col>

        <Col>
          <ColumnHeader icon={<ColIcon kind="planning" />} name="planning" count="1" />
          <Stack>
            <PlanningCard
              branch="feat/inventory-sync"
              title="Sync inventory across Shopify locations"
              agents={['architect']}
            />
            <NewTaskRow />
          </Stack>
        </Col>

        <Col>
          <ColumnHeader icon={<ColIcon kind="running" />} name="running" count="2" />
          <Stack>
            <TaskCard
              branch="feat/daily-deals-fmt"
              title="Fix daily-deals price formatting"
              agents={['architect', 'coder']}
              progress={60}
              eta={escalatedTaskIdx === 0 ? 'needs you' : '~5m left'}
              escalated={escalatedTaskIdx === 0}
            />
            <TaskCard
              branch="feat/email-digest"
              title="Build email digest worker"
              agents={['coder']}
              progress={30}
              eta="~22m left"
            />
            <NewTaskRow />
          </Stack>
        </Col>

        <Col>
          <ColumnHeader icon={<ColIcon kind="awaiting" />} name="awaiting" count="1" />
          <Stack>
            <AwaitingCard
              branch="feat/stripe-webhooks"
              title="Wire up Stripe webhooks for refunds"
              action="review PR #482"
            />
            <NewTaskRow />
          </Stack>
        </Col>

        <Col>
          <ColumnHeader icon={<ColIcon kind="done" />} name="done" count="3" dim />
          <Stack>
            <DoneCard branch="fix/checkout-tax" title="Checkout tax calc for EU customers" when="2h ago" />
            <DoneCard branch="feat/order-search" title="Order search by SKU + email" when="4h ago" />
            <DoneCard branch="chore/deps-bump" title="Bump Flutter to 3.24, tests green" when="9h ago" />
            <NewTaskRow />
          </Stack>
        </Col>
      </div>
    </div>
  );
}

function Screen6() {
  return (
    <div
      data-screen-label="06 Desktop · Kanban + sidebar · ambient"
      style={{
        width: '100%', height: '100%',
        background: TC.bg, color: TC.fg, fontFamily: FONT,
        display: 'flex', flexDirection: 'row',
        position: 'relative', overflow: 'hidden',
      }}>
      <TCGlobalStyles />
      <Sidebar />
      <DesktopKanban />
    </div>
  );
}

window.Screen6 = Screen6;
