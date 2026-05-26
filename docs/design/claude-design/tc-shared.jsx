// Tally Coding · shared tokens + components — BRUTAL TERMINAL skin
// Tokyo Night palette · JetBrains Mono everywhere · square corners
// solid colors only · no gradients, no shadows, no glassmorphism

const TC = {
  // Surfaces
  bg:        '#1a1b26',   // Tokyo Night bg
  elev:      '#24283b',   // elevated surface
  sheet:     '#1f2030',   // bottom sheet base
  border:    '#2f3349',   // hairline border
  borderStr: '#3b3f5c',   // stronger hairline

  // Text (semantic names + legacy aliases)
  fg:        '#c0caf5',   // primary text
  fg_dim:    '#a9b1d6',   // secondary text
  fg_xdim:   '#7a82af',   // tertiary text
  fg_dimmer: '#565f89',   // disabled/decorative

  th:  '#c0caf5',
  tm:  '#a9b1d6',
  td:  '#7a82af',
  tdd: '#565f89',

  // SIGNAL colors — ANSI semantic mapping
  green:     '#9ece6a',   // Tally · healthy · success · primary CTA
  red:       '#f7768e',   // escalation · alert · attention
  cyan:      '#7dcfff',   // Coder agent
  magenta:   '#bb9af7',   // Architect agent
  yellow:    '#e0af68',   // Reader agent
  orange:    '#ff9e64',   // Tester agent

  // Legacy amber tokens — remapped to coral red so old code keeps working
  amber:     '#f7768e',
  amberSoft: 'rgba(247,118,142,0.15)',
  amberWash: 'rgba(247,118,142,0.06)',
  amberLine: 'rgba(247,118,142,0.45)',

  // Legacy blue/purple — remapped to green
  blue:      '#9ece6a',
  blueDeep:  '#7aa854',
  purple:    '#9ece6a',

  // Card surfaces
  card:      'rgba(192,202,245,0.04)',
  cardHov:   'rgba(192,202,245,0.07)',
  bubble:    'rgba(192,202,245,0.06)',
};

const FONT = '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace';
const MONO = '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace';

// ─── global styles (terminal cursor blink replaces pulse) ──────────────
function TCGlobalStyles() {
  return (
    <style>{`
      @keyframes tcBlink {
        0%, 59%   { opacity: 1; }
        60%, 100% { opacity: 0; }
      }
      .tc-scroll::-webkit-scrollbar { display: none; }
      .tc-blink { animation: tcBlink 1.2s steps(1, end) infinite; }
    `}</style>
  );
}

// ─── avatars (solid color blocks, square, monogram letters) ────────────

function TallyAvatar({ size = 28, badge = true, badgeSurface = TC.bg }) {
  const sq = Math.max(6, Math.round(size * 0.30));
  return (
    <div style={{ width: size, height: size, position: 'relative', flexShrink: 0 }}>
      <div style={{
        width: size, height: size, borderRadius: 0,
        background: TC.green,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: TC.bg, fontWeight: 700, fontSize: size * 0.52,
        letterSpacing: 0, lineHeight: 1, fontFamily: FONT,
      }}>T</div>
      {badge && (
        <div
          className="tc-blink"
          style={{
            position: 'absolute', right: -1, bottom: -1,
            width: sq, height: sq,
            background: TC.green,
            border: `1px solid ${badgeSurface}`,
          }}
        />
      )}
    </div>
  );
}

const AGENT = {
  architect: { bg: TC.magenta, letter: 'A' },
  coder:     { bg: TC.cyan,    letter: 'C' },
  reader:    { bg: TC.yellow,  letter: 'R' },
  tester:    { bg: TC.orange,  letter: 'T' },
};

function AgentAvatar({ role = 'coder', size = 22, surface = TC.elev, pulse = true }) {
  const info = AGENT[role] || AGENT.coder;
  const cur = Math.max(4, Math.round(size * 0.28));
  return (
    <div style={{ width: size, height: size, position: 'relative', flexShrink: 0 }}>
      <div style={{
        width: size, height: size, borderRadius: 0,
        background: info.bg,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: TC.bg, fontWeight: 700, fontSize: size * 0.58,
        letterSpacing: 0, lineHeight: 1, fontFamily: FONT,
      }}>{info.letter}</div>
      {pulse && (
        <div
          className="tc-blink"
          style={{
            // pixel-square cursor INSIDE the avatar bottom-right
            position: 'absolute', right: 1, bottom: 1,
            width: cur, height: cur,
            background: TC.green,
          }}
        />
      )}
    </div>
  );
}

// ─── progress bar (solid green, square) ─────────────────────────────────

