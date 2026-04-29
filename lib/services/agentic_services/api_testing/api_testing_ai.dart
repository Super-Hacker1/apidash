import 'dart:convert';

import 'package:apidash/models/models.dart';
import 'package:apidash/services/agentic_services/api_testing/api_testing_models.dart';
import 'package:apidash_core/apidash_core.dart';

class ApiTestAssertionSuggestion {
  const ApiTestAssertionSuggestion({
    required this.selector,
    required this.operator,
    this.expected,
    this.description = '',
  });

  factory ApiTestAssertionSuggestion.fromJson(Map<String, dynamic> json) {
    return ApiTestAssertionSuggestion(
      selector: ApiTestSelector(
        type: _parseSelectorType(json['selector_type']?.toString()),
        expression: json['path']?.toString(),
      ),
      operator: _parseAssertionOperator(json['operator']?.toString()),
      expected: json['expected'],
      description: json['description']?.toString() ?? '',
    );
  }

  final ApiTestSelector selector;
  final ApiTestAssertionOperator operator;
  final Object? expected;
  final String description;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'selector_type': _selectorTypeToWire(selector.type),
      'path': selector.expression,
      'operator': _operatorToWire(operator),
      'expected': expected,
      'description': description,
    };
  }

  ApiTestAssertion toAssertion(String id) {
    return ApiTestAssertion(
      id: id,
      selector: selector,
      operator: operator,
      expected: expected,
      description: description,
    );
  }
}

class ApiTestFailureExplanation {
  const ApiTestFailureExplanation({
    required this.summary,
    this.rootCause,
    this.suggestedFixes = const <String>[],
    this.likelyCulpritVariables = const <String>[],
  });

  factory ApiTestFailureExplanation.fromJson(Map<String, dynamic> json) {
    return ApiTestFailureExplanation(
      summary: json['summary']?.toString() ?? '',
      rootCause: json['root_cause']?.toString(),
      suggestedFixes: _toStringList(json['suggested_fixes']),
      likelyCulpritVariables: _toStringList(json['likely_culprit_variables']),
    );
  }

  final String summary;
  final String? rootCause;
  final List<String> suggestedFixes;
  final List<String> likelyCulpritVariables;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'summary': summary,
      'root_cause': rootCause,
      'suggested_fixes': suggestedFixes,
      'likely_culprit_variables': likelyCulpritVariables,
    };
  }
}

class ApiTestChainPlanStep {
  const ApiTestChainPlanStep({
    required this.requestId,
    required this.purpose,
    this.consumesVariables = const <String>[],
    this.producesVariables = const <String, String>{},
    this.onFailure = ApiTestStepFailureBehavior.abort,
  });

  factory ApiTestChainPlanStep.fromJson(Map<String, dynamic> json) {
    return ApiTestChainPlanStep(
      requestId: json['request_id']?.toString() ?? '',
      purpose: json['purpose']?.toString() ?? '',
      consumesVariables: _toStringList(json['consumes_variables']),
      producesVariables: _toStringMap(json['produces_variables']),
      onFailure: _parseFailureBehavior(json['on_failure']?.toString()),
    );
  }

  final String requestId;
  final String purpose;
  final List<String> consumesVariables;
  final Map<String, String> producesVariables;
  final ApiTestStepFailureBehavior onFailure;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'request_id': requestId,
      'purpose': purpose,
      'consumes_variables': consumesVariables,
      'produces_variables': producesVariables,
      'on_failure': onFailure == ApiTestStepFailureBehavior.abort
          ? 'abort'
          : 'continue',
    };
  }
}

class ApiTestChainPlan {
  const ApiTestChainPlan({
    required this.summary,
    this.steps = const <ApiTestChainPlanStep>[],
  });

  factory ApiTestChainPlan.fromJson(Map<String, dynamic> json) {
    final stepsJson = json['steps'];
    final steps = <ApiTestChainPlanStep>[];
    if (stepsJson is List) {
      for (final step in stepsJson) {
        if (step is Map) {
          steps.add(
            ApiTestChainPlanStep.fromJson(Map<String, dynamic>.from(step)),
          );
        }
      }
    }
    return ApiTestChainPlan(
      summary: json['summary']?.toString() ?? '',
      steps: steps,
    );
  }

