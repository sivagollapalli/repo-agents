require 'ruby_llm'
require_relative '../shared-memory/session'

# Tool to ask the order-service agent
class AskOrderAgent < RubyLLM::Tool
  description "Sends a prompt to the order-service debugging agent. Use when the user's query is about orders, placing orders, order status, or any issue involving the order service endpoints (POST /orders, GET /orders, GET /orders/:id)."

  param :prompt, desc: "The debugging prompt to send to the order-service agent. Be specific — include endpoint, params, and response if available."

  def initialize(session_id)
    @session_id = session_id
  end

  def execute(prompt:)
    # Record what we're asking in shared memory
    SharedMemory.append(@session_id, agent: 'orchestrator', type: 'routing', content: "Asking order-service: #{prompt}")

    order_url = ENV.fetch('ORDER_URL', 'http://localhost:4002')
    uri = URI("#{order_url}/agent")
    http = Net::HTTP.new(uri.host, uri.port)
    req = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
    req.body = { prompt: prompt, session_id: @session_id }.to_json

    response = http.request(req)
    parsed = JSON.parse(response.body)

    # Record the agent's response in shared memory
    SharedMemory.append(@session_id, agent: 'order-service', type: 'answer', content: parsed['response'] || parsed.to_json)

    parsed
  rescue => e
    { error: "Order agent unavailable: #{e.message}" }
  end
end

# Tool to ask the inventory-service agent
class AskInventoryAgent < RubyLLM::Tool
  description "Sends a prompt to the inventory-service debugging agent. Use when the user's query is about products, stock, availability, or any issue involving the inventory service endpoints (GET /products, POST /products, PATCH /products/:id/stock, GET /products/:id/availability)."

  param :prompt, desc: "The debugging prompt to send to the inventory-service agent. Be specific — include endpoint, params, and response if available."

  def initialize(session_id)
    @session_id = session_id
  end

  def execute(prompt:)
    # Record what we're asking in shared memory
    SharedMemory.append(@session_id, agent: 'orchestrator', type: 'routing', content: "Asking inventory-service: #{prompt}")

    inventory_url = ENV.fetch('INVENTORY_URL', 'http://localhost:4001')
    uri = URI("#{inventory_url}/agent")
    http = Net::HTTP.new(uri.host, uri.port)
    req = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
    req.body = { prompt: prompt, session_id: @session_id }.to_json

    response = http.request(req)
    parsed = JSON.parse(response.body)

    # Record the agent's response in shared memory
    SharedMemory.append(@session_id, agent: 'inventory-service', type: 'answer', content: parsed['response'] || parsed.to_json)

    parsed
  rescue => e
    { error: "Inventory agent unavailable: #{e.message}" }
  end
end

# Tool to ask the user a clarifying question
class AskUser < RubyLLM::Tool
  description "Ask the user a clarifying question when you need more information to route or debug the issue."

  param :question, desc: "The clarifying question to ask the user"

  def execute(question:)
    { status: "question_for_user", question: question }
  end
end
