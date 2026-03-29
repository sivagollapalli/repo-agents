require 'agents'

class AskUserTool < Agents::Tool
  description "Ask the user a clarifying question when you need more information to continue tracing. Use when a variable's value depends on DB state, external input, or anything you cannot determine from the code alone."

  param :question, type: "string", desc: "The clarifying question to ask the user"

  def perform(tool_context, question:)
    # Store the question in shared state so the orchestrator knows to relay it
    tool_context.state[:pending_question] = question
    tool_context.state[:question_from] = tool_context.state[:current_agent] || "agent"
    "Question for user: #{question}"
  end
end
