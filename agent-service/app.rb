require 'sinatra'
require 'sinatra/json'
require 'net/http'
require 'json'
require 'securerandom'
require 'ruby_llm'
require_relative '../shared-memory/session'
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
  config.openai_api_key = ENV.fetch('OPENAI_API_KEY', nil)
end

COORDINATOR_SYSTEM_PROMPT = <<~PROMPT
  You are the orchestrator agent for a microservices system with two services:

  1. Order Service (POST /orders, GET /orders, GET /orders/:id)
  2. Inventory Service (GET /products, POST /products, PATCH /products/:id/stock, GET /products/:id/availability)

  You are the single entry point. The user talks only to you.

  Think step by step:

  1. UNDERSTAND: What is the user asking? Which service(s) does it involve?
  2. ROUTE: Send the query to the right service agent (AskOrderAgent or AskInventoryAgent). Be specific — include endpoint, params, and response the user mentioned.
  3. REVIEW: Read the agent's response carefully.
     - If the agent asks a question (e.g. "what would the inventory service return for GET /products/1?"), route that question to the appropriate other agent and send the answer back.
     - If the agent needs user input (e.g. DB state), relay the question to the user via AskUser.
     - If the response is incomplete, ask the agent for more detail.
  4. ITERATE: Keep going until you have a complete picture. Cross-service flows may require multiple rounds between agents.
  5. RESPOND: Give the user a clear, consolidated answer.

  Important:
  - Service agents may ask you questions — always answer them by querying the other agent or the user.
  - Don't just pass through raw agent responses. Synthesize and explain.
  - If a query spans both services, coordinate between them until the full flow is traced.
  - The conversation history from shared memory is provided below. When history exists, the user is replying to your last message — resume from there, don't restart.
PROMPT

post '/agent' do
  data = JSON.parse(request.body.read)
  prompt = data['prompt']
  halt 400, json(error: 'prompt is required') unless prompt && !prompt.strip.empty?

  # Create or load session from shared memory
  session_id = data['session_id']
  if session_id
    session = SharedMemory.load_session(session_id)
    halt 404, json(error: 'session not found') unless session
  else
    session_id = SharedMemory.create_session
  end

  # Record user message in shared memory
  SharedMemory.append(session_id, agent: 'user', type: 'question', content: prompt)

  # Build system prompt with shared memory context
  history = SharedMemory.conversation_context(session_id)
  history_block = history.empty? ? "" : "\n\n<shared-memory>\n#{history}\n</shared-memory>\n\nResume from where the conversation left off. Analyze the user's reply and proceed."

  system_prompt = "#{COORDINATOR_SYSTEM_PROMPT}#{history_block}"

  chat = RubyLLM.chat(model: 'gpt-4-turbo', provider: :openai)
    .with_instructions(system_prompt)
    .with_tools(AskOrderAgent.new(session_id), AskInventoryAgent.new(session_id), AskUser)
    .on_tool_call do |tool_call|
        puts "Calling tool: #{tool_call.name}"
        puts "Arguments: #{tool_call.arguments}"
      end
      .on_tool_result do |result|
        puts "Tool returned: #{result}"
      end

  response = chat.ask(prompt)

  # Record orchestrator response in shared memory
  SharedMemory.append(session_id, agent: 'orchestrator', type: 'answer', content: response.content)

  json({ session_id: session_id, response: response.content })
rescue => e
  status 500
  json({ error: e.message })
end