function ProgressBar({ pct = 0, height = 4 }) {
  return (
    <div style={{
      width: '100%', height, borderRadius: 0,
      background: TC.border,
    }}>
      <div style={{
        width: `${pct}%`, height: '100%',
        background: TC.green,
        borderRadius: 0,
      }} />
    </div>
  );
}

// ─── header pieces ──────────────────────────────────────────────────────

function TCIconBtn({ children }) {
  return (
    <button style={{
      width: 36, height: 36, borderRadius: 0,
      background: 'transparent', border: 'none', cursor: 'pointer',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
    }}>{children}</button>
  );
}

function AppHeader() {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      padding: '8px 16px 10px', gap: 12, fontFamily: FONT,
    }}>
      <button style={{
        display: 'flex', alignItems: 'center', gap: 8,
        background: 'transparent', border: 'none', padding: '6px 4px 6px 0',
        cursor: 'pointer', fontFamily: FONT,
      }}>
        <div style={{
          width: 24, height: 24, borderRadius: 0,
          background: TC.green,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: TC.bg, fontSize: 13, fontWeight: 700, lineHeight: 1,
          fontFamily: FONT,
        }}>P</div>
        <span style={{ color: TC.fg, fontSize: 14, fontWeight: 700, letterSpacing: 0 }}>
          pronoic
        </span>
        <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
          <path d="M2 3.5l3 3 3-3" stroke={TC.fg_xdim} strokeWidth="1.6" strokeLinecap="square" strokeLinejoin="miter"/>
        </svg>
      </button>

      <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
        <TCIconBtn>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <circle cx="10.5" cy="10.5" r="6.5" stroke={TC.fg_xdim} strokeWidth="1.6"/>
            <path d="M20 20l-4.5-4.5" stroke={TC.fg_xdim} strokeWidth="1.6" strokeLinecap="square"/>
          </svg>
        </TCIconBtn>
        <TCIconBtn>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <circle cx="12" cy="12" r="3" stroke={TC.fg_xdim} strokeWidth="1.6"/>
            <path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 11-2.83 2.83l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 11-4 0v-.09A1.65 1.65 0 008.5 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 11-2.83-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H2.5a2 2 0 010-4h.09A1.65 1.65 0 004.6 8.5a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 112.83-2.83l.06.06a1.65 1.65 0 001.82.33H9a1.65 1.65 0 001-1.51V2.5a2 2 0 014 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 112.83 2.83l-.06.06a1.65 1.65 0 00-.33 1.82V9a1.65 1.65 0 001.51 1H21.5a2 2 0 010 4h-.09a1.65 1.65 0 00-1.51 1z" stroke={TC.fg_xdim} strokeWidth="1.4"/>
          </svg>
        </TCIconBtn>
      </div>
    </div>
  );
}

// ─── kanban ─────────────────────────────────────────────────────────────

const COL_W = 234;
const COL_GAP = 12;

function ColumnHeader({ icon, name, count, dim }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 8,
      padding: '0 4px 12px', fontFamily: FONT,
    }}>
      <span style={{ fontSize: 14, lineHeight: 1, display: 'inline-flex', alignItems: 'center' }}>{icon}</span>
      <span style={{
        fontSize: 11, fontWeight: 700, color: dim ? TC.fg_xdim : TC.fg,
        textTransform: 'uppercase', letterSpacing: 0.8,
      }}>{name}</span>
      <span style={{
        fontSize: 10.5, fontWeight: 700,
        color: dim ? TC.fg_dimmer : TC.fg_xdim,
        padding: '1px 6px', borderRadius: 0,
        border: `1px solid ${TC.border}`,
        fontVariantNumeric: 'tabular-nums',
      }}>{count}</span>
    </div>
  );
}

function NewTaskRow() {
  const [hov, setHov] = React.useState(false);
  return (
    <button
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
        width: '100%', padding: '10px 0',
        background: hov ? 'rgba(192,202,245,0.04)' : 'transparent',
        border: 'none', borderRadius: 0,
        cursor: 'pointer', fontFamily: FONT,
        transition: 'background 120ms ease, color 120ms ease',
        color: hov ? TC.fg_dim : TC.fg_xdim,
      }}>
        <span style={{
          fontSize: 13, fontWeight: 700, letterSpacing: 0,
          fontFamily: FONT,
        }}>+</span>
      <span style={{
        fontSize: 12, fontWeight: 500, letterSpacing: 0,
        textTransform: 'lowercase',
      }}>new task</span>
    </button>
  );
}

