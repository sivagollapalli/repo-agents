require 'sinatra'
require 'sinatra/json'
require 'sqlite3'
require 'net/http'
require 'json'
require 'securerandom'
require 'ruby_llm'
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
  config.openai_api_key  = ENV.fetch('OPENAI_API_KEY', nil)
end

INVENTORY_AGENT_SYSTEM_PROMPT = <<~PROMPT
  You are a debugging agent for the Inventory Service — a Sinatra-based Ruby microservice.
  You respond ONLY to the orchestrator agent, never directly to end users.

  Think step by step before acting:

  1. THINK: Read the prompt carefully. What endpoint is being debugged? What params were sent? What response was received?
  2. READ: Use ReadCodebase to load the source code and find the relevant endpoint.
  3. TRACE: Walk through the code line by line. For each variable, determine its value given the params.
     - If a value depends on DB state you don't know, use AskUser to ask.
     - If the code makes an HTTP call to another service (e.g. order), use AskOrchestrator to ask what that service would return for those specific params. Do NOT guess — wait for the answer.
  4. REASON: Once you have all values, compare the traced execution path with the user-reported response. Identify where they diverge.
  5. RESPOND: Provide your analysis conversationally — explain what you found, what the code does, and where the issue is.

  Important:
  - Always read the code first before reasoning about it.
  - Never guess what another service returns — ask the orchestrator.
  - If you're missing any piece of information, ask for it before continuing.
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

# List all products
get '/products' do
  json db.execute('SELECT * FROM products')
end

# Get a single product
get '/products/:id' do
  product = db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Product not found') unless product
  json product
end

# Create a product
post '/products' do
  data = JSON.parse(request.body.read)
  db.execute('INSERT INTO products (name, price, stock) VALUES (?, ?, ?)',
             [data['name'], data['price'], data['stock'] || 0])
  id = db.last_insert_row_id
  json db.execute('SELECT * FROM products WHERE id = ?', id).first
end

# Update stock
patch '/products/:id/stock' do
  data = JSON.parse(request.body.read)
  product = db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Product not found') unless product

  new_stock = product['stock'] + data['quantity']
  halt 422, json(error: 'wont place the order') if new_stock < 0

  db.execute('UPDATE products SET stock = ? WHERE id = ?', [new_stock, params[:id]])
  json db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
end

# Check stock availability
get '/products/:id/availability' do
  product = db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Product not found') unless product

  quantity = (params[:quantity] || 1).to_i
  json(available: product['stock'] >= quantity, stock: product['stock'])
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

  system_prompt = "#{INVENTORY_AGENT_SYSTEM_PROMPT}#{history_context}"

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
