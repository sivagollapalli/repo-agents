require 'sinatra'
require 'sinatra/json'
require 'sqlite3'
require 'net/http'
require 'json'
require 'securerandom'
require 'ruby_llm'
require_relative '../shared-memory/session'
require_relative 'agent_tools'

set :port, 4001
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

INVENTORY_AGENT_SYSTEM_PROMPT = <<~PROMPT
  You are a debugging agent for the Inventory Service — a Sinatra-based Ruby microservice.
  You respond ONLY to the orchestrator agent, never directly to end users.

  Think step by step before acting:

  1. THINK: Read the prompt carefully. What endpoint is being debugged? What params were sent? What response was received?
  2. READ: Use ReadCodebase to load the source code and find the relevant endpoint.
  3. TRACE: Walk through the code line by line. For each variable, determine its value given the params.
     - If a value depends on DB state you don't know, use AskOrchestrator to ask.
     - If the code makes an HTTP call to another service (e.g. order), use AskOrchestrator to ask what that service would return for those specific params. Do NOT guess — wait for the answer.
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
    db = SQLite3::Database.new('inventory.db')
    db.results_as_hash = true
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        price REAL NOT NULL,
        stock INTEGER NOT NULL DEFAULT 0
      );
    SQL
    db
  end
end

get '/products' do
  json db.execute('SELECT * FROM products')
end

get '/products/:id' do
  product = db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Product not found') unless product
  json product
end

post '/products' do
  data = JSON.parse(request.body.read)
  db.execute('INSERT INTO products (name, price, stock) VALUES (?, ?, ?)',
             [data['name'], data['price'], data['stock'] || 0])
  id = db.last_insert_row_id
  json db.execute('SELECT * FROM products WHERE id = ?', id).first
end

patch '/products/:id/stock' do
  data = JSON.parse(request.body.read)
  product = db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Product not found') unless product

  new_stock = product['stock'] + data['quantity']
  halt 422, json(error: 'wont place the order') if new_stock < 0

  db.execute('UPDATE products SET stock = ? WHERE id = ?', [new_stock, params[:id]])
  json db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
end

get '/products/:id/availability' do
  product = db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Product not found') unless product

  quantity = (params[:quantity] || 1).to_i
  json(available: product['stock'] >= quantity, stock: product['stock'])
end

post '/agent' do
  data = JSON.parse(request.body.read)
  prompt = data['prompt']
  halt 400, json(error: 'prompt is required') unless prompt && !prompt.strip.empty?

  session_id = data['session_id']
  halt 400, json(error: 'session_id is required') unless session_id

  # Record incoming prompt in shared memory
  SharedMemory.append(session_id, agent: 'orchestrator', type: 'question', content: "To inventory-service: #{prompt}")

  # Build system prompt with shared memory context
  history = SharedMemory.conversation_context(session_id)
  history_block = history.empty? ? "" : "\n\n<shared-memory>\n#{history}\n</shared-memory>\n\nResume from where the conversation left off. Analyze the orchestrator's message and proceed."

  system_prompt = "#{INVENTORY_AGENT_SYSTEM_PROMPT}#{history_block}"

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
  SharedMemory.append(session_id, agent: 'inventory-service', type: 'answer', content: response.content)

  json({ session_id: session_id, response: response.content })
rescue => e
  status 500
  json({ error: e.message })
end
