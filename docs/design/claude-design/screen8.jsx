// Tally Coding · Screen 8 — iOS lock-screen push notification
// 390 × 844 · brand-neutral dark wallpaper · expanded notif with actions

const SF = '-apple-system, "SF Pro Display", "SF Pro", system-ui, sans-serif';
const SF_ROUNDED = '-apple-system, "SF Pro Rounded", "SF Pro Display", system-ui, sans-serif';

// ─── lock-screen clock block ────────────────────────────────────────────

function LockClock() {
  return (
    <div style={{
      paddingTop: 110, // below status bar
      textAlign: 'center',
      color: '#fff',
      pointerEvents: 'none',
    }}>
      <div style={{
        fontFamily: SF,
        fontSize: 17, fontWeight: 500,
        color: 'rgba(255,255,255,0.78)',
        letterSpacing: 0.2,
        lineHeight: 1.2,
        marginBottom: 4,
      }}>Tuesday, May 13</div>
      <div style={{
        fontFamily: SF_ROUNDED,
        fontSize: 92, fontWeight: 700,
        color: '#fff',
        letterSpacing: -3,
        lineHeight: 0.95,
        fontVariantNumeric: 'tabular-nums',
      }}>9:41</div>
    </div>
  );
}

// ─── app icon (Tally Coding) ────────────────────────────────────────────

function TallyAppIcon({ size = 38 }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: 9,
      background: TC.green,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      color: TC.bg, fontWeight: 700, fontSize: size * 0.50,
      letterSpacing: 0, lineHeight: 1,
      fontFamily: '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace',
      flexShrink: 0,
    }}>T</div>
  );
}

// ─── notification card ─────────────────────────────────────────────────

function NotifAction({ label, accent, last }) {
  const color = accent ? TC.green : 'rgba(255,255,255,0.95)';
  return (
    <button style={{
      width: '100%', height: 44,
      background: 'transparent',
      border: 'none',
      borderTop: '0.5px solid rgba(255,255,255,0.12)',
      cursor: 'pointer',
      color, fontFamily: SF,
      fontSize: 16, fontWeight: accent ? 600 : 500,
      letterSpacing: -0.2,
      borderBottomLeftRadius: last ? 18 : 0,
      borderBottomRightRadius: last ? 18 : 0,
      transition: 'background 80ms ease',
    }}
    onMouseDown={e => e.currentTarget.style.background = 'rgba(255,255,255,0.06)'}
    onMouseUp={e => e.currentTarget.style.background = 'transparent'}
    onMouseLeave={e => e.currentTarget.style.background = 'transparent'}
    >{label}</button>
  );
}

function NotificationCard() {
  return (
    <div style={{
      position: 'relative',
      width: 360,
      borderRadius: 18,
      background: 'rgba(28, 28, 30, 0.72)',
      backdropFilter: 'blur(20px) saturate(180%)',
      WebkitBackdropFilter: 'blur(20px) saturate(180%)',
      border: '0.5px solid rgba(255,255,255,0.10)',
      boxShadow: '0 8px 32px rgba(0,0,0,0.4), 0 2px 8px rgba(0,0,0,0.3)',
      overflow: 'hidden',
    }}>
      {/* header */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '12px 14px 8px',
      }}>
        <TallyAppIcon />
        <div style={{
          flex: 1, minWidth: 0,
          display: 'flex', flexDirection: 'column', justifyContent: 'center',
          gap: 1,
        }}>
          <div style={{
            fontFamily: SF, fontSize: 12, fontWeight: 700,
            color: '#fff', letterSpacing: 0.8,
            textTransform: 'uppercase',
            lineHeight: 1.2,
          }}>TALLY CODING</div>
          <div style={{
            fontFamily: SF, fontSize: 12, fontWeight: 400,
            color: 'rgba(255,255,255,0.55)',
            letterSpacing: -0.05, lineHeight: 1.2,
          }}>now · Pronoic</div>
        </div>
      </div>

      {/* body */}
      <div style={{ padding: '0 14px 14px' }}>
        <div style={{
          fontFamily: SF, fontSize: 15, fontWeight: 600,
          color: '#fff', letterSpacing: -0.2,
          lineHeight: 1.25,
        }}>Tally needs you</div>
        <div style={{
          marginTop: 4,
          fontFamily: SF, fontSize: 14, fontWeight: 400,
          color: 'rgba(255,255,255,0.85)',
          letterSpacing: -0.15,
          lineHeight: 1.32, textWrap: 'pretty',
        }}>
          Coder hit a rounding edge case on Fix daily-deals. Round to 2 decimals or keep 4?
        </div>
      </div>

      {/* actions — stacked, separated by hairlines */}
      <NotifAction label="2 decimals" accent />
      <NotifAction label="Keep 4" />
      <NotifAction label="Open" accent last />
    </div>
  );
}

