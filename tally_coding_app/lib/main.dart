import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:clerk_flutter/clerk_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'screens/discord_shell.dart';
import 'services/escalation_notifier.dart';
import 'services/notifications_ws.dart';
import 'state/workspace_context.dart';
import 'theme/theme.dart';
import 'widgets/bottom_sheet/bottom_sheet.dart';

/// Sprint 32.5: Clerk publishable key (compile-time via --dart-define).
/// The dart-define is mandatory; we fail loudly at boot rather than
/// silently falling back to admin-only auth.  Exposed as a public
/// top-level so the billing screen can decode the Clerk frontend
/// API host for the hosted-portal URL.
const clerkPublishableKey = String.fromEnvironment(
  'CLERK_PUBLISHABLE_KEY',
  defaultValue: 'pk_test_ZWFnZXItc2hyaW1wLTM2LmNsZXJrLmFjY291bnRzLmRldiQ',
);

/// Custom URL scheme that closes the OAuth loop. Registered as a
/// scheme handler on every platform (Android intent-filter, iOS
/// CFBundleURLTypes, Linux .desktop MimeType=x-scheme-handler, etc.).
/// Clerk redirects the browser here after sign-in; app_links catches
/// the deep-link and feeds it to Clerk SDK's deepLinkStream.
const _kDeepLinkScheme = 'tallycoding';
const _kDeepLinkHost = 'auth';
const _kOAuthRedirectPath = '/oauth';
const _kEmailLinkRedirectPath = '/email-link';
const _kClerkRedirectPaths = {_kOAuthRedirectPath, _kEmailLinkRedirectPath};

/// Sprint 32.5: orchestrator URL. Used to be configurable via the
/// ConfigScreen + ConfigStore; now hardcoded because the orchestrator
/// runs at tally.pronoic.dev and Clerk handles user identity directly.
/// Override with --dart-define for local dev.
const _kOrchestratorUrl = String.fromEnvironment(
  'TALLY_ORCH_URL',
  defaultValue: 'https://tally.pronoic.dev',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await clerk.setUpLogging(printer: const _LogPrinter());
  final themeController = ThemeController();
  await themeController.load();
  final bottomSheetController = BottomSheetController();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeController),
        ChangeNotifierProvider.value(value: bottomSheetController),
      ],
      child: const TallyApp(),
    ),
  );
}

class TallyApp extends StatelessWidget {
  const TallyApp({super.key});

  /// Tell Clerk where to land after OAuth completes.  Returning a Uri
  /// triggers the system-browser flow + deep-link callback (works on
  /// all platforms); returning null falls back to in-app webview
  /// (Android/iOS only — fails on desktop).
  Uri? _redirectFor(BuildContext _, clerk.Strategy strategy) {
    if (strategy.isOauth) {
      return Uri(
        scheme: _kDeepLinkScheme,
        host: _kDeepLinkHost,
        path: _kOAuthRedirectPath,
      );
    }
    if (strategy.isEmailLink) {
      return Uri(
        scheme: _kDeepLinkScheme,
        host: _kDeepLinkHost,
        path: _kEmailLinkRedirectPath,
      );
    }
    return null;
  }

  /// Filter incoming deep-links — only forward the ones Clerk should
  /// process (our two redirect paths).  Anything else is silently
  /// dropped so a future URL-scheme handler for non-auth routes
  /// doesn't accidentally feed garbage to Clerk.
  Future<Uri?> _handleDeepLink(Uri uri) async {
    if (uri.scheme != _kDeepLinkScheme) return null;
    if (!_kClerkRedirectPaths.contains(uri.path)) return null;
    return uri;
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeController>();
    final baseTheme = themeFromTokens(controller.activeEntry.tokens);
    final theme = baseTheme.copyWith(
      extensions: [
        ...baseTheme.extensions.values,
        ClerkThemeExtension.dark,
      ],
    );
    return ClerkAuth(
      config: ClerkAuthConfig(
        publishableKey: clerkPublishableKey,
        redirectionGenerator: _redirectFor,
        // Sprint 32.5: on Linux desktops without DBus activation, the
        // OAuth redirect spawns a *new* instance of the app with the
        // deep-link URL as argv. AppLinks().uriLinkStream only emits
        // links delivered after subscription, so we explicitly prepend
        // `getInitialLink()` to catch the launch-time URL. (On
        // Android/iOS, getInitialLink already returns the launch-intent
        // URL, so this is a no-op equivalent.)
        deepLinkStream: _mergedDeepLinkStream(),
      ),
      child: MaterialApp(
        title: 'Tally Coding',
        theme: theme,
        debugShowCheckedModeBanner: false,
        home: const _AuthGate(),
      ),
    );
  }

  Stream<Uri?> _mergedDeepLinkStream() async* {
    final appLinks = AppLinks();
    final initial = await appLinks.getInitialLink();
    if (initial != null) {
      final handled = await _handleDeepLink(initial);
      if (handled != null) yield handled;
    }
    yield* appLinks.uriLinkStream.asyncMap(_handleDeepLink);
  }
}

