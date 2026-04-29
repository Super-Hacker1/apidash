import 'dart:convert';

import 'package:apidash/models/models.dart';
import 'package:apidash/services/agentic_services/api_testing/api_testing.dart';
import 'package:apidash_core/apidash_core.dart';
import 'package:test/test.dart';

void main() {
  group('ApiTestingSelectorEngine', () {
    test('resolves selectors and evaluates assertion groups', () {
      const selectorEngine = ApiTestingSelectorEngine();
      final response = _jsonResponse(
        statusCode: 200,
        body: <String, dynamic>{
          'data': <String, dynamic>{
            'token': 'abc123',
            'email': 'raj@example.com',
          },
          'meta': <String, dynamic>{'total': 1},
          'items': [
            <String, dynamic>{'id': 10},
          ],
        },
        responseTimeMs: 245,
      );

      final tokenResolution = selectorEngine.resolve(
        const ApiTestSelector(
          type: ApiTestSelectorType.jsonPath,
          expression: r'$.data.token',
        ),
        response,
      );
      expect(tokenResolution.found, isTrue);
      expect(tokenResolution.value, 'abc123');

      final headerResolution = selectorEngine.resolve(
        const ApiTestSelector(
          type: ApiTestSelectorType.header,
          expression: 'Content-Type',
        ),
        response,
      );
      expect(headerResolution.found, isTrue);
      expect(headerResolution.value, 'application/json');

      final regexResolution = selectorEngine.resolve(
        const ApiTestSelector(
          type: ApiTestSelectorType.regex,
          expression: '"token"\\s*:\\s*"([^"]+)"',
        ),
        response,
      );
      expect(regexResolution.found, isTrue);
      expect(regexResolution.value, 'abc123');

      final groupResult = selectorEngine.evaluateGroup(
        ApiTestAssertionGroup(
          id: 'baseline',
          assertions: const [
            ApiTestAssertion(
              id: 'status',
              selector: ApiTestSelector(type: ApiTestSelectorType.statusCode),
              operator: ApiTestAssertionOperator.equals,
              expected: 200,
            ),
            ApiTestAssertion(
              id: 'content-type',
              selector: ApiTestSelector(
                type: ApiTestSelectorType.header,
                expression: 'content-type',
              ),
              operator: ApiTestAssertionOperator.contains,
              expected: 'application/json',
            ),
            ApiTestAssertion(
              id: 'response-time',
              selector: ApiTestSelector(type: ApiTestSelectorType.responseTime),
              operator: ApiTestAssertionOperator.lt,
              expected: 800,
            ),
          ],
        ),
        response,
      );

      expect(groupResult.passed, isTrue);
      expect(
        groupResult.assertionResults.every((assertion) => assertion.passed),
        isTrue,
      );
    });
  });

  group('ApiTestingWorkflowEngine', () {
    test(
      'chains extracted runtime variables into downstream requests',
      () async {
        final executedRequests = <RequestModel>[];

        Future<ApiTestExecutionResult> executor(RequestModel request) async {
          executedRequests.add(request);
          switch (request.id) {
            case 'login':
              expect(
                request.httpRequestModel?.headersMap['X-User'],
                'raj@example.com',
              );
              return _executionResult(
                request,
                _jsonResponse(
                  statusCode: 200,
                  body: <String, dynamic>{
                    'data': <String, dynamic>{'token': 'abc123'},
                  },
                  responseTimeMs: 180,
                ),
              );
            case 'profile':
              expect(
                request.httpRequestModel?.headersMap['Authorization'],
                'Bearer abc123',
              );
              return _executionResult(
                request,
                _jsonResponse(
                  statusCode: 200,
                  body: <String, dynamic>{
                    'data': <String, dynamic>{'id': 1, 'name': 'Raj'},
                  },
                ),
              );
          }
          fail('Unexpected request ${request.id}');
        }

        final engine = ApiTestingWorkflowEngine(requestExecutor: executor);
        final result = await engine.run(
          [
            ApiTestStep(
              id: 'login-step',
              name: 'Login',
              operation: const ApiTestOperationMetadata(
                method: HTTPVerb.post,
                path: '/auth/login',
                operationId: 'login',
              ),
              requestModel: RequestModel(
                id: 'login',
                httpRequestModel: const HttpRequestModel(
                  method: HTTPVerb.post,
                  url: 'https://api.example.com/auth/login',
                  headers: [
                    NameValueModel(name: 'X-User', value: '{{AUTH_USER}}'),
                  ],
                ),
              ),
              assertionGroups: const [
                ApiTestAssertionGroup(
                  id: 'login-assertions',
                  assertions: [
                    ApiTestAssertion(
                      id: 'login-status',
                      selector: ApiTestSelector(
                        type: ApiTestSelectorType.statusCode,
                      ),
                      operator: ApiTestAssertionOperator.equals,
                      expected: 200,
                    ),
                    ApiTestAssertion(
                      id: 'token-exists',
                      selector: ApiTestSelector(
                        type: ApiTestSelectorType.jsonPath,
                        expression: r'$.data.token',
                      ),
                      operator: ApiTestAssertionOperator.exists,
                    ),
                  ],
                ),
              ],
              extractions: const [
                ApiTestExtraction(
                  variableName: 'AUTH_TOKEN',
                  selector: ApiTestSelector(
                    type: ApiTestSelectorType.jsonPath,
                    expression: r'$.data.token',
                  ),
                ),
              ],
            ),
            ApiTestStep(
              id: 'profile-step',
              name: 'Profile',
              operation: const ApiTestOperationMetadata(
                method: HTTPVerb.get,
                path: '/users/me',
                operationId: 'me',
              ),
              requestModel: RequestModel(
                id: 'profile',
                httpRequestModel: const HttpRequestModel(
                  method: HTTPVerb.get,
                  url: 'https://api.example.com/users/me',
                  headers: [
                    NameValueModel(
                      name: 'Authorization',
                      value: 'Bearer {{AUTH_TOKEN}}',
                    ),
                  ],
                ),
              ),
              assertionGroups: const [
                ApiTestAssertionGroup(
                  id: 'profile-assertions',
                  assertions: [
                    ApiTestAssertion(
                      id: 'profile-status',
                      selector: ApiTestSelector(
                        type: ApiTestSelectorType.statusCode,
                      ),
                      operator: ApiTestAssertionOperator.equals,
                      expected: 200,
                    ),
                  ],
                ),
              ],
            ),
          ],
          initialVariables: const <String, String>{
            'AUTH_USER': 'raj@example.com',
          },
        );

        expect(result.passed, isTrue);
        expect(result.runtimeVariables['AUTH_TOKEN'], 'abc123');
        expect(executedRequests, hasLength(2));
        expect(result.uncoveredOperations, isEmpty);

        final paths = result.openApiDocument['paths'] as Map<String, dynamic>;
        expect(paths.containsKey('/auth/login'), isTrue);
        expect(paths.containsKey('/users/me'), isTrue);
      },
    );

    test('aborts the chain immediately after a failed gate', () async {
      var callCount = 0;

      Future<ApiTestExecutionResult> executor(RequestModel request) async {
        callCount += 1;
        if (request.id == 'login') {
          return _executionResult(
            request,
            _jsonResponse(
              statusCode: 401,
              body: <String, dynamic>{'error': 'invalid_credentials'},
            ),
          );
        }
        fail('Downstream request should not execute after abort.');
      }

      final engine = ApiTestingWorkflowEngine(requestExecutor: executor);
      final result = await engine.run([
        ApiTestStep(
          id: 'login-step',
          name: 'Login',
          requestModel: RequestModel(
            id: 'login',
            httpRequestModel: const HttpRequestModel(
              method: HTTPVerb.post,
              url: 'https://api.example.com/auth/login',
            ),
          ),
          assertionGroups: const [
            ApiTestAssertionGroup(
              id: 'must-succeed',
              assertions: [
                ApiTestAssertion(
                  id: 'status-200',
                  selector: ApiTestSelector(
                    type: ApiTestSelectorType.statusCode,
                  ),
                  operator: ApiTestAssertionOperator.equals,
                  expected: 200,
                ),
              ],
            ),
          ],
        ),
        ApiTestStep(
          id: 'profile-step',
          name: 'Profile',
          requestModel: RequestModel(
            id: 'profile',
            httpRequestModel: const HttpRequestModel(
              method: HTTPVerb.get,
              url: 'https://api.example.com/users/me',
            ),
          ),
        ),
      ]);

      expect(result.passed, isFalse);
      expect(result.abortedAtStepId, 'login-step');
      expect(callCount, 1);
      expect(result.stepResults.single.outcome, ApiTestStepOutcome.aborted);
    });
  });

  group('ApiTestingOpenApiAccumulator', () {
    test('merges optional and nullable fields across observations', () {
      final accumulator = ApiTestingOpenApiAccumulator();
      const createUserOperation = ApiTestOperationMetadata(
        method: HTTPVerb.post,
        path: '/users',
        operationId: 'createUser',
      );

      accumulator.observe(
        operation: createUserOperation,
        response: _jsonResponse(
          statusCode: 200,
          body: <String, dynamic>{'id': 1, 'email': 'raj@example.com'},
        ),
      );
      accumulator.observe(
        operation: createUserOperation,
        response: _jsonResponse(
          statusCode: 200,
          body: <String, dynamic>{
            'id': 2,
            'email': 'jay@example.com',
            'avatar': 'https://cdn.example.com/avatar/2.png',
          },
        ),
      );
      accumulator.observe(
        operation: createUserOperation,
        response: _jsonResponse(
          statusCode: 200,
          body: <String, dynamic>{
            'id': 3,
            'email': 'arjun@example.com',
            'avatar': null,
          },
        ),
      );

      final document = accumulator.buildDocument(
        knownOperations: const [
          createUserOperation,
          ApiTestOperationMetadata(method: HTTPVerb.get, path: '/health'),
        ],
      );

      final paths = document['paths'] as Map<String, dynamic>;
      final usersPath = paths['/users'] as Map<String, dynamic>;
      final postOperation = usersPath['post'] as Map<String, dynamic>;
      final responses = postOperation['responses'] as Map<String, dynamic>;
      final okResponse = responses['200'] as Map<String, dynamic>;
      final content = okResponse['content'] as Map<String, dynamic>;
      final schema =
          (content['application/json'] as Map<String, dynamic>)['schema']
              as Map<String, dynamic>;
      final properties = schema['properties'] as Map<String, dynamic>;
      final avatarSchema = properties['avatar'] as Map<String, dynamic>;
      final avatarTypes = avatarSchema['type'] as List<dynamic>;
      final required = (schema['required'] as List).cast<String>();
      final gaps = document['x-apidash-gaps'] as List<dynamic>;

      expect(avatarTypes, containsAll(<String>['string', 'null']));
      expect(required, isNot(contains('avatar')));
      expect(gaps, hasLength(1));
      expect((gaps.first as Map)['path'], '/health');
    });
  });

  group('ApiTestingAiParser', () {
    test('parses fenced JSON responses for all AI helpers', () {
      final suggestions = ApiTestingAiParser.parseAssertionSuggestions('''
```json
[
  {
    "selector_type": "status_code",
    "path": null,
    "operator": "equals",
    "expected": 200,
    "description": "status is successful"
  }
]
```''');
      expect(suggestions, hasLength(1));
      expect(suggestions.single.selector.type, ApiTestSelectorType.statusCode);

      final explanation = ApiTestingAiParser.parseFailureExplanation('''
{
  "summary": "Login failed before token extraction.",
  "root_cause": "Credentials are invalid.",
  "likely_culprit_variables": ["AUTH_USER"],
  "suggested_fixes": ["Update AUTH_USER in the active environment."]
}
''');
      expect(explanation.rootCause, 'Credentials are invalid.');
      expect(explanation.likelyCulpritVariables, contains('AUTH_USER'));

      final chainPlan = ApiTestingAiParser.parseChainPlan('''
{
  "summary": "Authenticate and then fetch the profile.",
  "steps": [
    {
      "request_id": "login",
      "purpose": "Obtain an access token",
      "consumes_variables": [],
      "produces_variables": {
        "AUTH_TOKEN": "\$.data.token"
      },
      "on_failure": "abort"
    }
  ]
}
''');
      expect(chainPlan.steps.single.requestId, 'login');
      expect(
        chainPlan.steps.single.producesVariables['AUTH_TOKEN'],
        r'$.data.token',
      );
    });
  });
}

ApiTestExecutionResult _executionResult(
  RequestModel request,
  HttpResponseModel response,
) {
  return ApiTestExecutionResult(
    executedRequest: request.copyWith(
      responseStatus: response.statusCode,
      httpResponseModel: response,
    ),
    response: response,
    responseStatus: response.statusCode,
  );
}

HttpResponseModel _jsonResponse({
  required int statusCode,
  required Map<String, dynamic> body,
  int responseTimeMs = 120,
}) {
  final rawBody = jsonEncode(body);
  return HttpResponseModel(
    statusCode: statusCode,
    headers: <String, String>{
      'content-type': 'application/json',
      'content-length': utf8.encode(rawBody).length.toString(),
    },
    body: rawBody,
    formattedBody: rawBody,
    time: Duration(milliseconds: responseTimeMs),
  );
}