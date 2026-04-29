import 'dart:convert';

import 'package:apidash/models/models.dart';
import 'package:apidash/services/agentic_services/api_testing/api_testing_models.dart';
import 'package:apidash/services/agentic_services/api_testing/api_testing_spec.dart';
import 'package:apidash/utils/envvar_utils.dart';
import 'package:apidash_core/apidash_core.dart';

typedef ApiTestRequestExecutor =
    Future<ApiTestExecutionResult> Function(RequestModel requestModel);

class ApiTestingRequestAdapter {
  static Future<ApiTestExecutionResult> execute(
    RequestModel requestModel, {
    SupportedUriSchemes defaultUriScheme = kDefaultUriScheme,
    bool noSSL = false,
  }) async {
    final httpRequestModel = requestModel.httpRequestModel;
    if (httpRequestModel == null) {
      return ApiTestExecutionResult(
        executedRequest: requestModel,
        responseStatus: -1,
        message: 'Missing HttpRequestModel on workflow step.',
      );
    }

    final (response, duration, errorMessage) = await sendHttpRequest(
      requestModel.id,
      requestModel.apiType,
      httpRequestModel,
      defaultUriScheme: defaultUriScheme,
      noSSL: noSSL,
    );

    if (response == null) {
      return ApiTestExecutionResult(
        executedRequest: requestModel,
        responseStatus: -1,
        message: errorMessage ?? 'Request execution failed.',
      );
    }

    final httpResponseModel = const HttpResponseModel().fromResponse(
      response: response,
      time: duration,
    );

    return ApiTestExecutionResult(
      executedRequest: requestModel.copyWith(
        responseStatus: response.statusCode,
        httpResponseModel: httpResponseModel,
      ),
      response: httpResponseModel,
      responseStatus: response.statusCode,
    );
  }
}

class ApiTestingSelectorEngine {
  const ApiTestingSelectorEngine();

  ApiTestSelectorResolution resolve(
    ApiTestSelector selector,
    HttpResponseModel response,
  ) {
    switch (selector.type) {
      case ApiTestSelectorType.jsonPath:
        return _resolveJsonPath(selector, response);
      case ApiTestSelectorType.regex:
        return _resolveRegex(selector, response);
      case ApiTestSelectorType.header:
        return _resolveHeader(selector, response);
      case ApiTestSelectorType.bodySize:
        return _resolveBodySize(selector, response);
      case ApiTestSelectorType.statusCode:
        return _resolveStatusCode(selector, response);
      case ApiTestSelectorType.responseTime:
        return _resolveResponseTime(selector, response);
    }
  }

  ApiTestAssertionResult evaluateAssertion(
    ApiTestAssertion assertion,
    HttpResponseModel response,
  ) {
    final resolution = resolve(assertion.selector, response);
    final actualValue = resolution.value;
    final normalizedExpected = _normalizeExpectedValue(
      assertion.expected,
      actualValue,
    );

    bool passed;
    switch (assertion.operator) {
      case ApiTestAssertionOperator.exists:
        passed = resolution.found && actualValue != null;
        break;
      case ApiTestAssertionOperator.equals:
        passed =
            resolution.found && _deepEquals(actualValue, normalizedExpected);
        break;
      case ApiTestAssertionOperator.notEquals:
        passed =
            !resolution.found || !_deepEquals(actualValue, normalizedExpected);
        break;
      case ApiTestAssertionOperator.contains:
        passed =
            resolution.found && _containsValue(actualValue, normalizedExpected);
        break;
      case ApiTestAssertionOperator.matchesRegex:
        passed =
            resolution.found &&
            RegExp(
              (normalizedExpected ?? '').toString(),
            ).hasMatch((actualValue ?? '').toString());
        break;
      case ApiTestAssertionOperator.gt:
        passed = _passesNumericComparison(
          actualValue,
          normalizedExpected,
          (comparison) => comparison > 0,
        );
        break;
      case ApiTestAssertionOperator.gte:
        passed = _passesNumericComparison(
          actualValue,
          normalizedExpected,
          (comparison) => comparison >= 0,
        );
        break;
      case ApiTestAssertionOperator.lt:
        passed = _passesNumericComparison(
          actualValue,
          normalizedExpected,
          (comparison) => comparison < 0,
        );
        break;
      case ApiTestAssertionOperator.lte:
        passed = _passesNumericComparison(
          actualValue,
          normalizedExpected,
          (comparison) => comparison <= 0,
        );
        break;
    }

    final expectedValueText = normalizedExpected == null
        ? ''
        : ' ${assertion.operator.name} ${_stringifyValue(normalizedExpected)}';
    final message = passed
        ? 'Passed: ${assertion.selector.displayName}$expectedValueText'
        : 'Failed: ${assertion.selector.displayName}$expectedValueText, actual: ${_stringifyValue(actualValue)}'
              '${resolution.message == null ? '' : ' (${resolution.message})'}';

    return ApiTestAssertionResult(
      assertion: assertion,
      passed: passed,
      resolution: resolution,
      message: message,
    );
  }

