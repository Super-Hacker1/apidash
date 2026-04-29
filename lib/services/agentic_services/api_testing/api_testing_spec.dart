import 'dart:convert';

import 'package:apidash/services/agentic_services/api_testing/api_testing_models.dart';
import 'package:apidash_core/apidash_core.dart';

class ApiTestingOpenApiAccumulator {
  ApiTestingOpenApiAccumulator({
    this.title = 'APIDash Observed API',
    this.version = '0.1.0',
  });

  final String title;
  final String version;
  final Map<String, _ObservedOperationState> _operations = {};

  void observe({
    required ApiTestOperationMetadata operation,
    required HttpResponseModel response,
  }) {
    final state = _operations.putIfAbsent(
      operation.operationKey,
      () => _ObservedOperationState(operation),
    );
    state.observe(response);
  }

  List<ApiTestOperationMetadata> detectGaps(
    Iterable<ApiTestOperationMetadata> knownOperations,
  ) {
    final missing = <ApiTestOperationMetadata>[];
    final seen = <String>{};
    for (final operation in knownOperations) {
      if (!seen.add(operation.operationKey)) {
        continue;
      }
      if (!_operations.containsKey(operation.operationKey)) {
        missing.add(operation);
      }
    }
    return missing;
  }

  Map<String, dynamic> buildDocument({
    Iterable<ApiTestOperationMetadata> knownOperations =
        const <ApiTestOperationMetadata>[],
  }) {
    final paths = <String, Map<String, dynamic>>{};
    final sortedKeys = _operations.keys.toList()..sort();
    for (final key in sortedKeys) {
      final state = _operations[key]!;
      final pathEntry = paths.putIfAbsent(
        state.operation.path,
        () => <String, dynamic>{},
      );
      pathEntry[state.operation.method.name] = state.toOpenApiOperation();
    }

    return <String, dynamic>{
      'openapi': '3.1.0',
      'info': <String, dynamic>{'title': title, 'version': version},
      'paths': paths,
      if (knownOperations.isNotEmpty)
        'x-apidash-gaps': [
          for (final gap in detectGaps(knownOperations))
            <String, dynamic>{
              'method': gap.method.name.toUpperCase(),
              'path': gap.path,
              if (gap.operationId != null) 'operationId': gap.operationId,
            },
        ],
    };
  }
}

class _ObservedOperationState {
  _ObservedOperationState(this.operation);

  final ApiTestOperationMetadata operation;
  final Map<String, _ObservedResponseState> responses = {};

  void observe(HttpResponseModel response) {
    final statusCode = (response.statusCode ?? 200).toString();
    final responseState = responses.putIfAbsent(
      statusCode,
      _ObservedResponseState.new,
    );
    responseState.observe(response);
  }

  Map<String, dynamic> toOpenApiOperation() {
    final responseEntries = <String, dynamic>{};
    final sortedStatusCodes = responses.keys.toList()..sort();
    for (final statusCode in sortedStatusCodes) {
      responseEntries[statusCode] = responses[statusCode]!.toOpenApiResponse(
        statusCode,
      );
    }

    return <String, dynamic>{
      if (operation.operationId != null) 'operationId': operation.operationId,
      'responses': responseEntries,
    };
  }
}

class _ObservedResponseState {
  int observations = 0;
  String? contentType;
  bool hasObservedBody = false;
  final _SchemaAccumulator schemaAccumulator = _SchemaAccumulator();

  void observe(HttpResponseModel response) {
    observations += 1;
    final normalizedContentType = _normalizeContentType(response.contentType);
    contentType = normalizedContentType ?? contentType ?? 'application/json';

    final schemaInput = _bodyToSchemaInput(response);
    if (schemaInput is _NoBody) {
      return;
    }

    hasObservedBody = true;
    schemaAccumulator.merge(schemaInput);
  }

  Map<String, dynamic> toOpenApiResponse(String statusCode) {
    final response = <String, dynamic>{
      'description': 'Observed response for HTTP $statusCode',
      'x-apidash-observations': observations,
    };

    if (hasObservedBody) {
      response['content'] = <String, dynamic>{
        contentType ?? 'application/json': <String, dynamic>{
          'schema': schemaAccumulator.toSchemaJson(),
        },
      };
    }

    return response;
  }
}