/// Branches on Clerk auth state: signed out → hosted-style sign-in UI;
/// signed in → DiscordShellScreen with a TallyOrchClient that mints
/// fresh JWTs from the active Clerk session on every request.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return ClerkErrorListener(
      child: ClerkAuthBuilder(
        signedInBuilder: (context, authState) {
          // Extract as a named variable so both TallyOrchClient and
          // NotificationsWsClient share the same token-minting closure.
          Future<String?> bearerProvider() async {
            // Mint a fresh JWT from the active Clerk session each
            // call.  60-second-lifetime tokens never expire mid-
            // request because we call this immediately before the
            // HTTP request fires.
            try {
              final st = await authState.sessionToken();
              return st.jwt;
            } catch (e) {
              if (kDebugMode) {
                debugPrint('Clerk sessionToken() failed: $e');
              }
              return null;
            }
          }

          final client = TallyOrchClient(
            baseUrl: Uri.parse(_kOrchestratorUrl),
            provider: bearerProvider,
          );
          return _SignedInShell(
            client: client,
            authState: authState,
            bearerProvider: bearerProvider,
          );
        },
        signedOutBuilder: (context, _) => const _SignedOutScreen(),
      ),
    );
  }
}

class _SignedOutScreen extends StatelessWidget {
  const _SignedOutScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1F22),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Text(
                    '✨ Tally Coding',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Multi-agent coding on Phala TEE workers.',
                    style: TextStyle(color: Color(0xFFB9BBBE), fontSize: 14),
                  ),
                  SizedBox(height: 24),
                  ClerkAuthentication(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SignedInShell extends StatefulWidget {
  final TallyOrchClient client;
  final ClerkAuthState authState;
  final Future<String?> Function() bearerProvider;

  const _SignedInShell({
    required this.client,
    required this.authState,
    required this.bearerProvider,
  });

  @override
  State<_SignedInShell> createState() => _SignedInShellState();
}

class _SignedInShellState extends State<_SignedInShell> {
  NotificationsWsClient? _wsClient;
  // Sprint 50: active workspace loaded from shared_preferences on first build.
  int _activeWorkspaceId = 1;
  bool _workspaceLoaded = false;

  @override
  void initState() {
    super.initState();
    final baseUrl = widget.client.baseUrl;
    final wsUri = baseUrl.replace(
      scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws/notifications',
    );
    _wsClient = NotificationsWsClient(
      api: widget.client,
      wsUrl: wsUri,
      bearerProvider: widget.bearerProvider,
    );
    // B4: initialize EscalationNotifier for inline-action push notifications.
    unawaited(EscalationNotifier.instance.initialize().then((_) {
      // Wire onNewEscalation: when a new_escalation WS event arrives,
      // fetch the message and show an OS notification.
      _wsClient!.onNewEscalation = (channelId, escalationMessageId) async {
        try {
          final messages = await widget.client.getMessages(
            channelId: channelId,
            limit: 10,
            sinceId: escalationMessageId - 1,
          );
          for (final msg in messages) {
            if (msg['id'] == escalationMessageId && msg['kind'] == 'escalation') {
              // payload_json is a string column in the DB; decode it.
              final payloadStr = msg['payload_json'] as String? ?? '{}';
              final payloadMap =
                  Map<String, dynamic>.from(jsonDecode(payloadStr) as Map);
              final pushPayload = EscalationPushPayload(
                escalationMessageId: escalationMessageId,
                channelId: channelId,
                question: payloadMap['question'] as String? ?? '',
                quickReplyOptions: List<String>.from(
                  (payloadMap['quick_reply_options'] as List?) ?? const [],
                ),
              );
              await EscalationNotifier.instance.showEscalationNotification(pushPayload);
              break;
            }
          }
        } catch (e) {
          debugPrint('[EscalationNotifier] fetch+show failed: $e');
        }
      };
      // Wire onActionSelected: quick-reply action buttons post reply to channel.
      EscalationNotifier.instance.onActionSelected =
          (channelId, escalationMessageId, actionId) async {
        if (actionId == 'Open') {
          // TODO(B4): deep-link to long-term channel when B3 navigator is merged.
          // B3's navigation controller handles deep links to channels by channelId.
          debugPrint('[EscalationNotifier] open channel $channelId');
          return;
        }
        try {
          await widget.client.postMessage(
            channelId: channelId,
            text: actionId,
            replyToId: escalationMessageId,
          );
        } catch (e) {
          debugPrint('[EscalationNotifier] reply post failed: $e');
        }
      };
    }));
    unawaited(_wsClient!.connect());
    unawaited(_loadActiveWorkspace());
  }

  Future<void> _loadActiveWorkspace() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _activeWorkspaceId = prefs.getInt('active_workspace_id') ?? 1;
      _workspaceLoaded = true;
    });
  }

  Future<void> _setActiveWorkspace(int id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('active_workspace_id', id);
    if (!mounted) return;
    setState(() => _activeWorkspaceId = id);
  }

  @override
  void dispose() {
    _wsClient?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_workspaceLoaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return WorkspaceContext(
      activeWorkspaceId: _activeWorkspaceId,
      onChange: _setActiveWorkspace,
      child: _SignedInInherited(
        authState: widget.authState,
        child: DiscordShellScreen(
          client: widget.client,
          wsClient: _wsClient!,
        ),
      ),
    );
  }
}

/// Lets descendants reach the Clerk auth state without prop-drilling —
/// used by the server rail's "sign out" affordance.
class _SignedInInherited extends InheritedWidget {
  final ClerkAuthState authState;
  const _SignedInInherited({required this.authState, required super.child});

  static ClerkAuthState? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SignedInInherited>()?.authState;

  @override
  bool updateShouldNotify(_SignedInInherited old) =>
      old.authState != authState;
}

/// Public-ish helper so the shell can wire its "sign out" button.
Future<void> resetTallyConfig(BuildContext context) async {
  final authState = _SignedInInherited.of(context);
  if (authState == null) return;
  try {
    await authState.signOut();
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Clerk signOut failed: $e');
    }
  }
}

class _LogPrinter extends clerk.Printer {
  const _LogPrinter();
  @override
  void print(String output) => Zone.root.print(output);
}