// ─── second notification (queued, behind) ───────────────────────────────

function QueuedHint() {
  return (
    <div style={{
      width: 348, height: 14,
      marginTop: 6, // sits ~6px below the main card
      borderRadius: 16,
      background: 'rgba(28, 28, 30, 0.55)',
      backdropFilter: 'blur(18px) saturate(180%)',
      WebkitBackdropFilter: 'blur(18px) saturate(180%)',
      border: '0.5px solid rgba(255,255,255,0.08)',
      boxShadow: '0 4px 18px rgba(0,0,0,0.25)',
    }} />
  );
}

// ─── lock-screen action pills (flashlight + camera) ─────────────────────

function LockPill({ children }) {
  return (
    <div style={{
      width: 50, height: 50, borderRadius: '50%',
      position: 'relative', overflow: 'hidden',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
    }}>
      <div style={{
        position: 'absolute', inset: 0, borderRadius: '50%',
        backdropFilter: 'blur(20px) saturate(180%)',
        WebkitBackdropFilter: 'blur(20px) saturate(180%)',
        background: 'rgba(0,0,0,0.55)',
      }} />
      <div style={{
        position: 'absolute', inset: 0, borderRadius: '50%',
        border: '0.5px solid rgba(255,255,255,0.10)',
        boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.08)',
      }} />
      <div style={{ position: 'relative', color: '#fff', display: 'flex' }}>
        {children}
      </div>
    </div>
  );
}

function LockActionPills() {
  return (
    <div style={{
      position: 'absolute', left: 0, right: 0, bottom: 50,
      display: 'flex', justifyContent: 'space-between',
      padding: '0 36px',
      zIndex: 5,
      pointerEvents: 'none',
    }}>
      <LockPill>
        {/* flashlight */}
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <path d="M9 3h6l-1.5 4.5L15 11l-3 10-3-10 1.5-3.5L9 3z" stroke="#fff" strokeWidth="1.6" strokeLinejoin="round" fill="rgba(255,255,255,0.05)"/>
        </svg>
      </LockPill>
      <LockPill>
        {/* camera */}
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <rect x="3" y="7" width="18" height="13" rx="2.5" stroke="#fff" strokeWidth="1.6"/>
          <circle cx="12" cy="13.5" r="3.6" stroke="#fff" strokeWidth="1.6"/>
          <path d="M9 7l1.2-2.2a1 1 0 011-0.6h1.6a1 1 0 011 0.6L15 7" stroke="#fff" strokeWidth="1.6" strokeLinejoin="round"/>
        </svg>
      </LockPill>
    </div>
  );
}

// ─── screen ─────────────────────────────────────────────────────────────

function Screen8() {
  return (
    <div
      data-screen-label="08 iOS lock-screen · push notification"
      style={{
        width: '100%', height: '100%',
        position: 'relative',
        overflow: 'hidden',
        // brand-neutral dark wallpaper — no photo
        background: 'radial-gradient(800px 600px at 50% 30%, #2a2d35 0%, #0a0c0f 70%), #08090b',
        fontFamily: SF,
      }}>
      <TCGlobalStyles />

      {/* clock */}
      <LockClock />

      {/* notification stack */}
      <div style={{
        position: 'absolute', left: 0, right: 0, top: 290,
        display: 'flex', flexDirection: 'column', alignItems: 'center',
        gap: 0,
      }}>
        <NotificationCard />
        <QueuedHint />
      </div>

      {/* lock-screen flashlight + camera pills */}
      <LockActionPills />
    </div>
  );
}

window.Screen8 = Screen8;