  final String summary;
  final List<ApiTestChainPlanStep> steps;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'summary': summary,
      'steps': steps.map((step) => step.toJson()).toList(),
    };
  }
}

class ApiTestingAiParser {
  static List<ApiTestAssertionSuggestion> parseAssertionSuggestions(
    String rawResponse,
  ) {
    final decoded = _decodeStructuredJson(rawResponse);
    if (decoded is! List) {
      throw const FormatException(
        'Expected a JSON array of assertion suggestions.',
      );
    }
    return decoded
        .whereType<Map>()
        .map(
          (item) => ApiTestAssertionSuggestion.fromJson(
            Map<String, dynamic>.from(item),
          ),
        )
        .toList();
  }

  static ApiTestFailureExplanation parseFailureExplanation(String rawResponse) {
    final decoded = _decodeStructuredJson(rawResponse);
    if (decoded is! Map) {
      throw const FormatException(
        'Expected a JSON object for failure explanation.',
      );
    }
    return ApiTestFailureExplanation.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  static ApiTestChainPlan parseChainPlan(String rawResponse) {
    final decoded = _decodeStructuredJson(rawResponse);
    if (decoded is! Map) {
      throw const FormatException(
        'Expected a JSON object for workflow chain plan.',
      );
    }
    return ApiTestChainPlan.fromJson(Map<String, dynamic>.from(decoded));
  }
}

class ApiTestingAiPayloads {
  static String buildAssertionGenerationInput(HttpResponseModel response) {
    final payload = <String, dynamic>{
      'status': response.statusCode,
      'response_time_ms': response.time?.inMilliseconds,
      'headers': response.headers ?? const <String, String>{},
      'body': _parseJsonWhenPossible(response.body),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  static String buildFailureExplanationInput({
    required ApiTestStepResult stepResult,
    Map<String, String> runtimeVariables = const <String, String>{},
  }) {
    final payload = <String, dynamic>{
      'step': <String, dynamic>{
        'id': stepResult.step.id,
        'name': stepResult.step.name,
        'description': stepResult.step.description,
      },
      'request': stepResult.execution.executedRequest.toJson(),
      'response': stepResult.execution.response?.toJson(),
      'outcome': stepResult.outcome.name,
      'failure_reason': stepResult.failureReason,
      'failed_assertions': [
        for (final group in stepResult.assertionGroupResults)
          for (final assertion in group.assertionResults)
            if (!assertion.passed)
              <String, dynamic>{
                'id': assertion.assertion.id,
                'selector': assertion.assertion.selector.displayName,
                'operator': assertion.assertion.operator.name,
                'expected': assertion.assertion.expected,
                'actual': assertion.resolution.value,
                'message': assertion.message,
              },
      ],
      'runtime_variables': runtimeVariables,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  static String buildChainBuilderInput({
    required String userIntent,
    required List<RequestModel> availableRequests,
  }) {
    final payload = <String, dynamic>{
      'user_intent': userIntent,
      'available_requests': [
        for (final request in availableRequests)
          <String, dynamic>{
            'request_id': request.id,
            'name': request.name,
            'method': request.httpRequestModel?.method.name.toUpperCase(),
            'url': request.httpRequestModel?.url,
            'description': request.description,
          },
      ],
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }
}

dynamic _decodeStructuredJson(String rawResponse) {
  final trimmed = rawResponse.trim();
  final direct = _tryDecodeJson(trimmed);
  if (direct != null) {
    return direct;
  }

  for (final delimiter in const [('[', ']'), ('{', '}')]) {
    final start = trimmed.indexOf(delimiter.$1);
    final end = trimmed.lastIndexOf(delimiter.$2);
    if (start == -1 || end == -1 || end <= start) {
      continue;
    }
    final sliced = trimmed.substring(start, end + 1);
    final decoded = _tryDecodeJson(sliced);
    if (decoded != null) {
      return decoded;
    }
  }

  throw const FormatException(
    'Unable to parse structured JSON from AI response.',
  );
}

dynamic _tryDecodeJson(String rawJson) {
  try {
    return jsonDecode(rawJson);
  } catch (_) {
    return null;
  }
}

dynamic _parseJsonWhenPossible(String? rawBody) {
  if (rawBody == null) {
    return null;
  }
  try {
    return jsonDecode(rawBody);
  } catch (_) {
    return rawBody;
  }
}

List<String> _toStringList(dynamic value) {
  if (value is! List) {
    return const <String>[];
  }
  return value.map((item) => item.toString()).toList();
}

Map<String, String> _toStringMap(dynamic value) {
  if (value is! Map) {
    return const <String, String>{};
  }
  return value.map(
    (key, dynamic item) => MapEntry(key.toString(), item.toString()),
  );
}

ApiTestSelectorType _parseSelectorType(String? rawType) {
  switch ((rawType ?? '').trim().toLowerCase()) {
    case 'jsonpath':
      return ApiTestSelectorType.jsonPath;
    case 'regex':
      return ApiTestSelectorType.regex;
    case 'header':
      return ApiTestSelectorType.header;
    case 'body_size':
    case 'bodysize':
      return ApiTestSelectorType.bodySize;
    case 'status_code':
    case 'statuscode':
      return ApiTestSelectorType.statusCode;
    case 'response_time':
    case 'responsetime':
      return ApiTestSelectorType.responseTime;
    default:
      throw FormatException('Unsupported selector_type `$rawType`.');
  }
}

ApiTestAssertionOperator _parseAssertionOperator(String? rawOperator) {
  switch ((rawOperator ?? '').trim().toLowerCase()) {
    case 'exists':
      return ApiTestAssertionOperator.exists;
    case 'equals':
      return ApiTestAssertionOperator.equals;
    case 'not_equals':
    case 'notequals':
      return ApiTestAssertionOperator.notEquals;
    case 'contains':
      return ApiTestAssertionOperator.contains;
    case 'matches_regex':
    case 'matchesregex':
      return ApiTestAssertionOperator.matchesRegex;
    case 'gt':
      return ApiTestAssertionOperator.gt;
    case 'gte':
      return ApiTestAssertionOperator.gte;
    case 'lt':
      return ApiTestAssertionOperator.lt;
    case 'lte':
      return ApiTestAssertionOperator.lte;
    default:
      throw FormatException('Unsupported operator `$rawOperator`.');
  }
}

ApiTestStepFailureBehavior _parseFailureBehavior(String? rawBehavior) {
  switch ((rawBehavior ?? '').trim().toLowerCase()) {
    case 'continue':
    case 'continuerun':
      return ApiTestStepFailureBehavior.continueRun;
    case 'abort':
    default:
      return ApiTestStepFailureBehavior.abort;
  }
}

String _selectorTypeToWire(ApiTestSelectorType type) {
  switch (type) {
    case ApiTestSelectorType.jsonPath:
      return 'jsonpath';
    case ApiTestSelectorType.regex:
      return 'regex';
    case ApiTestSelectorType.header:
      return 'header';
    case ApiTestSelectorType.bodySize:
      return 'body_size';
    case ApiTestSelectorType.statusCode:
      return 'status_code';
    case ApiTestSelectorType.responseTime:
      return 'response_time';
  }
}

String _operatorToWire(ApiTestAssertionOperator operator) {
  switch (operator) {
    case ApiTestAssertionOperator.exists:
      return 'exists';
    case ApiTestAssertionOperator.equals:
      return 'equals';
    case ApiTestAssertionOperator.notEquals:
      return 'not_equals';
    case ApiTestAssertionOperator.contains:
      return 'contains';
    case ApiTestAssertionOperator.matchesRegex:
      return 'matches_regex';
    case ApiTestAssertionOperator.gt:
      return 'gt';
    case ApiTestAssertionOperator.gte:
      return 'gte';
    case ApiTestAssertionOperator.lt:
      return 'lt';
    case ApiTestAssertionOperator.lte:
      return 'lte';
  }
}