import 'package:apidash/services/agentic_services/api_testing/api_testing_ai.dart';
import 'package:apidash/templates/templates.dart';
import 'package:apidash_core/apidash_core.dart';

class ApiChainBuilderAgent extends AIAgent {
  @override
  String get agentName => 'API_CHAIN_BUILDER';

  @override
  String getSystemPrompt() {
    return kPromptApiChainBuilder;
  }

  @override
  Future<bool> validator(String aiResponse) async {
    try {
      ApiTestingAiParser.parseChainPlan(aiResponse);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<dynamic> outputFormatter(String validatedResponse) async {
    final chainPlan = ApiTestingAiParser.parseChainPlan(validatedResponse);
    return {'CHAIN_PLAN': chainPlan.toJson()};
  }
}