import 'package:apidash/services/agentic_services/api_testing/api_testing_ai.dart';
import 'package:apidash/templates/templates.dart';
import 'package:apidash_core/apidash_core.dart';

class ApiAssertionGenerationAgent extends AIAgent {
  @override
  String get agentName => 'API_ASSERTION_GENERATION';

  @override
  String getSystemPrompt() {
    return kPromptApiAssertionGeneration;
  }

  @override
  Future<bool> validator(String aiResponse) async {
    try {
      ApiTestingAiParser.parseAssertionSuggestions(aiResponse);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<dynamic> outputFormatter(String validatedResponse) async {
    final suggestions = ApiTestingAiParser.parseAssertionSuggestions(
      validatedResponse,
    );
    return {
      'ASSERTIONS': suggestions
          .map((suggestion) => suggestion.toJson())
          .toList(),
    };
  }
}