class _SchemaAccumulator {
  final Set<String> _observedTypes = <String>{};
  final Map<String, _SchemaAccumulator> _properties = {};
  final Map<String, int> _propertyPresenceCounts = {};
  _SchemaAccumulator? _items;
  int _observationCount = 0;
  dynamic _latestExample;

  void merge(dynamic value) {
    _observationCount += 1;
    _latestExample = _jsonSafeCopy(value);

    if (value == null) {
      _observedTypes.add('null');
      return;
    }

    if (value is Map) {
      _observedTypes.add('object');
      for (final entry in value.entries) {
        final key = entry.key.toString();
        _propertyPresenceCounts.update(
          key,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        final propertyAccumulator = _properties.putIfAbsent(
          key,
          _SchemaAccumulator.new,
        );
        propertyAccumulator.merge(entry.value);
      }
      return;
    }

    if (value is List) {
      _observedTypes.add('array');
      if (value.isEmpty) {
        return;
      }
      final itemAccumulator = _items ??= _SchemaAccumulator();
      for (final item in value) {
        itemAccumulator.merge(item);
      }
      return;
    }

    if (value is bool) {
      _observedTypes.add('boolean');
      return;
    }

    if (value is int) {
      _observedTypes.add('integer');
      return;
    }

    if (value is double || value is num) {
      _observedTypes.add('number');
      return;
    }

    _observedTypes.add('string');
  }

  Map<String, dynamic> toSchemaJson() {
    final schema = <String, dynamic>{'type': _buildTypeValue()};

    if (_observedTypes.contains('object')) {
      schema['properties'] = <String, dynamic>{
        for (final entry in _sortedProperties())
          entry.key: entry.value.toSchemaJson(),
      };
      final requiredKeys = _requiredKeys();
      if (requiredKeys.isNotEmpty) {
        schema['required'] = requiredKeys;
      }
      if (_latestExample is Map) {
        schema['example'] = _latestExample;
      }
    } else if (_observedTypes.contains('array')) {
      if (_items != null) {
        schema['items'] = _items!.toSchemaJson();
      }
      if (_latestExample is List) {
        schema['example'] = _latestExample;
      }
    } else if (_latestExample != null) {
      schema['example'] = _latestExample;
    }

    return schema;
  }

  List<MapEntry<String, _SchemaAccumulator>> _sortedProperties() {
    final entries = _properties.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return entries;
  }

  List<String> _requiredKeys() {
    final requiredKeys =
        _propertyPresenceCounts.entries
            .where((entry) => entry.value == _observationCount)
            .map((entry) => entry.key)
            .toList()
          ..sort();
    return requiredKeys;
  }

  Object _buildTypeValue() {
    final orderedTypes = _observedTypes.toList()
      ..sort(
        (left, right) => _typeSortIndex(left).compareTo(_typeSortIndex(right)),
      );
    if (orderedTypes.length == 1) {
      return orderedTypes.first;
    }
    return orderedTypes;
  }
}

class _NoBody {
  const _NoBody();
}

dynamic _bodyToSchemaInput(HttpResponseModel response) {
  final body = response.body;
  final contentLength = int.tryParse(response.headers?['content-length'] ?? '');
  if ((body == null || body.isEmpty) &&
      (contentLength == null || contentLength == 0)) {
    return const _NoBody();
  }

  final normalizedContentType = _normalizeContentType(response.contentType);
  if ((normalizedContentType?.contains('json') ?? false) && body != null) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return body;
    }
  }

  if (body == null) {
    return null;
  }

  final trimmed = body.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      return body;
    }
  }

  return body;
}

String? _normalizeContentType(String? value) {
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  return value.split(';').first.trim().toLowerCase();
}

dynamic _jsonSafeCopy(dynamic value) {
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  try {
    return jsonDecode(jsonEncode(value));
  } catch (_) {
    return value.toString();
  }
}

int _typeSortIndex(String type) {
  switch (type) {
    case 'object':
      return 0;
    case 'array':
      return 1;
    case 'string':
      return 2;
    case 'integer':
      return 3;
    case 'number':
      return 4;
    case 'boolean':
      return 5;
    case 'null':
      return 6;
    default:
      return 99;
  }
}