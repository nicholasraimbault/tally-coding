import 'package:flutter/foundation.dart';

@immutable
class EscalationModel {
  final String id;
  final String question;
  final List<String> options;
  final String taskId;
  final int channelId;

  const EscalationModel({
    required this.id,
    required this.question,
    required this.options,
    required this.taskId,
    required this.channelId,
  });

  factory EscalationModel.fromJson(Map<String, dynamic> json) {
    return EscalationModel(
      id: json['id'] as String,
      question: json['question'] as String,
      options: (json['options'] as List?)?.cast<String>() ?? const [],
      taskId: json['task_id'] as String,
      channelId: json['channel_id'] as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is EscalationModel && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
