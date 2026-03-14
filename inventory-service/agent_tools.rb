require 'ruby_llm'

# Tool to read the inventory service codebase
class ReadCodebase < RubyLLM::Tool
  description "Reads the inventory service source code (app.rb) so you can understand and reason about the endpoints, logic, and database schema."

  def execute
    File.read(File.join(__dir__, 'app.rb'))
  end
end

# Tool to ask the orchestrator a question when something is missing.
# Use this when you encounter a cross-service HTTP call and need to know
# what the other service would return, or when you need any info that
# only the orchestrator can provide.
class AskOrchestrator < RubyLLM::Tool
  description <<~DESC
    Ask the orchestrator agent a question. Use this when:
    - The code makes an HTTP call to another service (e.g. order service) and you need to know what it would return for specific params.
    - You need information that is outside your scope (you only know about the inventory service).
    - You want the orchestrator to query the other service agent on your behalf.
    Be specific: include the endpoint, HTTP method, and params the code would send.
  DESC

  param :question, desc: "The question to ask the orchestrator. Be specific about what you need."

  def execute(question:)
    { status: "question_for_orchestrator", question: question }
  end
end

# Tool to ask the user a clarifying question
class AskUser < RubyLLM::Tool
  description "Ask the user a clarifying question when you need more information to continue tracing. Use this when a variable's value depends on DB state, external input, or anything you cannot determine from the code alone."

  param :question, desc: "The clarifying question to ask the user"

  def execute(question:)
    { status: "question_for_user", question: question }
  end
end