function ColIcon({ kind }) {
  if (kind === 'todo') return (
    <svg width="13" height="13" viewBox="0 0 14 14" fill="none">
      <rect x="2" y="2" width="10" height="10" stroke={TC.fg_xdim} strokeWidth="1.4"/>
    </svg>
  );
  if (kind === 'planning') return (
    <svg width="13" height="13" viewBox="0 0 14 14" fill="none">
      <path d="M2 12l1-2 6-6 2 2-6 6-3 0z" stroke={TC.magenta} strokeWidth="1.4" strokeLinejoin="miter" fill="none"/>
    </svg>
  );
  if (kind === 'running') return (
    <svg width="13" height="13" viewBox="0 0 14 14" fill={TC.green}>
      <path d="M3 2l8 5-8 5V2z"/>
    </svg>
  );
  if (kind === 'awaiting') return (
    <svg width="13" height="13" viewBox="0 0 14 14" fill="none">
      <rect x="2" y="2" width="10" height="10" stroke={TC.red} strokeWidth="1.4"/>
      <rect x="6" y="2" width="6" height="10" fill={TC.red}/>
    </svg>
  );
  if (kind === 'done') return (
    <svg width="13" height="13" viewBox="0 0 14 14" fill="none">
      <path d="M3 7L6 10L11 4" stroke={TC.green} strokeWidth="1.8" strokeLinecap="square" strokeLinejoin="miter"/>
    </svg>
  );
  return null;
}

function BranchRef({ name }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 5,
      color: TC.fg_dimmer, fontSize: 10.5, fontFamily: MONO,
      letterSpacing: 0,
    }}>
      <svg width="9" height="9" viewBox="0 0 16 16" fill="none">
        <rect x="3" y="2" width="2" height="2" fill={TC.fg_dimmer}/>
        <rect x="3" y="12" width="2" height="2" fill={TC.fg_dimmer}/>
        <rect x="11" y="7" width="2" height="2" fill={TC.fg_dimmer}/>
        <path d="M4 4v8M5 11h2c2 0 3-1 3-3" stroke={TC.fg_dimmer} strokeWidth="1.2" fill="none"/>
      </svg>
      {name}
    </div>
  );
}

// Generic card frame — used by all card variants
function CardFrame({ children, escalated, hover, setHover }) {
  const isCoral = !!escalated;
  return (
    <div
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        background: isCoral
          ? 'rgba(247,118,142,0.05)'
          : (hover ? TC.cardHov : 'transparent'),
        border: `1px solid ${
          isCoral
            ? 'rgba(247,118,142,0.45)'
            : (hover ? TC.borderStr : TC.border)
        }`,
        borderRadius: 0, padding: '12px 13px',
        display: 'flex', flexDirection: 'column', gap: 10,
        cursor: 'pointer', fontFamily: FONT,
        transition: 'background 120ms ease, border-color 120ms ease',
      }}>{children}</div>
  );
}

function TodoCard({ title, branch, queued }) {
  const [hov, setHov] = React.useState(false);
  return (
    <CardFrame hover={hov} setHover={setHov}>
      {branch && <BranchRef name={branch} />}
      <div style={{
        fontSize: 13.5, fontWeight: 700, color: TC.fg,
        lineHeight: 1.35, letterSpacing: 0, textWrap: 'pretty',
      }}>{title}</div>
      {queued && (
        <div style={{
          color: TC.fg_dimmer, fontSize: 10, fontWeight: 700,
          textTransform: 'uppercase', letterSpacing: 0.8,
        }}>queued</div>
      )}
    </CardFrame>
  );
}

function PlanningCard({ title, agents, branch }) {
  const [hov, setHov] = React.useState(false);
  return (
    <CardFrame hover={hov} setHover={setHov}>
      {branch && <BranchRef name={branch} />}
      <div style={{
        fontSize: 13.5, fontWeight: 700, color: TC.fg,
        lineHeight: 1.35, letterSpacing: 0, textWrap: 'pretty',
      }}>{title}</div>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ display: 'flex', gap: 6 }}>
          {agents.map((r, i) => <AgentAvatar key={i} role={r} surface={TC.bg} />)}
        </div>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 5,
          color: TC.magenta, fontSize: 10, fontWeight: 700,
          textTransform: 'uppercase', letterSpacing: 0.8,
        }}>
          <span style={{ width: 5, height: 5, background: TC.magenta }} />
          planning
        </div>
      </div>
    </CardFrame>
  );
}

