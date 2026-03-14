require 'sinatra'
require 'sinatra/json'
require 'sqlite3'
require 'net/http'
require 'json'
require 'securerandom'
require 'ruby_llm'
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
  config.openai_api_key  = ENV.fetch('OPENAI_API_KEY', nil)
end

ORDER_AGENT_SYSTEM_PROMPT = <<~PROMPT
  You are a debugging agent for the Order Service — a Sinatra-based Ruby microservice.
  You respond ONLY to the orchestrator agent, never directly to end users.

  Think step by step before acting:

  1. THINK: Read the prompt carefully. What endpoint is being debugged? What params were sent? What response was received?
  2. READ: Use ReadCodebase to load the source code and find the relevant endpoint.
  3. TRACE: Walk through the code line by line. For each variable, determine its value given the params.
     - If a value depends on DB state you don't know, use AskUser to ask.
     - If the code makes an HTTP call to another service (e.g. inventory), use AskOrchestrator to ask what that service would return for those specific params. Do NOT guess — wait for the answer.
  4. REASON: Once you have all values, compare the traced execution path with the user-reported response. Identify where they diverge.
  5. RESPOND: Provide your analysis conversationally — explain what you found, what the code does, and where the issue is.

  Important:
  - Always read the code first before reasoning about it.
  - Never guess what another service returns — ask the orchestrator.
  - If you're missing any piece of information, ask for it before continuing.
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

  # Check availability
  status, result = inventory_get("/products/#{product_id}/availability?quantity=#{quantity}")
  halt status, json(result) if status != 200
  halt 422, json(error: 'Wont able to place order') unless result['available']

  # Get product details for price
  status, product = inventory_get("/products/#{product_id}")
  halt status, json(product) if status != 200

  # Deduct stock
  status, deduct_result = inventory_patch("/products/#{product_id}/stock", { quantity: -quantity })
  halt status, json(deduct_result) if status != 200

  # Create order
  total = product['price'] * quantity
  db.execute('INSERT INTO orders (product_id, quantity, total_price) VALUES (?, ?, ?)',
             [product_id, quantity, total])
  order_id = db.last_insert_row_id
  json db.execute('SELECT * FROM orders WHERE id = ?', order_id).first
end

# List all orders
get '/orders' do
  json db.execute('SELECT * FROM orders')
end

# Get a single order
get '/orders/:id' do
  order = db.execute('SELECT * FROM orders WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Order not found') unless order
  json order
end

# Agent endpoint — accepts a prompt and debugs using LLM + tools
# Supports multi-turn conversations via session_id (UUID).
# - No session_id: creates a new session, returns the session_id.
# - With session_id: loads history from the session markdown file and continues.

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
    "\n\n<conversation-history>\n#{conversation}\n</conversation-history>\n\nContinue from where you left off. The orchestrator is replying to your last message. Analyze their response and proceed with the next step of your trace."
  else
    ""
  end

  system_prompt = "#{ORDER_AGENT_SYSTEM_PROMPT}#{history_context}"

  chat = RubyLLM.chat(model: 'gpt-4-turbo', provider: :openai)
    .with_instructions(system_prompt)
    .with_tools(ReadCodebase, AskOrchestrator, AskUser)
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
