require 'sinatra'
require 'sinatra/json'
require 'sqlite3'
require 'net/http'
require 'json'
require 'securerandom'
require 'ruby_llm'
require_relative '../shared-memory/session'
require_relative 'agent_tools'

set :port, 4002
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

INVENTORY_URL = ENV.fetch('INVENTORY_URL', 'http://localhost:4001')

RubyLLM.configure do |config|
  config.openai_api_key = ENV.fetch('OPENAI_API_KEY', nil)
end

ORDER_AGENT_SYSTEM_PROMPT = <<~PROMPT
  You are a debugging agent for the Order Service — a Sinatra-based Ruby microservice.
  You respond ONLY to the orchestrator agent, never directly to end users.

  Think step by step before acting:

  1. THINK: Read the prompt carefully. What endpoint is being debugged? What params were sent? What response was received?
  2. READ: Use ReadCodebase to load the source code and find the relevant endpoint.
  3. TRACE: Walk through the code line by line. For each variable, determine its value given the params.
     - If a value depends on DB state you don't know, use AskOrchestrator to ask.
     - If the code makes an HTTP call to another service (e.g. inventory), use AskOrchestrator to ask what that service would return for those specific params. Do NOT guess — wait for the answer.
  4. REASON: Once you have all values, compare the traced execution path with the user-reported response. Identify where they diverge.
  5. RESPOND: Provide your analysis conversationally — explain what you found, what the code does, and where the issue is.

  Important:
  - Always read the code first before reasoning about it.
  - Never guess what another service returns — ask the orchestrator.
  - If you're missing any piece of information, ask for it before continuing.
  - The shared memory conversation history is provided below. When history exists, the orchestrator is continuing a conversation — resume from there.
PROMPT

def db
  @db ||= begin
    db = SQLite3::Database.new('orders.db')
    db.results_as_hash = true
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS orders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL,
        quantity INTEGER NOT NULL,
        total_price REAL NOT NULL,
        status TEXT NOT NULL DEFAULT 'confirmed',
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
    SQL
    db
  end
end

def inventory_get(path)
  uri = URI("#{INVENTORY_URL}#{path}")
  response = Net::HTTP.get_response(uri)
  [response.code.to_i, JSON.parse(response.body)]
rescue StandardError => e
  [503, { 'error' => "Inventory service unavailable: #{e.message}" }]
end

def inventory_patch(path, body)
  uri = URI("#{INVENTORY_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  req = Net::HTTP::Patch.new(uri.path, 'Content-Type' => 'application/json')
  req.body = body.to_json
  response = http.request(req)
  [response.code.to_i, JSON.parse(response.body)]
rescue StandardError => e
  [503, { 'error' => "Inventory service unavailable: #{e.message}" }]
end

# Place an order
post '/orders' do
  data = JSON.parse(request.body.read)
  product_id = data['product_id']
  quantity = data['quantity'] || 1

  status, result = inventory_get("/products/#{product_id}/availability?quantity=#{quantity}")
  halt status, json(result) if status != 200
  halt 422, json(error: 'Wont able to place order') unless result['available']

  status, product = inventory_get("/products/#{product_id}")
  halt status, json(product) if status != 200

  status, deduct_result = inventory_patch("/products/#{product_id}/stock", { quantity: -quantity })
  halt status, json(deduct_result) if status != 200

  total = product['price'] * quantity
  db.execute('INSERT INTO orders (product_id, quantity, total_price) VALUES (?, ?, ?)',
             [product_id, quantity, total])
  order_id = db.last_insert_row_id
  json db.execute('SELECT * FROM orders WHERE id = ?', order_id).first
end

get '/orders' do
  json db.execute('SELECT * FROM orders')
end

get '/orders/:id' do
  order = db.execute('SELECT * FROM orders WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Order not found') unless order
  json order
end

post '/agent' do
  data = JSON.parse(request.body.read)
  prompt = data['prompt']
  halt 400, json(error: 'prompt is required') unless prompt && !prompt.strip.empty?

  session_id = data['session_id']
  halt 400, json(error: 'session_id is required') unless session_id

  # Record incoming prompt in shared memory
  SharedMemory.append(session_id, agent: 'orchestrator', type: 'question', content: "To order-service: #{prompt}")

  # Build system prompt with shared memory context
  history = SharedMemory.conversation_context(session_id)
  history_block = history.empty? ? "" : "\n\n<shared-memory>\n#{history}\n</shared-memory>\n\nResume from where the conversation left off. Analyze the orchestrator's message and proceed."

  system_prompt = "#{ORDER_AGENT_SYSTEM_PROMPT}#{history_block}"

  chat = RubyLLM.chat(model: 'gpt-4-turbo', provider: :openai)
    .with_instructions(system_prompt)
    .with_tools(ReadCodebase, AskOrchestrator, AskUser)
    .on_tool_call do |tool_call|
        puts "Calling tool: #{tool_call.name}"
        puts "Arguments: #{tool_call.arguments}"
      end
      .on_tool_result do |result|
        puts "Tool returned: #{result}"
      end

  response = chat.ask(prompt)

  # Record response in shared memory
  SharedMemory.append(session_id, agent: 'order-service', type: 'answer', content: response.content)

  json({ session_id: session_id, response: response.content })
rescue => e
  status 500
  json({ error: e.message })
end
