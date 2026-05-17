import 'package:flutter/material.dart';

void main() => runApp(const TallyCodingApp());

class TallyCodingApp extends StatelessWidget {
  const TallyCodingApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tally Coding',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B1B1B)),
          useMaterial3: true,
        ),
        home: const _Placeholder(),
      );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Tally Coding')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Privacy-first multi-agent coding workspace',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 16),
                Text(
                  'OpenHands · Phala TEE · Skytale MLS · Tally Workers',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.black54),
                ),
                SizedBox(height: 32),
                Text(
                  'Week 1 scaffold — agent UI lands next sprint.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.black45),
                ),
              ],
            ),
          ),
        ),
      );
}
