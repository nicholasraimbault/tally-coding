import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('getCreditsBalance returns plan + balance', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/billing/credits');
      return http.Response(
        '{"plan":"pro_beta","plan_label":"Pro (Beta)","is_beta":true,'
        '"period_start":0,"included_credits":1000,"used_credits":100,'
        '"available_credits":900,"prepaid_credit_balance":0,'
        '"overage_enabled":false,"auto_recharge_mode":0,'
        '"auto_recharge_block_credits":500,"auto_recharge_monthly_cap_micro_usd":null,'
        '"auto_recharge_spent_this_month_micro_usd":0,"stripe_payment_method_id":null,'
        '"spend_alert_threshold_pct":80}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = TallyOrchClient(
      baseUrl: Uri.parse('http://test'),
      provider: () async => 'token',
      client: mock,
    );
    final out = await api.getCreditsBalance();
    expect(out['plan'], 'pro_beta');
    expect(out['available_credits'], 900);
  });

  test('postCreditsCheckout returns stripe URL', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/billing/credits/checkout');
      return http.Response(
        '{"session_id":"cs_test","url":"https://checkout.stripe.com/cs_test"}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = TallyOrchClient(
      baseUrl: Uri.parse('http://test'),
      provider: () async => 'token',
      client: mock,
    );
    final out = await api.postCreditsCheckout(credits: 500);
    expect(out['url'], startsWith('https://checkout.stripe.com/'));
  });
}