  ApiTestAssertionGroupResult evaluateGroup(
    ApiTestAssertionGroup group,
    HttpResponseModel response,
  ) {
    final assertionResults = [
      for (final assertion in group.assertions)
        evaluateAssertion(assertion, response),
    ];

    final passed = switch (group.mode) {
      ApiTestAssertionGroupMode.and => assertionResults.every(
        (assertionResult) => assertionResult.passed,
      ),
      ApiTestAssertionGroupMode.or =>
        assertionResults.isEmpty ||
            assertionResults.any((assertionResult) => assertionResult.passed),
    };

    return ApiTestAssertionGroupResult(
      group: group,
      passed: passed,
      assertionResults: assertionResults,
    );
  }

  ApiTestExtractionResult extractValue(
    ApiTestExtraction extraction,
    HttpResponseModel response,
  ) {
    final resolution = resolve(extraction.selector, response);
    if (!resolution.found || resolution.value == null) {
      return ApiTestExtractionResult(
        extraction: extraction,
        succeeded: !extraction.required,
        resolution: resolution,
        message: extraction.required
            ? 'Required extraction ${extraction.variableName} could not be resolved.'
            : 'Optional extraction ${extraction.variableName} did not resolve a value.',
      );
    }

    final extractedValue = _stringifyValue(resolution.value);
    return ApiTestExtractionResult(
      extraction: extraction,
      succeeded: true,
      resolution: resolution,
      extractedValue: extractedValue,
      message: 'Extracted ${extraction.variableName} = $extractedValue',
    );
  }

  ApiTestSelectorResolution _resolveJsonPath(
    ApiTestSelector selector,
    HttpResponseModel response,
  ) {
    final body = response.body;
    if (body == null || body.trim().isEmpty) {
      return ApiTestSelectorResolution(
        selector: selector,
        found: false,
        message: 'Response body is empty.',
      );
    }

    final expression = selector.expression;
    if (expression == null || expression.trim().isEmpty) {
      return ApiTestSelectorResolution(
        selector: selector,
        found: false,
        message: 'JSONPath expression is missing.',
      );
    }

    dynamic decodedBody;
    try {
      decodedBody = jsonDecode(body);
    } catch (_) {
      return ApiTestSelectorResolution(
        selector: selector,
        found: false,
        message: 'Response body is not valid JSON.',
      );
    }

    try {
      final tokens = _parseJsonPath(expression);
      dynamic current = decodedBody;
      for (final token in tokens) {
        if (token.property != null) {
          if (current is! Map || !current.containsKey(token.property)) {
            return ApiTestSelectorResolution(
              selector: selector,
              found: false,
              message: 'Property ${token.property} was not found.',
            );
          }
          current = current[token.property];
          continue;
        }

        final index = token.index;
        if (current is! List || index == null || index >= current.length) {
          return ApiTestSelectorResolution(
            selector: selector,
            found: false,
            message: 'Array index ${token.index} was not found.',
          );
        }
        current = current[index];
      }

      return ApiTestSelectorResolution(
        selector: selector,
        found: true,
        value: current,
      );
    } on FormatException catch (error) {
      return ApiTestSelectorResolution(
        selector: selector,
        found: false,
        message: error.message,
      );
    }
  }

