require 'sinatra'
require 'sinatra/json'
require 'net/http'
require 'json'
require 'securerandom'
require 'ruby_llm'
require_relative 'agent_tools'

set :port, 4000
set :bind, '0.0.0.0'
set :logging, true

before do
  if request.request_method != 'GET'
    request.body.rewind
    body = request.body.read
    request.body.rewind
    logger.info "[#{request.request_method}] #{request.path_info} params=#{body}"
  else
    logger.info "[GET] #{request.path_info} params=#{params}"
  end
end

RubyLLM.configure do |config|
  config.openai_api_key  = ENV.fetch('OPENAI_API_KEY', nil)
end

COORDINATOR_SYSTEM_PROMPT = <<~PROMPT
  You are the orchestrator agent for a microservices system with two services:

  1. Order Service (POST /orders, GET /orders, GET /orders/:id)
  2. Inventory Service (GET /products, POST /products, PATCH /products/:id/stock, GET /products/:id/availability)

  You are the single entry point. The user talks only to you.

  Think step by step:

  1. UNDERSTAND: What is the user asking? Which service(s) does it involve?
  2. ROUTE: Send the query to the right service agent (AskOrderAgent or AskInventoryAgent). Be specific in your prompt — include the endpoint, params, and response the user mentioned.
  3. REVIEW: Read the agent's response carefully.
     - If the agent asks a question (e.g. "what would the inventory service return for GET /products/1?"), route that question to the appropriate other agent and send the answer back.
     - If the agent needs user input (e.g. DB state), relay the question to the user via AskUser.
     - If the response is incomplete, ask the agent for more detail.
  4. ITERATE: Keep going until you have a complete picture. Cross-service flows may require multiple rounds between agents.
  5. RESPOND: Give the user a clear, consolidated answer.
  6. SAVEPOINT: Please save conversation state before asking question to user so we can resume later. when user provides answer to question, reintiate the discussion with same agent who asked the question previsouly
  Important:
  - Service agents may ask you questions — always answer them by querying the other agent or the user.
  - Don't just pass through raw agent responses. Synthesize and explain.
  - If a query spans both services, coordinate between them until the full flow is traced.
PROMPT

SESSIONS_DIR = File.join(__dir__, 'sessions')
Dir.mkdir(SESSIONS_DIR) unless Dir.exist?(SESSIONS_DIR)

def session_path(session_id)
  File.join(SESSIONS_DIR, "#{session_id}.md")
end

def load_session(session_id)
  path = session_path(session_id)
  return [] unless File.exist?(path)

  messages = []
  current_role = nil
  current_content = []

  File.readlines(path).each do |line|
    if line.match?(/^## (user|assistant)$/)
      if current_role
        messages << { role: current_role, content: current_content.join.strip }
      end
      current_role = line.strip.sub('## ', '')
      current_content = []
    else
      current_content << line
    end
  end

  if current_role
    messages << { role: current_role, content: current_content.join.strip }
  end

  messages
end

def append_to_session(session_id, role, content)
  File.open(session_path(session_id), 'a') do |f|
    f.puts "\n## #{role}\n\n#{content}\n"
  end
end

post '/agent' do
  data = JSON.parse(request.body.read)
  prompt = data['prompt']
  halt 400, json(error: 'prompt is required') unless prompt && !prompt.strip.empty?

  session_id = data['session_id'] || SecureRandom.uuid

  # Build system prompt with conversation history so the LLM resumes, not restarts
  history = load_session(session_id)
  history_context = if history.any?
    conversation = history.map { |m| "#{m[:role].upcase}: #{m[:content]}" }.join("\n\n")
    "\n\n<conversation-history>\n#{conversation}\n</conversation-history>\n\nContinue from where you left off. The user is replying to your last message. Analyze their response and proceed with the next step."
  else
    ""
  end

  system_prompt = "#{COORDINATOR_SYSTEM_PROMPT}#{history_context}"

  chat = RubyLLM.chat(model: 'gpt-4-turbo', provider: :openai)
    .with_instructions(system_prompt)
    .with_tools(AskOrderAgent.new(session_id), AskInventoryAgent.new(session_id), AskUser)
    .on_tool_call do |tool_call|
        puts "Calling tool: #{tool_call.name}"
      end
      .on_tool_result do |result|
        puts "Tool returned: #{result}"
      end

  response = chat.ask(prompt)

  # Persist both sides
  append_to_session(session_id, 'user', prompt)
  append_to_session(session_id, 'assistant', response.content)

  json({ session_id: session_id, response: response.content })
rescue => e
  status 500
  json({ error: e.message })
end
