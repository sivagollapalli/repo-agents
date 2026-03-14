require 'ruby_llm'

# Tool to read the order service codebase
class ReadCodebase < RubyLLM::Tool
  description "Reads the order service source code (app.rb) so you can understand and reason about the endpoints, logic, and database schema."

  def execute
    File.read(File.join(__dir__, 'app.rb'))
  end
end

# Tool to ask the orchestrator a question when something is missing.
class AskOrchestrator < RubyLLM::Tool
  description <<~DESC
    Ask the orchestrator agent a question. Use this when:
    - The code makes an HTTP call to another service (e.g. inventory service) and you need to know what it would return for specific params.
    - You need information that is outside your scope (you only know about the order service).
    - You need DB state or runtime values that only the user can provide.
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