  ApiTestSelectorResolution _resolveRegex(
    ApiTestSelector selector,
    HttpResponseModel response,
  ) {
    final pattern = selector.expression;
    if (pattern == null || pattern.trim().isEmpty) {
      return ApiTestSelectorResolution(
        selector: selector,
        found: false,
        message: 'Regex pattern is missing.',
      );
    }
    final body = response.body ?? '';
    final match = RegExp(pattern, dotAll: true).firstMatch(body);
    if (match == null) {
      return ApiTestSelectorResolution(
        selector: selector,
        found: false,
        message: 'No regex match found.',
      );
    }

    final value = match.groupCount > 0 ? match.group(1) : match.group(0);
    return ApiTestSelectorResolution(
      selector: selector,
      found: value != null,
      value: value,
    );
  }

  ApiTestSelectorResolution _resolveHeader(
    ApiTestSelector selector,
    HttpResponseModel response,
  ) {
    final headerName = selector.expression;
    if (headerName == null || headerName.trim().isEmpty) {
      return ApiTestSelectorResolution(
        selector: selector,
        found: false,
        message: 'Header name is missing.',
      );
    }

    final headers = response.headers ?? const <String, String>{};
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == headerName.toLowerCase()) {
        return ApiTestSelectorResolution(
          selector: selector,
          found: true,
          value: entry.value,
        );
      }
    }

    return ApiTestSelectorResolution(
      selector: selector,
      found: false,
      message: 'Header $headerName was not found.',
    );
  }

  ApiTestSelectorResolution _resolveBodySize(
    ApiTestSelector selector,
    HttpResponseModel response,
  ) {
    final bodySize =
        response.bodyBytes?.length ?? utf8.encode(response.body ?? '').length;
    return ApiTestSelectorResolution(
      selector: selector,
      found: true,
      value: bodySize,
    );
  }

  ApiTestSelectorResolution _resolveStatusCode(
    ApiTestSelector selector,
    HttpResponseModel response,
  ) {
    final statusCode = response.statusCode;
    return ApiTestSelectorResolution(
      selector: selector,
      found: statusCode != null,
      value: statusCode,
      message: statusCode == null ? 'Status code is missing.' : null,
    );
  }

  ApiTestSelectorResolution _resolveResponseTime(
    ApiTestSelector selector,
    HttpResponseModel response,
  ) {
    final responseTime = response.time?.inMilliseconds;
    return ApiTestSelectorResolution(
      selector: selector,
      found: responseTime != null,
      value: responseTime,
      message: responseTime == null ? 'Response time is missing.' : null,
    );
  }
}

class ApiTestingWorkflowEngine {
  ApiTestingWorkflowEngine({
    required this.requestExecutor,
    ApiTestingSelectorEngine? selectorEngine,
    ApiTestingOpenApiAccumulator? specAccumulator,
  }) : selectorEngine = selectorEngine ?? const ApiTestingSelectorEngine(),
       specAccumulator = specAccumulator ?? ApiTestingOpenApiAccumulator();

  final ApiTestRequestExecutor requestExecutor;
  final ApiTestingSelectorEngine selectorEngine;
  final ApiTestingOpenApiAccumulator specAccumulator;

