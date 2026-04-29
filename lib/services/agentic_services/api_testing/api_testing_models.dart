import 'package:apidash/models/models.dart';
import 'package:apidash_core/apidash_core.dart';

enum ApiTestSelectorType {
  jsonPath,
  regex,
  header,
  bodySize,
  statusCode,
  responseTime,
}

enum ApiTestAssertionOperator {
  exists,
  equals,
  notEquals,
  contains,
  matchesRegex,
  gt,
  gte,
  lt,
  lte,
}

enum ApiTestAssertionGroupMode { and, or }

enum ApiTestStepFailureBehavior { abort, continueRun }

enum ApiTestStepOutcome { passed, failed, aborted }

class ApiTestSelector {
  const ApiTestSelector({required this.type, this.expression, this.label});

  final ApiTestSelectorType type;
  final String? expression;
  final String? label;

  String get displayName => label ?? expression ?? type.name;
}

class ApiTestAssertion {
  const ApiTestAssertion({
    required this.id,
    required this.selector,
    required this.operator,
    this.expected,
    this.description = '',
  });

  final String id;
  final ApiTestSelector selector;
  final ApiTestAssertionOperator operator;
  final Object? expected;
  final String description;
}

class ApiTestAssertionGroup {
  const ApiTestAssertionGroup({
    required this.id,
    this.mode = ApiTestAssertionGroupMode.and,
    this.assertions = const <ApiTestAssertion>[],
    this.description = '',
  });

  final String id;
  final ApiTestAssertionGroupMode mode;
  final List<ApiTestAssertion> assertions;
  final String description;
}

class ApiTestExtraction {
  const ApiTestExtraction({
    required this.variableName,
    required this.selector,
    this.required = true,
    this.description = '',
  });

  final String variableName;
  final ApiTestSelector selector;
  final bool required;
  final String description;
}

class ApiTestOperationMetadata {
  const ApiTestOperationMetadata({
    required this.method,
    required this.path,
    this.operationId,
  });

  factory ApiTestOperationMetadata.fromRequestModel(
    RequestModel requestModel, {
    String? pathOverride,
    String? operationId,
  }) {
    final httpRequestModel = requestModel.httpRequestModel;
    return ApiTestOperationMetadata(
      method: httpRequestModel?.method ?? HTTPVerb.get,
      path: pathOverride ?? _deriveOperationPath(httpRequestModel?.url ?? ''),
      operationId: operationId,
    );
  }

  final HTTPVerb method;
  final String path;
  final String? operationId;

  String get operationKey => '${method.name.toUpperCase()} $path';
}

class ApiTestStep {
  const ApiTestStep({
    required this.id,
    required this.name,
    required this.requestModel,
    this.operation,
    this.assertionGroups = const <ApiTestAssertionGroup>[],
    this.extractions = const <ApiTestExtraction>[],
    this.onFailure = ApiTestStepFailureBehavior.abort,
    this.description = '',
  });

  final String id;
  final String name;
  final RequestModel requestModel;
  final ApiTestOperationMetadata? operation;
  final List<ApiTestAssertionGroup> assertionGroups;
  final List<ApiTestExtraction> extractions;
  final ApiTestStepFailureBehavior onFailure;
  final String description;
}

class ApiTestSelectorResolution {
  const ApiTestSelectorResolution({
    required this.selector,
    required this.found,
    this.value,
    this.message,
  });

  final ApiTestSelector selector;
  final bool found;
  final Object? value;
  final String? message;
}

class ApiTestAssertionResult {
  const ApiTestAssertionResult({
    required this.assertion,
    required this.passed,
    required this.resolution,
    required this.message,
  });

  final ApiTestAssertion assertion;
  final bool passed;
  final ApiTestSelectorResolution resolution;
  final String message;
}

class ApiTestAssertionGroupResult {
  const ApiTestAssertionGroupResult({
    required this.group,
    required this.passed,
    required this.assertionResults,
  });

  final ApiTestAssertionGroup group;
  final bool passed;
  final List<ApiTestAssertionResult> assertionResults;
}

class ApiTestExtractionResult {
  const ApiTestExtractionResult({
    required this.extraction,
    required this.succeeded,
    required this.resolution,
    this.extractedValue,
    required this.message,
  });

  final ApiTestExtraction extraction;
  final bool succeeded;
  final ApiTestSelectorResolution resolution;
  final String? extractedValue;
  final String message;
}

class ApiTestExecutionResult {
  const ApiTestExecutionResult({
    required this.executedRequest,
    this.response,
    this.responseStatus,
    this.message,
  });

  final RequestModel executedRequest;
  final HttpResponseModel? response;
  final int? responseStatus;
  final String? message;

  bool get completed => response != null;
}

class ApiTestStepResult {
  const ApiTestStepResult({
    required this.step,
    required this.execution,
    required this.outcome,
    required this.passed,
    this.failureReason,
    this.assertionGroupResults = const <ApiTestAssertionGroupResult>[],
    this.extractionResults = const <ApiTestExtractionResult>[],
    this.runtimeVariablesSnapshot = const <String, String>{},
  });

  final ApiTestStep step;
  final ApiTestExecutionResult execution;
  final ApiTestStepOutcome outcome;
  final bool passed;
  final String? failureReason;
  final List<ApiTestAssertionGroupResult> assertionGroupResults;
  final List<ApiTestExtractionResult> extractionResults;
  final Map<String, String> runtimeVariablesSnapshot;
}

class ApiTestRunResult {
  const ApiTestRunResult({
    this.stepResults = const <ApiTestStepResult>[],
    this.runtimeVariables = const <String, String>{},
    this.openApiDocument = const <String, dynamic>{},
    this.uncoveredOperations = const <ApiTestOperationMetadata>[],
    this.abortedAtStepId,
  });

  final List<ApiTestStepResult> stepResults;
  final Map<String, String> runtimeVariables;
  final Map<String, dynamic> openApiDocument;
  final List<ApiTestOperationMetadata> uncoveredOperations;
  final String? abortedAtStepId;

  bool get passed =>
      abortedAtStepId == null &&
      stepResults.every((stepResult) => stepResult.passed);
}

String _deriveOperationPath(String rawUrl) {
  if (rawUrl.isEmpty) {
    return '/';
  }
  if (!rawUrl.contains('://')) {
    return rawUrl;
  }
  final uri = Uri.tryParse(rawUrl);
  if (uri == null) {
    return rawUrl;
  }
  final path = uri.path.isEmpty ? '/' : uri.path;
  if (!uri.hasQuery) {
    return path;
  }
  return '$path?${uri.query}';
}