import 'package:flutter/foundation.dart';

@immutable
class ChannelModel {
  final int id;
  final String name;
  final String kind;
  final String? lastMessageText;
  final String? lastMessageAuthor;
  final double? lastMessageAt;

  const ChannelModel({
    required this.id,
    required this.name,
    required this.kind,
    this.lastMessageText,
    this.lastMessageAuthor,
    this.lastMessageAt,
  });

  factory ChannelModel.fromJson(Map<String, dynamic> json) => ChannelModel(
        id: json['id'] as int,
        name: json['name'] as String,
        kind: json['kind'] as String,
        lastMessageText: json['last_message_text'] as String?,
        lastMessageAuthor: json['last_message_author'] as String?,
        lastMessageAt: (json['last_message_at'] as num?)?.toDouble(),
      );

  /// Long-term channels show in the channels sheet. Task channels do not.
  bool get isLongTerm => kind != 'task';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ChannelModel && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