  Future<ApiTestRunResult> run(
    List<ApiTestStep> steps, {
    Map<String, String> initialVariables = const <String, String>{},
  }) async {
    final runtimeVariables = Map<String, String>.from(initialVariables);
    final stepResults = <ApiTestStepResult>[];
    String? abortedAtStepId;

    for (final step in steps) {
      final executedRequest = _substituteRuntimeVariables(
        step.requestModel,
        runtimeVariables,
      );
      final execution = await requestExecutor(executedRequest);

      if (execution.response == null) {
        final outcome = step.onFailure == ApiTestStepFailureBehavior.abort
            ? ApiTestStepOutcome.aborted
            : ApiTestStepOutcome.failed;
        final result = ApiTestStepResult(
          step: step,
          execution: execution,
          outcome: outcome,
          passed: false,
          failureReason: execution.message ?? 'Request execution failed.',
          runtimeVariablesSnapshot: Map<String, String>.from(runtimeVariables),
        );
        stepResults.add(result);

        if (outcome == ApiTestStepOutcome.aborted) {
          abortedAtStepId = step.id;
          break;
        }
        continue;
      }

      final operation =
          step.operation ??
          ApiTestOperationMetadata.fromRequestModel(step.requestModel);
      specAccumulator.observe(
        operation: operation,
        response: execution.response!,
      );

      final assertionGroupResults = [
        for (final group in step.assertionGroups)
          selectorEngine.evaluateGroup(group, execution.response!),
      ];
      var passedAssertions = assertionGroupResults.every(
        (groupResult) => groupResult.passed,
      );

      final extractionResults = <ApiTestExtractionResult>[];
      String? failureReason = _firstFailedAssertionMessage(
        assertionGroupResults,
      );

      if (passedAssertions) {
        for (final extraction in step.extractions) {
          final extractionResult = selectorEngine.extractValue(
            extraction,
            execution.response!,
          );
          extractionResults.add(extractionResult);
          if (extractionResult.succeeded &&
              extractionResult.extractedValue != null) {
            runtimeVariables[extraction.variableName] =
                extractionResult.extractedValue!;
            continue;
          }
          if (extraction.required) {
            passedAssertions = false;
            failureReason = extractionResult.message;
          }
        }
      }

      final shouldAbort =
          !passedAssertions &&
          step.onFailure == ApiTestStepFailureBehavior.abort;
      final result = ApiTestStepResult(
        step: step,
        execution: execution,
        outcome: passedAssertions
            ? ApiTestStepOutcome.passed
            : (shouldAbort
                  ? ApiTestStepOutcome.aborted
                  : ApiTestStepOutcome.failed),
        passed: passedAssertions,
        failureReason: failureReason,
        assertionGroupResults: assertionGroupResults,
        extractionResults: extractionResults,
        runtimeVariablesSnapshot: Map<String, String>.from(runtimeVariables),
      );
      stepResults.add(result);

      if (shouldAbort) {
        abortedAtStepId = step.id;
        break;
      }
    }

    final knownOperations = steps
        .map(
          (step) =>
              step.operation ??
              ApiTestOperationMetadata.fromRequestModel(step.requestModel),
        )
        .toList();

    return ApiTestRunResult(
      stepResults: stepResults,
      runtimeVariables: runtimeVariables,
      openApiDocument: specAccumulator.buildDocument(
        knownOperations: knownOperations,
      ),
      uncoveredOperations: specAccumulator.detectGaps(knownOperations),
      abortedAtStepId: abortedAtStepId,
    );
  }
}

RequestModel _substituteRuntimeVariables(
  RequestModel requestModel,
  Map<String, String> runtimeVariables,
) {
  final httpRequestModel = requestModel.httpRequestModel;
  if (httpRequestModel == null) {
    return requestModel;
  }

  final substitutedHttpRequestModel = httpRequestModel.copyWith(
    url:
        substituteVariables(httpRequestModel.url, runtimeVariables) ??
        httpRequestModel.url,
    headers: httpRequestModel.headers?.map((header) {
      return header.copyWith(
        name: substituteVariables(header.name, runtimeVariables) ?? header.name,
        value: substituteVariables(header.value, runtimeVariables),
      );
    }).toList(),
    params: httpRequestModel.params?.map((param) {
      return param.copyWith(
        name: substituteVariables(param.name, runtimeVariables) ?? param.name,
        value: substituteVariables(param.value, runtimeVariables),
      );
    }).toList(),
    formData: httpRequestModel.formData?.map((field) {
      return field.copyWith(
        name: substituteVariables(field.name, runtimeVariables) ?? field.name,
        value:
            substituteVariables(field.value, runtimeVariables) ?? field.value,
      );
    }).toList(),
    body: substituteVariables(httpRequestModel.body, runtimeVariables),
    query: substituteVariables(httpRequestModel.query, runtimeVariables),
    authModel: substituteAuthModel(
      httpRequestModel.authModel,
      runtimeVariables,
    ),
  );

  return requestModel.copyWith(httpRequestModel: substitutedHttpRequestModel);
}

String? _firstFailedAssertionMessage(
  List<ApiTestAssertionGroupResult> groupResults,
) {
  for (final groupResult in groupResults) {
    for (final assertionResult in groupResult.assertionResults) {
      if (!assertionResult.passed) {
        return assertionResult.message;
      }
    }
  }
  return null;
}

Object? _normalizeExpectedValue(Object? expectedValue, Object? actualValue) {
  if (expectedValue == null) {
    return null;
  }

  if (actualValue is bool && expectedValue is String) {
    if (expectedValue.toLowerCase() == 'true') {
      return true;
    }
    if (expectedValue.toLowerCase() == 'false') {
      return false;
    }
  }

  if (actualValue is num) {
    if (expectedValue is num) {
      return expectedValue;
    }
    if (expectedValue is String) {
      return num.tryParse(expectedValue) ?? expectedValue;
    }
  }

  if ((actualValue is List || actualValue is Map) && expectedValue is String) {
    try {
      return jsonDecode(expectedValue);
    } catch (_) {
      return expectedValue;
    }
  }

  return expectedValue;
}