function DoneCard({ title, branch, when }) {
  const [hov, setHov] = React.useState(false);
  return (
    <div
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        background: hov ? TC.cardHov : 'transparent',
        border: `1px solid ${hov ? TC.borderStr : TC.border}`,
        borderRadius: 0, padding: '12px 13px',
        display: 'flex', flexDirection: 'column', gap: 8,
        cursor: 'pointer', fontFamily: FONT,
        opacity: hov ? 1 : 0.7,
        transition: 'background 120ms ease, border-color 120ms ease, opacity 120ms ease',
    }}>
      {branch && <BranchRef name={branch} />}
      <div style={{
        fontSize: 13.5, fontWeight: 700, color: TC.fg,
        lineHeight: 1.35, letterSpacing: 0, textWrap: 'pretty',
      }}>{title}</div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: TC.green, fontSize: 10, fontWeight: 700 }}>
        <span style={{ width: 5, height: 5, background: TC.green }} />
        <span style={{ textTransform: 'uppercase', letterSpacing: 0.8 }}>shipped</span>
        <span style={{ color: TC.fg_dimmer, fontWeight: 500, textTransform: 'none', letterSpacing: 0, marginLeft: 'auto' }}>{when}</span>
      </div>
    </div>
  );
}

function TaskCard({ title, agents, progress, eta, branch, escalated }) {
  const [hov, setHov] = React.useState(false);
  return (
    <CardFrame hover={hov} setHover={setHov} escalated={escalated}>
      {branch && <BranchRef name={branch} />}
      <div style={{
        fontSize: 13.5, fontWeight: 700, color: TC.fg,
        lineHeight: 1.35, letterSpacing: 0, textWrap: 'pretty',
      }}>{title}</div>

      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ display: 'flex', gap: 6 }}>
          {agents.map((r, i) => <AgentAvatar key={i} role={r} surface={TC.bg} pulse={!escalated} />)}
        </div>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 5,
          color: escalated ? TC.red : TC.fg_xdim,
          fontSize: 10.5, fontWeight: 700,
          fontVariantNumeric: 'tabular-nums', textTransform: 'uppercase', letterSpacing: 0.4,
        }}>
          <span style={{
            width: 5, height: 5,
            background: escalated ? TC.red : TC.green,
          }} />
          {eta}
        </div>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
        <ProgressBar pct={progress} />
        <div style={{
          display: 'flex', justifyContent: 'space-between',
          fontSize: 10, color: TC.fg_dimmer, fontVariantNumeric: 'tabular-nums',
        }}>
          <span style={{
            textTransform: 'uppercase', letterSpacing: 0.8, fontWeight: 700,
            color: escalated ? TC.red : TC.fg_xdim,
          }}>
            {escalated ? 'paused · needs you' : 'running'}
          </span>
          <span style={{ fontWeight: 700 }}>{progress}%</span>
        </div>
      </div>
    </CardFrame>
  );
}

function AwaitingCard({ title, branch, action }) {
  const [hov, setHov] = React.useState(false);
  return (
    <div
      onMouseEnter={() => setHov(true)}
      onMouseLeave={() => setHov(false)}
      style={{
        background: hov ? 'rgba(247,118,142,0.08)' : 'rgba(247,118,142,0.05)',
        border: `1px solid ${hov ? 'rgba(247,118,142,0.55)' : 'rgba(247,118,142,0.40)'}`,
        borderRadius: 0, padding: '12px 13px',
        display: 'flex', flexDirection: 'column', gap: 8, fontFamily: FONT,
        cursor: 'pointer',
        transition: 'background 120ms ease, border-color 120ms ease',
    }}>
      {branch && <BranchRef name={branch} />}
      <div style={{
        fontSize: 13.5, fontWeight: 700, color: TC.fg,
        lineHeight: 1.35, letterSpacing: 0,
      }}>{title}</div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <span style={{ width: 5, height: 5, background: TC.red }} />
        <span style={{
          color: TC.red, fontSize: 10.5, fontWeight: 700,
          textTransform: 'uppercase', letterSpacing: 0.6,
        }}>{action}</span>
      </div>
    </div>
  );
}

// ─── kanban scroll (5 columns) ──────────────────────────────────────────

function KanbanScroll({ bottomPad = 240, escalatedTaskIdx = null }) {
  const Col = ({ children }) => (
    <div style={{ width: COL_W, flexShrink: 0, display: 'flex', flexDirection: 'column' }}>
      {children}
    </div>
  );
  const Stack = ({ children }) => (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>{children}</div>
  );

  return (
    <div className="tc-scroll" style={{
      flex: 1, overflowX: 'auto', overflowY: 'hidden',
      WebkitOverflowScrolling: 'touch', scrollbarWidth: 'none',
    }}>
      <div style={{
        display: 'flex', gap: COL_GAP,
        padding: `4px 16px ${bottomPad}px`, minWidth: 'max-content',
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

Object.assign(window, {
  TC, FONT, MONO, COL_W, COL_GAP,
  TCGlobalStyles, TallyAvatar, AgentAvatar, ProgressBar,
  AppHeader, KanbanScroll, TaskCard, ColumnHeader, ColIcon, NewTaskRow,
  TodoCard, PlanningCard, AwaitingCard, DoneCard, BranchRef,
});
