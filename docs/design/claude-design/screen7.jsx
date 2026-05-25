// Tally Coding · Screen 7 — Desktop escalation takeover
// BRUTAL TERMINAL skin · same shell as Screen 6, mini-dash swapped, first running card escalated

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

// ─── sidebar mini-dash — ESCALATION TAKEOVER variant ──────────────────

function SidebarQuickPrimary({ label }) {
  const [hov, setHov] = React.useState(false);
  return (
    <button
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        width: '100%', height: 34, borderRadius: 0,
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

function SidebarQuickOutline({ label }) {
  const [hov, setHov] = React.useState(false);
  return (
    <button
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        width: '100%', height: 34, borderRadius: 0,
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

function SidebarGhost({ children }) {
  const [hov, setHov] = React.useState(false);
  return (
    <button
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        background: 'transparent', border: 'none', padding: '4px 0',
        cursor: 'pointer', whiteSpace: 'nowrap',
        color: hov ? TC.fg : TC.fg_xdim,
        fontWeight: 700, fontSize: 10, letterSpacing: 0.6,
        textTransform: 'uppercase', fontFamily: FONT,
        display: 'inline-flex', alignItems: 'center', gap: 5,
        transition: 'color 120ms ease',
      }}
    >{children}</button>
  );
}

function SidebarMiniDash() {
  return (
    <div style={{
      flexShrink: 0,
      position: 'relative',
      background: TC.sheet,
      borderTop: `1px solid ${TC.amberLine}`,
      fontFamily: FONT,
      overflow: 'hidden',
    }}>
      {/* coral wash */}
      <div style={{
        position: 'absolute', inset: 0,
        background: TC.amberWash,
        pointerEvents: 'none',
      }} />

      <div style={{
        position: 'relative',
        padding: '12px 14px',
        display: 'flex', flexDirection: 'column', gap: 12,
      }}>
        {/* header row */}
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 8 }}>
          <TallyAvatar size={22} badgeSurface={TC.sheet} />
          <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 4, whiteSpace: 'nowrap' }}>
              <span style={{
                display: 'inline-flex', alignItems: 'center', gap: 2,
                color: TC.fg, fontSize: 12, fontWeight: 700, letterSpacing: 0,
              }}>
                <span style={{ color: TC.fg_xdim, fontWeight: 500, fontSize: 10.5 }}>＃</span>
                general
              </span>
              <span style={{ color: TC.fg_dimmer, fontSize: 10 }}>│</span>
              <span style={{
                color: TC.red, fontSize: 10, fontWeight: 700,
                letterSpacing: 0.6, textTransform: 'uppercase',
              }}>needs you</span>
            </div>
            <div style={{
              color: TC.fg_xdim, fontSize: 10.5, letterSpacing: 0,
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}>
              about: <span style={{ color: TC.fg_dim }}>Fix daily-deals</span>
            </div>
          </div>
          <div style={{
            display: 'inline-flex', alignItems: 'center',
            padding: '2px 5px', borderRadius: 0,
            background: 'transparent',
            border: `1px solid ${TC.red}`,
            color: TC.red, fontSize: 9.5, fontWeight: 700,
            letterSpacing: 0.4, fontVariantNumeric: 'tabular-nums',
            flexShrink: 0, whiteSpace: 'nowrap', textTransform: 'uppercase',
          }}>1/2</div>
        </div>

        {/* question */}
        <div style={{
          color: TC.fg_dim, fontSize: 12, fontWeight: 400,
          lineHeight: 1.45, letterSpacing: 0, textWrap: 'pretty',
        }}>
          Coder hit a rounding edge case. Round to{' '}
          <span style={{ color: TC.fg, fontWeight: 700 }}>2 decimals</span>
          {' '}or keep{' '}
          <span style={{ color: TC.fg, fontWeight: 700 }}>4</span>?
        </div>

        {/* quick replies — stacked */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <SidebarQuickPrimary label="2 decimals" />
          <SidebarQuickOutline label="Keep 4" />
        </div>

        {/* bottom row */}
        <div style={{
          display: 'flex', justifyContent: 'space-between', alignItems: 'center',
        }}>
          <SidebarGhost>
            <svg width="11" height="11" viewBox="0 0 14 14" fill="none">
              <rect x="1.5" y="2" width="11" height="8" stroke="currentColor" strokeWidth="1.3" fill="none"/>
              <path d="M4 10.5l-1 2 3-2" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="miter" fill="none"/>
            </svg>
            Open #general
          </SidebarGhost>
          <SidebarGhost>
            Skip
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none">
              <path d="M5 12h14M13 5l7 7-7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="square" strokeLinejoin="miter"/>
            </svg>
          </SidebarGhost>
        </div>
      </div>
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

function Screen7() {
  return (
    <div
      data-screen-label="07 Desktop · Kanban + sidebar · escalation takeover"
      style={{
        width: '100%', height: '100%',
        background: TC.bg, color: TC.fg, fontFamily: FONT,
        display: 'flex', flexDirection: 'row',
        position: 'relative', overflow: 'hidden',
      }}>
      <TCGlobalStyles />
      <Sidebar />
      <DesktopKanban escalatedTaskIdx={0} />
    </div>
  );
}

window.Screen7 = Screen7;