bool _deepEquals(Object? left, Object? right) {
  if (left is List && right is List) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (!_deepEquals(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }

  if (left is Map && right is Map) {
    if (left.length != right.length) {
      return false;
    }
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key)) {
        return false;
      }
      if (!_deepEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }

  return left == right;
}

bool _containsValue(Object? actualValue, Object? expectedValue) {
  if (actualValue is String) {
    return actualValue.contains((expectedValue ?? '').toString());
  }
  if (actualValue is Iterable) {
    return actualValue.any((item) => _deepEquals(item, expectedValue));
  }
  if (actualValue is Map) {
    return actualValue.containsKey(expectedValue) ||
        actualValue.values.any((value) => _deepEquals(value, expectedValue));
  }
  return false;
}

bool _passesNumericComparison(
  Object? left,
  Object? right,
  bool Function(int comparison) matcher,
) {
  final comparison = _numericComparison(left, right);
  if (comparison == null) {
    return false;
  }
  return matcher(comparison);
}

int? _numericComparison(Object? left, Object? right) {
  final leftNumber = _toNum(left);
  final rightNumber = _toNum(right);
  if (leftNumber == null || rightNumber == null) {
    return null;
  }
  return leftNumber.compareTo(rightNumber);
}

num? _toNum(Object? value) {
  if (value is num) {
    return value;
  }
  if (value is String) {
    return num.tryParse(value);
  }
  return null;
}

String _stringifyValue(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is String) {
    return value;
  }
  try {
    return jsonEncode(value);
  } catch (_) {
    return value.toString();
  }
}

List<_JsonPathToken> _parseJsonPath(String expression) {
  final trimmedExpression = expression.trim();
  if (trimmedExpression == r'$') {
    return const <_JsonPathToken>[];
  }
  if (!trimmedExpression.startsWith(r'$')) {
    throw const FormatException(r'JSONPath must start with $.');
  }

  final tokens = <_JsonPathToken>[];
  var index = 1;

  while (index < trimmedExpression.length) {
    final character = trimmedExpression[index];
    if (character == '.') {
      index += 1;
      final start = index;
      while (index < trimmedExpression.length &&
          _isJsonPathIdentifierCharacter(trimmedExpression[index])) {
        index += 1;
      }
      if (start == index) {
        throw const FormatException('Invalid JSONPath property selector.');
      }
      tokens.add(
        _JsonPathToken.property(trimmedExpression.substring(start, index)),
      );
      continue;
    }

    if (character == '[') {
      final closingIndex = trimmedExpression.indexOf(']', index);
      if (closingIndex == -1) {
        throw const FormatException('JSONPath bracket selector is not closed.');
      }
      final content = trimmedExpression
          .substring(index + 1, closingIndex)
          .trim();
      if (content.startsWith("'") || content.startsWith('"')) {
        if (content.length < 2 || content[0] != content[content.length - 1]) {
          throw const FormatException('JSONPath property quotes are invalid.');
        }
        tokens.add(
          _JsonPathToken.property(content.substring(1, content.length - 1)),
        );
      } else {
        final parsedIndex = int.tryParse(content);
        if (parsedIndex == null) {
          throw const FormatException('JSONPath array index must be numeric.');
        }
        tokens.add(_JsonPathToken.index(parsedIndex));
      }
      index = closingIndex + 1;
      continue;
    }

    throw FormatException(
      'Unsupported JSONPath token starting at `${trimmedExpression.substring(index)}`.',
    );
  }

  return tokens;
}

bool _isJsonPathIdentifierCharacter(String character) {
  const extraCharacters = '_-\$';
  final codeUnit = character.codeUnitAt(0);
  return (codeUnit >= 48 && codeUnit <= 57) ||
      (codeUnit >= 65 && codeUnit <= 90) ||
      (codeUnit >= 97 && codeUnit <= 122) ||
      extraCharacters.contains(character);
}

class _JsonPathToken {
  const _JsonPathToken.property(this.property) : index = null;

  const _JsonPathToken.index(this.index) : property = null;

  final String? property;
  final int? index;
}